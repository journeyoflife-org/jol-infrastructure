#!/usr/bin/env bash
# =============================================================================
# terraform-state-rename-jolarca.sh — Terraform state migration for the
# jol-m-* → jolarca* repository rename (change record JOL-RENAME-20260831-01).
#
# Context: the github-org module uses for_each over var.repositories with
# repo names as keys. After the GitHub-side rename, the next `terraform plan`
# would propose destroy/recreate of the 5 renamed repos (catastrophic).
# This script moves the state entries to the new keys BEFORE the next apply.
#
# Scope: production environment only (staging has no github_org module).
#
# Pre-conditions:
#   1. Copy this script to jolarca-infrastructure/scripts/ (the renamed repo)
#   2. Run from jolarca-infrastructure/terraform/environments/production
#   3. terraform init already done (state file exists)
#   4. Backup the state file first (this script does it)
#
# Usage:
#   cd /opt/jolarca/repos/jolarca-infrastructure/terraform/environments/production
#   bash ../../scripts/terraform-state-rename-jolarca.sh
#   terraform plan  # should show NO changes
#
# Rollback: restore the state backup created by this script.
# =============================================================================
set -euo pipefail

STATE_FILE="terraform.tfstate"
BACKUP="${STATE_FILE}.bak.pre-jolarca-rename-$(date +%Y%m%d-%H%M%S)"

# Mapping: old_key -> new_key (must match var.repositories keys in modules/github-org/variables.tf)
declare -A RENAME_MAP=(
  ["jol-m-marketplace"]="jolarca"
  ["jol-m-infrastructure"]="jolarca-infrastructure"
  ["jol-m-compliance"]="jolarca-compliance"
  ["jol-m-legal"]="jolarca-legal"
  ["jol-m-data"]="jolarca-data"
)

# Resources that iterate over var.repositories
RESOURCES=(
  "module.github_org.github_repository.repos"
  "module.github_org.github_repository_vulnerability_alerts.repos"
  "module.github_org.github_branch_protection.main"
)

if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: $STATE_FILE not found. Run 'terraform init' first."
  exit 1
fi

echo "=== Terraform state migration: jol-m-* → jolarca* ==="
echo "Backing up state to $BACKUP"
cp "$STATE_FILE" "$BACKUP"

for resource in "${RESOURCES[@]}"; do
  for old_key in "${!RENAME_MAP[@]}"; do
    new_key="${RENAME_MAP[$old_key]}"
    old_addr="${resource}[\"${old_key}\"]"
    new_addr="${resource}[\"${new_key}\"]"
    
    # Check if the old address exists in state
    if terraform state list 2>/dev/null | grep -qF "$old_addr"; then
      echo "Moving: $old_addr → $new_addr"
      terraform state mv "$old_addr" "$new_addr" || {
        echo "ERROR: Failed to move $old_addr"
        echo "Restore from $BACKUP if needed"
        exit 1
      }
    else
      echo "SKIP: $old_addr (not in state)"
    fi
  done
done

echo ""
echo "=== Migration complete ==="
echo "Run 'terraform plan' to verify no changes are proposed."
echo "If plan shows drift, restore: cp $BACKUP $STATE_FILE"
