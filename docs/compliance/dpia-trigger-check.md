# DPIA Trigger Check — JOL Pilot Lithuania

> **Status**: DECIDED — **DPIA IS MANDATORY before pilot go-live** (see §3).
> **Date**: 2026-08-23
> **Legal basis**: GDPR Art. 35(1)/(3), Art. 36, Recital 91; EDPB/WP29
> Guidelines on DPIA (WP 248 rev.01); Lithuanian SA (Valstybinė duomenų
> apsaugos inspekcija) national guidance.
> **Inputs**: `docs/architecture/jol-pilot-vm-topology.md` (Step 1),
> `docs/security/jol-pilot-firewall-matrix.md` (Step 2), AGENTS.md §0.2
> (compliance boundaries), AGENTS.md §2.4 (prior-art DPIA in
> `jol-hermes-agents/docs/dpia-ai-processing.md`).
> **This document contains no personal data** — it is the trigger
> assessment, not the DPIA itself.

## 1. Processing profile of the pilot

| Attribute | Value | Source |
|-----------|-------|--------|
| Controller | Journey Of Life (JOL) — Church Platform tree (`/opt/jol`) | AGENTS.md §0.2 |
| Data categories | Parishioner PII, **religious affiliation (Art. 9 special category)**, clergy data; donation data if payments are in pilot scope | AGENTS.md §0.2 compliance table |
| Data subjects | Lithuanian pilot users of the Church platform; scale target per org mission: platform serves ~400,000 websites across 27 EU states (pilot = subset) | AGENTS.md org header |
| Processors (Art. 28) | Bitrix24 (SaaS CRM via connector VM 202); Proxmox Backup Server (internal, not a third-party processor) | Step 1 topology D3 |
| AI processing | On-prem Ollama only IF pilot enables it (no cross-border transfer — EU-only, per `docs/architecture/trust-boundaries.md` GDPR Art. 25) | Step 2 firewall rule #3 |
| Transfers outside EU | None by design; Bitrix24 hosting region ⚠ UNVERIFIED — manual check required: confirm data residency of the contracted Bitrix24 portal (Chapter V applies if non-EU) | — |

## 2. Trigger criteria evaluation (WP248 — ≥2 criteria ⇒ DPIA required)

| # | Criterion | Applies? | Justification |
|---|-----------|----------|---------------|
| 1 | Evaluation/scoring (incl. profiling) | ⚠ Pending | Applies if pilot includes analytics/telemetry on parishioner behaviour (jol-analytics-ai downstream — anonymised per AGENTS.md §2.1, but confirm for pilot) |
| 2 | Automated decision-making with legal/similar effect | No (pilot scope) | Not declared in pilot scope |
| 3 | Systematic monitoring | No | No user-side tracking declared |
| 4 | **Special category data (Art. 9)** | **YES** | Religious affiliation is the platform's core data class — AGENTS.md §0.2 explicitly cites GDPR Art. 9 |
| 5 | **Large-scale processing** | **YES** | Organisational scale (~400k websites, 27 EU states; Recital 91 — even the Lithuanian pilot serves a church community, which the EDPB treats as sensitive-population processing) |
| 6 | Matching/combining datasets | ⚠ Pending | Applies if Bitrix24 sync merges CRM records with parishioner records — confirm connector data mapping |
| 7 | **Data concerning vulnerable subjects** | **YES** | Religious-community members are treated as vulnerable data subjects under WP248 |
| 8 | Innovative use / new technology | YES (partial) | New platform stack + optional on-prem LLM integration |
| 9 | When processing itself prevents subjects from exercising a right | No | Not applicable |

**Score: 3 criteria firmly met (4, 5, 7), 2 pending confirmation (1, 6).**
Threshold is 2 — **the DPIA requirement triggers unconditionally**; the
pending items cannot reduce the score below threshold.

## 3. Decision

> **“DPIA MANDATORY under GDPR Art. 35(1) + Art. 35(3)(a). Trigger:
> processing of special-category data (Art. 9) on a new system (prox01)
> not previously assessed. Threshold: 2 of 9 WP248 criteria required;
> this pilot meets 3 (Art. 9 data, large scale, vulnerable subjects).
> Pilot MUST NOT accept live personal data until full DPIA + Bitrix24
> Art. 28 DPA are executed.”**

**DPIA MANDATORY** — Art. 35(1). The pilot MUST NOT accept live personal
data until the DPIA is completed and any residual high risk is either
mitigated or submitted to prior consultation (Art. 36) with the Lithuanian
supervisory authority.

