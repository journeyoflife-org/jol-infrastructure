#!/usr/bin/env bash
# =============================================================================
# Terraform Cost Estimation (Infracost wrapper)
# Estimates monthly cost impact of Terraform changes
# =============================================================================
set -euo pipefail

ENV="${1:?Usage: tf-cost-estimate.sh <environment>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "💰 Estimating cost for: ${ENV}"

if ! command -v infracost &>/dev/null; then
  echo "❌ Infracost not found. Install: https://www.infracost.io/docs/"
  exit 1
fi

cd "$ROOT_DIR/terraform/environments/$ENV"

infracost breakdown --path=. \
  --format=table \
  --show-skipped

echo ""
echo "💡 For PR comments, use: infracost breakdown --path=. --format=json"
