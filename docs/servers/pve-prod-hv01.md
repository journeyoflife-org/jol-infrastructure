# pve-prod-hv01

| Field              | Value                                      |
|--------------------|--------------------------------------------|
| **Hostname**       | pve-prod-hv01                              |
| **Role**           | hypervisor                                 |
| **Environment**    | prod                                       |
| **VLAN**           | 60 (Proxmox management)                  |
| **Static IP**      | 10.60.60.20                              |
| **OS**             | Proxmox VE 9.2 (Debian 13 Trixie)         |
| **Owner**          | jol-admin                                  |
| **Purpose**        | Hypervisor for AI service VMs (RAG, MCP, Hermes) |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | **NO — see Backup Policy** (verified 2026-08→2026-10-21: no PBS datastore registered, no valid vzdump job) |
| **Monitoring**     | **NO (verified 2026-10-21)** — node-exporter and netdata are not installed: no systemd units, no packages, no binaries, no listeners on 9100/19999. Only host artifact is the 06:00 cron watchdog (fixed same day, see Change History) |

## Role Description

Proxmox VE hypervisor hosting production AI service virtual machines.
Single-node cluster; no HA. Consumer-grade hardware with documented risk
acceptance (no ECC, no IPMI, single NIC/PSU).

## Hardware

| Component    | Specification                              |
|--------------|--------------------------------------------|
| Motherboard  | GIGABYTE GA-AX370-GAMING 5                |
| CPU          | AMD Ryzen 7 3700X (8C/16T, 4.4 GHz)       |
| RAM          | Corsair Vengeance LPX 64GB DDR4-2400 (non-ECC) |
| Storage      | NVMe 1.8 TB ADATA LEGEND 800 (`nvme0n1`) + HDD 1 TB Seagate ST1000LM024 (`sda`, 5400 rpm, 2.5″) |
| NIC          | Dual onboard: nic0 + nic1 (GA-AX370-GAMING 5) |
| IPMI/BMC     | None                                       |

### Storage roles (verified 2026-10-21, reconfigured same day)

| Device | Layout | Mount / storage id | Role | Backup copy |
|--------|--------|--------------------|------|-------------|
| `nvme0n1` 1.8 TB | p1 bios_grub, p2 ESP 1 G, p3 930 G → VG `pve` (`pve-root` 96 G, `pve-swap` 8 G, `pve-data` thin pool 810 G); **1001 GB unallocated** | `/`, `local`, `local-lvm` | host OS + ALL VM disks and cloud-init drives (VMIDs 100/101/102) | 1 (live) |
| `sda1` 400 G ext4 | UUID `1094ed1c…` | `/mnt/hdd-iso` → PVE `dir` storage `hdd-iso`, `content iso,vztmpl` | provisioning media (`noble-server-cloudimg-amd64.img`, SHA256 `d1940f7d…b005ac`) + container templates | 1 local (+ optional pxar to pbs01) |
| `sda2` 531 G ext4 | UUID `39c5baab…` | `/mnt/hdd-archive` (not a PVE storage) | host evidence: weekly `/etc/pve` config tarballs, daily health logs + `ALERTS.log`, access/system/mcp archives | 1 local → nightly pxar → **pbs01** (pending) |

Rules enforced on this host (runbook `docs/runbooks/hv01-storage-backup-reconfiguration.md` §2):

- The HDD is **not** a backup target and never was — `/mnt/hdd-iso/dump/` has been
  empty since creation 2026-07-30. `backup` content was removed from `hdd-iso` on
  2026-10-21 so no job or upload can target it, and so a missing mount can no
  longer make PVE silently write backups onto the NVMe root filesystem (observed
  behaviour: `pvesm status` reported `hdd-iso` "active, 93 GB free" == `local`).
- Both HDD fstab entries carry `nofail,x-systemd.mount-timeout=10s,
  x-systemd.device-timeout=10s` — a dead evidence disk must never block boot of
  the hypervisor or take RAG/MCP/Hermes down with it.
