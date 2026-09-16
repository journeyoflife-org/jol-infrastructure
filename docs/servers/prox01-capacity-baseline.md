# prox01 — Capacity Baseline (JOL Pilot Lithuania)

> **Status**: DRAFT — host RAM/CPU **VERIFIED 2026-08-30** from
> `racadm hwinventory` (see §0.4 verification rule, AGENTS.md); promotion
> from DRAFT still owed: `data` pool creation + ARC cap recording.
> **Date**: 2026-08-23 (host facts updated 2026-08-30)
> **Scope**: Resource budget for the JOL Pilot Lithuania VM topology on the
> Dell R640 (`prox01`, Service Tag JBJ1BW2).
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022.
> **Companion doc**: `docs/architecture/jol-pilot-vm-topology.md`.
> **Ground truth**: `docs/servers/prox01.md`,
> `docs/runbooks/proxmox-r640-provisioning.md`,
> `docs/servers/pve-prod-hv01.md` (baseline format).

## 1. Host Resource Budget (D1)

| Resource | Total Host | Reserved (Host/ZFS) | Available for VMs | Headroom Rule |
|----------|------------|---------------------|-------------------|---------------|
| RAM | **96 GB** — VERIFIED 2026-08-30 from `racadm hwinventory` (12× 8 GB DDR4-2400 ECC, 12/24 slots used; recorded in `docs/servers/prox01.md` Hardware table) | 16 GB ZFS ARC cap + 4 GB PVE host = 20 GB | 76 GB | ≤ 80 % of available allocated to VMs |
| vCPU | **2× Intel Xeon Gold 6138, 20 cores/socket = 40 cores** — VERIFIED 2026-08-30 from `racadm hwinventory`; thread count pending `lscpu` (HT state: 80 threads if HT enabled) | 2 cores (4 threads) for PVE host | 38 cores (76 threads if HT enabled) | ≤ 80 % of available; no overcommit for pilot |
| Boot storage (`rpool`) | ~430 GiB usable — ZFS mirror, 2× 480 GB SAS SSD (verified: `docs/servers/prox01.md` Storage table) | PVE install + host pools | remainder | OS disks and small-footprint VMs only |
| Data storage (`data`) | ~7.3 TiB usable — planned ZFS raidz2, 6× 1.92 TB SATA SSD (verified: `docs/servers/prox01.md`; **pool NOT yet created** — status "post-install") | none | full pool | Primary target for pilot VM disks |

### Blocking prerequisite

The `data` raidz2 pool does not exist yet (`docs/servers/prox01.md` Status:
*In provisioning*; runbook Phase 5 step 3). **No pilot VM whose disk lives on
`data` may be created before the pool exists.** Verify with:

```bash
ssh root@10.60.60.10 zpool status data      # expect: raidz2, ONLINE, 6 disks
```

## 2. Proposed VM Demand (from topology doc)

| VMID | Hostname | vCPU | RAM | Disk | Disk pool |
|------|----------|------|-----|------|-----------|
| 200 | jol-app-pilot-lt01 | 4 | 8 GB | 80 GB | data (raidz2) |
| 201 | jol-db-pilot-lt01 | 4 | 16 GB | 120 GB | data (raidz2) |
| 202 | jol-bitrix-pilot-lt01 | 2 | 4 GB | 60 GB | data (raidz2) |
| 203 | jol-ingress-pilot-lt01 | 2 | 4 GB | 40 GB | rpool |
| 204 | jol-observ-pilot-lt01 | 2 | 6 GB | 100 GB | data (raidz2) |
| **Total** | | **14** | **38 GB** | **400 GB** | |

Storage check: 40 GB on `rpool` (~430 GiB usable, PVE already installed) —
passes with ample margin. 360 GB on `data` (~7.3 TiB usable) — passes once
the pool exists.

## 3. Headroom Analysis (D4)

Rule: `(Sum VM RAM) / (Host RAM − Reserve) ≤ 0.80`. Reserve = 20 GB
(16 GB ARC cap + 4 GB host). Sum VM RAM = 38 GB.

| Host RAM scenario | Available | Allocation ratio | Verdict |
|-------------------|-----------|------------------|---------|
| **96 GB — VERIFIED (actual)** | **76 GB** | 38 / 76 = **0.50** | ✅ **PASS** |
| With VM 202 resize to 1C-Bitrix spec (total 42 GB / 16 vCPU) | 76 GB | 42 / 76 = **0.55** | ✅ PASS |
| ~~64 GB floor scenario~~ | ~~44 GB~~ | ~~38 / 44 = 0.86~~ | superseded — actual config is 96 GB; kept for audit trail |

Note: Linux reclaims ZFS ARC under memory pressure, but a compliance-bound
pilot budgets conservatively — the ARC cap, not runtime reclaim behaviour, is
the auditable control. Record the chosen ARC cap
(`zfs set primarycache=… / zfs_arc_max` in `/etc/modprobe.d/zfs.conf`) in
this file once the host RAM is confirmed.

### vCPU headroom

Sum VM vCPU = 14 (16 with the VM 202 1C-Bitrix resize). Host verified:
2× Xeon Gold 6138, 40 cores. Conservative bound (HT disabled, 40 threads):
14 / (40 − 4) = **0.39**, 16 / 36 = **0.44**; with HT enabled (80 threads):
14 / 76 = **0.18**, 16 / 76 = **0.21** — ✅ PASS in every scenario.
Confirm HT state with `lscpu` once remote access is restored.

## 4. Verification Checklist

- [x] Host RAM confirmed via `racadm hwinventory` (iDRAC9 Enterprise session
      2026-08-30): 96 GB; recorded in `docs/servers/prox01.md`
- [x] Host CPUs confirmed via `racadm hwinventory`: 2× Xeon Gold 6138
      (20 cores/socket); recorded in `docs/servers/prox01.md`
      (`lscpu` thread-count confirmation still owed)
- [ ] `data` raidz2 pool created and ONLINE (runbook Phase 5 step 3)
- [ ] ARC cap configured and documented here
- [ ] Allocation ratio re-computed with real numbers; this doc promoted from DRAFT
      (ratio re-computed 2026-08-30: 0.50 PASS; promotion still owed the two
      items above)

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-23 | Initial capacity baseline (DRAFT) for JOL Pilot Lithuania planning | this document; `docs/servers/prox01.md` |
| 2026-08-30 | Host facts VERIFIED from iDRAC9 Enterprise `racadm hwinventory` (2× Xeon Gold 6138 40 cores; 96 GB ECC); headroom re-computed with real numbers: 38/76 = 0.50 PASS (0.55 with VM 202 resize); RAM/CPU checklist items closed. Backup: `prox01-capacity-baseline.md.bak.20260830-0253` | `docs/servers/prox01.md` Provisioning Log 2026-08-30; operator iDRAC session output |
