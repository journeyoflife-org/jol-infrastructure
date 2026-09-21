# Wave 1 — API Source of Truth, Editing, Spokes, LV/EE/PL

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip the resolver from fixture-only to API-primary with fixtures fallback, expose content via scoped API, enable editing workflow, publish packages for spoke consumption, and add LV/EE/PL country groundwork.

**Architecture:** API becomes source of truth for tenant resolution and content delivery. Resolver fetches `GET /api/v1/tenants` via mTLS with LRU cache and circuit-breaker; fixtures remain fallback. Content API scoped to `t_<slug>` schema. Editing via tenant-scoped Django admin (near-term) then admin-dashboard (strategic). Packages published to npm for spoke consumption.

**Tech Stack:** Django 6.0.3 + DRF 3.16, mTLS (client certificates), Zod schemas, pnpm workspace, Ansible Vault for secrets

**Prerequisites:** Wave −1 (PR #136) merged; Wave 0 (PR #137) merged; packages publishable.

---

## Task 1: Tenant API Endpoint (`GET /api/v1/tenants`)

**Files:**
- Create: `jol-hub/backend/django/core/api/tenants.py`
- Modify: `jol-hub/backend/django/core/urls.py`
- Test: `jol-hub/backend/django/core/tests/test_tenants_api.py`

- [ ] **Step 1: Write failing test for tenant list endpoint**

```python
# core/tests/test_tenants_api.py
import pytest
from django.test import Client
from django.urls import reverse

@pytest.mark.django_db
def test_tenants_api_returns_resolver_shape():
    """API returns the same shape as resolver fixtures."""
    client = Client()
    response = client.get(reverse("tenant-list"))
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) > 0
    # Must match resolver Tenant shape
    tenant = data[0]
    assert "slug" in tenant
    assert "name" in tenant
    assert "vertical" in tenant
    assert "locale" in tenant
    assert "schema" in tenant  # t_<slug>
    assert "domain" in tenant

@pytest.mark.django_db
def test_tenants_api_no_cross_tenant_leakage():
    """Each tenant row has only its own data."""
    client = Client()
    response = client.get(reverse("tenant-list"))
    data = response.json()
    slugs = {t["slug"] for t in data}
    # No duplicate slugs
    assert len(slugs) == len(data)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd jol-hub/backend/django
pytest core/tests/test_tenants_api.py -v
```

Expected: FAIL — URL not found

- [ ] **Step 3: Implement tenant list view**

```python
# core/api/tenants.py
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from organizations.models import Organization

class TenantListView(viewsets.ViewSet):
    """
    GET /api/v1/tenants — returns resolver-compatible tenant list.
    
    Server-to-server only. No client-side enumeration.
    Response shape matches tenant-resolver Tenant fixture schema.
    """
    authentication_classes = []  # mTLS at ingress, not Django-level
    permission_classes = []  # mTLS at ingress

    def list(self, request):
        """Return all active tenants in resolver-compatible shape."""
        tenants = Organization.objects.filter(
            is_active=True,
            vertical__isnull=False,
        ).select_related("website", "country")
        
        result = []
        for org in tenants:
            result.append({
                "slug": org.slug,
                "name": {"lt": org.name_lt, "en": org.name_en or org.name_lt},
                "vertical": org.vertical,
                "locale": org.locale or "lt",
                "schema": f"t_{org.slug}",
                "domain": org.website.domain if org.website else None,
                "country": org.country.code if org.country else "LT",
            })
        
        return Response(result)
```

- [ ] **Step 4: Register URL**

```python
# core/urls.py — add to urlpatterns
from core.api.tenants import TenantListView

urlpatterns = [
    # ... existing
    path("api/v1/tenants/", TenantListView.as_view({"get": "list"}), name="tenant-list"),
]
```

- [ ] **Step 5: Run test to verify it passes**

```bash
pytest core/tests/test_tenants_api.py -v
```

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add core/api/tenants.py core/urls.py core/tests/test_tenants_api.py
git commit -m "feat(api): add GET /api/v1/tenants endpoint (resolver-compatible shape)"
```

---

## Task 2: Resolver API Flip (API-Primary, Fixtures Fallback)

**Files:**
- Modify: `jol-hub/frontend/packages/tenant-resolver/src/registry.ts`
- Modify: `jol-hub/frontend/packages/tenant-resolver/src/index.ts`
- Test: `jol-hub/frontend/packages/tenant-resolver/src/__tests__/api-fallback.test.ts`

- [ ] **Step 1: Write failing test for API-primary resolution**

```typescript
// tenant-resolver/src/__tests__/api-fallback.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { resolveTenant } from '../registry';

describe('API-primary resolution', () => {
  beforeEach(() => {
    vi.stubEnv('BACKEND_API_URL', 'https://api.gyvenimo-kelias.lt');
    vi.stubEnv('MTLS_CERT_PATH', '/etc/ssl/certs/resolver.crt');
    vi.stubEnv('MTLS_KEY_PATH', '/etc/ssl/private/resolver.key');
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  it('fetches from API when BACKEND_API_URL set', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([
        { slug: 'test-parish', name: { lt: 'Test' }, vertical: 'parish', locale: 'lt', schema: 't_test-parish', domain: 'test.gyvenimo-kelias.lt' }
      ]),
    });
    vi.stubGlobal('fetch', mockFetch);

    const result = await resolveTenant('test.gyvenimo-kelias.lt');
    expect(result?.slug).toBe('test-parish');
    expect(mockFetch).toHaveBeenCalledOnce();
  });

  it('falls back to fixtures on API failure', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network error'));
    vi.stubGlobal('fetch', mockFetch);

    const result = await resolveTenant('gyvenimo-kelias.lt');
    expect(result?.slug).toBe('gyvenimo-kelias'); // from fixtures
  });

  it('returns null on unknown tenant (no enumeration)', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([]),
    });
    vi.stubGlobal('fetch', mockFetch);

    const result = await resolveTenant('unknown.example.com');
    expect(result).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd jol-hub/frontend
