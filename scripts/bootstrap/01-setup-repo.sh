#!/usr/bin/env bash
# =============================================================================
# Bootstrap Step 1: Repository setup
# Git signing, pre-commit hooks, tool verification
# =============================================================================
set -euo pipefail

echo "🔧 Setting up jol-infrastructure repository..."

# Verify required tools
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/../utils/check-tools.sh"

# Configure git signing (if GPG key exists)
if gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -q "sec"; then
  echo "✅ GPG key found, configuring commit signing..."
  git config commit.gpgsign true
  git config tag.gpgsign true
else
  echo "⚠️  No GPG key found. Consider setting up commit signing:"
  echo "    https://docs.github.com/en/authentication/managing-commit-signature-verification"
fi

# Install pre-commit hooks
echo "📦 Installing pre-commit hooks..."
if command -v pre-commit &>/dev/null; then
  pre-commit install
  pre-commit install --hook-type commit-msg
  echo "✅ Pre-commit hooks installed"
else
  echo "⚠️  pre-commit not found. Install with: pip install pre-commit"
fi

# Configure git attributes
git config core.autocrlf input
git config core.eol lf

echo ""
echo "✅ Repository setup complete!"
echo "   Next step: ./scripts/bootstrap/02-bootstrap-state.sh"
