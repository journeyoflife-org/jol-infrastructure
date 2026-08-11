# pbs01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | pbs01 (pbs01.jol.lan)                      |
| **Role**           | backup-server                              |
| **Environment**    | prod                                       |
| **VLAN**           | 10 (management), 70 (iSCSI), 85 (backup)  |
| **Static IP**      | 10.10.10.30                                |
| **OS**             | Proxmox Backup Server 4.2 (Debian 13 Trixie) |
| **Kernel**         | 7.0.0-3-pve                                |
| **Owner**          | jol-admin                                  |
| **Purpose**        | VM backup target for pve-prod-hv01 (nightly encrypted backups); model-store backup target for llm-prod-lt01 (since 2026-08-11) |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | n/a (IS the backup target)                 |
| **Monitoring**     | active (node-exporter :9100)               |

## Role Description

Proxmox Backup Server providing deduplicated, encrypted VM backups for the
on-prem Proxmox VE hypervisor, and (since 2026-08-11) encrypted
model-store backups from bare-metal llm-prod-lt01 via
`proxmox-backup-client`. Runs on repurposed HP P4500 storage hardware
with a RAIDZ2 ZFS pool (6-disk, tolerates 2 simultaneous failures).

## Hardware

| Component    | Specification                              |
|--------------|--------------------------------------------|
| Platform     | HP StorageWorks P4500 (LeftHand)           |
| CPU          | Intel Xeon X5650 @ 2.67 GHz (6C/12T, 1 socket) |
| RAM          | 48 GB DDR3 ECC                             |
| OS Disk      | 119 GB SSD (LVM: 94 GB root + 8 GB swap)  |
| Data Disks   | 6 × 559 GB SCSI (RAIDZ2 → ~3.27 TB usable)|
| NIC          | 4× total: nic0/nic1 (USB), nic2 (PCIe), nic3 (unused) |
| IPMI/BMC     | None (legacy HP iLO may exist, unconfigured) |
| Boot Mode    | Legacy BIOS (no Secure Boot)               |

## Network

| NIC  | Kernel Name     | IP           | VLAN | Gateway   | Status |
|------|-----------------|--------------|------|-----------|--------|
| nic0 | enx10604bb17436 | 10.10.10.30/24 | 10 (Mgmt) | 10.10.10.1 | Active |
| nic1 | enx10604bb17437 | 10.70.70.10/24 | 70 (iSCSI) | — | Active |
| nic2 | enp6s0f0        | 10.85.85.10/24 | 85 (PBS) | — | Down (no cable) |
| nic3 | —               | manual       | —    | —         | Disabled |

- DNS: 10.10.10.1 (MikroTik RB5009)
- Switch ports: Gi1/0/19, Gi1/0/20 (VLAN 10, Active)
- Web UI: https://10.10.10.30:8007

## Storage

| Pool         | Type    | Disks | Usable  | Used | Health |
|--------------|---------|-------|---------|------|--------|
| backup-pool  | RAIDZ2  | 6     | 3.27 TB | ~0%  | ONLINE |

- Datastore: `pbs-store` → `/backup-pool/pbs-store`
- Filesystem backend (ZFS on top)
- Dedup: off (appropriate at this scale)

## SSH Policy

- Password authentication **disabled**
- Key-only access via centrally managed SSH keys
- Root login: prohibit-password (key-only)
- Allowed users: root
- Idle session timeout: 15 minutes
- fail2ban: active (SSH jail, 3 retries → 24h ban, ignoreip 10.10.10.0/24)

## Security Controls

- nftables: default deny incoming; allow 22/tcp + 8007/tcp from 10.10.10.0/24, 8007 from 10.60.60.0/24, 8007/tcp from 10.30.30.10 (llm-prod-lt01, since 2026-08-11)
- chrony: NTP synchronisation via 10.10.10.50 (Stratum 3 local peer) — SOC2 CC7.2
- smartd: active, disk health monitoring
- auditd: active (SOC2/ISO 27001 rules — auth, identity, PBS config, cron, firewall, privileged exec)
- TLS: self-signed RSA-4096 (CN=pbs01.jol.lan), fingerprint pinned on PVE

## Network Notes

- Gateway 10.10.10.1 (MikroTik VLAN 10) — **operational** via static ARP entry
- Dell N2048 firmware bug: broadcast flooding fails on trunk Gi1/0/48 for VLAN 10
- Workaround: permanent ARP entry `10.10.10.1 → D0:EA:11:4B:67:A0` on nic0
- Internet routing: functional (APT, DNS, NTP all working)

