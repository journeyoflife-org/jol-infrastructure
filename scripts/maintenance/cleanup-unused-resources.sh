#!/usr/bin/env bash
# =============================================================================
# Cleanup Unused AWS Resources
# Identifies and reports orphaned resources (cost optimization)
# =============================================================================
set -euo pipefail

ENV="${1:-dev}"
REGION="${2:-eu-central-1}"

echo "🧹 Scanning for unused resources in ${ENV} (${REGION})..."

# Unattached EBS volumes
echo ""
echo "=== Unattached EBS Volumes ==="
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" "Name=tag:Environment,Values=${ENV}" \
  --query 'Volumes[*].[VolumeId,Size,CreateTime]' \
  --output table \
  --region "$REGION"

# Unassociated Elastic IPs
echo ""
echo "=== Unassociated Elastic IPs ==="
aws ec2 describe-addresses \
  --filters "Name=domain,Values=vpc" \
  --query 'Addresses[?AssociationId==`null`].[AllocationId,PublicIp]' \
  --output table \
  --region "$REGION"

# Old CloudWatch log groups with no recent writes
echo ""
echo "=== Stale Log Groups (>90 days) ==="
aws logs describe-log-groups \
  --query 'logGroups[?creationTime < `'$(( $(date +%s) * 1000 - 7776000000 ))'`].[logGroupName,storedBytes]' \
  --output table \
  --region "$REGION" 2>/dev/null || echo "  No stale log groups found"

echo ""
echo "✅ Scan complete. Review and remove unused resources to optimize costs."
