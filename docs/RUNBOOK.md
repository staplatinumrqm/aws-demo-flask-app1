# Runbook

Operational procedures for the Flask-on-ECS platform. Names assume the default
`app_name = flask-pipeline` in `us-east-1`.

## Quick reference

| Resource | Name / ID |
|----------|-----------|
| ECS cluster / service | `flask-pipeline` |
| CodeDeploy app / group | `flask-pipeline` / `flask-pipeline-dg` |
| Public HTTPS URL | API Gateway `app_https_url` output |
| Dashboard | `terraform output dashboard_url` |
| Logs | CloudWatch log group `/ecs/flask-pipeline` |

## Roll back a bad deploy

Blue/green rollback is **automatic** if the `flask-pipeline-alb-5xx-errors` alarm trips
during deployment. To roll back manually:

```bash
# Find the active deployment
aws deploy list-deployments --application-name flask-pipeline \
  --deployment-group-name flask-pipeline-dg --query "deployments[0]" --output text

# Stop + roll back to the previous task set
aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled
```

Or re-run the previous successful **CI/CD** workflow from the GitHub Actions UI.

## Scale the service

Autoscaling (CPU 60% / memory 70%) manages task count between `min_capacity` and
`max_capacity`. To change bounds, edit those vars and `terraform apply`. For an
immediate manual nudge:

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs --resource-id service/flask-pipeline/flask-pipeline \
  --scalable-dimension ecs:service:DesiredCount --min-capacity 2 --max-capacity 6
```

## Rotate the database password

The RDS master password is managed by RDS in Secrets Manager:

```bash
aws secretsmanager rotate-secret --secret-id <db_secret_arn>   # from terraform output
```

New tasks pick up the rotated value at next launch (force a new deployment to apply now).

## Rotate the Flask session key / Cognito client secret

These live in the `flask-pipeline-app-config` secret (set from Terraform). Update the
value via `terraform apply` (it re-generates `random_password` / re-reads the Cognito
secret), then trigger a deploy so tasks reload it.

## Rotate the Google OAuth client secret

1. Create a new secret in Google Cloud Console for the OAuth client.
2. Update `google_client_secret` in `terraform/terraform.tfvars` and the
   `GOOGLE_CLIENT_SECRET` GitHub secret.
3. `terraform apply` (updates the Cognito identity provider).

## Common issues

| Symptom | Likely cause / fix |
|---------|--------------------|
| `/health` returns 503 `database` | RDS unreachable — check the RDS SG allows the ECS SG on 5432, and RDS status is `available`. |
| Tasks die with exit code 137 | OOM or failed health check — check CloudWatch logs and task memory. |
| "Sign in with Google" → access blocked | OAuth consent screen still in *Testing*; add the user as a test user (or publish the app). |
| Deploy stuck in "Install" | New tasks failing health checks — inspect `/ecs/flask-pipeline` logs; CodeDeploy auto-rolls back after the alarm window. |
| CI plan shows spurious destroys | A `terraform.tfvars`-only variable isn't passed to CI — add it as a `TF_VAR_*` from a GitHub secret in `terraform-plan.yml`. |
