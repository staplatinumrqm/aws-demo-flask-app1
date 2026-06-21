# Read-only role for `terraform plan` on pull requests (GitOps preview).
# Account-wide: created only in the default (production) workspace.

resource "aws_iam_role" "terraform_plan" {
  count = local.is_shared ? 1 : 0
  name  = "${local.name}-github-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
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
  count      = local.is_shared ? 1 : 0
  role       = aws_iam_role.terraform_plan[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# State backend access: read the state object and acquire/release the lock.
# (ReadOnlyAccess covers GetObject/GetItem but not the lock's Put/Delete.)
resource "aws_iam_role_policy" "terraform_plan_state" {
  count = local.is_shared ? 1 : 0
  name  = "${local.name}-terraform-plan-state"
  role  = aws_iam_role.terraform_plan[0].id

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
      },
      {
        # `terraform plan` refreshes the app-config secret version, which needs
        # GetSecretValue (not covered by the ReadOnlyAccess managed policy).
        Sid      = "ReadAppSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.app.arn
      }
    ]
  })
}

moved {
  from = aws_iam_role.terraform_plan
  to   = aws_iam_role.terraform_plan[0]
}
moved {
  from = aws_iam_role_policy_attachment.terraform_plan_readonly
  to   = aws_iam_role_policy_attachment.terraform_plan_readonly[0]
}
moved {
  from = aws_iam_role_policy.terraform_plan_state
  to   = aws_iam_role_policy.terraform_plan_state[0]
}