pnpm --filter @journeyoflife-org/tenant-resolver test -- api-fallback
```

Expected: FAIL — `resolveTenant` doesn't fetch from API yet

- [ ] **Step 3: Implement API fetch with fixtures fallback**

```typescript
// tenant-resolver/src/registry.ts — add at top
import { LRUCache } from 'lru-cache';

const TENANT_API_URL = process.env.BACKEND_API_URL;
const MTLS_CERT = process.env.MTLS_CERT_PATH;
const MTLS_KEY = process.env.MTLS_KEY_PATH;

// LRU cache for API responses (TTL 5 min)
const tenantCache = new LRUCache<string, any[]>({
  max: 100,
  ttl: 5 * 60 * 1000,
});

// Circuit-breaker state
let circuitOpen = false;
let circuitResetAt = 0;
const CIRCUIT_BREAK_THRESHOLD = 3;
const CIRCUIT_RESET_MS = 60 * 1000;
let failureCount = 0;

async function fetchTenantsFromAPI(): Promise<any[] | null> {
  if (!TENANT_API_URL) return null;
  
  // Circuit-breaker check
  if (circuitOpen) {
    if (Date.now() < circuitResetAt) return null;
    circuitOpen = false;
    failureCount = 0;
  }

  const cached = tenantCache.get('tenants');
  if (cached) return cached;

  try {
    const response = await fetch(`${TENANT_API_URL}/api/v1/tenants/`, {
      headers: { Accept: 'application/json' },
      // mTLS handled at ingress (nginx/Envoy), not fetch-level
    });

    if (!response.ok) throw new Error(`API ${response.status}`);

    const tenants = await response.json();
    tenantCache.set('tenants', tenants);
    failureCount = 0;
    return tenants;
  } catch (error) {
    failureCount++;
    if (failureCount >= CIRCUIT_BREAK_THRESHOLD) {
      circuitOpen = true;
      circuitResetAt = Date.now() + CIRCUIT_RESET_MS;
      console.warn('[tenant-resolver] API circuit-breaker open, falling back to fixtures');
    }
    return null;
  }
}

