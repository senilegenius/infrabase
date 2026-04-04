# Platform infrastructure for the prd account.
# Calls the shared modules/platform module — resource definitions live there.
#
# Credentials: set AWS_PROFILE to your management account profile — Terraform
# assumes target_role_arn to create resources in the prd account.
#
# Usage:
#   export AWS_PROFILE=<your-mgmt-profile>
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

  assume_role {
    role_arn = var.target_role_arn
  }
}

module "platform" {
  source = "../modules/platform"

  environment                 = "prd"
  aws_region                  = var.aws_region
  github_repo_balance_tracker = var.github_repo_balance_tracker
}
