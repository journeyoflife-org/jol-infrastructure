# JOL Repository Scope Decisions

**Generated:** 2026-09-18  
**Organization:** `journeyoflife-org`  
**Decision log for Phase 0/1 discovery**

---

## Decision 1: Repository Count Reconciliation

| Field | Value |
|-------|-------|
| Expected count (from master prompt) | 29 |
| Discovered count — `gh repo list --limit 200` | **29** |
| Discovered count — REST `orgs/journeyoflife-org/repos?per_page=100` | **29** (page 1 = 29 items, <100 → no page 2 → **no truncation**) |
| Private repos in org | 0 (type=private returns empty) |
| Type-filter cross-check | source=29, fork=0, member=29, all=29 (all reconcile) |
| Archived repos in org | 0 |
| Forks in org | 0 |
| Templates in org | 5 (`jol-core`, `jol-ecommerce-engine`, `jol-mcp-servers`, `jol-rag-server`, `jol-security`) |
| Default branch | `main` on all 29 |
| **Status** | **RECONCILED (29/29)** |

### Discrepancy check: prompt/docs vs API

| Claimed repo (AGENTS.md / master prompt) | In `journeyoflife-org` API list? | Resolution |
|------------------------------------------|----------------------------------|------------|
| `jol-site-church` (12th spoke implied by "twelve spokes") | **NO — HTTP 404** | Does not exist. Only **10** `jol-site-*` spokes exist. The "twelve spokes" phrasing in AGENTS.md §1 is stale/aspirational. |
| `jol-site-site` (memory artifact) | **NO — HTTP 404** | Does not exist; memory artifact, not a real repo. |
| `jol-frontend-platform` (retired 2026-09-11) | **NO (in org)** — exists on personal `JourneyOfLife` account, archived | Out of org scope; retired. |
| `jol-backend-platform` (AGENTS.md Tier 1) | **NO (in org)** — exists on personal `JourneyOfLife` account, private, archived | Out of org scope; separate audit surface. |
| `jol-m`, `jol-m-data`, `jol-m-compliance`, `jol-m-legal`, `jol-m-infrastructure` | Redirect pointers to `jolarca-dev/*` | Marketplace fleet transferred 2026-09-02; out of church-tree org scope. |

**Result:** No repository expected to be *in* `journeyoflife-org` is missing, and no *unexpected* repository is present. The only documented delta is the **10-vs-12 spoke count**, resolved to **10** (verified authoritative via API). Two spoke names in the ecosystem docs were never provisioned.

### Reconciled tier census (29 total)

| Group | Count | Repositories |
|-------|-------|-------------|
| Tier 0 (contracts) | 3 | `jol-core`, `jol-hub`, `jol-auth` |
| Tier 1 (primary apps) | 3 | `jol-rag-server`, `jol-ecommerce-engine`, `jol-analytics-ai` |
| Tier 2 (AI estate) | 3 | `jol-llm`, `jol-mcp-servers`, `jol-hermes-agents` |
| Tier 3 (integrations) | 3 | `jol-link-registry`, `jol-domain-taxonomy`, `jol-bitrix24-integration` |
| Tier 4 (infra/gov) | 6 | `jol-infrastructure`, `jol-devops`, `jol-security`, `jol-compliance`, `jol-scripts`, `jol-repo-template` |
| Site spokes | 10 | `jol-site-{basilica,cathedral,cemetery-care,deanery,diocese,funeral,orthodox,other-church,parish,protestant}` |
| Org defaults | 1 | `.github` |
| **TOTAL** | **29** | — |

## Decision 2: Scope Boundaries

### In scope
- All 29 repositories in `journeyoflife-org`
- All local clones at `/opt/jol/repos/*`

### Out of scope (separate audit surfaces)
- `jolarca*` fleet (5 repos) — transferred to `jolarca-dev` org 2026-09-02, ISO 27001 A.8.13 segregation
- `jol-backend-platform` — personal account, archived, read-only
- `obsidian` — local knowledge base only, not in GitHub org, never deployable

### Rationale
The master prompt specifies `journeyoflife-org` as the scope. The `jolarca*` marketplace fleet is a legally separate audit surface (PCI-DSS, GDPR, EU VAT OSS) under a different GitHub organization with distinct governance. Including it would violate the tree-segregation rule (AGENTS.md §0.2).

## Decision 3: Default Branch Policy

| Field | Value |
|-------|-------|
| All 29 repos default branch | `main` |
| Branch protection on `main` | **29/29 PROTECTED** (verified via GitHub API) |
| Merge strategy | Squash (per org ruleset `protect-main`) |
| Admin bypass | Enabled (per org ruleset) |

## Decision 4: Local Clone State — Preservation Required

### Repositories with uncommitted changes (DO NOT DISCARD)

