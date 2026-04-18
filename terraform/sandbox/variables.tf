variable "target_role_arn" {
  description = "IAM role ARN to assume in the sandbox account"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "github_repo_balance_tracker" {
  description = "GitHub repository for balance-tracker in owner/repo format (used for OIDC trust policy)"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the central ECR repository in the management account"
  type        = string
}
