# Central management account infrastructure.
# Owns resources shared across all environments: ECR repositories, central
# OIDC provider for ECR push.
#
# Credentials: set AWS_PROFILE to your management account profile — Terraform
# runs directly in the pers account (no assume_role).
#
# Usage:
#   export AWS_PROFILE=pers
#   cp backend.hcl.example backend.hcl            # fill in real values
#   cp terraform.tfvars.example terraform.tfvars  # fill in real values
#   terraform init -backend-config=backend.hcl
#   terraform plan
#   terraform apply

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

module "mgmt" {
  source = "../modules/mgmt"

  aws_region                  = var.aws_region
  github_repo_balance_tracker = var.github_repo_balance_tracker
  sandbox_account_id          = var.sandbox_account_id
  prd_account_id              = var.prd_account_id
}
