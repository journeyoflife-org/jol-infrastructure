#!/usr/bin/env bash
# =============================================================================
# Encryption Status Audit
# Verifies encryption at rest for all data stores
# GDPR Art.32, ISO 27001 A.8.7
# =============================================================================
set -euo pipefail

ENV="${1:-prod}"
REGION="${2:-eu-central-1}"

echo "🔐 Encryption status audit for ${ENV}..."

# RDS instances
echo ""
echo "=== RDS Encryption ==="
aws rds describe-db-instances \
  --filters "Name=db-instance-id,Values=jol-${ENV}" \
  --query 'DBInstances[*].[DBInstanceIdentifier,StorageEncrypted,KmsKeyId]' \
  --output table \
  --region "$REGION" 2>/dev/null || echo "  No RDS instances found"

# EBS volumes
echo ""
echo "=== EBS Encryption ==="
aws ec2 describe-volumes \
  --filters "Name=tag:Environment,Values=${ENV}" \
  --query 'Volumes[*].[VolumeId,Encrypted,KmsKeyId]' \
  --output table \
  --region "$REGION" 2>/dev/null || echo "  No EBS volumes found"

# S3 buckets
echo ""
echo "=== S3 Encryption ==="
for bucket in $(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'jol-${ENV}')].Name" --output text); do
  echo "--- ${bucket} ---"
  aws s3api get-bucket-encryption --bucket "$bucket" --region "$REGION" 2>/dev/null || echo "  Not configured"
done

echo ""
echo "✅ Encryption audit complete"
