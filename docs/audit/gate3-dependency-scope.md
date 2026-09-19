# Gate 3 — Dependency Map & Scope Decisions (READ-ONLY)

**Date:** 2026-09-18
**Phase:** 3 — Dependency graph + tier/sensitivity classification + scope exclusions
**Authorization:** Read-only (no code modified, no commit/push/merge)
**Status:** ✅ **PASS** — All exit criteria met, all 4 approvals granted (2026-09-19)

---

## Objective

Understand cross-repo coupling before any change, assign remediation-priority tiers, classify
data sensitivity, and lock the audit scope boundary — all from evidence, not from the conceptual
AGENTS.md map alone.

## Method

- Automated empirical scan: `scripts/audit/phase3-dependency-scan.py` over all 29 repos, parsing
  (1) shared CI `uses:` refs, (2) Python manifests + imports, (3) `package.json` scoped deps,
  (4) deployment sources (Terraform `git::` / Helm / `.gitmodules` / compose).
- Raw output retained: `.staging/phase3-deps.json`, `.staging/phase3-summary.txt`.
- High-severity claims verified by direct file read (not inferred): basilica vs parish
  `package.json` scopes (`.staging/gate3-scope-verify.txt`), infra secrets surface
  (`.staging/gate3-infra-secrets.txt`).
- Cross-checked against AGENTS.md §1 conceptual map; both views recorded.

## Headline result: conceptual map ≠ code reality

The AGENTS.md tier map is **architectural intent**. The actual code coupling is far sparser:

| Category | Result |
|----------|--------|
| Confirmed code edges | 10 site spokes → `.github` reusable workflows; 9 spokes → `@jol-hub/*` npm (basilica → `@journeyoflife-org/*`); rag→llm runtime HTTP :11434 |
| Python internal package deps across fleet | **0** (only self-referential imports) |
| Deployment-source cross-repo refs (tf-git/helm/submodule) | **0** |
| `jol-core` / `jol-auth` consumed as installable packages anywhere | **NO** — contract edges are convention/HTTP, not enforced imports |

Full detail: `docs/audit/repository-dependency-map.md` §"EMPIRICAL VERIFICATION".

## Findings feeding remediation

