# Load testing

Drives traffic at the deployed app to demonstrate ECS autoscaling.

## Prerequisites

Install [k6](https://k6.io/docs/get-started/installation/):

```powershell
winget install k6 --source winget
# or: choco install k6
```

## Run

```powershell
$alb = "http://<your-alb-dns-name>"      # terraform output alb_url
k6 run -e TARGET_URL=$alb cpu-load.js
```

## What to watch

Open the CloudWatch dashboard while the test runs:
`terraform output dashboard_url`

| Phase | What you should see |
|-------|--------------------|
| Ramp up (0–2m) | ECS **CPU utilization** climbs toward / past 60% |
| Sustain (2–8m) | `ecs-cpu-high` alarm; **task count scales 1 → up to 4** |
| Ramp down (8–10m) | Load drops; after the 5‑min scale‑in cooldown, **tasks return to 1** |

Verify task count from the CLI:

```powershell
aws ecs describe-services --cluster flask-pipeline --services flask-pipeline `
  --query "services[0].{desired:desiredCount,running:runningCount}"
```

The CPU work per request is controlled by `?ms=` in `cpu-load.js`; raise VUs or `ms`
to scale harder.