- NVMe free space (1001 GB) is capacity headroom only. A second copy on the same
  device has zero protection value.
- ext4: `defaults,noatime` kept (`data=ordered`, barriers on — never set
  `writeback`/`barrier=0`); `tune2fs -c 30 -i 180d` on both partitions.
- smartd monitors both devices (`/etc/smartd.conf`: short test daily 04:00,
  long test Sun 05:00, temp warnings 45/50 °C, mail to root).

## Virtual Machines

| VMID | Hostname        | vCPU | RAM   | Balloon min | Disk   | IP          |
|------|-----------------|------|-------|-------------|--------|-------------|
| 100  | rag-prod-lt01   | 4    | 24 GB | —           | 100 GB | 10.40.40.10 |
| 101  | mcp-prod-lt01   | 2    | 8 GB  | —           | 50 GB  | 10.40.40.11 |
| 102  | her-prod-lt01   | 2    | 4 GB  | 2 GB        | 50 GB  | 10.40.40.12 |

## Network

- vmbr0: 10.60.60.20/24 (VLAN 60, gateway 10.60.60.1, bridge-ports nic1)
- vmbr1: no host IP (bridge-ports nic0) — VMs use MikroTik 10.40.40.1 as gateway
- nic1 (MAC 1C:1B:0D:9F:4E:A8) → Gi1/0/5, switch VLAN 60 — management
- nic0 (MAC 1C:1B:0D:9F:4E:A6) → Gi1/0/6, switch VLAN 40 — VM traffic (RAG/MCP/Hermes)
- VMs directly on VLAN 40 (10.40.40.0/24), routed by MikroTik (no NAT)
- Web UI (8006) restricted to management VLANs

## SSH Policy

- Password authentication **disabled**
- Key-only access via centrally managed SSH keys
- Root login: prohibit-password (key-only)
- Allowed users: root, jol-admin
- Idle session timeout: 15 minutes
- fail2ban: 3 attempts = 24h ban

## Security Controls

- ⚠ **UFW is NOT active** (verified 2026-10-21: `ufw status` → `inactive`,
  `iptables -S` → `-P INPUT ACCEPT -P FORWARD ACCEPT`). The previously documented
  "UFW: default deny incoming, allow 22/tcp, 8006/tcp (mgmt only)" was never in
  force — inbound exposure is mitigated only by switch VLANs and the MikroTik.
- ⚠ Do **not** enable UFW from the documented rule set: the operator's SSH session
  arrives from `192.168.88.249` (this workstation, routed via 192.168.88.1), which is
  **not** in `10.60.60.0/24`/`10.40.40.0/24`. Allowing only the documented mgmt
  subnets locks the session out immediately, and this board has **no IPMI/OOB** —
  recovery means physical console. Required preconditions before any enable:
  (1) allow the real client source as well as the mgmt subnets; (2) timed
  auto-rollback (`systemd-run --on-active=5min ufw disable`) so a bad rule set
  self-heals; (3) console access arranged first. Helpful fact: `net.bridge
  .bridge-nf-call-iptables = 0`, so enabling host filtering cannot drag bridged VM
  traffic into INPUT (the 2026-08-08 incident class).
- auditd: ⚠ status not re-verified this session
- chrony: active — `Leap status: Normal` (SOC2 CC7.2 time source OK)
- fail2ban: ⚠ status not re-verified this session
- ⚠ **Notification leg is dead**: postfix runs (`inet_interfaces =
  loopback-only`, `relayhost` empty) but outbound :25 to Google MX is blocked by the
  upstream network (`Connection timed out`, IPv6 `Network is unreachable`), so mail
  from cron and from `mailnotification failure` sits deferred in the queue (observed:
  6 requests, oldest delay ≈ 3.4 days, all to the operator mailbox). Until an
  authenticated submission relay (465 is reachable; 25/587 are not) or a PVE 9
  notification target is configured, **every mail-based control in this fleet is
  void** — detection must be pull-based (watchdog gates + `ALERTS.log`).

