# =============================================================================
# Bootstrap — Outputs
# =============================================================================

output "state_bucket_names" {
  description = "S3 bucket names for Terraform state storage"
  value       = { for k, v in aws_s3_bucket.terraform_state : k => v.bucket }
}

output "state_bucket_arns" {
  description = "S3 bucket ARNs for Terraform state storage"
  value       = { for k, v in aws_s3_bucket.terraform_state : k => v.arn }
}

output "kms_key_arns" {
  description = "KMS key ARNs for state encryption"
  value       = { for k, v in aws_kms_key.terraform_state : k => v.arn }
}

output "kms_key_ids" {
  description = "KMS key IDs for state encryption"
  value       = { for k, v in aws_kms_key.terraform_state : k => v.key_id }
}

output "dynamodb_table_names" {
  description = "DynamoDB table names for state locking"
  value       = { for k, v in aws_dynamodb_table.terraform_locks : k => v.name }
}

output "backend_config_snippet" {
  description = "Backend configuration snippets for each environment"
  value = {
    for env in local.environments : env => templatefile("${path.module}/backend.tpl", {
      bucket         = aws_s3_bucket.terraform_state[env].bucket
      key            = "terraform.tfstate"
      region         = var.aws_region
      dynamodb_table = aws_dynamodb_table.terraform_locks[env].name
      kms_key_id     = aws_kms_key.terraform_state[env].arn
    })
  }
}
