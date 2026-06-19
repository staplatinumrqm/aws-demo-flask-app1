# Read-only role for `terraform plan` on pull requests (GitOps preview).
# Separate from the deploy role: this one is read-only and assumable from PRs,
# the deploy role is write-capable and locked to the main branch only.

resource "aws_iam_role" "terraform_plan" {
  name = "${var.app_name}-github-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # Assumable from PRs (for plan previews) and the main branch.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_owner}/${var.github_repo}:pull_request",
              "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
            ]
          }
        }
      }
    ]
  })
}

# Broad read access so `terraform plan` can refresh state against live resources.
resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# State backend access: read the state object and acquire/release the lock.
# (ReadOnlyAccess covers GetObject/GetItem but not the lock's Put/Delete.)
resource "aws_iam_role_policy" "terraform_plan_state" {
  name = "${var.app_name}-terraform-plan-state"
  role = aws_iam_role.terraform_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      },
      {
        Sid      = "StateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.tfstate_lock.arn
      }
    ]
  })
}
