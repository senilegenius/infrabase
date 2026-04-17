variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "github_repo_balance_tracker" {
  description = "GitHub repository for balance-tracker in owner/repo format"
  type        = string
}

# ── Cross-account pull access ─────────────────────────────────────────────────
# These account IDs are referenced in the ECR repository policy to grant
# workload accounts permission to pull images.

variable "sandbox_account_id" {
  description = "AWS account ID for the sandbox workload account"
  type        = string
  sensitive   = true
}

variable "prd_account_id" {
  description = "AWS account ID for the prd workload account"
  type        = string
  sensitive   = true
}
