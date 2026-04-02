output "balance_tracker_ecr_repository_url" {
  description = "ECR repository URL for balance-tracker container images"
  value       = aws_ecr_repository.balance_tracker.repository_url
}

output "balance_tracker_github_actions_role_arn" {
  description = "IAM role ARN for balance-tracker GitHub Actions to assume via OIDC"
  value       = aws_iam_role.github_actions_balance_tracker.arn
}
