# CC8.1 Change Request DRAFT — file via GitHub issue (template: infra-change-request.yml)

> Status: DRAFT 2026-08-24 — `gh` CLI is unauthenticated on this workstation;
> file this as a GitHub issue on `journeyoflife-org/jol-infrastructure`, then
> replace `TBD (CC8.1 issue)` references with the issued number.

**Title:** `[infra-change]: jol-db-pilot-lt01 spec delta — schema-per-tenant + RLS tenant isolation`

## Form fields

| Field | Value |
|---|---|
| Change Type | other (provisioning specification — docs-only) |
| Target Environment(s) | prod (pilot planning; VM not yet provisioned) |
| Risk Level | Low — documentation/spec change only; zero runtime mutation; VM 201 does not exist yet |
| Ticket Reference | JOL-XXXX (assign at filing) |

## Change Description

**What:** Spec delta applied to `docs/servers/jol-db-pilot-lt01.md`:
ratifies the tenant data isolation model for the Lithuania pilot —
PostgreSQL **schema-per-tenant** (`t_<tenant_id>` naming) on a shared
cluster with **Row-Level Security enabled + forced** on all tenant-scoped
tables, `search_path` pinning per resolved tenant, separate migration role,
and per-tenant erasure boundary. Two pre-go-live audit rows added
(schema inventory; RLS enforcement query expecting 0 non-compliant tables).

**Why:** The earlier "separate database per website" formulation is not
operable at pilot→industrialization scale (23 → ~1,300 → ~400,000 tenants)
and was superseded by platform-owner ratification recorded in
`jol-hub/docs/decisions/ADR-001-schema-per-tenant-isolation.md`.

**Expected:** Provisioning of VM 201 proceeds against the corrected spec;
D5 audit checklist gates tenant isolation evidence at go-live.

## Rollback Plan

1. `git revert` the delta commit on the merged branch (docs-only revert).
2. No VM/database exists yet — no state rollback required.
3. Cross-repo twin: jol-hub ADR-001 status → Superseded, recorded in its
   Change History (separate PR in jol-hub).

## Compliance Checklist

- [x] No secrets hardcoded (TruffleHog clean — jol-hub hygiene gate 2026-08-24, docs-only diff here)
- [x] Checkov/tfsec pass with no new critical findings (no IaC touched)
- [ ] OPA policies evaluated — N/A (no k8s manifests)
- [x] Rollback plan documented
- [x] Cost impact assessed — none (same single cluster; reduces per-tenant DB overhead)
- [x] GDPR data impact assessed — improves Art. 9/17 posture (schema-scoped erasure boundary + RLS defense-in-depth); cross-references DPIA trigger check §4

## Linked evidence

- `docs/servers/jol-db-pilot-lt01.md` — Change History row 2026-08-24
- `jol-hub/docs/decisions/ADR-001-schema-per-tenant-isolation.md`
- `jol-hub/docs/decisions/MASTER-PROMPT-LT-PILOT-FRONTEND.md` §8
- `jol-hub/docs/compliance/evidence/hygiene-gate-execution-20260824.md`
