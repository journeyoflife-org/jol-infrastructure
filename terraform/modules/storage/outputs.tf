# =============================================================================
# Module: Storage — Outputs
# =============================================================================

output "kms_key_arn" {
  description = "KMS key ARN for storage encryption"
  value       = aws_kms_key.storage.arn
}

output "kms_key_id" {
  description = "KMS key ID"
  value       = aws_kms_key.storage.key_id
}

output "app_bucket_name" {
  description = "Application data S3 bucket name"
  value       = var.create_app_bucket ? aws_s3_bucket.app_data[0].bucket : null
}

output "app_bucket_arn" {
  description = "Application data S3 bucket ARN"
  value       = var.create_app_bucket ? aws_s3_bucket.app_data[0].arn : null
}
