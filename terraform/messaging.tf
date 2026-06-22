# ── RabbitMQ avatar-processing pipeline ───────────────────────────────────────
# Self-hosted RabbitMQ broker + a thumbnail worker, both on Fargate. Gated behind
# var.enable_messaging so the default cost is $0 — flip the flag and apply to run
# the async pipeline, set it back to false to tear the two tasks down.
#
#   Flask (producer) --amqp--> RabbitMQ --> worker (consumer)
#   worker: S3 download -> Pillow thumbnail -> S3 upload -> Profile.thumbnail_key
#
# Discovery: the broker registers an A record in a Cloud Map private DNS namespace,
# so the app and worker reach it at rabbitmq.<name>.local with no hard-coded IPs.

# Private DNS namespace for in-VPC service discovery.
resource "aws_service_discovery_private_dns_namespace" "main" {
  count       = local.messaging_count
  name        = "${local.name}.local"
  description = "Service discovery for ${local.name} internal services"
  vpc         = module.networking.vpc_id
}

resource "aws_service_discovery_service" "rabbitmq" {
  count = local.messaging_count
  name  = "rabbitmq"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main[0].id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# Broker SG: only the ECS tasks (app + worker share the ecs SG) may reach 5672.
resource "aws_security_group" "rabbitmq" {
  count       = local.messaging_count
  name        = "${local.name}-rabbitmq-sg"
  description = "RabbitMQ broker: accept AMQP (5672) only from ECS tasks"
  vpc_id      = module.networking.vpc_id

  ingress {
    description     = "AMQP from ECS tasks (app + worker)"
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [module.networking.ecs_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-rabbitmq-sg" }
}

# ── Broker ────────────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "rabbitmq" {
  count                    = local.messaging_count
  family                   = "${local.name}-rabbitmq"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "rabbitmq"
      image     = "public.ecr.aws/docker/library/rabbitmq:3.13-management-alpine"
      essential = true

      portMappings = [{ containerPort = 5672, protocol = "tcp" }]

      environment = [
        { name = "RABBITMQ_DEFAULT_USER", value = "app" },
      ]
      secrets = [
        { name = "RABBITMQ_DEFAULT_PASS", valueFrom = "${aws_secretsmanager_secret.app.arn}:RABBITMQ_PASSWORD::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "rabbitmq"
        }
      }
    }
  ])

  tags = { Name = "${local.name}-rabbitmq" }
}

resource "aws_ecs_service" "rabbitmq" {
  count           = local.messaging_count
  name            = "${local.name}-rabbitmq"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rabbitmq[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.networking.public_subnet_ids
    security_groups  = [aws_security_group.rabbitmq[0].id]
    assign_public_ip = true # required to pull the image without a NAT gateway
  }

  service_registries {
    registry_arn = aws_service_discovery_service.rabbitmq[0].arn
  }

  tags = { Name = "${local.name}-rabbitmq" }
}

# ── Worker ────────────────────────────────────────────────────────────────────
# Same image as the web app (worker.py ships in it); entry point overridden to run
# the consumer. Reuses the app's task + execution roles (S3 + secret access).
resource "aws_ecs_task_definition" "worker" {
  count                    = local.messaging_count
  family                   = "${local.name}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name       = "worker"
      image      = "${aws_ecr_repository.app.repository_url}:latest"
      essential  = true
      entryPoint = ["python", "-u", "worker.py"]

      environment = [
        { name = "DB_HOST", value = module.database.db_address },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = var.db_name },
        { name = "AVATAR_BUCKET", value = aws_s3_bucket.avatars.bucket },
        { name = "AWS_DEFAULT_REGION", value = var.aws_region },
        { name = "RABBITMQ_HOST", value = local.rabbitmq_dns },
        { name = "RABBITMQ_USER", value = "app" },
        { name = "RABBITMQ_PORT", value = "5672" },
      ]
      secrets = [
        { name = "DB_USER", valueFrom = "${module.database.db_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${module.database.db_secret_arn}:password::" },
        { name = "RABBITMQ_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:RABBITMQ_PASSWORD::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = { Name = "${local.name}-worker" }
}

resource "aws_ecs_service" "worker" {
  count           = local.messaging_count
  name            = "${local.name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker[0].arn
  desired_count   = var.worker_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.networking.public_subnet_ids
    security_groups  = [module.networking.ecs_sg_id]
    assign_public_ip = true
  }

  # The image tag is :latest; new revisions are rolled out by the app pipeline.
  # Ignore task_definition so re-applying Terraform doesn't fight a fresh push.
  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = { Name = "${local.name}-worker" }
}
