# Flask on AWS ECS Fargate — Production-Style DevOps Platform

A containerized Flask REST API deployed to AWS with a full DevOps platform around it:
infrastructure as code, automated CI/CD with security gates, blue/green deployments,
observability, autoscaling, and remote Terraform state — all provisioned with Terraform
and shipped through GitHub Actions using OIDC (no long-lived AWS keys).

> Demonstrates: AWS (ECS Fargate, ALB, RDS, CodeDeploy, ECR, IAM, CloudWatch, Secrets
> Manager), Terraform, GitHub Actions CI/CD, container security scanning, blue/green
> deployments, and load-tested autoscaling.

---

## Architecture

```
                              Internet
                                 │  HTTP :80 (prod)  :8080 (test)
                                 ▼
                        ┌────────────────────┐
                        │  Application LB     │
                        └────────────────────┘
                          │ blue TG  │ green TG     ← CodeDeploy shifts traffic
                          ▼          ▼
                        ┌────────────────────┐      ECS SG: :5000 only from ALB SG
                        │  ECS Fargate tasks  │  ◄── autoscale 1→4 on CPU/memory
                        │  (Flask + gunicorn) │
                        └────────────────────┘
                          │ pulls image          │ SQL :5432 (private)
                          ▼                       ▼
                   ┌──────────────┐        ┌──────────────────┐
                   │  Amazon ECR  │        │  RDS PostgreSQL   │  (private subnets)
                   └──────────────┘        └──────────────────┘
                                                   ▲
                                            creds from Secrets Manager
```

All resources live in a single VPC: public subnets for the ALB and tasks, private
subnets for RDS. CloudWatch alarms feed an SNS topic and drive CodeDeploy auto-rollback.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| Application | Python, Flask, SQLAlchemy, gunicorn |
| Database | Amazon RDS PostgreSQL (credentials in Secrets Manager) |
| Container | Docker (multi-stage), Amazon ECR (scan-on-push) |
| Compute | Amazon ECS Fargate |
| Networking | VPC, public/private subnets, ALB, security groups |
| Deployment | AWS CodeDeploy (blue/green) |
| CI/CD | GitHub Actions + OIDC |
| IaC | Terraform (S3 + DynamoDB remote state) |
| Security | Trivy (image + IaC), least-privilege IAM, Dependabot |
| Observability | CloudWatch dashboards, alarms, SNS alerts |
| Autoscaling | Application Auto Scaling (target tracking) |

---

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Status page (shows item count) |
| `GET` | `/health` | Liveness + DB connectivity (ALB health check) |
| `GET` | `/api/items` | List items |
| `POST` | `/api/items` | Create item — `{"name", "description"}` |
| `GET` | `/api/items/<id>` | Fetch one item |
| `DELETE` | `/api/items/<id>` | Delete an item |
| `GET` | `/api/cpu?ms=<n>` | CPU-bound work (used to exercise autoscaling) |

---

## CI/CD pipelines (GitHub Actions)

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `app-ci.yml` | Pull request | Run pytest |
| `terraform-ci.yml` | PR / push (terraform/**) | `fmt`, `validate`, TFLint, Trivy IaC scan |
| `terraform-plan.yml` | PR (terraform/**) | `terraform plan` posted as a PR comment (read-only OIDC role) |
| `deploy.yml` | Push to main (app changes) | Test → build → Trivy image scan → push to ECR → CodeDeploy blue/green |

**Deploy flow:** authenticate via OIDC → build image → **Trivy scan (block on fixable
CRITICAL)** → push to ECR → render the live task definition with the new image →
CodeDeploy shifts traffic blue→green after health checks, with **automatic rollback**
if the CloudWatch 5xx alarm trips.

---

## Security

- **No static AWS credentials** — GitHub Actions authenticates via OIDC; the deploy
  role's trust is scoped to the `main` branch, and `plan` uses a separate read-only role.
- **Least-privilege IAM** for every role (task execution, task, CodeDeploy, CI).
- **DB credentials in Secrets Manager** — generated and rotated by RDS, injected into the
  task at launch; never in code or Terraform state.
- **Two-layer scanning** — Trivy on container images (CVEs) and on Terraform (misconfig).
- **Network isolation** — tasks accept traffic only from the ALB; RDS only from the tasks.
- **Documented risk acceptances** in [`.trivyignore`](.trivyignore).

---

## Observability & autoscaling

- **Dashboard**: ALB request count / HTTP codes / latency percentiles, ECS CPU & memory,
  healthy host counts.
- **Alarms → SNS email**: ALB 5xx (also drives rollback), target 5xx, p95 latency,
  ECS CPU, ECS memory.
- **Autoscaling**: target-tracking on CPU (60%) and memory (70%), 1–4 tasks. Verified
  under load — see [`loadtest/`](loadtest/).

---

## Repository layout

```
app/                 Flask application (+ entrypoint, templates)
tests/               pytest suite (runs on SQLite — no DB needed in CI)
terraform/           root config (ALB, ECS, CodeDeploy, IAM, observability)
  modules/
    networking/      VPC, subnets, route tables, security groups
    database/        RDS Postgres, subnet group, secret access
loadtest/            k6 script + dependency-free Python load generator
.github/workflows/   CI/CD pipelines
appspec.yaml         CodeDeploy ECS deployment spec
Dockerfile           multi-stage build
```

Reusable modules expose clean inputs/outputs; the root composes them and wires the
remaining resources. The refactor used Terraform `moved` blocks so resources were
relocated in state with **zero** infrastructure changes.

---

## Getting started

### Prerequisites
- AWS account + credentials configured locally
- Terraform >= 1.5, Docker, a GitHub repo

### Provision infrastructure
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
```

### Wire up GitHub Actions
Add these repo secrets (values from `terraform output`):
- `AWS_ROLE_ARN` → `github_actions_role_arn`
- `AWS_PLAN_ROLE_ARN` → `terraform_plan_role_arn`

Push to `main` to trigger the first deploy.

### Load test
See [`loadtest/README.md`](loadtest/README.md).

---

## Roadmap

- [x] CI/CD with OIDC, blue/green deploys, auto-rollback
- [x] Remote Terraform state (S3 + DynamoDB)
- [x] Security scanning (Trivy image + IaC), Dependabot
- [x] Observability (dashboard, alarms, SNS)
- [x] Autoscaling (load-tested)
- [x] RDS Postgres + functional CRUD API (Secrets Manager)
- [x] Refactor Terraform into reusable modules (`networking`, `database`)
- [ ] HTTPS via ACM + custom domain
