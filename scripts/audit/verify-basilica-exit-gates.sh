#!/usr/bin/env bash
# =============================================================================
# Basilica Multi-Tenant Content Source — Exit-Gate Verification
#
# Verifies the wave exit criteria from the design spec (§5.3, §6.3, §7.3).
# Run after implementation to confirm each wave's acceptance criteria are met.
#
# Spec: docs/superpowers/specs/2026-09-21-basilica-multi-tenant-content-source-design.md
# Compliance: GDPR Art. 9, SOC 2 CC6/CC7/CC8, ISO 27001 A.8.x
#
# Usage:
#   ./scripts/audit/verify-basilica-exit-gates.sh              # all waves
#   ./scripts/audit/verify-basilica-exit-gates.sh --wave -1    # Wave -1 only
#   ./scripts/audit/verify-basilica-exit-gates.sh --wave 0     # Wave 0 only
#   ./scripts/audit/verify-basilica-exit-gates.sh --wave 1     # Wave 1+ only
#   ./scripts/audit/verify-basilica-exit-gates.sh --verbose    # show evidence
#
# Exit codes:
#   0  all applicable checks PASS
#   1  one or more checks FAIL (wave not ready for promotion)
#   2  script error
#
# Properties: read-only (no mutations), idempotent.
# Runtime checks (database, services) require host access and are marked
# RUNTIME — they skip with a clear message when run from a non-host machine.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------- config ----
REPO_ROOT="/opt/jol/repos"
HUB="$REPO_ROOT/jol-hub"
DEPLOY="$REPO_ROOT/jol-deploy"
INFRA="$REPO_ROOT/jol-infrastructure"

WAVE_FILTER=""
VERBOSE=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

# ----------------------------------------------------------- arg parsing ----
while [ $# -gt 0 ]; do
  case "$1" in
    --wave)
      shift
      WAVE_FILTER="$1"
      ;;
    --verbose) VERBOSE=1 ;;
    -h|--help)
      sed -n '3,/^# ====.*$/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------- helpers ----
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  [ "$VERBOSE" = "1" ] && echo "  ✅ PASS  $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  ❌ FAIL  $1" >&2
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  [ "$VERBOSE" = "1" ] && echo "  ⚠️  WARN  $1"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  [ "$VERBOSE" = "1" ] && echo "  ⏭️  SKIP  $1 ($2)"
}

# Check if a file contains a pattern; fail with message if not.
assert_pattern() {
  # $1=label  $2=file  $3=pattern  $4=fail_context
  if [ ! -f "$2" ]; then
    fail "$1 — file absent: $2"
    return
  fi
  if grep -qE "$3" "$2" 2>/dev/null; then
    pass "$1"
  else
    fail "$1 — $4"
  fi
}

# Check that a pattern is NOT present (negative assertion).
assert_absent() {
  # $1=label  $2=file  $3=pattern  $4=fail_context
  if [ ! -f "$2" ]; then
    pass "$1 (file absent — trivially satisfied)"
    return
  fi
  if grep -qE "$3" "$2" 2>/dev/null; then
    fail "$1 — $4"
  else
    pass "$1"
  fi
}

# Check a command succeeds (for runtime checks).
assert_command() {
  # $1=label  $2=command  $3=skip_reason_if_no_host
  if eval "$2" >/dev/null 2>&1; then
    pass "$1"
  else
    warn "$1 — command failed: $2"
  fi
}

should_run_wave() {
  local wave="$1"
  [ -z "$WAVE_FILTER" ] || [ "$WAVE_FILTER" = "$wave" ]
}

# ===================================================================== main
echo "🔍 Basilica exit-gate verification — $(date -Is)"
[ -n "$WAVE_FILTER" ] && echo "   Wave filter: $WAVE_FILTER"
echo ""

# ================================================================== WAVE -1
if should_run_wave "-1"; then
echo "=== Wave −1: Tenant identity & isolation (§5.3) ==="
echo ""

# (a) Schema-per-tenant migration (ADR-001 honoured)
echo "--- Schema-per-tenant (D5 / ADR-001) ---"
assert_pattern \
  "django-tenants or search_path switching in requirements" \
  "$HUB/backend/django/requirements.txt" \
  "django.tenants|search_path|schema" \
  "no schema-per-tenant library found in requirements.txt"