## Backup Policy

**Target state (design, not yet in force)**

- VM backups: hypervisor `vzdump` → pbs01 datastore `pbs-store`, namespace
  `jol-hv01`, nightly staggered 02:00/02:15/02:30 UTC, `mode snapshot` +
  qemu-guest-agent fs-freeze, zstd, prune keep-daily=7/weekly=4/monthly=6
- Host evidence (`/mnt/hdd-archive`): nightly `proxmox-backup-client` pxar push
  → pbs01 `host/pve-prod-hv01` at 03:45 UTC
  (`scripts/maintenance/hv01-archive-to-pbs.sh`)
- RPO: 24 h | RTO: 4 h

**Actual state (verified 2026-10-21 — evidence
`docs/compliance/evidence/hv01-storage-inspection-20261021.txt`)**

| Item | Reality |
|------|---------|
| PBS datastore on this host | **none** — `/etc/pve/priv/storage/` absent, `storage.cfg` has only `local`, `local-lvm`, `hdd-iso` |
| Backup jobs | `pvesh get /cluster/backup` → `[]`. `jobs.cfg` holds a hand-written `job-vm100-nightly` whose option lines **lack the mandatory leading TAB** (`cat -A` proof, evidence file §8), so the parser dropped every one of them (`ignore config line: …` → `missing value for required option 'schedule'`) → it has never run. The `30 3 * * *` schedule form itself is valid PVE cron — the defect is file serialisation, not the schedule |
| Backup artifacts | one manual `vzdump-qemu-100-2026_08_12-23_26_27.vma.zst` (14 GB) in `/var/lib/vz/dump` — on the **same NVMe** as the VM it protects. VMIDs 101/102: never dumped |
| Consequence | ⚠ **No off-host backup exists for rag/mcp/her today.** The RPO 24 h / RTO 4 h claim in this file and in `docs/servers/rag-prod-lt01.md` is not met. `mailnotification failure` cannot alert, because a job that does not exist cannot fail |
| Blocking step | registering the datastore requires the `pve-backup@pbs!pve-token` secret from the password manager — it must be typed into the **PVE Web UI** (Add Storage → Proxmox Backup Server, fingerprint `4b:93:a9…54:92`, namespace `jol-hv01`), never into a CLI (`pvesm add pbs --password …` exposes it in argv and shell history, §0.1) |
| 3-2-1 | "one off-site" leg unmet: pbs01 remote sync (`pbs-jol01`) pending since 2026-08-01; backup traffic rides the management VLAN because VLAN 85 `nic2` is uncabled (open decision D6) |
| Do not delete | the 2026-08-12 vma file until a pbs01 snapshot of VMID 100 exists **and** its restore drill passed |

## Audit Checklist — Storage and Backup (run before declaring this host operational)

> Run as root on pve-prod-hv01. Never put the PBS token on a command line. Q: is
> there a backup? A: only if the target is a different device AND a restore worked.

