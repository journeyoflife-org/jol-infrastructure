#!/usr/bin/env bash
# =============================================================================
# Generate Terraform Documentation
# Uses terraform-docs to auto-generate module documentation
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "📄 Generating Terraform documentation..."

if ! command -v terraform-docs &>/dev/null; then
  echo "❌ terraform-docs not found. Install: https://terraform-docs.io/"
  exit 1
fi

for module_dir in "$ROOT_DIR"/terraform/modules/*/; do
  module_name=$(basename "$module_dir")
  echo "  Generating docs for: ${module_name}"

  terraform-docs markdown table \
    --output-file README.md \
    --output-mode inject \
    "$module_dir" 2>/dev/null || echo "  ⚠️  Skipped: ${module_name}"
done

for env in dev staging prod; do
  echo "  Generating docs for: environments/${env}"
  terraform-docs markdown table \
    --output-file README.md \
    --output-mode inject \
    "$ROOT_DIR/terraform/environments/$env" 2>/dev/null || echo "  ⚠️  Skipped: ${env}"
done

echo ""
echo "✅ Documentation generated"
