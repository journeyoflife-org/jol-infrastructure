# her-prod-lt01

> **⚠ HARDENED 2026-09-01**: `harden-ai-hosts.yml` roles applied manually
> (Ansible not available on control path). Snapshot `pre-harden-20260901-2024`
> taken before changes. Final verification: **18/19 PASS** — all core
> hardening controls active. See Change History and
> `docs/compliance/ai-services-audit-20260901.md` §1.1 for full evidence.

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | her-prod-lt01                              |
| **Role**           | hermes                                     |
| **Environment**    | prod                                       |
| **VLAN**           | 40                                         |
| **Static IP**      | 10.40.40.12                                |
| **OS**             | Ubuntu 24.04 LTS (VM)                      |
| **Owner**          | jol-admin                                  |
| **Purpose**        | Hermes agent orchestration, workflows, automation |
| **SSH Policy**     | key-only (ENFORCED 2026-09-01) |
| **Backup Enabled** | **yes (re-verified 2026-11-01)** — nightly `vzdump` on pve-prod-hv01 → pbs01 ns `jol-hv01`; VMID 102 newest snapshot `2026-11-01T00:00:07Z` (10 consecutive OK local nights); this group was also the one whose 2026-10-22 restore drill proved the store |
| **Monitoring**     | yes (node-exporter 1.7.0, active 2026-09-01) |
| **VMID**           | 102                                        |
| **Hypervisor**     | pve-prod-hv01                              |

## Role Description

Hermes Agent orchestration server running AI-powered infrastructure
automation: backup verification, CIS compliance scanning, P1 incident
triage, daily operational reporting, and Bitrix24 CRM integration.
All data residency confined to EU/EEA (GDPR Art.25).

## Resources

| Resource | Allocation |
|----------|-----------|
| vCPU     | 2         |
| RAM      | 4 GB (reduced from 8 GB, 2026-09-01; no runtime = C1 CRITICAL) |
| Disk     | 50 GB (NVMe thin) |

## Network

- VLAN 40 — AI Services segment (10.40.40.0/24)
- Gateway: 10.40.40.1 (MikroTik RB5009 inter-VLAN router; vmbr1 is direct L2 bridge, no NAT)
- Ollama access: 10.30.30.10:11434 (VLAN 30, routed)
- MCP access: stdio-only on mcp-prod-lt01 — no HTTP endpoint exists
  (port 3000 deliberately closed; Hermes MCP client integration requires
  C1 CRITICAL runtime resolution first — see AGENTS.md §2.4)
- Ingress restricted to internal service mesh and bastion only

## SSH Policy

- Password authentication **disabled** (enforced 2026-09-01)
- Key-only access via centrally managed SSH keys
- Root login **disabled** (enforced 2026-09-01)
- Administrative access via `jol-admin` + sudo
- Idle session timeout: 15 minutes (ClientAliveInterval 300 × 3)
- LogLevel VERBOSE, MaxAuthTries 3
- Hardening drop-in: `/etc/ssh/sshd_config.d/00-jol-hardening.conf`

## Firewall Ports

| Port | Service        | Access       | Status |
|------|----------------|--------------|--------|
| 22   | SSH            | 10.40.40.0/24, 10.60.60.0/24, 10.10.10.0/24 | active (UFW) |
| 9100 | node-exporter  | 10.40.40.0/24 | active (UFW) |

## Backup Policy

**Working baseline (verified 2026-10-31T20:36Z — read-only probes in
`docs/compliance/evidence/hv01-backup-baseline-20261031.txt`)**

- Off-host VM backup **IS in force**: hypervisor job `hv01-nightly-pbs` (`schedule 02:00`
  Europe/Vilnius, `vmid 100,101,102`, `mode snapshot`, `compress zstd`, `prune-backups
  keep-daily=7,keep-weekly=4,keep-monthly=6`, `repeat-missed 1`) → datastore `pbs01` (active),
  namespace `jol-hv01`.
