variable "environment" {
  description = "Deployment environment (sandbox or prd) — used in resource names"
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

# ── Per-app GitHub repo variables ─────────────────────────────────────────────
# Add one variable per app, used to scope the OIDC trust policy.

variable "github_repo_balance_tracker" {
  description = "GitHub repository for balance-tracker in owner/repo format"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the central ECR repository (management account) — grants the GitHub Actions deploy role permission to validate image access during UpdateFunctionCode"
  type        = string
}
