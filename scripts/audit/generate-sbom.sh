#!/usr/bin/env bash
# =============================================================================
# SBOM Generation (Syft/Trivy)
# Generates Software Bill of Materials for supply chain security
# =============================================================================
set -euo pipefail

IMAGE="${1:?Usage: generate-sbom.sh <image:tag> [output-dir]}"
OUTPUT_DIR="${2:-./sbom}"

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "📦 Generating SBOM for: ${IMAGE}"

# Generate with Syft (CycloneDX format)
if command -v syft &>/dev/null; then
  echo "🔧 Running Syft..."
  syft "$IMAGE" -o cyclonedx-json > "$OUTPUT_DIR/sbom-${IMAGE//[:\/]/-}-${TIMESTAMP}.cyclonedx.json"
  echo "✅ CycloneDX SBOM generated"
else
  echo "⚠️  Syft not found. Install: https://github.com/anchore/syft"
fi

# Scan with Trivy
if command -v trivy &>/dev/null; then
  echo "🔧 Running Trivy..."
  trivy image --format cyclonedx --output "$OUTPUT_DIR/trivy-${IMAGE//[:\/]/-}-${TIMESTAMP}.cyclonedx.json" "$IMAGE"
  echo "✅ Trivy SBOM generated"
else
  echo "⚠️  Trivy not found. Install: https://github.com/aquasecurity/trivy"
fi

echo ""
echo "✅ SBOMs generated in: $OUTPUT_DIR"