### Required actions before go-live

| # | Action | Standard | Owner | Status |
|---|--------|----------|-------|--------|
| 1 | Draft full DPIA covering the pilot processing (reuse structure of `jol-hermes-agents/docs/dpia-ai-processing.md` prior art) | GDPR Art. 35(7) a–g | Compliance + Platform Architect | OPEN |
| 2 | Art. 28 DPA with Bitrix24; confirm hosting region + subprocessor list; confirm connector transfers only the minimum fields (data minimisation, Art. 5(1)(c)) | GDPR Art. 28, Ch. V | Compliance | OPEN |
| 3 | Resolve pending criteria #1 (analytics scope) and #6 (Bitrix↔parishioner record matching) and record the answers in the DPIA | WP248 | Product + Compliance | OPEN |
| 4 | Evidence pack: this trigger check + DPIA + DPA filed under `docs/compliance/evidence/` (SOC 2 evidence pattern per `collect-soc2-evidence.sh`) | SOC 2 CC1.4, ISO 27001 5.34 | Compliance | OPEN |
| 5 | If DPIA residual risk stays HIGH after mitigations → prior consultation with VDAI before launch | GDPR Art. 36 | Compliance | Conditional |
| 6 | Record of Processing Activities (Art. 30) entry for the pilot | GDPR Art. 30 | Compliance | OPEN |

### Technical mitigations already designed in (Step 1 + 2 outputs)

- DB isolation in its own VM + no internet egress from the data tier
  (firewall matrix §2.2) — Art. 32 "isolation" and exfiltration resistance.
- Art. 9 data never transits the Bitrix connector in the reverse direction
  without a recorded mapping decision (matrix §2.3 DENY connector→DB).
- Encryption in transit: TLS 1.3 at the only public edge (ingress VM);
  encrypted at rest: ZFS pools + client-side encrypted PBS backups
  (fleet baseline, `docs/servers/prox01.md` Backup Policy).
- Data residency: EU-only; on-prem LLM path keeps inference data on-site
  (trust-boundaries.md Art. 25).
- Erasure path (Art. 17) must be verified in the app tier before go-live —
  cascade + audit entry, same gate as AGENTS.md §2.1 RAG checklist.

## 4. Re-trigger conditions

The DPIA must be re-assessed (Art. 35(11)) if any of these occur:
- Donations/payments enter pilot scope (adds PCI-DSS + payment-processor
  subprocessor — new processor chain).
- Bitrix24 data residency resolves to non-EU (Chapter V transfer mechanism
  required: SCCs + TIA).
- On-prem LLM integration moves from optional to active with personal data
  in prompts (retention rule applies — AGENTS.md §2.2: 0-day prompt
  retention must be enforced and tested).
- Pilot scales beyond the Lithuanian user base.

## 5. Re-check entries

### 2026-08-26 — SOPS git-at-rest key management (ADR-003 amendment, C3)

**Scope checked**: introduction of SOPS+age encryption of committed
configuration files across the fleet, per the merged ADR-003 amendment
(PR #35, commit `3dd9fda`).

**Assessment**:
- The processing under review is **cryptographic key management**, not a new
  personal-data processing activity: no new data categories, subjects,
  processors, or transfers arise. Keys protect Art. 9-adjacent configuration
  material; they are not themselves personal data.
- WP248 re-score: **no new criterion met**. Criteria 4/5/7 remain those of the
  underlying pilot DPIA; key management is a **security measure** (Art. 32)
  within that scope, not a separate processing operation.
- The amendment's dual-identity segregation (age-jol / age-jolm) *reinforces*
  Art. 25 by-design separation rather than merging audit surfaces.

**Decision**: covered by the existing mandatory pilot DPIA scope; **no new
DPIA triggered**. This entry satisfies amendment Condition C3. Residual
obligation: key lifecycle (custody, rotation, revocation) is documented in
`docs/compliance/sops-age-key-custody-plan.md` and must be referenced from
the full DPIA when it is drafted (Required Action #1 above).

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-26 | Document first committed to main (previously untracked on pilot branch `docs/db-pilot-tenant-isolation-delta`); C3 re-check §5 added: SOPS key management assessed — no new DPIA triggered | ADR-003 amendment PR #35; git history |
| 2026-08-23 | Trigger check executed — DPIA MANDATORY (3/9 criteria met, threshold 2) | this document |
| 2026-08-23 | Ratified-spec reconciliation: verbatim Art. 35(1)+35(3)(a) mandatory declaration added to §3 | Step 2 ratified task spec |
