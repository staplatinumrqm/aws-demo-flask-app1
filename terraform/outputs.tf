output "alb_url" {
  description = "Application URL (live after first successful deploy)"
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_test_url" {
  description = "Test listener — CodeDeploy routes canary traffic here before cutover"
  value       = "http://${aws_lb.main.dns_name}:8080"
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service" {
  description = "ECS service name"
  value       = aws_ecs_service.app.name
}

output "github_actions_role_arn" {
  description = "IMPORTANT: add this value as the AWS_ROLE_ARN secret in your GitHub repo settings"
  value       = aws_iam_role.github_actions.arn
}

output "terraform_plan_role_arn" {
  description = "IMPORTANT: add this value as the AWS_PLAN_ROLE_ARN secret in your GitHub repo settings (read-only, for plan-on-PR)"
  value       = aws_iam_role.terraform_plan.arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard for ALB + ECS metrics"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "SNS topic that fans out CloudWatch alarm notifications"
  value       = aws_sns_topic.alerts.arn
}