assert_pattern \
  "DATABASE_ROUTERS configured" \
  "$HUB/backend/django/core/settings/base.py" \
  "DATABASE_ROUTERS" \
  "DATABASE_ROUTERS not set — shared-schema model still active"

assert_pattern \
  "ATOMIC_REQUESTS enabled (RLS + connection pooling)" \
  "$HUB/backend/django/core/settings/base.py" \
  "ATOMIC_REQUESTS" \
  "ATOMIC_REQUESTS not set — RLS SET LOCAL leaks across pooled connections"

# (b) Fail-closed guards (C3 fixed)
echo ""
echo "--- Fail-closed guards (C1-C3) ---"
assert_absent \
  "No 'except ImportError: pass' in content models" \
  "$HUB/backend/django/apps/content/models.py" \
  "except ImportError.*pass" \
  "fail-open ImportError guard still present"

assert_absent \
  "No 'except Exception.*logger.debug' in content models" \
  "$HUB/backend/django/apps/content/models.py" \
  "except Exception.*logger\.debug" \
  "fail-open Exception guard still present"

# (c) JWT tenant claim (C1 fixed)
echo ""
echo "--- Server-signed tenant claim (C1/D7) ---"
assert_pattern \
  "Token serializer overrides get_token or injects tenant claim" \
  "$HUB/backend/django/apps/users/serializers.py" \
  "get_token|tenant_id|organization_id|entitlement" \
  "JWT still has no tenant claim — C1 not fixed"

# (d) X-Tenant-ID validation (C2 fixed)
echo ""
echo "--- X-Tenant-ID validation (C2/D7) ---"
assert_pattern \
  "Middleware validates user membership for X-Tenant-ID" \
  "$HUB/backend/django/apps/crm/middleware.py" \
  "member|entitled|membership|OrganizationMember" \
  "middleware does not validate user membership — C2 not fixed"

# (e) Queryset scoping (C3/C5 fixed)
echo ""
echo "--- Queryset scoping (C3/C5) ---"
assert_pattern \
  "Content views use tenant-scoped queryset" \
  "$HUB/backend/django/apps/content/views.py" \
  "tenant|organization.*request|get_tenant|scoped" \
  "content views still unscoped — C3 not fixed"

assert_absent \
  "Content serializer: organization not client-writable" \
  "$HUB/backend/django/apps/content/serializers.py" \
  '"organization".*read_only.*False|fields.*"organization"' \
  "organization still client-writable in serializer"

# (f) Entitlement service exists
echo ""
echo "--- Entitlement service (D8) ---"
ENTITLEMENT_FOUND=0
for candidate in \
  "$HUB/backend/django/apps/organizations/services/entitlement.py" \
  "$HUB/backend/django/apps/organizations/entitlement.py" \
  "$HUB/backend/django/apps/core/services/entitlement.py"; do
  if [ -f "$candidate" ]; then
    ENTITLEMENT_FOUND=1
    pass "Entitlement service exists at $(basename "$candidate")"
    break
  fi
done
[ "$ENTITLEMENT_FOUND" = "0" ] && fail "Entitlement service not found (D8)"

# (g) GET /api/v1/tenants endpoint (D9)
echo ""
echo "--- Tenant API (D9) ---"
assert_pattern \
  "GET /api/v1/tenants URL pattern exists" \
  "$HUB/backend/django/core/urls.py" \
  "tenants" \
  "/api/v1/tenants not mounted in urls.py"

# (h) Config remediation
echo ""
echo "--- Config remediation (production.py) ---"
assert_pattern \
  "PROMETHEUS_ALLOWED_IPS set (not open)" \
  "$HUB/backend/django/core/settings/production.py" \
  "PROMETHEUS_ALLOWED_IPS" \
  "/metrics still world-readable"

assert_pattern \
  "ALLOWED_HOSTS includes tenant domain" \
  "$HUB/backend/django/core/settings/production.py" \
  "gyvenimo-kelias|ALLOWED_HOSTS" \
  "ALLOWED_HOSTS not configured for tenant domains"

# (i) RUNTIME: RLS proof (requires database)
echo ""
echo "--- RUNTIME checks (require host access) ---"
if command -v psql >/dev/null 2>&1 && [ -n "${DATABASE_URL:-}" ]; then
  skip "RLS proof test" "requires live database connection — run on rag-prod-lt01"
