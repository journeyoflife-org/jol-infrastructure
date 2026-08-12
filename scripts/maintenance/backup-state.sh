#!/usr/bin/env bash
# =============================================================================
# Terraform State Backup
# Creates a point-in-time backup of all Terraform state files
# SOC 2 CC8.1 — Change management: state backup before major operations
# =============================================================================
set -euo pipefail

ENV="${1:?Usage: backup-state.sh <environment>}"
BACKUP_DIR="./state-backups/${ENV}-$(date +%Y%m%d-%H%M%S)"

echo "💾 Backing up Terraform state for ${ENV}..."

mkdir -p "$BACKUP_DIR"

BUCKET="jol-terraform-state-${ENV}"

# Download current state
aws s3 cp "s3://${BUCKET}/terraform.tfstate" "${BACKUP_DIR}/terraform.tfstate" \
  --region eu-central-1

# Download state version history (last 5)
echo "Downloading state versions..."
VERSIONS=$(aws s3api list-object-versions \
  --bucket "$BUCKET" \
  --prefix terraform.tfstate \
  --query 'Versions[:5].[VersionId,LastModified]' \
  --output text \
  --region eu-central-1 2>/dev/null || echo "")

if [ -n "$VERSIONS" ]; then
  i=1
  echo "$VERSIONS" | while read -r version_id _last_modified; do
    aws s3api get-object \
      --bucket "$BUCKET" \
      --key terraform.tfstate \
      --version-id "$version_id" \
      "${BACKUP_DIR}/terraform.tfstate.v${i}" \
      --region eu-central-1 > /dev/null 2>&1
    i=$((i + 1))
  done
fi

echo ""
echo "✅ State backup saved to: ${BACKUP_DIR}"
echo "   Files: $(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 | wc -l)"