```text
□ HDD present:          lsblk -o NAME,SIZE,MOUNTPOINT,MODEL /dev/sda
                        sda1 400G /mnt/hdd-iso, sda2 531G /mnt/hdd-archive
□ Mounts boot-safe:     grep hdd /etc/fstab   → both lines carry nofail + timeouts
□ Mount != root fs:     stat -c '%d' /mnt/hdd-iso /mnt/hdd-archive /  → the two HDD
                        devices, NOT the same device as /
□ No fake backup store: pvesm status → hdd-iso total ≈ 393 G (HDD), not 93 G (= root)
                        grep -A3 'dir: hdd-iso' /etc/pve/storage.cfg → content has no 'backup'
□ Drive health:         smartctl -H /dev/sda → PASSED; smartctl -A → Reallocated 0,
                        Current_Pending 0; smartd active and covers /dev/sda
□ FS integrity:         tune2fs -l /dev/sda1 | grep 'Filesystem state' → clean
                        tune2fs -l … | egrep 'mount count|interval' → 30 / 180d
□ Evidence readable:    for t in /mnt/hdd-archive/config-backup/*.tar.gz; do tar tzf "$t" >/dev/null || echo BAD $t; done
□ Evidence fresh:       ls -t /mnt/hdd-archive/config-backup | head -1  → within 8 days
                        ls -t /mnt/hdd-archive/health | head -1        → within 26 h
□ PBS datastore:        pvesm status | grep -w pbs01 → active
                        ls -l /etc/pve/priv/storage/pbs01.pw → 600 root (PVE 9 path per PBSPlugin)
                        pvesh get /nodes/pve-prod-hv01/storage/pbs01/status → ok
□ Job registered:       pvesh get /cluster/backup --output-format yaml → job listed
                        (an entry only in jobs.cfg but not here = job NEVER runs —
                        PVE drops option lines that lack the leading TAB)
□ Job schedule valid:   pvesh get /cluster/backup/hv01-nightly-pbs --output-format yaml
                        schedule is a pve-calendar-event ("02:00"), NOT legacy cron
□ Job covers all VMs:   vmid list includes 100, 101, 102; storage = pbs01; mode snapshot
□ Next run scheduled:   pvesh get /cluster/next-run | grep -A2 vzdump
□ Backup actually lands: pbs list on pbs01 (ns jol-hv01) → vm/100, vm/101, vm/102 each
                        ≥ 1 snapshot with a timestamp inside 26 h
□ Evidence replicated:  pbs list → host/pve-prod-hv01 with hv01-archive.pxar
□ Retention + GC:       pbs01 pbs-store-prune covers ns/jol-hv01; datastore usage < 80 %
□ Negative test:        restore WITHOUT the encryption key → MUST fail
□ Restore drill:        qmrestore of VMID 100 to scratch VMID 199 (NIC detached),
                        boot, service check, destroy 199 — logged in
                        docs/compliance/evidence/restore-test-<vmid>-<date>.log
□ VM data untouched:    grep -h '^scsi0' /etc/pve/qemu-server/*.conf → all local-lvm
```

## Maintenance Notes

- Kernel updates require reboot — schedule with maintenance window
- PVE package updates via no-subscription repository
- All changes tracked via ticket and recorded in change log

## Risk Acceptance

| Risk | Mitigation |
|------|-----------|
| No ECC RAM | nightly backups + PBS checksums (⚠ backup path itself is the open risk, see Backup Policy) |
| No IPMI/OOB | Physical access documented; netdata alerts — ⚠ netdata is not installed, so this mitigation is currently void; physical access is also what makes a bad firewall change expensive |
| Dual NIC (nic0 spare) | nic1 active on VLAN 60; nic0 available for failover/iSCSI |
| Single PSU | UPS; documented acceptance |
| HDD is consumer 5400 rpm, 2482 power cycles, `brokenfpdmaaa nolpm` quirks | holds no VM data and no backup role; evidence on it is replicated to pbs01; `nofail` so its death cannot block boot |
| Host config hand-maintained (no Ansible play targets `hypervisors`) | drift detection manual; extraction under Ansible is a tracked follow-up (same root-cause class as MCP finding M3) |

## Change History

