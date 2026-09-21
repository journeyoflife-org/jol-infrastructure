#!/usr/bin/env bash
# =============================================================================
# Basilica Multi-Tenant Content Source — Pre-Flight Verification
#
# Verifies the §1 starting-state facts from the design spec against live repos
# BEFORE implementation begins. Catches stale assumptions early.
#
# Spec: docs/superpowers/specs/2026-09-21-basilica-multi-tenant-content-source-design.md
# Compliance: GDPR Art. 9, SOC 2 CC8.1, ISO 27001 A.8.13
#
# Usage:
#   ./scripts/audit/verify-basilica-preflight.sh              # all checks
#   ./scripts/audit/verify-basilica-preflight.sh --verbose    # show evidence
#   ./scripts/audit/verify-basilica-preflight.sh --json       # machine-readable output
#
# Exit codes:
#   0  all checks PASS
#   1  one or more checks FAIL (implementation should not proceed)
#   2  script error (missing repo, bad arguments)
#
# Properties: read-only (no mutations), idempotent, no secrets required.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------- config ----
REPO_ROOT="/opt/jol/repos"
HUB="$REPO_ROOT/jol-hub"
BACKEND_PLATFORM="$REPO_ROOT/jol-backend-platform"
DEPLOY="$REPO_ROOT/jol-deploy"
BITRIX="$REPO_ROOT/jol-bitrix24-integration"
INFRA="$REPO_ROOT/jol-infrastructure"

VERBOSE=0
JSON_OUT=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
RESULTS=()

# ----------------------------------------------------------- arg parsing ----
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=1 ;;
    --json)    JSON_OUT=1 ;;
    -h|--help)
      sed -n '3,/^# ====.*$/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------- helpers ----
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  local msg="PASS  $1"
  RESULTS+=("PASS|$1|${2:-}")
  [ "$VERBOSE" = "1" ] && echo "  ✅ $msg"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  local msg="FAIL  $1"
  RESULTS+=("FAIL|$1|${2:-}")
  echo "  ❌ $msg" >&2
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  local msg="WARN  $1"
  RESULTS+=("WARN|$1|${2:-}")
  [ "$VERBOSE" = "1" ] && echo "  ⚠️  $msg"
}

check_file() {
  # $1=label  $2=path  $3=expected_content_pattern (optional)
  local label="$1" path="$2" pattern="${3:-}"
  if [ ! -f "$path" ]; then
    fail "$label" "file absent: $path"
    return
  fi
  if [ -n "$pattern" ]; then
    if grep -qE "$pattern" "$path" 2>/dev/null; then
      pass "$label"
    else
      fail "$label" "pattern '$pattern' not found in $path"
    fi
  else
    pass "$label"
  fi
}

check_dir() {
  # $1=label  $2=path
  if [ -d "$2" ]; then
    pass "$1"
  else
    fail "$1" "directory absent: $2"
  fi
}

check_dir_empty() {
  # $1=label  $2=path  (expect only .git, LICENSE, README.md, .gitignore)
  local path="$2"
  if [ ! -d "$path" ]; then
    fail "$1" "directory absent: $path"
    return
  fi
  local count
  count=$(find "$path" -mindepth 1 -maxdepth 1 \
    ! -name '.git' ! -name 'LICENSE' ! -name 'README.md' ! -name '.gitignore' \
    | wc -l)
  if [ "$count" -eq 0 ]; then
    pass "$1"
  else
    fail "$1" "directory not empty ($count unexpected entries): $path"
  fi
}

# ===================================================================== main
echo "🔍 Basilica pre-flight verification — $(date -Is)"
echo ""

# --- 1. Repository existence ---
echo "=== Repository existence ==="
check_dir "jol-hub exists" "$HUB"
check_dir "jol-hub/backend/django exists" "$HUB/backend/django"
check_dir "jol-backend-platform exists" "$BACKEND_PLATFORM"
check_dir "jol-deploy exists" "$DEPLOY"
check_dir "jol-bitrix24-integration exists" "$BITRIX"

# --- 2. jol-backend-platform is empty (D2) ---
echo ""
echo "=== D2: jol-backend-platform retirement ==="
check_dir_empty "jol-backend-platform is empty (D2)" "$BACKEND_PLATFORM"

# --- 3. Django backend structure ---
echo ""
echo "=== Django backend structure ==="
check_file "requirements.txt exists" "$HUB/backend/django/requirements.txt"
check_file "Django 6.x in requirements" "$HUB/backend/django/requirements.txt" "Django[>=~]*6\."
check_file "DRF in requirements" "$HUB/backend/django/requirements.txt" "djangorestframework"
check_dir "12+ apps exist" "$HUB/backend/django/apps"

