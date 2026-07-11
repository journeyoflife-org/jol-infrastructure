#!/usr/bin/env bash
# =============================================================================
# Cluster Benchmark
# Runs kube-bench and generates compliance report
# =============================================================================
set -euo pipefail

ENV="${1:-dev}"
OUTPUT_DIR="${2:-./benchmark-results}"

mkdir -p "$OUTPUT_DIR"
echo "📊 Running cluster benchmark for ${ENV}..."

# Ensure kubeconfig
aws eks update-kubeconfig --name "jol-${ENV}-cluster" --region eu-central-1

# Run kube-bench
"$R/scripts/audit/kube-bench-scan.sh" "$ENV"

# Save results
kubectl logs job/kube-bench > "$OUTPUT_DIR/kube-bench-${ENV}-$(date +%Y%m%d).txt" 2>/dev/null || true

echo ""
echo "✅ Benchmark results saved to: $OUTPUT_DIR"
echo "   Compare with previous runs to track compliance improvements"
