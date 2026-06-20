output "db_address" {
  description = "RDS instance endpoint hostname"
  value       = aws_db_instance.main.address
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master credentials"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "db_name" {
  description = "Initial database name"
  value       = var.db_name
}
