#!/usr/bin/env bash
# =============================================================================
# Secret Rotation Helper
# ISO 27001 A.8.7 — Cryptographic key management
# =============================================================================
set -euo pipefail

SERVICE="${1:?Usage: rotate-secret.sh <service> <environment>}"
ENV="${2:?Usage: rotate-secret.sh <service> <environment>}"

echo "🔄 Rotating secrets for ${SERVICE} in ${ENV}..."

# This script is a helper — actual rotation depends on your secrets manager
echo "Steps:"
echo "  1. Generate new credentials in Vaultwarden"
echo "  2. Update the secret in the external secrets store"
echo "  3. Verify ESO picks up the new secret (check ExternalSecret status)"
echo "  4. Restart the application deployment:"
echo "     kubectl rollout restart deployment/${SERVICE} -n jol-${ENV}"
echo "  5. Verify application health"
echo "  6. Remove old credentials after 24h grace period"
echo ""
echo "Document this rotation in the change log per SOC 2 CC8.1"
