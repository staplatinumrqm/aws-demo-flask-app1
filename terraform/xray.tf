# X-Ray: the ECS task role (shared by the app and the daemon sidecar) needs to
# write trace segments. AWSXRayDaemonWriteAccess grants exactly that
# (PutTraceSegments, PutTelemetryRecords, GetSamplingRules/Targets).
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
