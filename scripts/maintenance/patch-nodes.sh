#!/usr/bin/env bash
# =============================================================================
# Rolling OS Patch
# Applies OS patches across EKS node group with zero-downtime
# =============================================================================
set -euo pipefail

ENV="${1:?Usage: patch-nodes.sh <environment>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Starting rolling OS patch for ${ENV}..."

# Get all nodes in the environment
NODES=$(kubectl get nodes -l "environment=${ENV}" -o jsonpath='{.items[*].metadata.name}')

for node in $NODES; do
  echo ""
  echo "=== Patching node: ${node} ==="

  # Drain
  "$SCRIPT_DIR/drain-node.sh" "$node"

  # SSH and apply patches (requires SSM or SSH access)
  echo "⚠️  Apply OS patches via SSM or SSH session"
  echo "    aws ssm start-session --target ${node}"
  echo "    sudo dnf update -y --security"
  echo "    sudo reboot"

  read -rp "Press Enter after node ${node} is patched and rebooted..."

  # Uncordon
  kubectl uncordon "$node"
  echo "✅ Node ${node} uncordoned"

  # Wait for pods to stabilize
  echo "⏳ Waiting for pods to stabilize..."
  sleep 60
  kubectl wait --for=condition=Ready pods --all --timeout=300s -A || true
done

echo ""
echo "✅ Rolling patch complete for ${ENV}"
