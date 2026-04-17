# ── balance-tracker ───────────────────────────────────────────────────────────

output "balance_tracker_deploy_role_arn" {
  description = "IAM role ARN for balance-tracker GitHub Actions to deploy to Lambda"
  value       = aws_iam_role.github_actions_balance_tracker.arn
}
