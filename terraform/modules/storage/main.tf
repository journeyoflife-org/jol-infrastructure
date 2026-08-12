# =============================================================================
# Module: Storage — S3, EBS, KMS encryption
# SOC 2 CC6.1 — Encryption at rest for all data stores
# GDPR Art.32 — Encryption of personal data
# =============================================================================

# ---------------------------------------------------------------------------
# KMS Key — for EBS and S3 encryption
# ---------------------------------------------------------------------------
resource "aws_kms_key" "storage" {
  description             = "KMS key for storage encryption — ${var.project} ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${var.project}-storage-${var.environment}"
  })
}

resource "aws_kms_alias" "storage" {
  name          = "alias/${var.project}-storage-${var.environment}"
  target_key_id = aws_kms_key.storage.key_id
}

# tfsec:ignore:aws-s3-enable-bucket-logging
#trivy:ignore:AWS-0089
resource "aws_s3_bucket" "app_data" {
  # checkov:skip=CKV_AWS_18:Access logging for application data is centralized via CloudTrail S3 data events; bucket-level server access logging deferred to avoid log recursion and cost.
  # checkov:skip=CKV_AWS_21:Versioning is configured via the separate aws_s3_bucket_versioning resource per AWS provider v4+ best practice.
  # checkov:skip=CKV_AWS_144:Cross-region replication is handled by the organizational backup/DR strategy, not bucket-level replication.
  count  = var.create_app_bucket ? 1 : 0
  bucket = "${var.project}-app-data-${var.environment}"

  tags = merge(var.tags, {
    Name = "${var.project}-app-data-${var.environment}"
  })
}

resource "aws_s3_bucket_versioning" "app_data" {
  count  = var.create_app_bucket ? 1 : 0
  bucket = aws_s3_bucket.app_data[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  count  = var.create_app_bucket ? 1 : 0
  bucket = aws_s3_bucket.app_data[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.storage.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "app_data" {
  count  = var.create_app_bucket ? 1 : 0
  bucket = aws_s3_bucket.app_data[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# EBS Volume Templates (referenced by node groups)
# ---------------------------------------------------------------------------
resource "aws_ebs_encryption_by_default" "main" {
  count   = var.enable_ebs_encryption ? 1 : 0
  enabled = true
}
