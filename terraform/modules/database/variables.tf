variable "app_name" {
  description = "Name prefix / RDS identifier"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security group ID controlling access to RDS"
  type        = string
}

variable "execution_role_id" {
  description = "ECS task execution role name/id to grant read access to the DB secret"
  type        = string
}

variable "db_name" {
  description = "Initial Postgres database name"
  type        = string
}

variable "db_username" {
  description = "Postgres master username"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
}

variable "db_engine_version" {
  description = "Postgres major version"
  type        = string
}

variable "db_allocated_storage" {
  description = "RDS storage in GB"
  type        = number
}
