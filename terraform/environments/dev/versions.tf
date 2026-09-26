# =============================================================================
# Environment: dev — Versions
# =============================================================================
#
# AWS PROVIDER FROZEN — JOL runs 100% on-prem (Proxmox). This Terraform code
# is never applied against AWS. The provider constraint is kept for structural
# completeness only. Do NOT bump without verifying third-party module compat
# (terraform-aws-modules pin ~> 5.60 internally). See Dependabot ignore rules
# in .github/dependabot.yml.
#

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"  # frozen — Proxmox-only, never deployed to AWS
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
