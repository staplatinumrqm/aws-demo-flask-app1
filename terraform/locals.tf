# ── Environment / naming ──────────────────────────────────────────────────────
# Multi-environment via Terraform workspaces. The `default` workspace is the live
# production stack and keeps its original names (so existing resources are never
# renamed). Any other workspace (e.g. `dev`) gets a suffix, producing a fully
# isolated parallel stack with its own state (S3 backend keys per workspace).
#
#   terraform workspace new dev      # create the dev environment
#   terraform workspace select dev
#   terraform apply -var-file=environments/dev.tfvars
#
locals {
  environment = terraform.workspace == "default" ? "prod" : terraform.workspace

  # Resource name prefix: unchanged in prod, suffixed elsewhere.
  name = terraform.workspace == "default" ? var.app_name : "${var.app_name}-${terraform.workspace}"

  # Account-wide CI/OIDC resources live only in the default workspace; other
  # environments reuse them (one OIDC provider + CI roles per account).
  is_shared = terraform.workspace == "default"

  # Messaging: gate the RabbitMQ broker + worker behind a single flag. The app's
  # RABBITMQ_HOST resolves to the broker's Cloud Map DNS when enabled, or is left
  # empty so the producer no-ops instantly (no connect attempt) when disabled.
  messaging_count = var.enable_messaging ? 1 : 0
  rabbitmq_dns    = "rabbitmq.${local.name}.local"
  rabbitmq_host   = var.enable_messaging ? local.rabbitmq_dns : ""
}
