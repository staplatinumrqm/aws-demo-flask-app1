# ── ECS Service Auto Scaling ──────────────────────────────────────────────────
# Application Auto Scaling adjusts the service's desired task count between
# min/max based on load. The ECS service ignores changes to desired_count
# (see ecs.tf) so Terraform and the autoscaler don't fight over it.
#
# CPU + memory target-tracking is used (rather than ALB request-count) because
# blue/green deployments swap the active target group, which would make a
# request-count policy bound to a single target group unreliable.

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60  # scale to keep avg CPU ~60%
    scale_in_cooldown  = 300 # wait 5m before scaling in (avoid flapping)
    scale_out_cooldown = 60  # scale out quickly under load
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${local.name}-memory-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