| Repository | Branch | Dirty Files | Risk |
|-----------|--------|-------------|------|
| `jol-analytics-ai` | `main` | 6 | Uncommitted work on default branch |
| `jol-auth` | `main` | 31 | Significant uncommitted work on default branch |
| `jol-compliance` | `feature/initial-setup` | 7 | Feature branch with uncommitted changes |
| `jol-core` | `main` | 2 | Uncommitted work on default branch |
| `jol-hermes-agents` | `main` | 16 | Uncommitted work on default branch |
| `jol-infrastructure` | `main` | 6 | Includes this audit script (new files) |
| `jol-link-registry` | `main` | 13 | Uncommitted work on default branch |
| `jol-llm` | `main` | 32 | Significant uncommitted work on default branch |
| `jol-repo-template` | `main` | 1 | Minor uncommitted change |

### Repositories on non-default branches

| Repository | Current Branch | Default Branch | Unpushed |
|-----------|---------------|----------------|----------|
| `jol-compliance` | `feature/initial-setup` | `main` | Unknown (no upstream set) |
| `jol-site-basilica` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-cathedral` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-cemetery-care` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-deanery` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-diocese` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-funeral` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-orthodox` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-other-church` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-parish` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |
| `jol-site-protestant` | `feature/stage0-gate-remediation` | `main` | NO_UPSTREAM |

### Repositories with unpushed commits on `main`

| Repository | Unpushed Commits |
|-----------|-----------------|
| `jol-devops` | 1 commit: `d089cef feat(maintenance): add workstation disk layout fix script` |

### Repositories clean on `main`

| Repository | Status |
|-----------|--------|
| `jol-bitrix24-integration` | Clean, on `main`, up to date |
| `jol-devops` | On `main`, 1 unpushed commit |
| `jol-domain-taxonomy` | Clean, on `main`, up to date |
| `jol-ecommerce-engine` | Clean, on `main`, up to date |
| `jol-hub` | Clean, on `main`, up to date |
| `jol-mcp-servers` | Clean, on `main`, up to date |
| `jol-rag-server` | Clean, on `main`, no upstream set |
| `jol-scripts` | Clean, on `main`, up to date |
| `jol-security` | Clean, on `main`, up to date |

## Decision 5: GitHub Actions Coverage

| Repository | Workflows | Status |
|-----------|-----------|--------|
| `jol-hub` | 9 | MOST MATURE |
| `jol-compliance` | 7 | Active |
| `jol-ecommerce-engine` | 7 | Active |
| `jol-mcp-servers` | 6 | Active |
| `jol-auth` | 5 | Active |
| `jol-infrastructure` | 5 | Active |
| `jol-link-registry` | 5 | Active |
| `jol-analytics-ai` | 4 | Active |
| `jol-bitrix24-integration` | 4 | Active |
| `jol-llm` | 4 | Active |
| `jol-scripts` | 4 | Active |
| `jol-security` | 4 | Active |
| `jol-hermes-agents` | 3 | Active |
| `jol-repo-template` | 3 | Template |
| `jol-devops` | 2 | Active |
| `jol-rag-server` | 1 | MINIMAL |
| `jol-core` | 0 | **GAP** |
| `jol-domain-taxonomy` | 0 | **GAP** |
| `.github` | 0 | Expected (org defaults only) |
| `jol-site-*` (10 repos) | 1 each (ci.yml) | Minimal but present |

## Decision 6: Data Sensitivity Classification

| Classification | Repositories | Regulatory Scope |
|---------------|-------------|-----------------|
| HIGH-GDPR-Art9 | `jol-hub`, `jol-rag-server`, `jol-core`, `jol-auth` | Special category: religious affiliation data |
| HIGH-PCI | `jol-ecommerce-engine`, `jol-analytics-ai` | Payment card data, donations |
| MEDIUM | `jol-llm`, `jol-mcp-servers`, `jol-hermes-agents`, `jol-compliance`, `jol-security` | Infrastructure secrets, audit data |
| LOW | All remaining repos | No direct PII/payment processing |

## Decision 7: Authorization Boundary (Read-Only Phase)

Per the master prompt startup instruction:

- **AUTHORIZED**: Read-only discovery, inventory generation, state inspection, report generation
- **NOT AUTHORIZED**: Code modifications, commits, pushes, PRs, merges, deployments
- **ESCALATION REQUIRED**: Any P0/P1 finding (active credential exposure, exploitable vulnerability)

## Decision 8: Pilot Repository Selection (Recommendation)

For Phase 7 pilot remediation, the recommended pilot candidate is:

**`jol-infrastructure`** — because:
1. It is the current workspace (immediate access)
2. Tier 4 (infrastructure only) — no application logic risk
3. LOW data sensitivity
4. Already has mature CI/CD (5 workflows)
5. Changes here have no direct tenant-isolation or PII impact
6. The master prompt was executed from this repository

## Decision 9: Empirical Dependency Findings (Phase 3 code scan)

Cross-reference: `docs/audit/repository-dependency-map.md` §"EMPIRICAL VERIFICATION".

The tier map from AGENTS.md is **architectural intent**; an automated scan of manifests, imports,
`uses:` workflow refs, and Terraform/Helm/submodule sources established the **actual** coupling:

