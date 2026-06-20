resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-db"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${var.app_name}-db-subnet-group" }
}

# manage_master_user_password=true → AWS generates the password and stores it in
# Secrets Manager. The password never touches Terraform state or the repo.
resource "aws_db_instance" "main" {
  identifier     = var.app_name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username

  manage_master_user_password = true

  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [var.rds_sg_id]
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = { Name = var.app_name }
}

# Allow the ECS task execution role to read the DB credentials secret.
resource "aws_iam_role_policy" "ecs_execution_db_secret" {
  name = "${var.app_name}-read-db-secret"
  role = var.execution_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.main.master_user_secret[0].secret_arn
      }
    ]
  })
}
