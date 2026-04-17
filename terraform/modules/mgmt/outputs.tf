# ── balance-tracker ───────────────────────────────────────────────────────────

output "balance_tracker_ecr_repository_url" {
  description = "Central ECR repository URL for balance-tracker container images"
  value       = aws_ecr_repository.balance_tracker.repository_url
}

output "balance_tracker_ecr_push_role_arn" {
  description = "IAM role ARN for balance-tracker GitHub Actions to push images to central ECR"
  value       = aws_iam_role.github_actions_balance_tracker_ecr_push.arn
}
