resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.networking.alb_sg_id]
  subnets            = module.networking.public_subnet_ids

  tags = { Name = "${var.app_name}-alb" }
}

resource "aws_lb_target_group" "blue" {
  name        = "${var.app_name}-blue"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = module.networking.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = { Name = "${var.app_name}-blue" }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.app_name}-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = module.networking.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = { Name = "${var.app_name}-green" }
}

# Production listener: serves live traffic, starts pointing at blue
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy shifts traffic between blue/green — Terraform must not revert it
  lifecycle {
    ignore_changes = [default_action]
  }
}

# Test listener: CodeDeploy routes canary/validation traffic here before cutover
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}