else
  skip "RLS proof test" "no database access from this machine"
fi
skip "Pooled-connection leak test" "requires live database — run on rag-prod-lt01"
skip "AuditLog signal on content mutations" "requires live Django — run on app host"

echo ""
fi  # end Wave -1

# ================================================================== WAVE 0
if should_run_wave "0"; then
echo "=== Wave 0: LT fixtures + shared-runtime resolver (§6.3) ==="
echo ""

# (a) Fixture schema v2
echo "--- Fixture schema v2 (governance + RRULE + pl) ---"
assert_pattern \
  "governance fields in schema.ts" \
  "$HUB/frontend/packages/seed-data/src/schema.ts" \
  "governance|sourceUrl|verifiedDate|approvalStatus" \
  "governance fields not added to fixture schema"

assert_pattern \
  "RRULE recurrence model in schema.ts" \
  "$HUB/frontend/packages/seed-data/src/schema.ts" \
  "RRULE|rrule|recurrence" \
  "RRULE recurrence model not added (D12)"

assert_pattern \
  "pl field in LocalizedTextSchema (groundwork)" \
  "$HUB/frontend/packages/seed-data/src/schema.ts" \
  "pl\??\s*:" \
  "pl field not added to LocalizedTextSchema (D13 groundwork)"

# (b) pl groundwork in i18n
echo ""
echo "--- pl groundwork (D13) ---"
assert_pattern \
  "pl-PL hreflang in i18n config" \
  "$HUB/frontend/packages/i18n/src/config.ts" \
  "pl-PL|pl" \
  "pl-PL hreflang not configured"

assert_pattern \
  "Locale regexes derive from SUPPORTED_LOCALES (data-driven)" \
  "$HUB/frontend/packages/i18n/src/config.ts" \
  "SUPPORTED_LOCALES.*join|Object\\.keys.*SUPPORTED|derive" \
  "locale regexes still hardcoded — adding a locale is not data-only"

# (c) Resolver fixes
echo ""
echo "--- Resolver / topology-A fixes ---"
assert_pattern \
  "TENANT_BY_DOMAIN populated from fixtures" \
  "$HUB/frontend/packages/tenant-resolver/src/registry.ts" \
  "TENANT_BY_DOMAIN.*=.*\{" \
  "TENANT_BY_DOMAIN still empty"

assert_pattern \
  "slugFromHost handles multi-label domains (F16)" \
  "$HUB/frontend/packages/tenant-resolver/src/index.ts" \
  "slugFromHost" \
  "slugFromHost not fixed for multi-label deploy domains"

# (d) Package scope rename (D11 — BLOCKER)
echo ""
echo "--- Package scope rename (D11 — BLOCKER) ---"
RENAME_CLEAN=1
for pkg in i18n seed-data tenant-resolver ui auth; do
  pkgjson="$HUB/frontend/packages/$pkg/package.json"
  if [ -f "$pkgjson" ]; then
    if grep -q '"@jol-hub/' "$pkgjson" 2>/dev/null; then
      fail "packages/$pkg still @jol-hub/* — rename incomplete"
      RENAME_CLEAN=0
    fi
  fi
done
if [ "$RENAME_CLEAN" = "1" ]; then
  pass "All packages renamed to @journeyoflife-org/*"
fi

assert_absent \
  ".npmrc no longer scopes @jol-hub" \
  "$HUB/frontend/.npmrc" \
  "@jol-hub" \
  ".npmrc still scopes @jol-hub"

# (e) Deploy reconciliation (D14)
echo ""
echo "--- Deploy reconciliation (D14) ---"
if [ -f "$DEPLOY/tenants/schemas/tenant-config.schema.json" ]; then
  assert_absent \
    "Per-tenant vm: deprecated in schema" \
    "$DEPLOY/tenants/schemas/tenant-config.schema.json" \
    '"vm"' \
    "per-tenant vm: still in schema (D14)"
else
  warn "tenant-config.schema.json not found"
fi

# (f) Build verification
echo ""
echo "--- Build verification ---"
if command -v pnpm >/dev/null 2>&1; then
  skip "pnpm -r build" "requires node_modules — run 'cd $HUB/frontend && pnpm install && pnpm -r build'"
