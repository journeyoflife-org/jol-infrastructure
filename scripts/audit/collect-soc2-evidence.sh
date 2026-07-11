#!/usr/bin/env bash
# =============================================================================
# SOC 2 Evidence Collection
# Quarterly artifact collection for SOC 2 Type II audit
# =============================================================================
set -euo pipefail

OUTPUT_DIR="${1:-./soc2-evidence-$(date +%Y-Q%q)}"

echo "📋 Collecting SOC 2 evidence artifacts..."
mkdir -p "$OUTPUT_DIR"

# 1. Git commit history (change management)
echo "📝 Collecting git history..."
git log --oneline --since="3 months ago" > "$OUTPUT_DIR/git-history.txt"

# 2. Terraform state encryption verification
echo "🔐 Verifying state encryption..."
for env in dev staging prod; do
  aws s3api get-bucket-encryption \
    --bucket "jol-terraform-state-${env}" \
    > "$OUTPUT_DIR/s3-encryption-${env}.json" 2>/dev/null || echo "Bucket not found: ${env}"
done

# 3. CloudTrail events (last 90 days)
echo "📊 Collecting CloudTrail events..."
aws cloudtrail lookup-events \
  --start-time "$(date -d '90 days ago' -u +%Y-%m-%dT%H:%M:%SZ)" \
  --max-results 100 \
  > "$OUTPUT_DIR/cloudtrail-events.json" 2>/dev/null || echo "CloudTrail not configured"

# 4. IAM access report
echo "👤 Collecting IAM access data..."
aws iam generate-credential-report > /dev/null 2>&1 || true
sleep 5
aws iam get-credential-report \
  --query 'Content' --output text | base64 -d \
  > "$OUTPUT_DIR/iam-credential-report.csv" 2>/dev/null || echo "IAM report not available"

# 5. VPC flow logs status
echo "🌐 Checking VPC flow logs..."
for env in dev staging prod; do
  aws ec2 describe-flow-logs \
    --filters "Name=resource-id,Values=*" \
    > "$OUTPUT_DIR/vpc-flow-logs-${env}.json" 2>/dev/null || echo "Flow logs not found: ${env}"
done

echo ""
echo "✅ Evidence collected in: $OUTPUT_DIR"
echo "   Review and upload to your SOC 2 evidence repository"