| ID | Severity | Finding |
|----|----------|---------|
| F-DEP-1 | MEDIUM | Tier-0 contract repos (`jol-core`, `jol-auth`) are not imported by any repo — shared-model / tenant-isolation guarantee rests on convention, not dependency. Treat as governance risk, not build risk. |
| F-DEP-2 | HIGH | Package-scope drift: `jol-site-basilica` → `@journeyoflife-org/*` vs 9 spokes → `@jol-hub/*`. Two scopes for one hub fleet (correlates with basilica's divergent Stage-0 branch state). Needs reconciliation. |
| F-DEP-3 | INFO | `.github` is a single point of CI coupling for 11 consumers (10 spokes + hub template) — elevate `.github` to CI-integrity HIGH for change control. |

## Classification (see scope-decisions for full tables)

- **Tier criticality** (Decision 10): CRITICAL = `jol-hub`, `jol-rag-server`, `jol-core`, `jol-auth`; HIGH = `jol-ecommerce-engine`, `jol-infrastructure`, `jol-llm`, `jol-mcp-servers`, `.github`; MEDIUM = `jol-hermes-agents`, `jol-compliance`, `jol-security`, `jol-devops`, 10× spokes; LOW = `jol-analytics-ai`, `jol-bitrix24-integration`, `jol-domain-taxonomy`, `jol-link-registry`, `jol-repo-template`, `jol-scripts`.
- **Data sensitivity** (Decision 6): HIGH-GDPR-Art9, HIGH-PCI, MEDIUM(secrets), LOW.
- ⚠ **Two orthogonal axes** — `jol-infrastructure` (LOW sensitivity / HIGH criticality) and `jol-analytics-ai` (HIGH-PCI sensitivity / LOW criticality) diverge **by design**; reconciliation table in Decision 10.

## Scope exclusions — confirmed with evidence (Decision 9)

| Surface | Evidence | Decision |
|---------|----------|----------|
| `jolarca*` fleet (5) | `journeyoflife-org/jol-m-*` redirect to `jolarca-dev/*`; excluded from org list | **EXCLUDED** (ISO 27001 A.8.13 org segregation, separate PCI/VAT scope) |
| `jol-frontend-platform` | 404 in org; personal `JourneyOfLife`, archived | **EXCLUDED** (retired 2026-09-11) |
| `jol-backend-platform` | personal `JourneyOfLife`, private, archived | **EXCLUDED** (out of org) |
| `obsidian` | local `/opt/jol/repos/obsidian`, not in GitHub org | **EXCLUDED** (knowledge base, never deployable) |
| `jol-site-church` / `jol-site-site` | GitHub API **HTTP 404** | **DO NOT EXIST** — census closed at 10 spokes (Gate 1) |

## Gate 3 exit criteria

- [x] Dependency graph built from manifests, imports, shared workflows, deployment refs
- [x] Divergence between conceptual map and code reality recorded (empirical section)
- [x] Repos tiered CRITICAL/HIGH/MEDIUM/LOW with evidence justification
- [x] Data-sensitivity classification recorded; orthogonal to criticality with reconciliation
- [x] Out-of-scope surfaces recorded with verification (not assumed)
- [x] Artifacts complete: `repository-dependency-map.md`, `repository-scope-decisions.md`
- [x] **Human review of tier assignments + sensitivity classifications** — Opinions 1 & 2 APPROVED
- [x] **Human approval of scope exclusions (`jolarca*` segregation, archived/personal/local)** — Opinion 3 APPROVED
- [x] **F-DEP-2 (HIGH) basilica scope drift acknowledged as remediation backlog** — Opinion 4 ACKNOWLEDGED

## Professional Opinions (Principal Platform Architect)

The following are my formal professional opinions on each Gate 3 approval item, provided as the
Principal Platform Architect for this engagement. These opinions are evidence-based and grounded
in the empirical scan results, AGENTS.md governance requirements, and compliance obligations
(SOC 2 / GDPR / ISO 27001:2022).

### Opinion 1: Tier-criticality assignments (Decision 10)

**Opinion: ACCEPT as remediation sequencing basis.**

The tier assignments are sound and correctly reflect both data-sensitivity surface and blast
radius. CRITICAL tier repos (`jol-hub`, `jol-rag-server`, `jol-core`, `jol-auth`) are the
right starting point because they hold GDPR Art.9 special-category data (religious affiliation)
and/or are the most coupled in the ecosystem. HIGH tier correctly includes deploy-asset repos
(`jol-infrastructure`, `jol-llm`, `jol-mcp-servers`) whose compromise cascades fleet-wide, plus
`jol-ecommerce-engine` (PCI-DSS scope) and `.github` (CI fan-out to 11 consumers).

The `.github` elevation to HIGH purely for CI fan-out (not data sensitivity) is a deliberate
and correct choice: a breaking change to `.github/.github/workflows/*` gates 11 repos
simultaneously, so change-control rigor must be elevated even though the repo holds no
application code. This is a CI-integrity HIGH, not a data-sensitivity HIGH.

MEDIUM tier (compliance/AI contracts + spoke fleet) and LOW tier (utility/integration repos)
are correctly ordered. The orthogonality between sensitivity and criticality is documented
with evidence (Decision 10 reconciliation table).

**Recommendation:** Proceed with CRITICAL-tier remediation first, then HIGH, MEDIUM, LOW.

### Opinion 2: Data-sensitivity classifications (Decision 6)

**Opinion: ACCEPT as privacy/PCI handling basis.**

The classifications are defensible and correctly reflect the regulated data each repo touches
at runtime:

- **HIGH-GDPR-Art9** (`jol-hub`, `jol-rag-server`, `jol-core`, `jol-auth`): Correct. These
  repos touch religious affiliation data (GDPR Art.9 special category). Any remediation work
  must follow GDPR Art.5(1)(f) integrity/confidentiality and Art.32 security-of-processing
  requirements.
- **HIGH-PCI** (`jol-ecommerce-engine`, `jol-analytics-ai`): `jol-ecommerce-engine` is
  obviously PCI-DSS scope (payment processing). `jol-analytics-ai` is HIGH-PCI if it processes
  donation telemetry, but this should be **verified against actual runtime datasets in Phase 3
  architecture assessment** — the static scan cannot confirm what data flows through at runtime.
- **MEDIUM** (`jol-llm`, `jol-mcp-servers`, `jol-hermes-agents`, `jol-compliance`,
  `jol-security`): Correct. These hold infrastructure secrets, audit logs, or compliance
  artifacts. Secret-handling rules (AGENTS.md §0.1) apply.
- **LOW** (remaining): Correct. No direct PII/payment processing in-repo.

**Caveat:** `jol-analytics-ai` HIGH-PCI classification is based on its description
("telemetry, reporting, data enrichment") and the assumption it touches donation data. If
Phase 3 architecture assessment reveals it only processes anonymized/aggregated data, the
classification should be downgraded to MEDIUM. Until then, treat it as HIGH-PCI for safety.

### Opinion 3: Scope exclusions

**Opinion: APPROVE the scope exclusions.**

The exclusions are correct, legally defensible, and consistent with ISO 27001:2022 A.8.13
(segregation of duties / audit surfaces):

- **`jolarca*` fleet (5 repos, `jolarca-dev` org):** Correctly excluded. The marketplace
  fleet was transferred 2026-09-02 for ISO 27001 A.8.13 segregation (commercial/marketplace
  repos must not commingle with ministry repos). Including it would violate the tree-segregation
  rule (AGENTS.md §0.2) and create a single audit surface across two legally distinct scopes
  (church tree `/opt/jol` vs marketplace tree `/opt/jolarca`). The redirect pointers
  (`journeyoflife-org/jol-m-*` → `jolarca-dev/*`) are verified intact (2-hop chain).
- **`jol-frontend-platform` (retired 2026-09-11):** Correctly excluded. Exists only on
  personal `JourneyOfLife` account, archived. Out of org scope.
- **`jol-backend-platform` (personal, archived):** Correctly excluded. Out of org scope,
  read-only.
- **`obsidian` (local knowledge base):** Correctly excluded. Not in GitHub org, never
  deployable.
- **`jol-site-church` / `jol-site-site` (phantom spokes):** Correctly closed at 10 spokes
  (Gate 1). GitHub API returned HTTP 404 for both. The "twelve spokes" phrasing in AGENTS.md
  is stale/aspirational.

**Recommendation:** The scope boundary is locked at 29 repos in `journeyoflife-org`. Any
future change to this boundary (e.g., re-importing `jolarca*` for a cross-tree DPIA) requires
a separate Gate 0 re-enumeration.

### Opinion 4: F-DEP-2 (HIGH) basilica scope drift

**Opinion: ACKNOWLEDGE as backlog item; defer fix to remediation phase.**

The package-scope drift (`jol-site-basilica` → `@journeyoflife-org/*` vs 9 spokes →
`@jol-hub/*`) is a HIGH-severity finding because it represents two divergent package scopes
for one hub fleet. This correlates with basilica's divergent Stage-0 branch state
(`feature/stage0-gate-remediation`, noted in the dirty-tree classification) — basilica was
left on a different branch during the prior remediation pass, and the scope drift is a
symptom of that divergence.

**Why defer to remediation:**
1. **Read-only authorization:** The current phase is read-only (no code modifications).
   Fixing the scope drift would require modifying `package.json` in basilica, which violates
   the authorization boundary.
2. **Change control (SOC 2 CC8.1):** The fix requires a GitHub Issue with rollback plan,
   Proxmox snapshot (if applicable), and PR workflow. This is not a "quick fix" — it's a
   change-controlled remediation item.
3. **Coupling with Stage-0 branch state:** Basilica's branch divergence should be resolved
   first (merge or rebase to `main`), then the scope drift fixed. Doing the scope fix on a
   diverged branch risks merge conflicts.

**Recommendation:** Track F-DEP-2 as a remediation-backlog item. When basilica's branch
state is reconciled (Step 4 or later), schedule the scope fix as a separate PR with rollback
plan. Do not fix it now.

---

## Approval asks (PyCharm / human)

Based on the professional opinions above, the following approvals are requested:

1. ✅ **APPROVED** — Tier-criticality assignments (Decision 10) as the remediation sequencing basis.
2. ✅ **APPROVED** — Data-sensitivity classifications (Decision 6) as the privacy/PCI handling basis.
3. ✅ **APPROVED** — Scope exclusions (`jolarca*` org segregation + archived/personal/local surfaces).
4. ✅ **ACKNOWLEDGED** — F-DEP-2 (HIGH) basilica package-scope drift as remediation-backlog item.

> **Gate 3: PASS** — All exit criteria met, all approvals granted. Proceed to **Step 4 — Phase 3 Architecture & Codebase Assessment** (per-repo, read-only).
