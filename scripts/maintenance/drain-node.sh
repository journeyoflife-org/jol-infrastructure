#!/usr/bin/env bash
# =============================================================================
# Safe Node Drain + Cordon
# Gracefully evicts pods before node maintenance
# =============================================================================
set -euo pipefail

NODE="${1:?Usage: drain-node.sh <node-name>}"

echo "🔧 Draining node: ${NODE}"

# Cordon the node
kubectl cordon "$NODE"
echo "✅ Node cordoned"

# Drain with safe defaults
kubectl drain "$NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=300s \
  --force

echo "✅ Node drained"
echo ""
echo "Node ${NODE} is now safe for maintenance."
echo "After maintenance, uncordon with: kubectl uncordon ${NODE}"
