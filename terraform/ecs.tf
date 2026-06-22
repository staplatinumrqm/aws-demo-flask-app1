resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30

  tags = { Name = "${local.name}-logs" }
}

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = local.name }
}

# Initial task definition using a public placeholder image.
# The pipeline replaces this on the first successful run via CodeDeploy.
resource "aws_ecs_task_definition" "app" {
  family                   = local.name
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

      # Non-sensitive DB / app config as plain env vars.
      environment = [
        { name = "DB_HOST", value = module.database.db_address },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = var.db_name },
        { name = "AVATAR_BUCKET", value = aws_s3_bucket.avatars.bucket },
        { name = "AWS_DEFAULT_REGION", value = var.aws_region },
        { name = "APP_BASE_URL", value = aws_apigatewayv2_api.app.api_endpoint },
        { name = "COGNITO_DOMAIN", value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com" },
        { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.web.id },
        { name = "ENABLE_XRAY", value = "true" },
        { name = "XRAY_SERVICE_NAME", value = local.name },
        { name = "AWS_XRAY_DAEMON_ADDRESS", value = "127.0.0.1:2000" },
        # Empty when messaging is disabled, so the avatar-job producer no-ops.
        { name = "RABBITMQ_HOST", value = local.rabbitmq_host },
        { name = "RABBITMQ_USER", value = "app" },
        { name = "RABBITMQ_PORT", value = "5672" },
      ]

      # Secrets pulled from Secrets Manager at launch (specific JSON keys), so
      # they never appear in the task definition.
      secrets = [
        { name = "DB_USER", valueFrom = "${module.database.db_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${module.database.db_secret_arn}:password::" },
        { name = "SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:SECRET_KEY::" },
        { name = "COGNITO_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.app.arn}:COGNITO_CLIENT_SECRET::" },
        { name = "RABBITMQ_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:RABBITMQ_PASSWORD::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      # X-Ray daemon sidecar — the app sends trace segments to it over UDP 2000
      # (shared localhost on Fargate); it forwards them to the X-Ray service.
      name              = "xray-daemon"
      image             = "public.ecr.aws/xray/aws-xray-daemon:latest"
      essential         = false
      cpu               = 32
      memoryReservation = 64

      portMappings = [
        {
          containerPort = 2000
          protocol      = "udp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "xray"
        }
      }
    }
  ])

  tags = { Name = local.name }
}

resource "aws_ecs_service" "app" {
  name            = local.name
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

  tags = { Name = local.name }
}
