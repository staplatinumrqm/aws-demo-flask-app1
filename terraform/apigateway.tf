# ── API Gateway: free HTTPS front door ────────────────────────────────────────
# An HTTP API that transparently proxies every request to the (HTTP-only) ALB,
# giving the app a valid HTTPS URL (https://<id>.execute-api.<region>.amazonaws.com)
# with no custom domain or certificate. Used instead of CloudFront, which is gated
# on this (unverified) AWS account. Auth is handled in-app via Cognito, so the
# gateway routes are intentionally open ($default, authorization NONE).

resource "aws_apigatewayv2_api" "app" {
  name          = "${local.name}-http"
  protocol_type = "HTTP"

  tags = { Name = "${local.name}-http-api" }
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id                 = aws_apigatewayv2_api.app.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = "http://${aws_lb.main.dns_name}"
  payload_format_version = "1.0"
}

# $default catches every method + path and forwards (appending the request path).
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.app.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

# $default stage serves at the root of the execute-api URL (no /stage prefix).
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.app.id
  name        = "$default"
  auto_deploy = true

  tags = { Name = "${local.name}-http-stage" }
}
