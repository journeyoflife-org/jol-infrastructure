# prox01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | prox01                                     |
| **Role**           | hypervisor (compute node)                  |
| **Environment**    | prod                                       |
| **Status**         | **In provisioning** (started 2026-08-06)   |
| **VLAN**           | 60 (Proxmox management), 10 (iDRAC OOB)    |
| **Static IP**      | 10.60.60.10                                |
| **OOB Management** | iDRAC9 — 10.10.10.11 (Gi1/0/40, VLAN 10)   |
| **OS**             | Proxmox VE 9.2 (Debian 13 Trixie)          |
| **Owner**          | jol-admin                                  |
| **Purpose**        | R640 cluster Node 1 — compute for AI service VMs |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | yes (PBS — pbs01, nightly encrypted)       |
| **Monitoring**     | planned (node-exporter, netdata)           |

## Role Description

First node of the Dell R640 Proxmox cluster (prox01–prox03). Provisioning
runbook: `docs/runbooks/proxmox-r640-provisioning.md`.

## Hardware

| Component     | Specification                             |
|---------------|-------------------------------------------|
| Platform      | Dell PowerEdge R640                        |
| Service Tag   | JBJ1BW2                                    |
| CPU           | TBD — record from `racadm hwinventory` after provisioning |
| RAM           | TBD — record from `racadm hwinventory` after provisioning |
| Boot Disks    | 2× HP 480 GB SAS SSD → ZFS mirror (`rpool`) |
| Data Disks    | 6× HPE 1.92 TB SATA SSD → ZFS data pool (post-install) |
| Storage Ctrl  | PERC H730P Mini — 8× single-disk RAID-0 VDs (Write Through / No Read Ahead); ZFS mirror on top; HBA330 swap still recommended long-term |
| PSU           | 2× hot-swap (Slot 1+2, fw 00.1B.53)        |
| iDRAC         | iDRAC9 (license level to be verified: `racadm getlicense -s`) |

### Firmware (recorded 2026-08-06, iDRAC Firmware Update page)

| Component | Version |
|-----------|---------|
| BIOS | 2.27.0 |
| iDRAC9 / Lifecycle Controller | 7.00.00.184 |
| PERC H730P Mini | 25.5.9.0001 |
| Backplane 1 | 4.35 |
| System CPLD | 1.0.2 |
| PSU (Slot 1+2) | 00.1B.53 |
| Intel X520/I350 rNDC NICs | 22.5.7 |

## Network

| Interface | IP / Role            | VLAN | Switch Port | Status |
|-----------|----------------------|------|-------------|--------|
| vmbr0 ← nic1 (I350 1G copper, MAC 24:6e:96:cb:ff:cd) | 10.60.60.10/24, gw 10.60.60.1 | 60 | Gi1/0/11 | In provisioning |
| nic0 (I350 1G copper, MAC 24:6e:96:cb:ff:cc) | no IP — spare/failover, bond candidate | 60 | Gi1/0/10 | Cabled, not addressed |
| nic2/nic3 (X520 10G SFP+) | unused — **no fiber on site** | — | — | Dark |
| iSCSI NIC  | 10.70.70.20 (planned) | 70 | Gi1/0/23 | Deferred (decision D6) |
| iDRAC9     | 10.10.10.11/24       | 10   | Gi1/0/40    | Reachable |

- DNS: internal resolver via MikroTik inter-VLAN routing
- Web UI: https://10.60.60.10:8006 (management VLANs only)
- Never assign 10.60.60.10 to Gi1/0/10 as well — same IP on two switch
  ports causes MAC-flapping and port-security violations. Configure a bond
  first (see runbook Phase 5).

## Storage

| Pool   | Type       | Disks | Usable (approx.) | Status |
|--------|------------|-------|------------------|--------|
| rpool  | ZFS mirror | 2× 480 GB SAS | ~430 GiB | Installed with PVE |
| data   | ZFS raidz2 (planned) | 6× 1.92 TB SATA | ~7.3 TiB | Post-install |

- Boot pool: `ashift=12`, `compress=zstd`, `checksum=on`
- Data drives: HP/HPE-branded in Dell backplane — functionally fine,
  reported as non-certified (cosmetic)

## SSH Policy

- Password authentication **disabled**
- Key-only access via centrally managed SSH keys
- Root login: prohibit-password (key-only)
- Idle session timeout: 15 minutes
- fail2ban: 3 attempts = 24h ban

## Security Controls

- Firewall: default deny incoming, allow 22/tcp, 8006/tcp (mgmt VLANs only)
- auditd: enabled for syscall auditing
- chrony: NTP synchronisation (SOC2 CC7.2)
- fail2ban: SSH brute-force protection
- iDRAC hardening: telnet disabled, TLS ≥ 1.2, NTP enabled,
  root password rotated on provisioning (see runbook Phase 4)
- iDRAC config backup stored **outside the repo** (secrets manager)

## OOB Management (iDRAC9)

- RACADM over SSH is the permanent management path (from admin01):
  `ssh root@10.10.10.11 racadm <command>` — no OMSA on the PVE host.
- Known issue resolved at provisioning: Storage → Controllers tab missing;
  fixed per Dell KB 000388426
  (`set system.storage.LimitExternalHBATopology Enabled`).

## Backup Policy

- VM backups via Proxmox Backup Server (pbs01)
- Schedule: nightly 02:00 UTC
- Encryption: client-side (PBS)
- RPO: 24 h | RTO: 4 h
- Note: ZFS mirror is redundancy, **not** a backup

## Maintenance Notes

- Firmware versions (iDRAC / BIOS / storage controller) must be recorded
  here after each update — see runbook recommendation #4
- Kernel updates require reboot — schedule with maintenance window
- PVE package updates via no-subscription repository
- All changes tracked via ticket and recorded in change log

## Risk Acceptance

| Risk | Mitigation |
|------|-----------|
| HP/HPE drives in Dell backplane (non-certified) | Monitor SMART via `smartd`; fan behaviour workaround in runbook Phase 2 |
| PERC RAID controller lacks true HBA mode (if present) | Single-disk RAID-0 VDs, Write-Through; HBA330 swap recommended |
| ZFS mirror boot = single-node resilience only | PBS nightly backups; prox02/prox03 cluster planned |
| iDRAC on management VLAN | VLAN 10 segmented; key/strong-auth; TLS 1.2+ only |

## Provisioning Log

- **2026-08-06**: provisioning started. iDRAC9 reachable at 10.10.10.11;
  Storage → Controllers tab missing (Dell KB 000388426 workaround queued).
  Credential hygiene action raised: pre-existing iDRAC password treated as
  compromised and scheduled for rotation (runbook Phase 4).
- **2026-08-06**: storage controller restored — PERC H730P Mini detected
  after BIOS defaults / flea-power drain; 8× single-disk RAID-0 VDs created
  (Write Through / No Read Ahead). iDRAC SSH host keys regenerated by the
  firmware update: stale ECDSA entry removed from admin01 known_hosts, new
  ED25519 fingerprint verified on-site (service tag JBJ1BW2) and accepted.