| Date       | Change | Evidence |
|------------|--------|----------|
| 2026-07-31 | vmbr0/vmbr1 migrated to nic1 (Gi1/0/5, VLAN 60) / nic0 (Gi1/0/6, VLAN 40) | n2048-config-2026-07-31.txt |
| 2026-08-08 | Network incident: vmbr1 had drifted to an isolated NAT bridge (`bridge-ports none`, hypervisor IP 10.40.40.1 squatting the gateway, iptables MASQUERADE to vmbr0) — contradicting the documented L2 design. Restored: `bridge-ports nic0`, NAT rule and host IP removed; rag/mcp/her reachable again from admin01 | `/etc/network/interfaces.bak-20260808`, n2048 session 2026-08-08 |
| 2026-09-01 | Memory reconfiguration: her-prod-lt01 reduced 8 GB → 4 GB (no runtime, C1 CRITICAL, actual RSS was 2.4 GB). Balloon min set to 2048 MB. Total VM allocation 40 GB → 36 GB. Host available: 29 Gi / 62 Gi (53% free). Storage confirmed LVM thin on NVMe (no ZFS pool). ZFS ARC cap at 6.28 GB exists in `/etc/modprobe.d/zfs.conf` but is moot (no ZFS). | live `qm set 102` session 2026-09-01 |
| 2026-10-21 ~13:06 | 1 TB HDD (`sda`, ST1000LM024) hot-removed while mounted, later reconnected. Kernel: `Buffer I/O error on dev sda2 … lost sync page write`, `JBD2: I/O error when updating journal superblock for sda2-8`, `ata4.00: detaching`. Impact: no VM data at risk (all disks on `local-lvm`/NVMe); `/mnt/hdd-iso` and `/mnt/hdd-archive` mounts dropped, so `hdd-iso` silently resolved to the NVMe root fs (PVE reported it "active, 93 GB free"), `jol-config-backup`/`jol-health` targets unreachable, and PVE auto-created `dump/` + `template/` on `/`. Reconnected same day; forced `e2fsck -f -p` on both partitions → rc=0, no errors; all 5 config tarballs `tar tzf` OK; cloud image SHA256 `d1940f7d…b005ac` readable. Lesson: this device is not hot-swappable-safe and holds no backup role. | `dmesg`, `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §1–3 |
| 2026-10-21 | Storage/backup roles reconfigured per `docs/runbooks/hv01-storage-backup-reconfiguration.md` phases 1–3: (a) both HDD fstab entries given `nofail` + systemd mount/device timeouts; (b) `pvesm set hdd-iso --content iso,vztmpl` — `backup` capability removed from the single-copy HDD; (c) `tune2fs -c 30 -i 180d` on `sda1`/`sda2` (was `-1`/`0`, i.e. fsck disabled); (d) evidence dirs verified. Rollback: `/etc/fstab.bak.20261021-152255` and `/mnt/hdd-archive/system/prechange-20261021-152255/`. **NOT yet done (needs operator secret custody):** pbs01 namespace+ACL, PBS datastore registration via Web UI, replacement vzdump job for VMIDs 100/101/102, nightly `hv01-archive-to-pbs.sh` cron. Backup Enabled corrected from "yes (PBS)" to NO — the claim was never true (job `job-vm100-nightly` was rejected by the parser; last dump 2026-08-12). | `scripts/maintenance/hv01-storage-baseline.sh` run log `/var/log/jol-hv01/baseline-20261021-152255.log`; evidence file above |
| 2026-10-21 | Control-plane claims corrected after live probes (see runbook §1c): **monitoring absent** (no node_exporter/netdata units, packages, binaries or listeners — the "node-exporter, netdata" claim and `monitoring_enabled: true` in inventory were false); **UFW inactive** with `iptables -P INPUT ACCEPT` (the documented default-deny rule set was never applied, and applying it as documented would lock out the only operator SSH source, `192.168.88.249`, on a board with no IPMI); **mail notifications undeliverable** (outbound :25 blocked, queue deferred up to ~3.4 d, no notification target) — so `mailnotification failure` is void and detection must stay pull-based. No config change made for these three: each needs its own change record and, for UFW, console access + timed auto-rollback | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §11 |
| 2026-10-21 | Phase-7 prep installed: `/usr/local/bin/hv01-archive-to-pbs.sh` (750 root:root, SHA256 `1a28bb6c…c70dc3`, identical to the repo copy) and `/etc/jol-hv01` created `700 root:root`. No cron entry yet (needs the two secret files). `proxmox-backup-client` already present | `docs/servers/pbs01.md` §"Pending onboarding"; evidence file §9 |
| 2026-10-21 | **HIGH fixed — the weekly `/etc/pve` config backup contained private key material** (`etc/pve/priv/pve-root-ca.key`, `priv/authkey.key`, `pve-www.key`, `nodes/pve/pve-ssl.key`, `priv/authorized_keys`) in a **644** archive on the HDD; the planned nightly replication to pbs01 would have copied it off-host. Replaced by `scripts/maintenance/hv01-config-backup.sh` (installed `/usr/local/bin` 750, sha256 `c1a56589d717`, host == repo): excludes `priv`/`*.key`/`*.pem`/`*.srl`, `umask 077`, forces mode 600, and **refuses to publish** if any key entry survives; `/etc/cron.d/jol-config-backup` rewritten with `PATH`/`SHELL` and no `2>/dev/null` error suppression; old tarballs chmod 600; previous cron preserved at `/mnt/hdd-archive/system/jol-config-backup.pre-fix-20261021-222224`. New archive verified: **0 key entries, 9 useful config entries**, mode 600, 132K. Key material is now escrow-only (Vaultwarden) and deliberately not backed up. ⚠ Open decision: five pre-fix tarballs still hold the keys — delete them, and rotate `pve-root-ca.key`/`authkey.key` if the HDD ever left the site. Watchdog also gained two gates (no key material in config archives; every declared storage must be `active`) and immediately flagged `storage pbs01 is declared but status=inactive` | `scripts/maintenance/hv01-config-backup.sh` (sha256 `c1a56589d717`, host == repo); `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §18 |
| 2026-10-21 | `pbs01` PBS storage exists (created via Web UI 19:50, encryption key `priv/storage/pbs01.enc` present, namespace `jol-hv01`, fingerprint pinned) but **cannot activate**: `priv/storage/pbs01.pw` is empty (1 byte = newline), PVE reports `Use of uninitialized value $password … 401 Unauthorized`. Enabled it (`pvesm set pbs01 --disable 0`) so the failure is visible instead of silent. ⚠ **No backup job, no off-host backup yet** — the credential value is the single blocker, and it must be typed by the operator (browser field or a `read -rs` pipe), never via chat or argv | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §18; `/etc/pve/storage.cfg`, `pvesm status` |
| 2026-10-21 | Monitoring control restored (runbook phase 8, HIGH): the daily watchdog had emitted **415 CRITICALs since 2026-07-31, all of them false** (249 `VM 10x is  - attempting restart`, 166 `SMART FAILURE on /dev/…`) because `/etc/cron.d/jol-health` sets no `PATH`, cron's default PATH lacks `/usr/sbin`, and the script mapped "command not found" to "drive failed / VM stopped". Side effects: the `qm start` safety net had never actually run, and the alert volume made the channel untrustworthy — which is how "Backup Enabled: yes" rotted unnoticed for ten weeks. Replaced with the managed `scripts/maintenance/hv01-health-check.sh` (750 root:root, SHA256 `fdd1a5fa…32cece`): explicit PATH, probe-unavailable reported separately from failure, rasdaemon parsed by record block (the old `grep -c error` counted its own "No Memory errors." headings — the reported "22 RAM errors" was fiction; the 6 real records are today's block-device I/O errors), plus new gates for mount reality, `jobs.cfg`-vs-scheduler registration drift, last vzdump outcome and config-evidence freshness. `PATH=/usr/sbin:/usr/bin:/sbin:/bin` added to the cron file. Verified under `env -i PATH=/usr/bin:/bin`: 3 alerts, all true, rc=1; negative test `VM_IDS=9999` no longer claims a stopped VM. VM auto-restart is opt-in (`HV01_AUTO_START_VM=1`, default off) per §0.3 | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §5–§6 |
