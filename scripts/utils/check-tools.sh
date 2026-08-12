#!/usr/bin/env bash
# =============================================================================
# Tool Version Checker
# Verifies all required tools are installed at correct versions
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ERRORS=0

check_tool() {
  local name="$1"
  local min_version="$2"
  local cmd="$3"

  if command -v "$name" &>/dev/null; then
    local version
    version=$(eval "$cmd" 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✅ ${name}${NC}: ${version} (min: ${min_version})"
  else
    echo -e "${RED}❌ ${name}${NC}: NOT INSTALLED (min: ${min_version})"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "🔧 Checking required tools..."
echo ""

check_tool "terraform" "1.9.0"  "terraform version | head -1"
check_tool "kubectl"   "1.28"   "kubectl version --client --short 2>/dev/null || kubectl version --client"
check_tool "helm"      "3.14"   "helm version --short"
check_tool "aws"       "2.15"   "aws --version"
check_tool "pre-commit" "3.5"   "pre-commit --version"
check_tool "jq"        "1.7"    "jq --version"
check_tool "yq"        "4.0"    "yq --version"
check_tool "checkov"   "3.0"    "checkov --version"
check_tool "tfsec"     "1.28"   "tfsec --version"
check_tool "opa"       "0.60"   "opa version | head -1"
check_tool "kube-bench" "0.7"   "kube-bench version"
check_tool "trivy"     "0.50"   "trivy --version"
check_tool "syft"      "1.0"    "syft version"

echo ""
if [ $ERRORS -gt 0 ]; then
  echo -e "${RED}❌ ${ERRORS} tool(s) missing. Please install them before proceeding.${NC}"
  exit 1
else
  echo -e "${GREEN}✅ All required tools are installed!${NC}"
fi
