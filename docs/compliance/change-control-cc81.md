# Change Control Package — JOL Pilot Lithuania Deployment (SOC 2 CC8.1)

> **Status**: TEMPLATE — this package governs the EXECUTION of the pilot
> deployment (Steps 1–5 deliverables are the planning inputs).
> **Date**: 2026-08-23
> **Standard**: SOC 2 Type II CC8.1 (change management); AGENTS.md §0.3
> (change control non-negotiables); §0.4 (verification rule).
> **Scope**: all mutations on prox01, N2048 Gi1/0/11, MikroTik (VLAN 45
> SVI + inter-VLAN rules), pbs01 (datastore), and the 5 pilot VMs.

## 1. GitHub Issue (mandatory before any mutation)

Use `.github/ISSUE_TEMPLATE/infra-change-request.yml`. Canonical fields:

- **Title**: `[CC8.1] prox01 JOL Pilot Lithuania Deployment — Steps 1-5`
- **Labels**: `change-control`, `soc2`, `infrastructure`, `pilot`
- **Body must contain**:
  1. Scope: VMIDs 200–204, bridge/VLAN change on Gi1/0/11, MikroTik
     rules #1–#5 (Step 2 §3), PBS datastore `pilot-lt` + nightly jobs.
  2. Links to the planning docs (Step 1 topology, Step 2 vmbr layout +
     firewall matrix, Step 3 VM specs ×5, Step 4 backup plan).
  3. **Pre-conditions**: ADR-004 amendment merged; `data` pool created
     with `encryption=on`; Ubuntu 24.04 cloud template SHA256-verified;
     DPIA actions #1–#2 closed (`docs/compliance/dpia-trigger-check.md`).
  4. Rollback plan (per VM + per network change) — §2 below.
  5. Downstream repos named (AGENTS.md §1 rule 4): `jol-backend-platform`,
     `jol-bitrix24-integration`, `jol-core` (contracts consumed by the VMs).

## 2. Rollback Plan (recorded in the issue BEFORE execution)

### Per-VM snapshot discipline (AGENTS.md §0.3 naming)

Before ANY mutation of an existing or just-provisioned VM:

```bash
qm snapshot <vmid> pre-pilot-deploy-<YYYYMMDD-HHMM>
# backout:
qm rollback <vmid> pre-pilot-deploy-<YYYYMMDD-HHMM>
```

Timestamped naming per fleet precedent (`pre-rag-deploy-20260807-1959`,
`pre-m3-fix-20260818-0014`). Snapshot existence verified with
`qm listsnapshot <vmid>` and recorded in the issue.

### Per change class

| Change | Rollback |
|--------|----------|
| VM provisioning failure | `qm destroy <vmid> --purge` (fresh VMs have no external dependents — same posture as runbook Rollback §); data pool intact |
| VM mutation after go-live | `qm rollback <vmid> pre-pilot-deploy-<ts>`; if snapshot missing → PBS restore from last nightly (`docs/runbooks/jol-pilot-backup-plan.md` §2, RTO 4 h) |
| Gi1/0/11 trunk change | revert to `switchport mode access / access vlan 60` (pre-change running-config saved: `copy running-config startup-config` backup captured before change, filename recorded in issue) |
| MikroTik VLAN 45 SVI / rules | remove SVI + rules (they are additive; nothing depends on them until ingress exists); export/backup config before change |
| PBS datastore/jobs | remove job from `jobs.cfg`; datastore may remain (no destructive side effects) |
| `/etc/network/interfaces` on prox01 | `.bak.<timestamp>` file created before edit (AGENTS.md §0.3); restore + `ifreload -a` |

### AIDE protocol (AGENTS.md §0.3)

Before the deployment window on every affected guest/host: run
`sudo aide --check`, investigate ANY diff before proceeding; rebuild the
baseline only after the deployment completes and diffs are explained.

Per-VM baseline lifecycle (evidence-producing):

1. **Post-hardening baseline**: `aideinit` → move
   `/var/lib/aide/aide.db.new` → `/var/lib/aide/aide.db`.
2. **Seal the baseline hash**:
   `sha256sum /var/lib/aide/aide.db > evidence/<vm>-aide-baseline.sha256`
   (file joins the sealed evidence package — §3).
3. **Post-change verification**: `sudo aide --check` → record the diff
   against baseline in `evidence/<vm>-aide-postchange.txt`; any unexpected
   entry is an incident signal, not noise.
4. **Rebuild rule**: `aide --update` only via a change-controlled action
   whose diffs are explained in the CC8.1 issue.

## 3. Evidence requirements (verification rule §0.4)

Nothing is declared working without command output. Minimum evidence set,
each saved under `docs/compliance/evidence/` and linked from the issue:

| Evidence | File |
|----------|------|
| Host pool status post-change | `evidence/prox01-zpool-status-<YYYYMMDD>.txt` |
| Bridge/VLAN verification (`brctl`/`ip -br a` + switch `show`) | `evidence/prox01-vmbr-verify-<YYYYMMDD>.txt` |
| Per-VM provisioning log (cloud-init + hardening run) | `evidence/vm<vmid>-provision-<YYYYMMDD>.log` |
| Per-VM Step-3 D5 audit checklist output | `evidence/vm<vmid>-audit-<YYYYMMDD>.txt` |
| Firewall negative tests (Step 2 §5) | `evidence/pilot-firewall-negtests-<YYYYMMDD>.txt` |
| First PBS nightly success + restore drill | `evidence/restore-test-<vmid>-<YYYYMMDD>.log` |

Evidence files referenced in the CHANGELOG MUST exist at the time the row
is written — never cite future files (fabricated evidence is itself an
audit failure).

## 4. CHANGELOG discipline

`CHANGELOG.md` is the fleet **table format** — one row per production
change (Timestamp UTC | Author | Change | Environment | Ticket):

- One row per significant execution milestone (network change; VM batch;
  PBS jobs; go-live gate), each citing its ticket and evidence.
- Planning/design documents get a single documentation row (done for
  Steps 1–4 on 2026-08-23); they are not production changes.
- `CHANGELOG.md` row + ticket link are the completion criteria for CC8.1 —
  a change without a row is an open finding.

## 5. Go-live gate sequence

1. Issue open, labels set, rollback plan reviewed ✅
2. ADR-004 amendment merged; VLAN 45 live on N2048 + MikroTik
3. `data` pool ONLINE, `encryption on` verified
4. VMs 200–204 provisioned + Step-3 D5 checklists PASS (evidence saved)
5. Firewall matrix verified incl. negative tests
6. PBS jobs ran successfully; restore drill PASS for VM 201 (+200)
7. DPIA closed; erasure-log register live
8. Final `aide --check` rc=0 on all guests; CHANGELOG rows complete
9. Issue closed with evidence links → pilot accepts live data

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | CC8.1 change-control package created (Step 4) — template until execution issue is opened | this document |
| 2026-08-23 | Ratified-spec reconciliation: `pilot` label added to issue template | Step 4 ratified task spec |
| 2026-08-23 | Ratified-spec final: AIDE baseline lifecycle (aideinit → SHA256 seal → post-change diff evidence → change-controlled rebuild) added to AIDE protocol | Step 4 ratified task spec (final) |