- **Confirmed code edges:** 10 site spokes → `.github` reusable workflows; 9 spokes → `@jol-hub/*` npm packages; rag→llm via runtime HTTP.
- **No code-level `jol-core` / `jol-auth` package dependency exists anywhere** — the Tier-0 "contract" edges are convention/HTTP, not enforced imports (0 Python internal deps, 0 deployment-source refs fleet-wide).

### New scope findings

| ID | Severity | Finding | Scope impact |
|----|----------|---------|--------------|
| F-DEP-1 | MEDIUM | Contract repos (`jol-core`, `jol-auth`) are not consumed as installable packages by any repo — shared-model / tenant-isolation guarantees rest on convention, not enforced dependency. | Assessment must treat contract drift as a governance (not build) risk. |
| F-DEP-2 | HIGH | `jol-site-basilica` uses `@journeyoflife-org/*`; the other 9 spokes use `@jol-hub/*` (verified by direct `package.json` read). Two scopes for one hub fleet. | basilica enters remediation backlog as a scope-reconciliation change. |
| F-DEP-3 | INFO | `.github` is a single point of CI coupling for 11 consumers (10 spokes + hub template). | Elevate `.github` to CI-integrity HIGH for change-control (not data-sensitivity). |

### Out-of-scope surfaces — confirmed with evidence (not assumed)

| Surface | Verification | Decision |
|---------|-------------|----------|
| `jolarca*` fleet (5) | `journeyoflife-org/jol-m-*` resolve to `jolarca-dev/*` (redirect); org list excludes them | **EXCLUDED** — separate org, ISO 27001 A.8.13 segregation, separate PCI/VAT scope |
| `jol-frontend-platform` | `repos/journeyoflife-org/...` → 404 in org; exists only on personal `JourneyOfLife` (archived) | **EXCLUDED** — retired 2026-09-11 |
| `jol-backend-platform` | personal `JourneyOfLife` account, private, archived | **EXCLUDED** — read-only, out of org |
| `obsidian` | local dir `/opt/jol/repos/obsidian`, not in GitHub org | **EXCLUDED** — knowledge base, never deployable |
| `jol-site-church`, `jol-site-site` | GitHub API → **HTTP 404** | **DO NOT EXIST** — "twelve spokes" phrasing is stale; census closed at 10 |

## Decision 10: Tier Criticality (evidence-adjusted)

Criticality is used to sequence remediation. Data-sensitivity tier (Decision 6) and CI-coupling tier (F-DEP-3) are combined:

| Tier | Repos | Justification (evidence) |
|------|-------|--------------------------|
| **CRITICAL** | `jol-hub`, `jol-rag-server`, `jol-core`, `jol-auth` | GDPR Art.9 special-category surface + PRIMARY application (rag) + Tier-0 contracts |
| **HIGH** | `jol-ecommerce-engine`, `jol-infrastructure`, `jol-llm`, `jol-mcp-servers`, **`.github`** (CI-coupling only) | PCI payments (ecommerce); host-level deploy assets (infra/llm/mcp); `.github` gates 11 repos |
| **MEDIUM** | `jol-hermes-agents`, `jol-compliance`, `jol-security`, `jol-devops`, 10× `jol-site-*` | Compliance/AI contracts + spoke fleet |
| **LOW** | `jol-analytics-ai`, `jol-bitrix24-integration`, `jol-domain-taxonomy`, `jol-link-registry`, `jol-repo-template`, `jol-scripts` | Utility/integration, no direct PII in-repo |

> ### How to read Decision 6 vs Decision 10 (two orthogonal axes — not a contradiction)
>
> - **Decision 6 (data sensitivity)** = *what regulated data the repo's runtime touches* (GDPR Art.9 / PCI / secrets / low). Drives **privacy/security handling** rules.
> - **Decision 10 (remediation criticality)** = *blast radius + coupling if the repo changes breaks* (contract role, CI fan-out, host-level assets). Drives **sequencing priority**.
>
> Two repos diverge **on purpose** — do not "fix" one table to match the other:
>
> | Repo | Sensitivity | Criticality | Why they differ (evidence) |
> |------|-------------|-------------|----------------------------|
> | `jol-infrastructure` | LOW (no PII/card data in-repo) | HIGH | Verified 2026-09-18: `.sops.yaml` secret-governance config present, but **0 sops-encrypted blobs** and **no plaintext secret keys** in `inventory/prod/host_vars/`. It is a secret-*configuration* + host-deploy-asset surface — compromise cascades fleet-wide (deploy assets for llm/mcp), so criticality is elevated even though it holds no regulated data content. |
> | `jol-analytics-ai` | HIGH-PCI (runtime touches donation/telemetry datasets) | LOW | No PII/card data **stored in-repo** (static scan: only self-imports, 0 external coupling). In-repo change risk is low, but any runtime-data work inherits PCI handling rules from Decision 6. Re-check actual datasets in Phase 3 architecture assessment. |

---
