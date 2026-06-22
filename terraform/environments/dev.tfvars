# Dev environment — used with the Terraform `dev` workspace:
#
#   terraform workspace select dev   # (terraform workspace new dev) first time
#   terraform plan  -var-file=environments/dev.tfvars
#   terraform apply -var-file=environments/dev.tfvars
#
# The `dev` workspace suffixes every resource name (flask-pipeline-dev-*) and uses
# a separate state, so this is a fully isolated parallel stack. No secrets here —
# Google login is left unconfigured in dev (the login button reports "not configured").

aws_region    = "us-east-1"
app_name      = "flask-pipeline"
github_owner  = "maximcapsa"
github_repo   = "aws-demo-flask-app1"
github_branch = "main"

desired_count = 1
min_capacity  = 1
max_capacity  = 2
