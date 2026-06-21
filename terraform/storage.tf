# ── Profile picture storage (S3) ──────────────────────────────────────────────
# Private bucket for user avatars. The app reads/writes objects using the ECS
# *task* role (runtime credentials) — no access keys, and the bucket stays
# private (objects are streamed back through the app, not served publicly).

resource "aws_s3_bucket" "avatars" {
  bucket = "${local.name}-avatars-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${local.name}-avatars" }
}

resource "aws_s3_bucket_public_access_block" "avatars" {
  bucket                  = aws_s3_bucket.avatars.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "avatars" {
  bucket = aws_s3_bucket.avatars.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Grant the ECS task role read/write access to the avatar bucket only.
resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "${local.name}-task-s3-avatars"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AvatarObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.avatars.arn}/*"
      }
    ]
  })
}
