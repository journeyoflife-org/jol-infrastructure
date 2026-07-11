# =============================================================================
# Environment: staging — Terraform Backend (S3 + DynamoDB)
# SOC 2 CC8.1 — State encrypted at rest, locked via DynamoDB
# =============================================================================

terraform {
  backend "s3" {
    bucket         = "jol-terraform-state-staging"
    key            = "terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "jol-terraform-locks-staging"
    kms_key_id     = "alias/jol-terraform-state-staging"
  }
}