- **10** consecutive scheduled OK runs (local nights 2026-10-23 → **2026-11-01**, re-measured
  2026-11-01T15:21Z from the hypervisor's task epochs); VMID 102 holds **8** groups, newest
  `2026-11-01T00:00:07Z` ⇒ **RPO 24 h met** (age 15.3 h at probe time, `verification.state=ok`).
- **Restore drill PASSED for THIS VMID** on 2026-10-22: `qmrestore` of `vm/102/2026-10-22T20:42:23Z`
  to scratch VMID 199 (task OK, 50 GiB in 9.4 s, decrypted with the stored key), booted with `net0`
  removed, guest agent responsive after 80 s, then destroyed clean. All three AI-estate VMIDs now have
  a proven restore of their own group (102 → 2026-10-22, 100 → 2026-10-31T21:58Z, 101 → 2026-10-31T22:41Z).
- Impact framing unchanged: VMID 102 is a definition-only host with no runtime state (C1 resolved
  2026-09-19), so rebuild from `jol-hermes-agents` remains the documented recovery path; the nightly
  backup removes the single-copy risk of whatever has accumulated on the disk since.
- Still open: the 3-2-1 "one off-site" leg — pbs01 `proxmox-backup-manager remote list` returns
  empty (verified 2026-10-31), so hypervisor and backup custodian still share one site.

RPO: 24 h (met) | RTO: 4 h (met for VMID 102 — the only drilled group)

**History**: on 2026-10-21 this page claimed a nightly PBS backup that had never existed (no
datastore on the hypervisor; `pvesh get /cluster/backup` → `[]`). Closed 2026-10-22 by
`docs/runbooks/hv01-storage-backup-reconfiguration.md`.

## Monitoring Expectations

- Node-level metrics: CPU, memory, disk, network via node-exporter
- Alerting: host unreachable > 2 min, disk > 90 %
- Log shipping to centralised logging stack

## Compliance Notes

- GDPR: All inference via local Ollama (EU-only, zero cross-border transfer)
- SOC2: Full audit trail of agent actions
- ISO 27001: Access control via key-only SSH + UFW

## Maintenance Notes

- Kernel patching during approved maintenance windows only
- Reboot required for kernel updates — schedule with AI team
- All changes tracked via ticket and recorded in change log

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-09-01 | **CRITICAL AUDIT FINDING**: Hardening probes executed (admin01 → pbs01 agent-forward → her-prod-lt01). Result: `harden-ai-hosts.yml` NEVER applied. 17/17 checks FAIL. Finding H1 = CRITICAL. | `docs/compliance/ai-services-audit-20260901.md` §1.1 |
| 2026-09-01 | **H1 REMEDIATION EXECUTED**: Snapshot `pre-harden-20260901-2024`. All hardening roles applied manually (Ansible not available on control path): packages (auditd/fail2ban/chrony/aide/qemu-guest-agent/node-exporter), sysctl (kptr_restrict=2, rp_filter=1), SSH drop-in (key-only, root=no, MaxAuthTries=3, LogLevel=VERBOSE), UFW (default deny + rules), AIDE init + nightly cron, timezone Europe/Vilnius, directory layout. UFW blocked pbs01 relay path (10.10.10.0/24) — fixed via `qm guest exec` through hypervisor. Final verification: **18/19 PASS** (AIDE DB exists, `aide --check` needs config — cron handles nightly). node_exporter v1.7.0 from apt (fleet pin 1.8.2 — minor version gap, functional). | live session 2026-09-01 |
| 2026-10-22 | VMID 102 backed up off-host for the first time and **restored in a drill** (`vm/102/2026-10-22T20:42:23Z` → scratch VMID 199 → destroyed clean) | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §17 |
| 2026-10-31 | **Backup baseline re-verified read-only; "Backup Enabled: NO (2026-10-21)" corrected to YES.** 9 consecutive scheduled OK nightlies, newest vm/102 group `2026-10-31T00:00:13Z`; still single-site (no pbs01 remote sync) | `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` |
| 2026-11-01 16:11Z | **Offline filesystem check of THIS VMID's restored image (issue #137, runbook §6)** — `vm/102/2026-11-01T00:00:07Z` → scratch VMID 199 (53.7 GB in 9.4 s @5.47 GB/s, 91 % zeroes), never booted, `losetup -f --show -P` then `e2fsck -fn` / `fsck.vfat -n`: `/` **rc=4** (35 orphan-list inodes + one zero-dtime, negative bitmaps, superblock `state: clean`, **0** severe markers), `/boot` **rc=0 clean**, **ESP rc=1 FAT dirty bit** (accepted, non-severe, present in every nightly image). Exit 1 = CHECKED-WITH-RESIDUAL; teardown verified by post-state (`lv_count=0 loop_count=0`, pool 5.94 % → 5.94 %, all VMs running). Run by the new durable `pve:/usr/local/bin/jol-offline-fsck-drill.sh` (repo == host, sha `6dbc6d8a167a7705…`) | evidence §12; host `/var/log/jol-hv01/offline-fsck-20261101-180616.log` (= 16:06:16Z) |
