# =============================================================================
# Bootstrap — Provider & Version Constraints
# =============================================================================
#
# AWS PROVIDER FROZEN — JOL runs 100% on-prem (Proxmox). This Terraform code
# is never applied against AWS. The provider constraint is kept for structural
# completeness only.
#

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"  # frozen — Proxmox-only, never deployed to AWS
    }
  }

  # Bootstrap uses local state — do NOT configure remote backend here
  # After bootstrap, environments use S3 + DynamoDB backend
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}