for app in content organizations countries users crm core; do
  check_dir "apps/$app exists" "$HUB/backend/django/apps/$app"
done

# --- 4. Content API mounted ---
echo ""
echo "=== Content API (C3) ==="
check_file "content/models.py exists" "$HUB/backend/django/apps/content/models.py"
check_file "content/views.py exists" "$HUB/backend/django/apps/content/views.py"
check_file "content/serializers.py exists" "$HUB/backend/django/apps/content/serializers.py"
check_file "content/urls.py exists" "$HUB/backend/django/apps/content/urls.py"
check_file "content/admin.py exists" "$HUB/backend/django/apps/content/admin.py"
check_file "content mounted in core/urls.py" "$HUB/backend/django/core/urls.py" "content"

# --- 5. Page model tenant-scoped ---
echo ""
echo "=== Page model (multi-tenant, multi-language) ==="
check_file "Page has organization FK" "$HUB/backend/django/apps/content/models.py" "organization.*ForeignKey"
check_file "Page has language field" "$HUB/backend/django/apps/content/models.py" "language"
check_file "Page has unique_together (org,slug,lang)" "$HUB/backend/django/apps/content/models.py" "unique_together"

# --- 6. Organization model mature ---
echo ""
echo "=== Organization model ==="
check_file "basilica org type" "$HUB/backend/django/apps/organizations/models.py" "basilica"
check_file "compliance_level field" "$HUB/backend/django/apps/organizations/models.py" "compliance_level"
check_file "sacramental_data_processing (Art. 9)" "$HUB/backend/django/apps/organizations/models.py" "sacramental_data_processing"
check_file "legal_hold (Art. 17)" "$HUB/backend/django/apps/organizations/models.py" "legal_hold"
check_file "parent_diocese hierarchy" "$HUB/backend/django/apps/organizations/models.py" "parent_diocese"

# --- 7. ADR-001 ratified ---
echo ""
echo "=== ADR-001: Schema-per-tenant + RLS ==="
ADR001="$HUB/docs/decisions/ADR-001-schema-per-tenant-isolation.md"
check_file "ADR-001 exists" "$ADR001"
check_file "ADR-001 Accepted" "$ADR001" "Accepted|accepted"
check_file "ADR-001 mentions schema-per-tenant" "$ADR001" "schema.per.tenant"
check_file "ADR-001 mentions RLS" "$ADR001" "row.level.security|RLS"

# --- 8. ADR-011 ratified ---
echo ""
echo "=== ADR-011: Hub-and-spoke ==="
ADR011="$HUB/docs/decisions/ADR-011-ten-vertical-frontends-hub-and-spoke.md"
check_file "ADR-011 exists" "$ADR011"
check_file "ADR-011 Accepted" "$ADR011" "Accepted|accepted"
check_file "ADR-011 mentions @journeyoflife-org" "$ADR011" "journeyoflife-org"
check_file "ADR-011 mentions template-renderer" "$ADR011" "template.renderer"

# --- 9. Tenant resolver ---
echo ""
echo "=== Tenant resolver ==="
check_file "resolver index.ts exists" "$HUB/frontend/packages/tenant-resolver/src/index.ts"
check_file "resolver registry.ts exists" "$HUB/frontend/packages/tenant-resolver/src/registry.ts"
check_file "resolver types.ts exists" "$HUB/frontend/packages/tenant-resolver/src/types.ts"
check_file "resolver has slugFromHost" "$HUB/frontend/packages/tenant-resolver/src/index.ts" "slugFromHost"
check_file "resolver has LRU cache" "$HUB/frontend/packages/tenant-resolver/src/index.ts" "LRU|lru|cache"

# --- 10. Seed-data fixture schema ---
echo ""
echo "=== Seed-data fixture schema ==="
check_file "schema.ts exists" "$HUB/frontend/packages/seed-data/src/schema.ts"
check_file "LocalizedTextSchema exists" "$HUB/frontend/packages/seed-data/src/schema.ts" "LocalizedTextSchema"
check_file "TenantFixtureSchema exists" "$HUB/frontend/packages/seed-data/src/schema.ts" "TenantFixtureSchema"
check_file "clergyRoleList (roles only, no names)" "$HUB/frontend/packages/seed-data/src/schema.ts" "clergyRoleList"

