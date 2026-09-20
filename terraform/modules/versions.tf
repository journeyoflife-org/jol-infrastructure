# =============================================================================
# Shared module version constraints
# Imported by all modules via source reference
# =============================================================================
#
# AWS PROVIDER FROZEN — JOL runs 100% on-prem (Proxmox). Terraform is never
# applied against AWS. Constraints kept for structural completeness only.
# Do NOT bump without verifying third-party module compat
# (terraform-aws-modules pin ~> 5.60 internally). See Dependabot ignore rules
# in .github/dependabot.yml.
#
# All modules must use:
#   terraform { required_version = ">= 1.9.0" }
#   aws provider = "~> 5.60"  (frozen)
#   tls provider = "~> 4.0" (where needed)
#
# Version updates:
# 1. Update this file
# 2. Update each module's versions.tf
# 3. Run `make validate` to verify compatibility
# 4. Update docs/dev-setup/tool-versions.md
#

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"  # frozen — Proxmox-only, never deployed to AWS
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
