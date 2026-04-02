# Platform infrastructure for the sandbox account.
# Owns shared resources that app repos depend on: ECR repositories, etc.
#
# Credentials: set AWS_PROFILE to your management account profile — Terraform
# assumes target_role_arn to create resources in the sandbox account.
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

data "aws_caller_identity" "current" {}
