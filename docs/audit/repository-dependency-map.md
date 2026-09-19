# JOL Repository Dependency Map

**Generated:** 2026-09-18  
**Organization:** `journeyoflife-org`  
**Source:** Empirical code scan (`scripts/audit/phase3-dependency-scan.py`) cross-checked against AGENTS.md §1 Ecosystem Map, GitHub API, local code inspection

---

## EMPIRICAL VERIFICATION (Phase 3 code scan) — source of truth

The conceptual tier map below (from AGENTS.md) describes **contractual/architectural intent**. An
automated scan of the actual manifests, imports, `uses:` workflow references, and deployment
sources found that **most declared code-level edges do not yet exist in the repos.** Both views
are recorded so remediation priorities are evidence-based.

### Edges CONFIRMED in code

| Coupling type | Consumer → Provider | Evidence |
|---------------|---------------------|----------|
| **Shared CI workflows** | all 10 `jol-site-*` → **`.github`** | `uses: journeyoflife-org/.github/.github/workflows/{frontend-build,frontend-test,security-scan,payment-boundary-guard,compliance-check}.yml@main` |
| **Shared CI workflows** | `jol-hub` (embedded template) → **`.github`** | `docs/templates/jol-frontend-repo-template/.github/workflows/ci.yml` |
| **Node package deps** | 9 `jol-site-*` → **`@jol-hub/*`** (a11y, auth, commerce, i18n, observability, perf, seed-data, seo, tenant-resolver, ui) | `package.json` |
| **Runtime HTTP** | `jol-rag-server` → `jol-llm` | host protocol :11434 (documented; not visible to static scan) |

### Edges DECLARED in AGENTS.md but NOT found in code (aspirational / not-yet-wired)

| Declared edge | Scan result |
|---------------|-------------|
| `jol-rag-server` → `jol-core`, `jol-auth` (package import) | **NO import / manifest reference found** |
| `jol-mcp-servers` → `jol-core` (shared audit/auth models) | **NO package reference found** |
| `jol-analytics-ai`, `jol-bitrix24-integration`, `jol-ecommerce-engine` → `jol-core` | **Only self-imports detected** (`jol_analytics_ai`, `jol_bitrix24_integration`, `jol_commerce`) |
| `jol-link-registry` → `jol-core` | **NO reference found** |
| Any repo → `jol-devops` reusable workflows | **NO repo uses `jol-devops`; reusable CI is hosted by `.github`** |
| Terraform `git::` / Helm / `.gitmodules` cross-repo sources | **ZERO found across all 29 repos** |

**Python internal package deps detected: 0** (only self-referential imports).
**Deployment-source cross-repo refs (tf-git/helm/submodule): 0.**

### Findings to feed remediation

- **F-DEP-1 (MEDIUM):** No repo consumes `jol-core` / `jol-auth` as installable packages, despite the Tier-0 "contract" role. Either the contract repos are not yet published as importable artifacts, or consumers inline their own models. Tenant-isolation and shared-model guarantees therefore rest on convention, not enforced dependency.
- **F-DEP-2 (HIGH, drift):** `jol-site-basilica` depends on `@journeyoflife-org/*` while the other **9** spokes depend on `@jol-hub/*`. Two divergent package scopes for one hub fleet. Correlates with the dirty-tree state (basilica was left on a different branch state in the Stage-0 remediation). Needs reconciliation to a single scope.
- **F-DEP-3 (INFORMATIONAL):** `.github` is a **single point of CI coupling** for all 10 spokes + the hub template. A breaking change to `.github/.github/workflows/*` gates 11 repos at once — elevate `.github` criticality for CI-integrity purposes.

---

## Tier 0 — Contracts (Foundation Layer) — CONCEPTUAL VIEW

| Repository | Role | Depends On | Depended On By |
|-----------|------|-----------|----------------|
| `jol-core` | Domain models, shared contracts | — | ALL Tier 1/2/3 repos |
| `jol-hub` | Enterprise monorepo (frontend + backend + shared packages) | `jol-core`, `jol-auth` | `jol-site-*` spokes (via `@jol-hub/*` packages) |
| `jol-auth` | Identity, OAuth 2.0 / OIDC, RBAC | `jol-core` | `jol-hub`, `jol-rag-server`, `jol-ecommerce-engine` |

## Tier 1 — Primary Applications

| Repository | Role | Depends On | Depended On By |
|-----------|------|-----------|----------------|
| `jol-rag-server` | RAG retrieval (Qdrant, MinIO, Ollama client) | `jol-core`, `jol-auth`, `jol-llm` (runtime) | `jol-hub` (UI), `jol-analytics-ai` |
| `jol-ecommerce-engine` | Payments, VAT, orders | `jol-core`, `jol-auth` | `jol-hub` (commerce UI) |
| `jol-analytics-ai` | Telemetry, reporting, data enrichment | `jol-core`, `jol-rag-server` | `jol-hub` (dashboards) |

## Tier 2 — AI Estate

