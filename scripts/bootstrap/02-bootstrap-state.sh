#!/usr/bin/env bash
# =============================================================================
# Bootstrap Step 2: Terraform state bucket bootstrap
# Creates S3 buckets, KMS keys, and DynamoDB tables for state management
# =============================================================================
set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../terraform/bootstrap" && pwd)"

echo "🪣 Bootstrapping Terraform state infrastructure..."
echo "   Directory: $BOOTSTRAP_DIR"

cd "$BOOTSTRAP_DIR"

# Initialize
echo "📦 Running terraform init..."
terraform init

# Plan
echo "📋 Running terraform plan..."
terraform plan -out=bootstrap.tfplan

# Confirm
read -rp "Apply bootstrap? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "❌ Bootstrap cancelled"
  exit 1
fi

# Apply
echo "🚀 Applying bootstrap..."
terraform apply bootstrap.tfplan

echo ""
echo "✅ State infrastructure bootstrapped!"
echo "   Run 'terraform output backend_config_snippet' for backend configs"
echo "   Next step: ./scripts/bootstrap/03-bootstrap-cluster.sh"
