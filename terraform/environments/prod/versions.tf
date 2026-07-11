# =============================================================================
# Environment: prod — Versions
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "jol"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}
