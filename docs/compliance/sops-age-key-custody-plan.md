# SOPS age Key Custody Plan (C4) — APPROVED

> **Status**: APPROVED — D1–D6 signed off 2026-08-26 (owner directive:
> accept all architect recommendations; recorded verbatim below).
> Gate 5 key generation remains conditional on C5 (jol-hub reconciliation).
> Historical draft state: This document records LOCATIONS AND PROCEDURES ONLY —
> no key material, share content, or Vaultwarden item names with secrets
> ever appear here or in git (AGENTS.md §0.1; amendment rule 3).
> **Basis**: ADR-003 amendment (PR #35, `3dd9fda`) Condition C4;
> PCI-DSS Req. 3.6 key-management documentation; ISO 27001 A.8.24.

## 1. Key inventory (post-Gate 5 target state)

| Identity | Tree | Operational copy | Shamir scheme | Shares |
|---|---|---|---|---|
| `age-jol` | Church (`/opt/jol/**`) | Vaultwarden (authoritative) + workstation cache `700/600` | M=2 of N=3 | JOL-S1, JOL-S2, JOL-S3 |
| `age-jolm` | Marketplace (`/opt/jol-m/**`) | Vaultwarden (authoritative) + workstation cache `700/600` | M=2 of N=3 | JOLM-S1, JOLM-S2, JOLM-S3 |

No share of one identity may be stored alongside a share of the other in the
same physical container (segregation, amendment rule 1).

## 2. Custody decisions (⚠ = owner must decide)

| # | Decision | Architect recommendation | Owner decision |
|---|---|---|---|
| D1 | Splitting tool | `ssss-split`/`ssss-combine` (apt) — sops has no Shamir feature | ACCEPTED 2026-08-26 |
| D2 | Share 1 location per identity (hot DR) | Offline encrypted USB in the on-site safe; container label only, no content description | ACCEPTED 2026-08-26 |
| D3 | Share 2 location per identity (cold DR) | Sealed+signed envelope, off-site (bank safe deposit or trusted third location); separate building from Share 1 | ACCEPTED 2026-08-26 |
| D4 | Share 3 location per identity (cyber DR) | Dedicated DR-only recipient generated at Gate 5, itself immediately Shamir-split; Vaultwarden emergency-access item is the fallback (owner accepted recommendation, 2026-08-26) | ACCEPTED 2026-08-26 |
| D5 | Rehearsal cadence | Quarterly: reconstruct from 2 shares, verify public key, decrypt fixture; log result below | ACCEPTED 2026-08-26 |
| D6 | Revocation trigger list | Suspected share exposure, personnel/custodian change, identity rotation (12-month default), Vaultwarden compromise | ACCEPTED 2026-08-26 |

Single-owner note: all three custodian roles are currently one person.
Residual risk formally ACCEPTED by owner 2026-08-26 (same directive).
Compensating control = time-locked locations (safe deposit opening hours,
sealed-envelope tamper evidence) + rehearsal log; record acceptance of this
residual risk with the sign-off below (ISO 27001 A.5.9 risk acceptance).

## 3. Share custody log (locations only)

| Share ID | Location class | Specific location (no content) | Custodian | Sealed | Date |
|---|---|---|---|---|---|
| JOL-S1 | ⚠ D2 | ⚠ | owner | ☐ | ⚠ |
| JOL-S2 | ⚠ D3 | ⚠ | owner | ☐ | ⚠ |
| JOL-S3 | ⚠ D4 | ⚠ | owner | ☐ | ⚠ |
| JOLM-S1 | ⚠ D2 | ⚠ | owner | ☐ | ⚠ |
| JOLM-S2 | ⚠ D3 | ⚠ | owner | ☐ | ⚠ |
| JOLM-S3 | ⚠ D4 | ⚠ | owner | ☐ | ⚠ |

## 4. DR rehearsal log

| Date | Identity | Shares used | Public key match | Fixture decrypt | Operator | Result |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | no rehearsal yet |

## 5. Procedure (unblocked: D1–D6 signed off; PR #37 merged bd17f16; pending C5 only)

1. Generate identity with `age-keygen` into a temporary 600 file (never the
   final path); display recipient (public key only).
2. Split the identity file with the D1 tool (M=2/N=3); verify recombination
   round-trip in the rehearsal step BEFORE destroying the temporary file.
3. Distribute shares per §3 log; record seal/tamper-evidence state.
4. Import the identity into Vaultwarden (authoritative operational copy);
   workstation cache written last with 600 inside 700 directory.
5. Update `docs/dev-setup/tool-versions.md` provenance section with the
   rehearsal date; commit rehearsal row to §4 via docs PR.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-26 | Plan drafted — DRAFT, all D1–D6 decisions pending owner sign-off; Gate 5 remains blocked | ADR-003 amendment C4; issue #36 |
| 2026-08-26 | APPROVED — owner directive accepts all architect recommendations (D1–D6) + single-custodian residual risk; C4 CLOSED; Gate 5 gated on C5 only | chat directive 2026-08-26; PR #38 (fc5056e) |
