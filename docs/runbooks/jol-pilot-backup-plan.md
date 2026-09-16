# Runbook: JOL Pilot Lithuania — Backup & DR Plan (pbs01)

> **Status**: DRAFT — activates when VMs 200–204 are provisioned on prox01.
> **Date**: 2026-08-23
> **Compliance**: SOC 2 Type II (CC7.3/A1.3 availability, A1.2 recovery) /
> GDPR Art. 17, Art. 32(1)(c) / ISO 27001:2022 A.8.13 (backup).
> **Inputs**: `docs/servers/pve-prod-hv01.md` (fleet backup baseline),
> `docs/servers/pbs01.md`, `docs/runbooks/proxmox-r640-provisioning.md`
> Phase 5, Step 3 VM specs, `docs/compliance/dpia-trigger-check.md`.
> **No credentials in this document** — PBS datastore fingerprints and
> encryption keys follow `docs/architecture/secret-flow.md`.

## 1. Architecture (D1)

- **Backup target**: pbs01 (HP P4500, 10.10.10.30:8007) — the single fleet
  PBS. Open decision D6 (port table §8) governs whether backup traffic
  gets a dedicated VLAN 85 path; until closed, backups flow over the
  existing routed path, **client-side encrypted** (fleet pattern,
  verified for hv01 and llm-prod-lt01).
- **Mechanism**: hypervisor-level **vzdump → PBS** from prox01 (fleet
  default). Guest-side `proxmox-backup-client` push is NOT used for pilot
  VMs — that pattern is reserved for the llm model-store precedent.
- **Consistency**: qemu-guest-agent fs-freeze on all 5 VMs (Step 3 specs).
- **All times UTC** (fleet convention; SOC 2 evidence consistency). Jobs
  are staggered away from the existing hv01 02:00 window so the single
  PBS/P4500 target is not contended.

### Per-VM schedule

| VM (VMID) | Schedule (UTC) | Pool | Encryption | Retention | RPO | RTO | Priority |
|-----------|----------------|------|------------|-----------|-----|-----|----------|
| jol-db-pilot-lt01 (201) | Daily 02:15 | data (raidz2, encrypted) | Client-side AES-256 (PBS) | 7d / 4w / 6m | 24 h | 4 h | **1 — crown jewel, freshest copy** |
| jol-app-pilot-lt01 (200) | Daily 02:30 | data | Client-side AES-256 (PBS) | 7d / 4w / 6m | 24 h | 4 h | 2 |
| jol-bitrix-pilot-lt01 (202) | Daily 02:45 | data | Client-side AES-256 (PBS) | 7d / 4w / 6m | 24 h | 4 h | 3 |
| jol-observ-pilot-lt01 (204) | Daily 03:00 | data | Client-side AES-256 (PBS) | 7d / 4w / 6m | 24 h | 4 h | 4 |
| jol-ingress-pilot-lt01 (203) | Daily 03:15 | rpool (unencrypted pool — guest holds no personal data at rest, Step 3 §D2 residual risk) | Client-side AES-256 (PBS) | 7d / 4w / 6m | 24 h | 4 h | 5 |

