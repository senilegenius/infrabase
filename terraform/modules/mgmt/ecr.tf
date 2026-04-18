# ── balance-tracker ───────────────────────────────────────────────────────────

resource "aws_ecr_repository" "balance_tracker" {
  name                 = "balance-tracker"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "balance_tracker" {
  repository = aws_ecr_repository.balance_tracker.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_repository_policy" "balance_tracker" {
  repository = aws_ecr_repository.balance_tracker.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Grants workload account IAM principals (e.g. GitHub Actions deploy role)
        # permission to validate image access during UpdateFunctionCode.
        Sid    = "AllowCrossAccountPull"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${var.sandbox_account_id}:root",
            "arn:aws:iam::${var.prd_account_id}:root",
          ]
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
      },
      {
        # Grants the Lambda service permission to pull images at function
        # invocation time. Lambda uses an internal service principal for
        # cross-account image pulls — account root delegation does not cover this.
        Sid    = "AllowLambdaServicePull"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Condition = {
          StringLike = {
            "aws:sourceArn" = [
              "arn:aws:lambda:${var.aws_region}:${var.sandbox_account_id}:function:*",
              "arn:aws:lambda:${var.aws_region}:${var.prd_account_id}:function:*",
            ]
          }
        }
      },
    ]
  })
}
