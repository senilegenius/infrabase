# GitHub Actions OIDC authentication — one provider per account, shared across all apps.
# Each app gets its own role scoped to its GitHub repo and its own resources.
#
# Adding a new app: add an aws_iam_role + aws_iam_role_policy block below,
# following the balance-tracker pattern.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprints (see https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# ── balance-tracker ───────────────────────────────────────────────────────────

resource "aws_iam_role" "github_actions_balance_tracker" {
  name = "balance-tracker-sandbox-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Scoped to this repo only; wildcard allows any branch/tag/PR
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo_balance_tracker}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_balance_tracker" {
  name = "deploy"
  role = aws_iam_role.github_actions_balance_tracker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is account-level, cannot be scoped to a specific repo
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.balance_tracker.arn
      },
      {
        Sid    = "LambdaDeploy"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:GetFunctionConfiguration", # Required by `aws lambda wait function-updated`
        ]
        # Predictable ARN pattern — no dependency on Lambda existing at apply time
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:balance-tracker-*"
      },
    ]
  })
}
