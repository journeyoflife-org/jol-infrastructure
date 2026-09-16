# Erasure Register — GDPR Art. 17 (JOL Pilot Lithuania)

> **Status**: ACTIVE register — created with the pilot backup/DR plan.
> **Date**: 2026-08-23
> **Legal basis**: GDPR Art. 17 (right to erasure), Art. 5(1)(e),
> Art. 12(2) (facilitation of data-subject rights).
> **Policy source**: `docs/runbooks/jol-pilot-backup-plan.md` §3
> (erasure-vs-backup resolution).
> **CONFIDENTIALITY**: this register contains data-subject request
> metadata — access restricted to compliance role; never attach raw
> personal data to entries.

## Policy summary

1. Live erasure executed ≤ 30 days via app-tier Art. 17 endpoints
   (jol-app-pilot-lt01 → jol-db-pilot-lt01): **logical deletion** —
   `deleted_at` timestamp marks the record erased (referential integrity
   and audit trail preserved), followed by scheduled hard-purge of
   tombstoned rows; the marking itself carries the audit entry (fleet
   audit.jsonl pattern).
2. Backups are NOT rewritten — residual copies age out at backup expiry
   (keep-monthly=6 ⇒ maximum 6-month residual), declared in the Privacy
   Notice and the DPIA.
3. **Restore-replay**: any restore of a backup containing erased records
   MUST replay this register against the restored dataset before the
   system serves traffic.
4. Erasure requests that are lawfully declined (Art. 17(3) exemptions —
   legal obligation, public interest, etc.) are recorded here with the
   legal basis of the refusal **and legal-counsel sign-off**.

## Register

| # | Date received (UTC) | Request ref | Scope (data classes) | Live erasure executed (UTC) | Executed by | Backup residual expiry (latest) | Restore-replay needed? | Status |
|---|---------------------|-------------|----------------------|-----------------------------|-------------|---------------------------------|------------------------|--------|
| — | _YYYY-MM-DDTHH:MMZ_ | _ER-YYYY-NNN_ | _e.g., parishioner record + CRM sync_ | — | — | _≤ 6 months from erasure date_ | no | _example row — delete on first real entry_ |

## Verification (auditor-facing)

- [ ] Every row has a matching application audit entry (timestamp, actor,
      outcome) in the app-tier audit log
- [ ] No row older than 30 days without an execution timestamp or a
      documented Art. 17(3) refusal with legal-counsel sign-off
- [ ] After any PBS restore drill/go-live restore: replay checkbox
      evidenced in the restore log (`evidence/restore-test-*`)

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Register created (Step 4 D3); policy linked from backup plan | this document |
| 2026-08-23 | Ratified-spec reconciliation: `deleted_at` logical-deletion mechanism + scheduled hard-purge; legal-counsel sign-off required for Art. 17(3) refusals | Step 4 ratified task spec |
