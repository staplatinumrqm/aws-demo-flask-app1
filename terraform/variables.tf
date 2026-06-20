variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Name prefix for all AWS resources"
  type        = string
  default     = "flask-pipeline"
}

variable "github_owner" {
  description = "GitHub repository owner (username or org)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "github_branch" {
  description = "Branch that triggers the pipeline"
  type        = string
  default     = "main"
}

variable "container_port" {
  description = "Port the Flask app listens on"
  type        = number
  default     = 5000
}

variable "task_cpu" {
  description = "ECS task CPU units (256 = 0.25 vCPU)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "ECS task memory in MB"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Desired number of ECS tasks. Set to 0 on first apply if ECR is empty; the pipeline will bootstrap the image."
  type        = number
  default     = 1
}

variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications via SNS. Leave empty to skip the subscription."
  type        = string
  default     = ""
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks (autoscaling floor)"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks (autoscaling ceiling — caps cost)"
  type        = number
  default     = 4
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_name" {
  description = "Initial Postgres database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Postgres master username (password is generated + stored in Secrets Manager)"
  type        = string
  default     = "appuser"
}

variable "db_instance_class" {
  description = "RDS instance class (db.t4g.micro is free-tier eligible)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "Postgres major version"
  type        = string
  default     = "16"
}

variable "db_allocated_storage" {
  description = "RDS storage in GB (20 is free-tier)"
  type        = number
  default     = 20
}

# ── Google OAuth (for Cognito federated login) ────────────────────────────────
variable "google_client_id" {
  description = "Google OAuth 2.0 client ID (created in Google Cloud Console)"
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "Google OAuth 2.0 client secret"
  type        = string
  default     = ""
  sensitive   = true
}
