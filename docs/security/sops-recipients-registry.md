# SOPS Recipients Registry (Gate 7)

> **Authority**: ADR-003 amendment (PR #35) rules 1, 5; custody per
> `docs/compliance/sops-age-key-custody-plan.md`. CC8.1 record: issue #36.
> This registry holds PUBLIC keys only. Any entry carrying
> `AGE-SECRET-KEY` material is a security incident — rotate per D6.

## Active recipients

| Identity | Tree | Public recipient | Created | Identity digest (audit) | Rotation due |
|---|---|---|---|---|---|
| age-jol | Church `/opt/jol/**` | `age17ne7fvag6gxedsgs4yzpefqe5t8uefp4ldezrc7ajfqyjad79g5qsv0rn2` | 2026-08-27 | a5747ad2bf81c439... | 2027-08-27 (D6) |
| age-jolm | Marketplace `/opt/jol-m/**` | `age1h6knxanpsq332ufrh54mh5y0wgzhu43vgq8flh55hrnc2zvuwe8qjn4n47` | 2026-08-27 | 8a2b783545b695ff... | 2027-08-27 (D6) |

## Binding rules

1. A `.sops.yaml` in a `/opt/jol/**` repo may list ONLY `age-jol`; a
   `/opt/jol-m/**` repo may list ONLY `age-jolm`. Cross-tree listing =
   segregation incident (AGENTS.md 0.2).
2. Creation rules restricted to `*.enc.yaml|yml|json` and
   `secrets/encrypted/**` (C5-R3 convention).
3. Private keys: Vaultwarden `SOPS-Custody` (authoritative) + Shamir M=2/N=3
   custody; workstation cache transient, mode 600 inside 700 dir.
4. Revocation triggers (custody plan D6): suspected exposure, custodian
   change, 12-month rotation, Vaultwarden compromise. On revocation:
   generate replacement identity, re-encrypt affected files, update this
   registry row (old row struck, never deleted — audit trail).

## Fleet rollout status

| Tree | Template PR | Fleet enablement |
|---|---|---|
| Church | jol-infrastructure PR #43 (merged fc0753b) | **ROLLED OUT 2026-08-27** — 15 church repos merged (owner-approved admin merges per issue #36; review-required rulesets); jol-compliance PENDING (its required compliance-lint check cannot start: GitHub Actions infra failure, zero-step job failures — local repro 3/3 PASS); archived repos excluded |
| Marketplace | jol-m-compliance PR #8 (merged 7d68113) | **ROLLED OUT 2026-08-27** — jol-m-data #5, jol-m-infrastructure #14, jol-m-legal #7, jol-m-marketplace #19 merged |

Rollout notes (2026-08-27):
- detect-secrets false positives on PUBLIC age recipients resolved via
  `pragma: allowlist secret` (fleet-sanctioned mechanism).
- jol-llm commit message adapted to its Conventional-Commits commit-msg hook.
- FINDING: jol-backend-platform, jol-domain-taxonomy, jol-frontend-platform are
  ARCHIVED on GitHub (read-only since 2026-02-04) — excluded from rollout;
  ecosystem-map reconciliation owed.
- FINDING: jol-compliance GitHub Actions runs fail with zero executed steps
  (runner allocation/org quota suspected); local reproduction of
  scripts/run-compliance-lint.sh on the PR commit passes 3/3.
