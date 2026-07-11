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

# Shared KMS key for the access-logs bucket (bootstrap terminus)
resource "aws_kms_key" "terraform_state_logs" {
  description             = "KMS key for Terraform state access-logs encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Purpose = "terraform-state-access-logs-encryption"
  })
}

resource "aws_kms_alias" "terraform_state_logs" {
  name          = "alias/jol-terraform-state-logs"
  target_key_id = aws_kms_key.terraform_state_logs.key_id
}

# ---------------------------------------------------------------------------
# S3 Bucket — Terraform state storage
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "terraform_state" {
  # checkov:skip=CKV_AWS_144:Cross-region replication for Terraform state buckets is deferred to the organizational DR strategy; state is protected by versioning, KMS encryption, and DynamoDB locking.
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

# Access logging — centralize all state-bucket access logs for audit review
# tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "terraform_state_logs" {
  # checkov:skip=CKV_AWS_18:Server access logging is intentionally disabled on the access-logs terminus bucket to avoid log recursion and cost; access is tracked via bucket policy and CloudTrail.
  # checkov:skip=CKV_AWS_144:Cross-region replication for the access-logs bucket is deferred to the organizational DR strategy.
  bucket = "jol-terraform-state-logs"

  tags = merge(local.common_tags, {
    Purpose = "terraform-state-access-logs"
  })
}

resource "aws_s3_bucket_versioning" "terraform_state_logs" {
  bucket = aws_s3_bucket.terraform_state_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "terraform_state_logs" {
  bucket = aws_s3_bucket.terraform_state_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_logs" {
  bucket = aws_s3_bucket.terraform_state_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state_logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state_logs" {
  bucket = aws_s3_bucket.terraform_state_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "terraform_state_logs" {
  bucket = aws_s3_bucket.terraform_state_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowS3AccessLogs"
      Effect = "Allow"
      Principal = {
        Service = "logging.s3.amazonaws.com"
      }
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.terraform_state_logs.arn}/*"
      Condition = {
        ArnLike = {
          "aws:SourceArn" = [
            for env in local.environments : aws_s3_bucket.terraform_state[env].arn
          ]
        }
      }
    }]
  })
}

resource "aws_s3_bucket_logging" "terraform_state" {
  for_each = toset(local.environments)

  bucket = aws_s3_bucket.terraform_state[each.value].id

  target_bucket = aws_s3_bucket.terraform_state_logs.id
  target_prefix = "${each.value}/"
}

# Lifecycle — retain old state versions for 90 days (SOC 2 audit trail)
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  for_each = toset(local.environments)

  bucket = aws_s3_bucket.terraform_state[each.value].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

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

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.terraform_state[each.value].arn
  }

  tags = merge(local.common_tags, {
    Environment = each.value
    Purpose     = "terraform-state-locking"
  })
}
