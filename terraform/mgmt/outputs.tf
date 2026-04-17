# ── balance-tracker ───────────────────────────────────────────────────────────

output "balance_tracker_ecr_repository_url" {
  description = "Central ECR repository URL for balance-tracker container images"
  value       = module.mgmt.balance_tracker_ecr_repository_url
}

output "balance_tracker_ecr_push_role_arn" {
  description = "IAM role ARN for balance-tracker GitHub Actions to push images to central ECR"
  value       = module.mgmt.balance_tracker_ecr_push_role_arn
}