// Modify resolveTenant to try API first
export async function resolveTenant(domain: string): Promise<Tenant | null> {
  // Try API first
  if (TENANT_API_URL) {
    const apiTenants = await fetchTenantsFromAPI();
    if (apiTenants) {
      const match = apiTenants.find((t) => t.domain === domain);
      if (match) return match;
      // Unknown tenant → 404 (no enumeration)
      return null;
    }
    // API unreachable → fall through to fixtures
  }

  // Fixtures fallback
  // ... existing fixture resolution logic
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pnpm --filter @journeyoflife-org/tenant-resolver test -- api-fallback
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add frontend/packages/tenant-resolver/src/registry.ts frontend/packages/tenant-resolver/src/__tests__/api-fallback.test.ts
git commit -m "feat(resolver): API-primary with fixtures fallback + circuit-breaker"
```

---

## Task 3: Content API Scoping (`/api/v1/content/` → `t_<slug>`)

**Files:**
- Modify: `jol-hub/backend/django/content/views.py`
- Modify: `jol-hub/backend/django/content/serializers.py`
- Test: `jol-hub/backend/django/content/tests/test_scoped_content.py`

- [ ] **Step 1: Write failing test for scoped content API**

```python
# content/tests/test_scoped_content.py
import pytest
from django.test import Client
from django.urls import reverse
from content.models import Page

@pytest.mark.django_db
def test_content_api_scoped_to_tenant():
    """Content API returns only pages for the requested tenant schema."""
    client = Client()
    # Request content for tenant A
    response = client.get(
        reverse("page-list"),
        HTTP_X_TENANT_ID="tenant-a",
    )
    assert response.status_code == 200
    data = response.json()
    # All pages belong to tenant A
    for page in data["results"]:
        assert page["organization"] == "tenant-a"

@pytest.mark.django_db
def test_content_api_cross_tenant_returns_404():
    """Requesting content for a different tenant returns 404."""
    client = Client()
    response = client.get(
        reverse("page-list"),
        HTTP_X_TENANT_ID="tenant-b",
    )
    # Tenant B has no pages → 404 (no enumeration)
    assert response.status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest content/tests/test_scoped_content.py -v
```

Expected: FAIL — content API not scoped yet

- [ ] **Step 3: Implement tenant-scoped content view**

```python
# content/views.py — modify PageViewSet
from rest_framework import viewsets
from rest_framework.response import Response
from .models import Page
from .serializers import PageSerializer

class PageViewSet(viewsets.ModelViewSet):
    """Tenant-scoped page API."""
    serializer_class = PageSerializer

    def get_queryset(self):
        """Scope queryset to the verified tenant."""
        tenant_id = self.request.headers.get("X-Tenant-ID")
        if not tenant_id:
            return Page.objects.none()
        
        # Verify tenant entitlement (Wave -1 middleware sets request.tenant)
        if not hasattr(self.request, "tenant") or self.request.tenant.slug != tenant_id:
            return Page.objects.none()
        
        return Page.objects.filter(organization=self.request.tenant)

    def list(self, request, *args, **kwargs):
        queryset = self.get_queryset()
        if not queryset.exists():
            return Response(status=404)  # No enumeration
        return super().list(request, *args, **kwargs)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest content/tests/test_scoped_content.py -v
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add backend/django/content/views.py backend/django/content/tests/test_scoped_content.py
git commit -m "feat(content): scope /api/v1/content/ to t_<slug> schema"
```

---

## Task 4: Tenant-Scoped Django Admin

**Files:**
- Modify: `jol-hub/backend/django/content/admin.py`
- Modify: `jol-hub/backend/django/organizations/admin.py`

- [ ] **Step 1: Scope content admin to entitled tenants**

```python
# content/admin.py
from django.contrib import admin
from .models import Page

@admin.register(Page)
class PageAdmin(admin.ModelAdmin):
    list_display = ["title", "slug", "language", "organization"]
    list_filter = ["language", "organization"]
    search_fields = ["title", "slug"]

    def get_queryset(self, request):
        """Scope admin queryset to entitled tenants."""
        qs = super().get_queryset(request)
        if hasattr(request, "tenant"):
            return qs.filter(organization=request.tenant)
        # Superuser with no tenant context → no data
        return qs.none()

    def formfield_for_foreignkey(self, db_field, request, **kwargs):
        """Lock organization to entitled set."""
        if db_field.name == "organization" and hasattr(request, "tenant"):
            kwargs["queryset"] = type(request.tenant).objects.filter(pk=request.tenant.pk)
        return super().formfield_for_foreignkey(db_field, request, **kwargs)
```

- [ ] **Step 2: Commit**

```bash
git add backend/django/content/admin.py backend/django/organizations/admin.py
git commit -m "feat(admin): scope Django admin to entitled tenants (no cross-tenant)"
```

---

## Task 5: LV/EE/PL Country Groundwork

**Files:**
- Create: `jol-hub/backend/django/countries/fixtures/countries_lv.json`
- Create: `jol-hub/backend/django/countries/fixtures/countries_ee.json`
- Create: `jol-hub/backend/django/countries/fixtures/countries_pl.json`
- Create: `jol-deploy/tenants/lv/.gitkeep`
- Create: `jol-deploy/tenants/ee/.gitkeep`
- Create: `jol-deploy/tenants/pl/.gitkeep`

- [ ] **Step 1: Create LV country fixture**

```json
// countries/fixtures/countries_lv.json
[
  {
    "model": "countries.country",
    "pk": "LV",
    "fields": {
      "name": "Latvija",
      "default_language": "lv",
      "timezone": "Europe/Riga",
      "gdpr_consent_age": 16,
      "supervisory_authority": "Datu valsts inspekcija",
      "vat_rate": 21.0
    }
  }
]
```

- [ ] **Step 2: Create EE country fixture**

```json
// countries/fixtures/countries_ee.json
[
  {
    "model": "countries.country",
    "pk": "EE",
    "fields": {
      "name": "Eesti",
      "default_language": "et",
      "timezone": "Europe/Tallinn",
      "gdpr_consent_age": 16,
      "supervisory_authority": "Andmekaitse Inspektsioon",
      "vat_rate": 22.0
    }
  }
]
```

- [ ] **Step 3: Create PL country fixture**

```json
// countries/fixtures/countries_pl.json
[
  {
    "model": "countries.country",
    "pk": "PL",
    "fields": {
      "name": "Polska",
      "default_language": "pl",
      "timezone": "Europe/Warsaw",
      "gdpr_consent_age": 16,
      "supervisory_authority": "Urząd Ochrony Danych Osobowych",
      "vat_rate": 23.0
    }
  }
]
```

- [ ] **Step 4: Create tenant directories**

```bash
mkdir -p jol-deploy/tenants/{lv,ee,pl}
touch jol-deploy/tenants/{lv,ee,pl}/.gitkeep
```

- [ ] **Step 5: Commit**

```bash
git add backend/django/countries/fixtures/countries_*.json jol-deploy/tenants/{lv,ee,pl}/.gitkeep
git commit -m "feat(countries): add LV/EE/PL groundwork (fixtures + deploy dirs)"
```

---

## Task 6: `pl` Enablement (Gated D13)

**Files:**
- Modify: `jol-hub/frontend/packages/i18n/src/config.ts`
- Create: `jol-hub/frontend/packages/i18n/messages/pl.json`
- Modify: `jol-hub/frontend/packages/i18n/src/middleware.ts`

- [ ] **Step 1: Add `pl` to SUPPORTED_LOCALES**

```typescript
// i18n/src/config.ts
export const SUPPORTED_LOCALES: readonly SupportedLocale[] = [
  "lt",
  "ru",
  "en",
  "pl", // Added — D13 gated, requires ratified PL tenant + DPIA/ROPA
];

export const LOCALE_CONFIGS: Record<SupportedLocale, LocaleConfig> = {
  // ... existing
  pl: {
    code: "pl",
    name: "Polski",
    hreflang: "pl-PL",
    dir: "ltr",
  },
};

export const FALLBACK_ORDER: Record<SupportedLocale, SupportedLocale[]> = {
  lt: ["ru", "en"],
  ru: ["en", "lt"],
  en: ["lt", "ru"],
  pl: ["en", "lt"], // Polish → English → Lithuanian
};
```

- [ ] **Step 2: Create Polish messages file**

```json
// i18n/messages/pl.json
{
  "common": {
    "loading": "Ładowanie...",
    "error": "Błąd",
    "notFound": "Nie znaleziono"
  }
}
```

- [ ] **Step 3: Update middleware regex (SSOT-derived)**

```typescript
// i18n/src/middleware.ts — line 34
// Before: const LOCALE_PATTERN = /(lt|ru|en)/;
// After: derived from SUPPORTED_LOCALES
import { SUPPORTED_LOCALES } from "./config";

const LOCALE_PATTERN = new RegExp(`(${SUPPORTED_LOCALES.join("|")})`);
```

- [ ] **Step 4: Commit**

```bash
git add frontend/packages/i18n/src/config.ts frontend/packages/i18n/messages/pl.json frontend/packages/i18n/src/middleware.ts
git commit -m "feat(i18n): enable pl locale (D13 gated — requires PL tenant + DPIA)"
```

---

## Task 7: Retire `jol-backend-platform` (D2)

**Files:**
- Modify: `jol-backend-platform/README.md`
- Modify: `jol-infrastructure/AGENTS.md`

- [ ] **Step 1: Archive jol-backend-platform with pointer README**

```markdown
<!-- jol-backend-platform/README.md -->
# jol-backend-platform — ARCHIVED

**Status:** Archived (2026-09-XX)

**Reason:** Empty repository. Real backend is `jol-hub/backend/django` (Django 6.0.3 + DRF 3.16).

**Successor:** [`jol-hub/backend/django`](https://github.com/journeyoflife-org/jol-hub/tree/main/backend/django)

**Decision:** D2 in [Basilica Multi-Tenant Content Source Design](https://github.com/journeyoflife-org/jol-infrastructure/blob/main/docs/superpowers/specs/2026-09-21-basilica-multi-tenant-content-source-design.md)
```

- [ ] **Step 2: Update AGENTS.md ecosystem map**

```markdown
# AGENTS.md — remove jol-backend-platform from Tier 0
# Before:
# ├── jol-hub
# └── jol-backend-platform
# After:
# └── jol-hub
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "chore: archive jol-backend-platform (D2 — empty repo, successor is jol-hub)"
```

---

## Task 8: Package Publishing (`@journeyoflife-org/*`)

**Files:**
- Create: `jol-hub/.npmrc`
- Modify: `jol-hub/frontend/packages/*/package.json` (publishConfig)

- [ ] **Step 1: Configure npm registry**

```ini
# .npmrc
@journeyoflife-org:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NPM_TOKEN}
```

- [ ] **Step 2: Add publishConfig to packages**

```json
// frontend/packages/*/package.json — add to each
{
  "publishConfig": {
    "access": "restricted",
    "registry": "https://npm.pkg.github.com"
  }
}
```

- [ ] **Step 3: Dry-run publish**

```bash
cd jol-hub/frontend
NPM_TOKEN=xxx pnpm -r publish --dry-run
```

Expected: All 12 packages publish successfully (dry-run)

- [ ] **Step 4: Commit**

```bash
git add .npmrc frontend/packages/*/package.json
git commit -m "feat(packages): configure @journeyoflife-org/* for GitHub npm registry"
```

---

## Task 9: Spoke Extraction (D18/Q3)

**Files:**
- Modify: `jol-site-*/src/lib/resolve-locale.ts` (delete)
- Modify: `jol-site-*/package.json` (add `@journeyoflife-org/i18n` dependency)

- [ ] **Step 1: Replace spoke `resolve-locale.ts` with shared package**

```typescript
// jol-site-*/src/lib/resolve-locale.ts — DELETE
// Replace with:
import { resolveLocale } from "@journeyoflife-org/i18n";

export { resolveLocale };
```

- [ ] **Step 2: Add dependency to spoke package.json**

```json
// jol-site-*/package.json
{
  "dependencies": {
    "@journeyoflife-org/i18n": "workspace:*"
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add jol-site-*/src/lib/resolve-locale.ts jol-site-*/package.json
git commit -m "refactor(spokes): replace duplicated resolve-locale with @journeyoflife-org/i18n (INV-1)"
```

---

## Task 10: Contract Test (API ≡ Fixtures)

**Files:**
- Create: `jol-hub/backend/django/core/tests/test_api_fixture_parity.py`

- [ ] **Step 1: Write contract test**

```python
# core/tests/test_api_fixture_parity.py
import pytest
from django.test import Client
from django.urls import reverse

@pytest.mark.django_db
def test_api_response_matches_fixture_shape():
    """API tenant list shape ≡ resolver fixture shape."""
    client = Client()
    response = client.get(reverse("tenant-list"))
    assert response.status_code == 200
    api_tenants = response.json()
    
    # Load fixtures
    from seed_data.registry import TENANTS
    fixture_tenants = TENANTS
    
    # Same count
    assert len(api_tenants) == len(fixture_tenants)
    
    # Same slugs
    api_slugs = {t["slug"] for t in api_tenants}
    fixture_slugs = {t["slug"] for t in fixture_tenants}
    assert api_slugs == fixture_slugs
    
    # Same shape
    for api_t in api_tenants:
        fixture_t = next((t for t in fixture_tenants if t["slug"] == api_t["slug"]), None)
        assert fixture_t is not None
        assert set(api_t.keys()) == set(fixture_t.keys())
```

- [ ] **Step 2: Run test**

```bash
pytest core/tests/test_api_fixture_parity.py -v
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add backend/django/core/tests/test_api_fixture_parity.py
git commit -m "test(api): contract test — API response ≡ fixture shape"
```

---

## Task 11: Rollback Drill (API Down → Fixtures Serve)

**Files:**
- Create: `jol-deploy/deployment/strategies/api-fallback-drill.sh`

- [ ] **Step 1: Create rollback drill script**

```bash
#!/usr/bin/env bash
# deployment/strategies/api-fallback-drill.sh
# Rollback drill: simulate API failure, verify fixtures serve

set -euo pipefail

echo "=== API Fallback Drill ==="
echo "1. Stop backend API"
systemctl stop jol-backend

echo "2. Request tenant resolution"
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" https://gyvenimo-kelias.lt/api/v1/tenants/)

if [ "$RESPONSE" = "200" ]; then
  echo "✓ Fixtures serving (HTTP 200)"
else
  echo "✗ Fixtures NOT serving (HTTP $RESPONSE)"
  systemctl start jol-backend
  exit 1
fi

echo "3. Restart backend API"
systemctl start jol-backend

echo "=== Drill PASS ==="
```

- [ ] **Step 2: Make executable**

```bash
chmod +x jol-deploy/deployment/strategies/api-fallback-drill.sh
```

- [ ] **Step 3: Commit**

```bash
git add jol-deploy/deployment/strategies/api-fallback-drill.sh
git commit -m "feat(deploy): API fallback rollback drill script"
```

---

## Summary

**11 tasks**, targeting:
- **jol-hub** (backend + frontend): Tasks 1–4, 6, 8, 10
- **jol-deploy**: Tasks 5, 11
- **jol-backend-platform**: Task 7
- **jol-site-*** spokes: Task 9

**Exit gate (§7.3):**
- Contract + fallback-parity tests ✓ (Tasks 10, 11)
- Wave −1 isolation re-run at API layer ✓ (Task 3)
- Tenant-scoped admin cannot cross tenants ✓ (Task 4)
- `pl`-enablement data-only test ✓ (Task 6)
- Per-country fixtures validate ✓ (Task 5)
- Rollback drill: API down → fixtures serve ✓ (Task 11)
- `pnpm publish --dry-run` exit 0 ✓ (Task 8)

**Open findings remaining after Wave 1:**
- F5: Bitrix24 deployment-model contradiction (DPIA required)
- F7: `LANGUAGE_CODE=en-us`, `TIME_ZONE=UTC` (LT-first)
- F9: `postgres/postgres` default creds; AuditLog not wired
- F11: `.env`/`*.db` verify never committed
- F19: Spoke `resolve-locale.ts` duplicates (closed by Task 9)