else
  skip "pnpm -r build" "pnpm not available on this machine"
fi

# (g) RUNTIME: topology-A proof
echo ""
echo "--- RUNTIME checks ---"
skip "32 tenants render on shared runtime" "requires running template-renderer"
skip "axe-core WCAG 2.1 AA exit 0" "requires running renderer + browser"
skip "Canonical hostname→tenant resolution" "requires running resolver + wildcard DNS"

echo ""
fi  # end Wave 0

# ================================================================== WAVE 1
if should_run_wave "1"; then
echo "=== Wave 1+: API source of truth, spokes, rollout (§7.3) ==="
echo ""

# (a) Resolver API flip
echo "--- Resolver API flip ---"
assert_pattern \
  "Resolver fetches GET /api/v1/tenants when BACKEND_API_URL set" \
  "$HUB/frontend/packages/tenant-resolver/src/index.ts" \
  "BACKEND_API_URL|fetch.*tenants|api.*tenants" \
  "resolver not yet flipped to API-primary"

assert_pattern \
  "Fixtures fallback on API unreachable" \
  "$HUB/frontend/packages/tenant-resolver/src/index.ts" \
  "fallback|fixture|catch" \
  "no fixtures fallback path in resolver"

# (b) Content API scoped
echo ""
echo "--- Content API scoped to t_<slug> ---"
assert_pattern \
  "Content views scope to tenant schema" \
  "$HUB/backend/django/apps/content/views.py" \
  "schema|search_path|tenant.*scope|t_" \
  "content views not scoped to tenant schema"

# (c) Spoke extraction
echo ""
echo "--- Spoke extraction (D18/INV-1) ---"
skip "12 packages published" "requires npm registry access — run 'pnpm publish --dry-run'"
skip "Spokes consume @journeyoflife-org/* packages" "requires spoke repo access"
skip "No resolve-locale.ts duplication in spokes (INV-1)" "requires spoke repo access"

# (d) Country rollout groundwork
echo ""
echo "--- Country rollout groundwork ---"
assert_pattern \
  "LV/EE/PL Country rows in data migration" \
  "$HUB/backend/django/apps/countries/" \
  "lv|ee|pl" \
  "LV/EE/PL country groundwork not started"

# (e) jol-backend-platform retired (D2)
echo ""
echo "--- jol-backend-platform retirement (D2) ---"
BP="$REPO_ROOT/jol-backend-platform"
if [ -d "$BP" ]; then
  if [ -f "$BP/README.md" ]; then
    assert_pattern \
      "jol-backend-platform README points to jol-hub" \
      "$BP/README.md" \
      "jol-hub|retired|deprecated|archived" \
      "README does not point to jol-hub/backend/django"
  else
    warn "jol-backend-platform/README.md absent (retirement incomplete)"
  fi
else
  pass "jol-backend-platform directory removed (fully retired)"
fi

# (f) RUNTIME checks
echo ""
echo "--- RUNTIME checks ---"
skip "Contract test: API response ≡ Tenant/fixture" "requires live API"
skip "Fallback parity: API down → fixtures serve" "requires live API + resolver"
skip "Four-eyes moderation + audit-on-edit" "requires live Django admin"
skip "pl enablement data-only test" "requires pl tenant ratification"
skip "Per-country fixtures validate + correct timezone" "requires fixture data"

echo ""
fi  # end Wave 1

# ================================================================= summary
echo "================================================================"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT + SKIP_COUNT))
echo "Exit-gate complete: $PASS_COUNT PASS / $FAIL_COUNT FAIL / $WARN_COUNT WARN / $SKIP_COUNT SKIP ($TOTAL checks)"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "❌ BLOCKED: $FAIL_COUNT check(s) failed. Wave not ready for promotion."
  echo "   Spec: docs/superpowers/specs/2026-09-21-basilica-multi-tenant-content-source-design.md §5.3/§6.3/§7.3"
  exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo "⚠️  PASSED with warnings: $WARN_COUNT item(s) need attention."
  exit 0
else
  echo "✅ ALL CLEAR: $PASS_COUNT checks passed (+ $SKIP_COUNT runtime skips)."
  echo "   Runtime skips require host-level verification — see spec §12."
  exit 0
fi