## Backup Policy (as target)

- Receives nightly VM backups from pve-prod-hv01
- Schedule: 02:00 UTC (configured on PVE side)
- Encryption: client-side (PBS encryption key stored outside repo)
- Prune: keep-daily=7, keep-weekly=4, keep-monthly=6 (job: `pbs-store-prune`, daily 03:00)
- Verify: monthly re-check after 30 days (job: `pbs-store-verify`, 1st of month 04:00)
- **llm-prod-lt01 model store (since 2026-08-11)**: namespace `jol-llm`,
  group `host/llm-prod-lt01`, archive `jol-models.pxar` (~22 GB);
  nightly 03:15 client-side cron on the LLM host; client-side
  encryption (`/etc/jol-ollama/pbs-encryption.key` on that host,
  fingerprint `74:f6:4f:c5:a3:75:69:f4`); retention prune
  keep-daily=7/keep-weekly=4 runs client-side; restore drill passed
  2026-08-11 (full 22 GB, SHA256-verified)
- RPO: 24 h | RTO: 4 h

## Certificates

- Self-signed RSA-4096, issued 2026-07-04
- CN: pbs01.jol.lan | SAN: localhost, pbs01, pbs01.jol.lan
- Fingerprint: `4b:93:a9:7e:0b:9a:89:ee:1a:9f:64:2c:40:e1:8f:3a:4a:91:92:d4:29:ed:f5:a6:1b:1d:b3:26:e6:4c:54:92`

## APT Repository

- `deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription`
- Enterprise repo: disabled (no subscription)

## Maintenance Notes

- Kernel updates require reboot — schedule with maintenance window
- PBS package updates via no-subscription repository
- ZFS scrub: monthly (automatic via zfs-zed)
- All changes tracked via ticket and recorded in change log

## Risk Acceptance

| Risk | Mitigation |
|------|-----------|
| Legacy CPU (Westmere 2010, no AES-NI) | Adequate for I/O-bound backup; plan R740 migration |
| No IPMI/OOB management | Physical access documented; smartd alerts |
| USB NICs (nic0/nic1) | Monitor for stability; PCIe nic2 available for VLAN 85 |
| Single PSU (P4500 chassis) | UPS; documented acceptance |
| Legacy BIOS boot | Functional; no Secure Boot required for PBS |

## First Audit: 2026-08-01

- PBS 4.2 installed, RAIDZ2 healthy, datastore empty (fresh install)
- P0 hardening executed: SSH keys deployed, password auth disabled, root login
  restricted to key-only, nftables firewall enabled (default deny), NTP synced
  via local peer 10.10.10.50, root password rotated
- New root password stored in password manager (not in repo)
- P1 completed (2026-08-01): fail2ban, auditd, prune/verify jobs, MikroTik VLAN 10 gateway (static ARP workaround), PVE backup user created
- P2 completed: node-exporter (systemd+zfs+processes collectors)
- Remaining: PVE client config (needs console access for static ARP on PVE), remote sync (pbs-jol01), centralised logging
- PVE backup credentials: user `pve-backup@pbs`, token `pve-backup@pbs!pve-token` (secret in password manager)

## Onboarding: llm-prod-lt01 model store — 2026-08-11

- User `jol-llm-backup@pbs` + token `llm-token` created; ACL
  `DatastorePowerUser` on `/datastore/pbs-store` for both (backup +
  restore + prune of owned snapshots). Note: PBS intersects token
  privileges with the parent user's, so both entries are required.
- Namespace `jol-llm` created (directory-based:
  `/backup-pool/pbs-store/ns/jol-llm`, backup:backup 750). PBS 4.2
  has no CLI for namespaces and creation via API/client requires
  `Datastore.Modify`, which no non-admin role grants.
- nftables: 8007/tcp opened for 10.30.30.10 only (routed path
  VLAN 30 → MikroTik → VLAN 10; no switch change needed). VLAN 85
  nic2 remains uncabled (open decision D6 — future hardening).
- Client: `proxmox-backup-client` 3.4.7 on llm-prod-lt01 (Debian
  bookworm pbs-client repo — the `ubuntu/pbs-client` path does not
  exist). Token secret via `PBS_PASSWORD_FILE`; TLS pinned via
  `PBS_FINGERPRINT`.
- Token secret + client encryption key recorded in the password
  manager (not in repo).
