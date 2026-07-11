# =============================================================================
# Module: IAM — Outputs
# =============================================================================

output "external_secrets_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = module.irsa_external_secrets.iam_role_arn
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager"
  value       = module.irsa_cert_manager.iam_role_arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for EBS CSI driver"
  value       = module.irsa_ebs_csi.iam_role_arn
}

output "monitoring_reader_policy_arn" {
  description = "Monitoring reader IAM policy ARN"
  value       = aws_iam_policy.monitoring_reader.arn
}
