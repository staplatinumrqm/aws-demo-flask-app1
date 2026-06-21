# Environments

Multi-environment is implemented with **Terraform workspaces**. Each workspace has its
own state (separate S3 backend key) and a name prefix from [`locals.tf`](../locals.tf):

| Workspace | `local.name` prefix | Purpose | Config |
|-----------|---------------------|---------|--------|
| `default` | `flask-pipeline`     | Production (the live stack) | `../terraform.tfvars` (git-ignored, holds secrets) |
| `dev`     | `flask-pipeline-dev` | On-demand dev environment   | `dev.tfvars` (this folder, no secrets) |

Account-wide resources (the GitHub OIDC provider and the CI/plan IAM roles) are created
**only in the `default` workspace** and reused by other environments.

## Stand up the dev environment

```bash
terraform workspace new dev          # first time only
terraform workspace select dev
terraform apply -var-file=environments/dev.tfvars
```

This creates a fully isolated `flask-pipeline-dev-*` stack (VPC, ALB, ECS, RDS, S3,
Cognito, API Gateway). Tear it down with `terraform destroy -var-file=environments/dev.tfvars`
to avoid ongoing cost.

## Back to production

```bash
terraform workspace select default
terraform plan        # uses terraform.tfvars
```
