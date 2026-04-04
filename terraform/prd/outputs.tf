output "balance_tracker_ecr_repository_url" {
  description = "ECR repository URL for balance-tracker container images"
  value       = module.platform.balance_tracker_ecr_repository_url
}

output "balance_tracker_github_actions_role_arn" {
  description = "IAM role ARN for balance-tracker GitHub Actions to assume via OIDC"
  value       = module.platform.balance_tracker_github_actions_role_arn
}