Rationale: DB first (freshest copy of the crown jewel), then dependency
order. Retention 7d/4w/6m = fleet standard (runbook Phase 5 #2). RPO/RTO
match the pve-prod-hv01 baseline. DB-level PITR (WAL archiving) is a
tracked enhancement — if donations enter pilot scope, revisit RPO for
VM 201 (PCI-DSS).

### Implementation — command/config evidence

Proxmox scheduled job (`/etc/pve/jobs.cfg` on prox01, applied via change
control):

```
pbs: pbs01-pilot
    server 10.10.10.30
    datastore pilot-lt
    fingerprint <PBS fingerprint — from secrets manager, never in repo>
    username pilot-backup@pam
```

```
vzdump-pilot: pilot-nightly
    schedule 02:15,02:30,02:45,03:00,03:15
    vmid 201,200,202,204,203
    storage pbs01-pilot
    mode snapshot
    notes-template "JOL pilot nightly — CC8.1 ticket {{ticket}}"
```

Datastore retention on pbs01 (`proxmox-backup-manager`) — the automated
retention control; an on-demand equivalent is `proxmox-backup-client prune
--repository … --keep-daily=7 --keep-weekly=4 --keep-monthly=6`:

```bash
proxmox-backup-manager datastore update pilot-lt \
  --prune-options keep-daily=7,keep-weekly=4,keep-monthly=6
```

Key handling (fleet precedent — llm-prod-lt01 PBS credentials): the PBS
encryption key and datastore token live ONLY in the secrets manager
(Vaultwarden — escrow entry labeled **`pbs01-pilot-encryption-key`**) and
on-host at `600 root:root` on prox01
(`/etc/pve/priv/…` managed by PVE); **never in the repo, never in
inventory**. Key loss = unrecoverable backups → the key itself is part of
the DR plan and the Vaultwarden escrow entry is verified at the go-live
gate (existence + authorized access).

## 2. Restore-Test Gate (D2) — MANDATORY before pilot go-live

Per VM (at minimum VM 201 and VM 200), execute and evidence:

1. **Simulated restore** to isolated VMID **299** on prox01:
   ```bash
   # on prox01 — restore network-DISCONNECTED (prevents IP duplication
   # of 10.40.40.x on live VLAN 40 during the drill)
   proxmox-backup-client restore --repository \
     pilot-backup@pam@10.10.10.30:pilot-lt vm/201/<timestamp> \
     --target 299
   # or via PVE: qmrestore <backup> 299 --force 0, then REMOVE the NIC
   # (net0 deleted) before first boot
   ```
2. **Integrity check**: boot test (systemd reaches multi-user), then —
   with the NIC attached only to an **isolated test bridge** (no VLAN 40):
   - VM 201: PostgreSQL starts, `pg_isready` OK, row-count sanity query
   - VM 200: application health endpoint returns HTTP 200
   - AIDE on the restored guest: `sudo aide --check` rc=0 (baseline travels
     with the backup)
3. **Evidence**: full session log to
   `docs/compliance/evidence/restore-test-<vmid>-<YYYYMMDD>.log`; record a
   row in each VM doc's Change History + the DR drill register
   (precedent: llm-prod-lt01 drill 2026-08-11 PASS — manifests + SHA256).
4. **Cleanup**: destroy VMID 299 (`qm destroy 299 --purge`) and verify no
   residue on the data pool; record cleanup in the evidence log.

**Gate rule**: no pilot go-live without a PASS for VM 201 (DB). A backup
that has never been restored is not a backup.

## 3. GDPR Art. 17 — Erasure vs. Backup Paradox (D3)

**The paradox**: Art. 17 requires erasure of personal data on request;
backups retained for RPO/RTO legitimately contain copies of that data and
cannot be selectively rewritten (PBS immutability is itself a security
control).

**Resolution (documented policy — cite in the Privacy Notice)**:

1. **Live erasure ≤ 30 days**: erasure requests are executed in the live
   DB (cascade DELETE, VM 201 via the app-tier Art. 17 endpoints) within
   the statutory window and recorded in the erasure register
   (`docs/compliance/erasure-log.md`).
2. **Backups are NOT rewritten**: copies age out naturally at backup
   expiry (keep-monthly=6 ⇒ maximum 6-month residual). This is the
   accepted, documented Art. 17(3)/Art. 5(1)(e)-compatible pattern
   (backups serve a legitimate recovery purpose; retention is bounded and
   declared).
3. **Restore-replay obligation**: if a backup containing erased data is
   ever restored to live, the erasure register MUST be replayed against
   the restored dataset before it serves traffic (restore runbook step).
4. **Containment while residual**: backup media are client-side encrypted
   (AES-256), access-restricted to the backup identity, and never mounted
   for routine processing — residual copies are inaccessible in practice.
5. **Declaration**: this policy (logical erasure + bounded backup
   residual + replay-on-restore) is stated in the pilot Privacy Notice and
   in the DPIA (`docs/compliance/dpia-trigger-check.md` §3 action #1).

## 4. Verification checklist

- [ ] All 5 jobs present in `jobs.cfg`; first nightly run succeeded (PBS task log OK)
- [ ] Retention visible on pbs01: `proxmox-backup-manager datastore info pilot-lt`
- [ ] Encryption: restore without key FAILS (negative drill, evidence logged)
- [ ] Restore-test gate PASS for VM 201 (and 200); evidence in `docs/compliance/evidence/`
- [ ] Erasure-log register exists and is referenced by the app-tier Art. 17 runbook
- [ ] DR drill recorded in VM docs' Change History

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Backup/DR plan created (Step 4, DRAFT) — activates at VM provisioning | this document |
| 2026-08-23 | Ratified-spec reconciliation: Priority column added; Vaultwarden escrow label `pbs01-pilot-encryption-key`; on-demand prune command noted | Step 4 ratified task spec |
