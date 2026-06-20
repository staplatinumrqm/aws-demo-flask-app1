# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub's **Report a vulnerability**
(Security → Advisories) rather than opening a public issue. You'll get an
acknowledgement within a few days.

## Security measures in this project

- **No long-lived cloud credentials** — GitHub Actions authenticates to AWS via OIDC.
  The deploy role's trust is scoped to the `main` branch; the plan role is read-only.
- **Least-privilege IAM** for every role (task execution, task, CodeDeploy, CI).
- **Secrets in AWS Secrets Manager** — database and application secrets are injected
  into the container at launch; they never appear in source, the image, or Terraform
  state. The Google OAuth client secret lives in a git-ignored `terraform.tfvars`.
- **Federated authentication** via Amazon Cognito + Google (no passwords stored).
- **Container scanning** — Trivy scans every image for fixable CRITICAL CVEs before it
  is pushed to ECR; ECR also scans on push.
- **IaC scanning** — Trivy scans Terraform for misconfigurations on every PR; accepted
  risks are documented in `.trivyignore`.
- **Dependency hygiene** — Dependabot updates GitHub Actions, pip, and the base image
  weekly; the Trivy action is pinned to a commit SHA.
- **Network isolation** — ECS tasks accept traffic only from the ALB; RDS accepts
  traffic only from the tasks and lives in private subnets.
- **Non-root container** — the runtime image runs as an unprivileged user.

## Supported versions

Only the latest `main` is supported; deploys are continuous.
