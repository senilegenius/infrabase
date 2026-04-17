output "balance_tracker_deploy_role_arn" {
  description = "IAM role ARN for balance-tracker GitHub Actions to deploy to Lambda"
  value       = module.platform.balance_tracker_deploy_role_arn
}
