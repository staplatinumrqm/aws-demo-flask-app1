resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 30

  tags = { Name = "${var.app_name}-logs" }
}

resource "aws_ecs_cluster" "main" {
  name = var.app_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = var.app_name }
}

# Initial task definition using a public placeholder image.
# The pipeline replaces this on the first successful run via CodeDeploy.
resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "flask-app"
      image     = "public.ecr.aws/docker/library/python:3.11-slim"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Non-sensitive DB connection info as plain env vars.
      environment = [
        { name = "DB_HOST", value = module.database.db_address },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = var.db_name },
      ]

      # Credentials pulled from the RDS-managed Secrets Manager secret at launch
      # (specific JSON keys), so they never appear in the task definition.
      secrets = [
        { name = "DB_USER", valueFrom = "${module.database.db_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${module.database.db_secret_arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = var.app_name }
}

resource "aws_ecs_service" "app" {
  name            = var.app_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = module.networking.public_subnet_ids
    security_groups  = [module.networking.ecs_sg_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "flask-app"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.http]

  # CodeDeploy owns task_definition updates and load_balancer routing after the first deploy
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  tags = { Name = var.app_name }
}