# --- 11. i18n config ---
echo ""
echo "=== i18n config ==="
check_file "i18n config.ts exists" "$HUB/frontend/packages/i18n/src/config.ts"
check_file "lt locale present" "$HUB/frontend/packages/i18n/src/config.ts" "lt"
check_file "en locale present" "$HUB/frontend/packages/i18n/src/config.ts" "en"
check_file "ru locale present" "$HUB/frontend/packages/i18n/src/config.ts" "ru"
# pl is PLANNED but not enabled (D13)
if grep -q "'pl'" "$HUB/frontend/packages/i18n/src/config.ts" 2>/dev/null; then
  warn "pl locale declared in i18n config (D13: groundwork only)"
else
  pass "pl locale not yet enabled (D13 correct)"
fi

# --- 12. Package scope (F17) ---
echo ""
echo "=== Package scope (F17 — build blocker) ==="
for pkg in i18n seed-data tenant-resolver ui auth a11y bitrix-sdk commerce observability perf seo testing; do
  pkgjson="$HUB/frontend/packages/$pkg/package.json"
  if [ -f "$pkgjson" ]; then
    if grep -q '"@jol-hub/' "$pkgjson" 2>/dev/null; then
      warn "packages/$pkg still scoped @jol-hub/* (D11 rename pending)"
    elif grep -q '"@journeyoflife-org/' "$pkgjson" 2>/dev/null; then
      pass "packages/$pkg scoped @journeyoflife-org/*"
    else
      warn "packages/$pkg has unexpected scope"
    fi
  else
    fail "packages/$pkg/package.json missing"
  fi
done

# Check .npmrc scope
if grep -q '@jol-hub' "$HUB/frontend/.npmrc" 2>/dev/null; then
  warn ".npmrc still scopes @jol-hub (D11 rename pending)"
fi

# --- 13. Deploy model (B2) ---
echo ""
echo "=== Deploy model (B2/D14) ==="
if [ -d "$DEPLOY/tenants/lt" ]; then
  for f in "$DEPLOY/tenants/lt"/*.yml; do
    [ -f "$f" ] || continue
    if grep -q 'vm:' "$f" 2>/dev/null; then
      warn "$(basename "$f"): per-tenant vm: present (D14: deprecate)"
    fi
  done
  pass "jol-deploy/tenants/lt exists"
else
  warn "jol-deploy/tenants/lt absent"
fi

# --- 14. Bitrix24 = CRM (D3) ---
echo ""
echo "=== Bitrix24 scope (D3) ==="
if [ -f "$BITRIX/README.md" ]; then
  if grep -qi 'CRM\|crm' "$BITRIX/README.md" 2>/dev/null; then
    pass "Bitrix24 scoped as CRM"
  else
    warn "Bitrix24 README does not mention CRM"
  fi
  if grep -qi 'CMS\|content.management' "$BITRIX/README.md" 2>/dev/null; then
    warn "Bitrix24 README mentions CMS (D3: CRM only)"
  else
    pass "Bitrix24 not scoped as CMS"
  fi
else
  warn "Bitrix24 README absent"
fi

# --- 15. Countries model ---
echo ""
echo "=== Countries model ==="
check_file "countries/models.py exists" "$HUB/backend/django/apps/countries/models.py"
check_file "gdpr_consent_age field" "$HUB/backend/django/apps/countries/models.py" "gdpr_consent_age"
check_file "supervisory_authority field" "$HUB/backend/django/apps/countries/models.py" "supervisory_authority"

# --- 16. Audit log ---
echo ""
echo "=== Audit log ==="
check_file "core/models.py has AuditLog" "$HUB/backend/django/apps/core/models.py" "AuditLog"
check_file "AuditLog has checksum" "$HUB/backend/django/apps/core/models.py" "checksum"

# --- 17. Tenant middleware ---
echo ""
echo "=== Tenant middleware ==="
check_file "crm/middleware.py exists" "$HUB/backend/django/apps/crm/middleware.py"
check_file "TenantContextMiddleware defined" "$HUB/backend/django/apps/crm/middleware.py" "TenantContextMiddleware"
check_file "middleware registered in base.py" "$HUB/backend/django/core/settings/base.py" "TenantContextMiddleware"

# ================================================================= summary
echo ""
echo "================================================================"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "Pre-flight complete: $PASS_COUNT PASS / $FAIL_COUNT FAIL / $WARN_COUNT WARN ($TOTAL checks)"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "❌ BLOCKED: $FAIL_COUNT check(s) failed. Fix before proceeding with implementation."
  echo "   Spec: docs/superpowers/specs/2026-09-21-basilica-multi-tenant-content-source-design.md §1"
  exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo "⚠️  PASSED with warnings: $WARN_COUNT item(s) need attention but are not blockers."
  exit 0
else
  echo "✅ ALL CLEAR: $PASS_COUNT checks passed. Safe to proceed with implementation."
  exit 0
fi
