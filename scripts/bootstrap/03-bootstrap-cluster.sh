#!/usr/bin/env bash
# =============================================================================
# Bootstrap Step 3: EKS cluster bootstrap
# Creates EKS cluster, installs ESO, cert-manager, and monitoring
# =============================================================================
set -euo pipefail

ENV="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "☸️  Bootstrapping EKS cluster for environment: ${ENV}"

# Apply Terraform
echo "📦 Applying Terraform..."
cd "$ROOT_DIR/terraform/environments/$ENV"
terraform init
terraform plan -out="cluster-${ENV}.tfplan"

read -rp "Apply cluster for ${ENV}? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "❌ Bootstrap cancelled"
  exit 1
fi

terraform apply "cluster-${ENV}.tfplan"

# Configure kubectl
echo "🔧 Configuring kubectl..."
aws eks update-kubeconfig --name "jol-${ENV}-cluster" --region eu-central-1

# Install infrastructure services via Helm
echo "⎈ Installing infrastructure services..."
helm upgrade --install jol-infrastructure-services \
  "$ROOT_DIR/helm/charts/jol-infrastructure-services" \
  -f "$ROOT_DIR/helm/environments/${ENV}/values-jol-infrastructure-services.yaml" \
  --namespace kube-system \
  --wait --timeout 15m

echo ""
echo "✅ Cluster bootstrap complete for ${ENV}!"
echo "   Verify with: kubectl get nodes && kubectl get pods -A"
