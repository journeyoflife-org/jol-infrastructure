# =============================================================================
# Bootstrap — Provider & Version Constraints
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
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
