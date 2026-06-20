# ── Module composition ────────────────────────────────────────────────────────
# Networking (VPC, subnets, security groups) and the database are factored into
# reusable modules. The remaining resources (ALB, ECS, CodeDeploy, IAM, etc.)
# stay in the root and consume these modules' outputs.

module "networking" {
  source         = "./modules/networking"
  app_name       = var.app_name
  azs            = data.aws_availability_zones.available.names
  container_port = var.container_port
}

module "database" {
  source               = "./modules/database"
  app_name             = var.app_name
  private_subnet_ids   = module.networking.private_subnet_ids
  rds_sg_id            = module.networking.rds_sg_id
  execution_role_id    = aws_iam_role.ecs_task_execution.id
  db_name              = var.db_name
  db_username          = var.db_username
  db_instance_class    = var.db_instance_class
  db_engine_version    = var.db_engine_version
  db_allocated_storage = var.db_allocated_storage
}

# ── State address migrations ──────────────────────────────────────────────────
# Tell Terraform these resources moved from the root into modules, so it renames
# them in state instead of destroying + recreating. Pure refactor — no infra change.
moved {
  from = aws_vpc.main
  to   = module.networking.aws_vpc.main
}
moved {
  from = aws_internet_gateway.main
  to   = module.networking.aws_internet_gateway.main
}
moved {
  from = aws_subnet.public
  to   = module.networking.aws_subnet.public
}
moved {
  from = aws_route_table.public
  to   = module.networking.aws_route_table.public
}
moved {
  from = aws_route_table_association.public
  to   = module.networking.aws_route_table_association.public
}
moved {
  from = aws_subnet.private
  to   = module.networking.aws_subnet.private
}
moved {
  from = aws_route_table.private
  to   = module.networking.aws_route_table.private
}
moved {
  from = aws_route_table_association.private
  to   = module.networking.aws_route_table_association.private
}
moved {
  from = aws_security_group.alb
  to   = module.networking.aws_security_group.alb
}
moved {
  from = aws_security_group.ecs
  to   = module.networking.aws_security_group.ecs
}
moved {
  from = aws_security_group.rds
  to   = module.networking.aws_security_group.rds
}
moved {
  from = aws_db_subnet_group.main
  to   = module.database.aws_db_subnet_group.main
}
moved {
  from = aws_db_instance.main
  to   = module.database.aws_db_instance.main
}
moved {
  from = aws_iam_role_policy.ecs_execution_db_secret
  to   = module.database.aws_iam_role_policy.ecs_execution_db_secret
}
