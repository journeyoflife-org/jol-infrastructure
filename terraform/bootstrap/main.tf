# =============================================================================
# Bootstrap — ONE-TIME execution
# Creates S3 state buckets + KMS keys for all environments
# Run ONCE manually, then migrate to remote backend
# SOC 2 CC6.1 — State encryption at rest via KMS
# =============================================================================

locals {
  environments = ["dev", "staging", "prod"]
  common_tags = {
    Project     = "jol-infrastructure"
    ManagedBy   = "terraform"
    Component   = "bootstrap"
    Environment = "shared"
  }
}

# ---------------------------------------------------------------------------
# KMS Key — used to encrypt Terraform state in S3
# ---------------------------------------------------------------------------
resource "aws_kms_key" "terraform_state" {
  for_each = toset(local.environments)

  description             = "KMS key for Terraform state encryption — ${each.value}"
  deletion_window_in_days = 30
  enable_key_rotation     = true # ISO 27001 A.8.7

  tags = merge(local.common_tags, {
    Environment = each.value
    Purpose     = "terraform-state-encryption"
  })
}

resource "aws_kms_alias" "terraform_state" {
  for_each = toset(local.environments)

  name          = "alias/jol-terraform-state-${each.value}"
  target_key_id = aws_kms_key.terraform_state[each.value].key_id
}

# ---------------------------------------------------------------------------
# S3 Bucket — Terraform state storage
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "terraform_state" {
  for_each = toset(local.environments)

  bucket = "jol-terraform-state-${each.value}"

  tags = merge(local.common_tags, {
    Environment = each.value
    Purpose     = "terraform-state"
  })
}

# Versioning — required for state recovery
resource "aws_s3_bucket_versioning" "terraform_state" {
  for_each = toset(local.environments)

  bucket = aws_s3_bucket.terraform_state[each.value].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption with KMS
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  for_each = toset(local.environments)

  bucket = aws_s3_bucket.terraform_state[each.value].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state[each.value].arn
    }
    bucket_key_enabled = true
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  for_each = toset(local.environments)

  bucket = aws_s3_bucket.terraform_state[each.value].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle — retain old state versions for 90 days (SOC 2 audit trail)
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  for_each = toset(local.environments)

  bucket = aws_s3_bucket.terraform_state[each.value].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — State locking
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "terraform_locks" {
  for_each = toset(local.environments)

  name         = "jol-terraform-locks-${each.value}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Environment = each.value
    Purpose     = "terraform-state-locking"
  })
}
