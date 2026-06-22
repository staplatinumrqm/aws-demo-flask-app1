# ── Cognito (user pool + hosted UI domain) ────────────────────────────────────
# Managed authentication. The hosted UI domain provides a free HTTPS sign-in page;
# Google is added as a federated identity provider once its OAuth client exists.

resource "aws_cognito_user_pool" "main" {
  name = "${local.name}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = { Name = "${local.name}-users" }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

output "cognito_hosted_ui_domain" {
  description = "Cognito hosted UI base domain"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

# Google as a federated identity provider. Created only once the OAuth client
# credentials are supplied (var.google_client_id).
resource "aws_cognito_identity_provider" "google" {
  count = var.google_client_id != "" ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  # Include the attributes AWS computes for Google so there's no perpetual drift.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "openid email profile"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
    name     = "name"
  }
}

# App client used by the Flask app for the Authorization Code flow via the hosted UI.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = ["${aws_apigatewayv2_api.app.api_endpoint}/auth/callback"]
  logout_urls   = ["${aws_apigatewayv2_api.app.api_endpoint}/"]

  supported_identity_providers = var.google_client_id != "" ? ["Google"] : ["COGNITO"]

  depends_on = [aws_cognito_identity_provider.google]
}

# Flask session secret (stable + shared across tasks) and the Cognito client
# secret, stored in Secrets Manager and injected into the task at launch.
resource "random_password" "flask_secret" {
  length  = 48
  special = false
}

# RabbitMQ broker credential. Generated unconditionally (it costs nothing) so the
# RABBITMQ_PASSWORD key always exists in the secret — the app/worker task
# definitions can reference it whether or not messaging is currently enabled.
resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name = "${local.name}-app-config"
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    SECRET_KEY            = random_password.flask_secret.result
    COGNITO_CLIENT_SECRET = aws_cognito_user_pool_client.web.client_secret
    RABBITMQ_PASSWORD     = random_password.rabbitmq.result
  })
}

output "cognito_client_id" {
  description = "Cognito app client ID"
  value       = aws_cognito_user_pool_client.web.id
}

# Let the ECS task execution role read the app-config secret.
resource "aws_iam_role_policy" "ecs_execution_app_secret" {
  name = "${local.name}-read-app-secret"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.app.arn
      }
    ]
  })
}
