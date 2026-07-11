#!/usr/bin/env bash
# =============================================================================
# Bootstrap Step 4: Setup Monitoring Stack
# Installs Prometheus, Grafana, and configures alerting
# =============================================================================
set -euo pipefail

ENV="${1:-dev}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "📊 Setting up monitoring for ${ENV}..."

# Configure kubeconfig
aws eks update-kubeconfig --name "jol-${ENV}-cluster" --region eu-central-1

# Install/upgrade monitoring stack
helm upgrade --install monitoring \
  "$ROOT_DIR/helm/charts/jol-infrastructure-services" \
  -f "$ROOT_DIR/helm/environments/${ENV}/values-jol-infrastructure-services.yaml" \
  --namespace monitoring \
  --create-namespace \
  --wait --timeout 15m

echo ""
echo "✅ Monitoring stack deployed!"
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring"
echo "  http://localhost:3000 (admin / check ExternalSecret)"
echo ""
echo "Access Prometheus:"
echo "  kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring"