| Repository | Role | Depends On | Depended On By |
|-----------|------|-----------|----------------|
| `jol-llm` | Ollama inference, model management | `jol-infrastructure` (Ansible, systemd) | `jol-rag-server` (runtime: `mistral-7b-instruct` alias) |
| `jol-mcp-servers` | MCP tool registry (stdio, 4 servers) | `jol-core`, `jol-infrastructure` (systemd) | `jol-hermes-agents` (aspirational) |
| `jol-hermes-agents` | Hermes agent contracts (declarative only, NO runtime) | — (self-contained YAML) | Future runtime TBD |

## Tier 3 — Integrations

| Repository | Role | Depends On | Depended On By |
|-----------|------|-----------|----------------|
| `jol-link-registry` | Web link registry + validation | `jol-core` | Platform services |
| `jol-domain-taxonomy` | Denominations, institution types, geo mappings | — | `jol-core`, `jol-hub` (seed data) |
| `jol-bitrix24-integration` | Bitrix24 CRM sync | `jol-core`, `jol-auth` | Platform CRM workflows |

## Tier 4 — Infrastructure / Governance

| Repository | Role | Depends On | Depended On By |
|-----------|------|-----------|----------------|
| `jol-infrastructure` | Fleet mgmt, hardening, Helm, Terraform, Ansible | — | `jol-llm`, `jol-mcp-servers` (deployment assets) |
| `jol-devops` | CI/CD workflows, runbooks, observability | — | Fleet-wide (reusable workflows) |
| `jol-security` | SOC 2 / GDPR / ISO 27001 compliance artifacts | — | Fleet-wide (policies) |
| `jol-compliance` | GDPR DSR, retention, evidence collection | — | Fleet-wide (compliance scripts) |
| `jol-scripts` | Utility scripts | — | Fleet-wide (maintenance) |

## Site Spokes (Frontend — 10 repos)

All spokes follow the same pattern: Next.js 14, consuming `@jol-hub/*` shared packages.

| Repository | Vertical | Depends On |
|-----------|----------|-----------|
| `jol-site-basilica` | Basilica | `jol-hub` (`@jol-hub/*`) |
| `jol-site-cathedral` | Cathedral | `jol-hub` (`@jol-hub/*`) |
| `jol-site-cemetery-care` | Cemetery care | `jol-hub` (`@jol-hub/*`) |
| `jol-site-deanery` | Deanery | `jol-hub` (`@jol-hub/*`) |
| `jol-site-diocese` | Diocese | `jol-hub` (`@jol-hub/*`) |
| `jol-site-funeral` | Funeral | `jol-hub` (`@jol-hub/*`) |
| `jol-site-orthodox` | Orthodox | `jol-hub` (`@jol-hub/*`) |
| `jol-site-other-church` | Other church | `jol-hub` (`@jol-hub/*`) |
| `jol-site-parish` | Parish | `jol-hub` (`@jol-hub/*`) |
| `jol-site-protestant` | Protestant | `jol-hub` (`@jol-hub/*`) |

## Organizational / Template

| Repository | Role |
|-----------|------|
| `.github` | Org default community health files (SECURITY.md, CODEOWNERS, PR templates) |
| `jol-repo-template` | Enterprise repository scaffold template |

## Cross-Repo Dependency Rules (from AGENTS.md §1)

1. **Priority**: Application behavior lives in PRIMARY repos. `jol-infrastructure` NEVER contains application logic.
2. **Secret Flow**: Cross-repo only via Ansible Vault / cloud-init / Vaultwarden.
3. **Trust Boundary**: VLAN 30 (LLM), VLAN 40 (AI services), VLAN 60 (management). Cross-VLAN requires an ADR.
4. **Change Impact**: PRs touching Tier 0 contracts or host-level controls MUST name downstream repos.
5. **Tree Segregation**: Church tree (`/opt/jol`) and marketplace tree (`/opt/jolarca`) NEVER merge.

## Runtime Dependencies (Not Visible in Git)

| Source | Target | Protocol | Notes |
|--------|--------|----------|-------|
| `jol-rag-server` (rag-prod-lt01) | `jol-llm` (llm-prod-lt01) | HTTP REST :11434 | VLAN 40 → VLAN 30, UFW-gated |
| `jol-mcp-servers` (mcp-prod-lt01) | stdio transport only | stdio | No HTTP listeners; port 3000 closed |
| `jol-site-*` spokes | `jol-hub` packages | npm (`@jol-hub/*`) | Via per-repo `.npmrc` registry scoping |
| `jol-hermes-agents` | Mistral / OVH-AI (EU-only) | HTTPS EXTERNAL | NOT on-prem Ollama; no MCP client exists yet |

## Repositories NOT in journeyoflife-org

| Repository | Location | Status |
|-----------|----------|--------|
| `jolarca` (formerly `jol-m`) | `jolarca-dev` GitHub org | Transferred 2026-09-02 (ISO 27001 A.8.13 segregation) |
| `jol-backend-platform` | Personal `JourneyOfLife` account | Archived, read-only |
| `obsidian` | Local only (`/opt/jol/repos/obsidian`) | Knowledge base, not deployable, not in GitHub org |
