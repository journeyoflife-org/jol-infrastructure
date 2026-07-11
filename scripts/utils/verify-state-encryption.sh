#!/usr/bin/env bash
# =============================================================================
# Verify S3 State Encryption
# Confirms KMS encryption is enabled on all Terraform state buckets
# =============================================================================
set -euo pipefail

echo "🔐 Verifying Terraform state bucket encryption..."
echo ""

ERRORS=0

for env in dev staging prod; do
  bucket="jol-terraform-state-${env}"
  echo "Checking: ${bucket}"

  # Check encryption
  encryption=$(aws s3api get-bucket-encryption --bucket "$bucket" 2>/dev/null || echo "")
  if echo "$encryption" | grep -q "aws:kms"; then
    echo "  ✅ SSE-KMS encryption enabled"
  else
    echo "  ❌ Encryption not configured or bucket not found"
    ERRORS=$((ERRORS + 1))
  fi

  # Check versioning
  versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" 2>/dev/null || echo "")
  if echo "$versioning" | grep -q "Enabled"; then
    echo "  ✅ Versioning enabled"
  else
    echo "  ❌ Versioning not enabled"
    ERRORS=$((ERRORS + 1))
  fi

  # Check public access block
  public_block=$(aws s3api get-public-access-block --bucket "$bucket" 2>/dev/null || echo "")
  if echo "$public_block" | grep -q "true"; then
    echo "  ✅ Public access blocked"
  else
    echo "  ❌ Public access not fully blocked"
    ERRORS=$((ERRORS + 1))
  fi

  echo ""
done

if [ $ERRORS -gt 0 ]; then
  echo "❌ ${ERRORS} issue(s) found. Review and fix before proceeding."
  exit 1
else
  echo "✅ All state buckets are properly secured!"
fi
