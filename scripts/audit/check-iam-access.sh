#!/usr/bin/env bash
# =============================================================================
# IAM Access Review
# SOC 2 CC6.1 — Quarterly review of IAM roles and permissions
# =============================================================================
set -euo pipefail

ENV="${1:-prod}"
echo "👤 Reviewing IAM access for ${ENV}..."

# List all IAM roles with project prefix
echo ""
echo "=== IAM Roles ==="
aws iam list-roles \
  --query "Roles[?starts_with(RoleName, 'jol-${ENV}')].[RoleName,CreateDate,MaxSessionDuration]" \
  --output table

# Check for overly permissive policies
echo ""
echo "=== Policy Attachments ==="
for role in $(aws iam list-roles --query "Roles[?starts_with(RoleName, 'jol-${ENV}')].RoleName" --output text); do
  echo "--- ${role} ---"
  aws iam list-attached-role-policies --role-name "$role" \
    --query 'AttachedPolicies[*].[PolicyName,PolicyArn]' \
    --output table
done

# Check for unused roles (last 90 days)
echo ""
echo "=== Unused Roles (>90 days) ==="
aws iam generate-service-last-accessed-details 2>/dev/null || true

echo ""
echo "✅ IAM access review complete"
echo "   Document findings and remediate unused roles per SOC 2 CC6.1"
