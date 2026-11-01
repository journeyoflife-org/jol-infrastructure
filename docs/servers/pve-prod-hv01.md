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
| **Backup Enabled** | **yes (verified 2026-10-31)** — job `hv01-nightly-pbs` → datastore `pbs01` ns `jol-hv01`, 9 consecutive scheduled OK runs. History: the claim was false from 2026-08 until the 2026-10-21 inspection found no datastore and no valid vzdump job; closed 2026-10-22 |
| **Monitoring**     | **NO push metrics (re-verified 2026-10-31)** — `systemctl is-active prometheus-node-exporter` → `inactive`, `netdata` → `inactive`, `ss -tln` → 0 listeners on 9100/19999. Detection is pull-based: the host's OWN schedule is `0 6 * * *` in `/etc/cron.d/jol-health`; the 15-minute cadence visible in the log comes from the **workstation** user timer `jol-fleet-health.timer` (`~/.config/systemd/user/`, active — last 23:02:57 → next 23:17:57) running `jol-fleet-health-pull.sh` over SSH. There is **no hv01-side timer** (`systemctl list-timers` on hv01 lists none — measured 2026-10-31). Today it emitted 2 true CRITICALs (alert transport dead + no end-to-end proof record). F-2 (HDD `ALERTS.log` mirror frozen since 2026-10-21) was **FIXED the same evening** — see Backup Policy and issue #124 |

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
| `sda2` 531 G ext4 | UUID `39c5baab…` | `/mnt/hdd-archive` (not a PVE storage) | host evidence: weekly `/etc/pve` config tarballs, daily health logs + `ALERTS.log`, access/system/mcp archives | 1 local → nightly pxar → **pbs01** (LIVE since 2026-10-25; newest `host/pve-prod-hv01/2026-10-31T01:45:01Z`) |

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

**Working baseline (verified 2026-10-31T20:36Z — read-only probes,
`docs/compliance/evidence/hv01-backup-baseline-20261031.txt`)**

| Item | State |
|------|-------|
| PBS datastore | `pvesm status` → `pbs01 pbs active`. Registered 2026-10-22 through the secret-safe path (token typed into the PVE form / delivered over stdin, never argv — §0.1), namespace `jol-hv01`, client-side encryption key `/etc/pve/priv/storage/pbs01.enc` escrowed off-host |
| Backup job | `pvesh get /cluster/backup` → `hv01-nightly-pbs`: `enabled 1`, `schedule 02:00` (pve-calendar-event, not legacy cron), `vmid 100,101,102`, `mode snapshot`, `compress zstd`, `prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6`, `repeat-missed 1`, `next-run 1793491200` (= 2026-10-31T23:00Z / Nov 1 02:00 local) |
| Scheduled runs | **10 consecutive `vzdump` tasks with status `OK`** (local nights 2026-10-23 → 2026-11-01; re-measured 2026-11-01T15:21Z from task epochs: Nov 1 `00:00:01Z`, Oct 31 `00:00:07Z`, Oct 30/29/28/27/26 `00:00:0xZ`, Oct 25-23 nights as `23:00:0xZ`). ⚠ Snapshot names are UTC and the series shifts at the 2026-10-25 DST change (`…T23:00:0xZ` before, `…T00:00:0xZ` after) — read in UTC without that break it looks like a missing night; there is none |
| Artifacts on pbs01 | `ns/jol-hv01/vm/{100,101,102}` → **8 groups each** (re-measured 2026-11-01T15:21Z; was 7 on 2026-10-31 — keep-daily=7 is doing real work); newest `2026-11-01T00:00:01Z`/`:04Z`/`:07Z` = 15.3 h old at probe time ⇒ **RPO 24 h met**, all three carrying the same `encrypted` fingerprint and `verification.state=ok`. `ns/jol-hv01/host/pve-prod-hv01` → nightly pxar evidence since 2026-10-25 |
| Restore proof | **All three groups individually drilled AND offline filesystem-checked.** Drills: vm/102 2026-10-22, vm/100 2026-10-31T21:58Z (#131), vm/101 2026-10-31T22:41Z (#135, with the fleet's first negative-encryption test). Offline legs (`e2fsck -fn` + `fsck.vfat -n`, image never booted): all three VMIDs 2026-11-01T16:06-16:11Z (#137) → `p1` rc=4 non-severe (orphan-list/zero-dtime/negative-bitmap pending work on a quiesced copy), `p16` rc=0 clean, `p15` (ESP) rc=1 dirty-bit, accepted and named. Evidence §11/§12; this row previously claimed vm/100 and vm/101 were UNVERIFIED, which was stale as of 2026-10-31 |
| pbs01 side jobs | `pbs-store-prune` daily `*-*-* 03:00` (keep-last 1, daily 7, weekly 4, monthly 6); `pbs-store-verify` monthly `*-*-01 04:00` (`ignore-verified=1`, `outdated-after=30`) |
| Capacity | `zfs list -o name,used,avail /backup-pool` → 73.6 G used / 2.04 T avail (~3.5 %). ⚠ `pvesh get …/storage/pbs01/status` reports `total/used/avail = 0` for `pbs` type — read usage on pbs01, never through PVE |
| Retention gate | AGENTS.md §2.1 required ≥ 7 consecutive OK nightly runs before retiring the 2026-08-12 manual `vzdump-qemu-100-2026_08_12-23_26_27.vma.zst`. **Met: 10 of 7 as of 2026-11-01** (epochs re-read from the node task list, not counted from directory names). The file was NOT deleted — that is a separate §0.3 change record |

**Still open — the table above is NOT "3-2-1 met"**

- **No off-site leg.** `proxmox-backup-manager remote list` on pbs01 → empty (verified 2026-10-31);
  the `pbs-jol01` sync has been pending since 2026-08-01. A site event still takes hv01 and its
  backup custodian together. Backup traffic rides the management VLAN because VLAN 85 `nic2` is
  uncabled (open decision D6).
- **GC unscheduled**: `proxmox-backup-manager garbage-collection list` → `schedule`, `next-run` and
  `last-run-state` all empty, `pending-bytes 0 B` (open since 2026-10-23). Prune deletes metadata;
  space is only reclaimed by GC, so the ~3.5 % figure does not self-correct.
- **Alert transport (mail) is dead** (§Security Controls): `mailnotification failure` reaches nobody,
  so the watchdog gates are the real detection layer, not this job's notification setting. Both
  CRITICALs re-raised on every run today (`3 outward message(s)` + `never verified end-to-end`).

- **F-3 — `cipassword:` on the admin plane: replication stopped 2026-10-31T22:03Z, rotation still
  the operator's step (issue #128).** `hv01-config-backup.sh` now builds the weekly archive through a
  staging copy in which every `^cipassword:` line is replaced by a marker, and **refuses to publish**
  if any un-stripped value survives or if the gate finds 0 `qemu-server` members (measured before:
  3 confs / 9 values travelling; after: 3 confs / 9 markers / 0 values; fail-closed copy: rc=1, no
  archive). That stops the *growth* of the exposure — the hash is still present in
  `/etc/pve/qemu-server/10*.conf` and in the archives already pushed to pbs01, which age out only
  with retention. PVE masks the field to `**********` on the API, so the surface is pmxcfs reads and
  archives, not the Web UI. **Rotation (Option A of #128) is now one command and still the operator's
  to type:** `ssh -t pve 'sudo jol-rotate-cipassword.sh 100 101 102'` — it snapshots each VMID first
  (§0.3; a PVE snapshot carries the VM *config* too, which is why a `.conf` holds inline `[snapshot]`
  sections), reads the new value with `read -rs`, applies it, proves the change by comparing
  **truncated sha-256 digests of the line** (never the value), then re-runs the archive gate. It
  **refuses to run without a TTY**, so no automation agent can complete a credential rotation —
  verified: the installed helper (`/usr/local/bin/jol-rotate-cipassword.sh`, sha `6e322a7bf27d…` ==
  repo, `750 root:root`) exited 1 on a no-TTY call having created **0** snapshots and changed nothing.
  Two things stated rather than smoothed over: the value is transiently in `argv` for root on this host
  during `qm set` (PVE 9 offers no alternative — `/usr/share/perl5/PVE/CLIHandler.pm` contains no
  interactive-prompt mechanism, `grep -c prompt` → 0; and my earlier claim that *"`qm set --help` does
  not list `cipassword`"* is **withdrawn**, because `qm set --help` is not a PVE 9 verb at all — it
  answers `Unknown option: help`, so it proved nothing), and a root-writable script that prompts for a
  secret is itself a tamper target, mitigated by `750 root:root` plus the §3d digest pair rather than
  claimed away. **No provisioning path in this repo sets `cipassword`** (measured 2026-11-01:
  `scripts/provisioning/prox01-create-vm20{5,7}*.sh` create VMs with `--sshkeys` and never a
  password; grep over `ansible/`/`terraform/`/`scripts/`/`inventory/` finds the field only in
  `hv01-config-backup.sh`), so the only custody store for the value is Vaultwarden and rotation does
  not strand any code path here.
- **F-3 close-out criteria corrected + four control defects found while reviewing them
  (2026-11-01T16:13Z, repo-side follow-ups to issue #128; see the CHANGELOG row).** ⚠ **ID note:**
  this batch is numbered **F-14…F-20**. A concurrent session on 2026-11-01 had already assigned
  F-8/F-9/F-10 to the offline-fsck thread (issue #137), so the first drafts of this page collided with
  it; this batch moved to a free block instead of redefining someone else's finding. Where a record
  cites `F-8`, `F-9` or `F-10` it means the fsck thread — two writers, one audit trail, and an
  ambiguous finding ID is a broken reference. What was wrong
  with what I had told the operator to look for, and what is now fixed in the repo:
  * **Count expectation was wrong (F-17).** "9" is the 2026-10-31 measurement, not a target: a `.conf`
    carries one `cipassword:` line per live stanza **plus one per `[snapshot]` stanza** (vm100 3 = 1+2,
    vm101 4 = 1+3, vm102 2 = 1+1). The helper snapshots before `qm set`, so each VMID gains a stanza
    holding the OLD hash → **12 at the rotation run, not 9**. A 12 therefore proves the snapshots
    were taken; a 9 after rotation would prove they were not. Stated in the script header now.
  * **The pass criteria were not greppable (F-17).** There is no `values=0` field in the cron/OK row —
    "0 values" was only ever proven by *absence* (a surviving value makes the script refuse to
    publish and print no OK row at all). The OK line now prints the measurement instead of leaving
    the operator to grep a field that never existed:
    `qemu_confs=N cipassword_lines_stripped=N cipassword_markers=N cipassword_values_unstripped=0`.
    Pass = exactly one OK row, `qemu_confs=3`, `cipassword_markers=12`, `cipassword_values_unstripped=0`,
    zero `ERROR:` rows.
  * **The rotation helper's own archive check could report success on a non-measurement (F-16).**
    `values-unstripped=$(tar xzOf "$A" …)` and `key-entries=$(tar tzf "$A" …)` both print **0** when
    `$A` is empty — measured: `archive=none values-unstripped=0 key-entries=0`, `tar` rc=2 — while the
    line underneath said "0 and 0 is the pass condition". So the one human-watched gate in a credential
    rotation was satisfiable by the absence of an archive. The block now refuses (`VERIFY INCONCLUSIVE`,
    `fail=1`) unless the archive is present, non-empty and contains at least one `qemu-server` conf, and
    a missing `hv01-config-backup.sh` is a failure rather than a note.
  * **Monitoring could not see F-3 at all (F-18).** Watchdog gate 11 screened config archives by NAME
    (`etc/pve/priv|\.key$|\.pem$`), and `cipassword:` is a FIELD inside a conf body — the 2026-10-25
    archive passed that gate while carrying 9 hashes. Gate 11 now reads the content of the newest
    archive and alerts on an unsanitised value, and it proves its own reach: an archive exposing no
    `qemu-server` conf is reported **UNVERIFIED, not clean** (the pbs01 gate-3 class).
  * **Both patterns were indentation-blind (F-20, found by writing the fixture).** Strip, publish gate,
    gate 11 and the helper counters anchored to `^cipassword:`. PVE writes those options at column 0
    (measured: all 9 matched), so nothing leaked — but if a section's options were ever indented, the
    value would travel *and* every gate would still report zero survivors. All four now accept leading
    whitespace; the fixture keeps an indented snapshot line as a permanent control.
  * **The proofs were not in the repository (F-15).** `.staging/` is gitignored (`.gitignore:96`), and the
    F-3 gate test plus both drill harnesses lived only there — so the red/green runs cited in the
    change record were unrecoverable from the repo an auditor reads. Committed now as
    `scripts/maintenance/tests/test-hv01-config-backup-f3.sh` (18 assertions),
    `test-pve-rotate-verify.sh` (15) and `test-hv01-gate11.sh` (11), all runnable off-host via two
    test hooks (`SRC_PATHS`, `JOL_ROTATE_VERIFY_DIR`) and wired into `make test-gates` + the CI job.
  * **What rotation still does NOT remove:** the old hash stays in the live conf's `[snapshot]` stanzas
    and in `/root/prechange-*-cipassword/*.conf.before`. Expiring those snapshots is the second half of
    F-3 and is its own §0.3 change; `qm rollback` restores the OLD password into the live stanza, which
    invalidates the new Vaultwarden value until console login is re-tested. Both are now printed by the
    helper at the end of a successful run, so they cannot be lost in the scrollback.
- **Still open (unchanged)**: GC's first real run is 2026-11-07 (reclaim proof owed), no off-site
  remote sync, mail alert transport dead, no node_exporter/netdata on this host. Restore coverage is
  now complete for the estate: vm/100 ✅ 2026-10-31T21:58Z, vm/101 ✅ 2026-10-31T22:41Z,
  vm/102 ✅ 2026-10-22, and the negative-encryption gate passed for the first time on 2026-11-01
  (issue #135, evidence §10).

**Fixed 2026-10-31T21:05Z — issue [#124](https://github.com/journeyoflife-org/jol-infrastructure/issues/124)**

- **F-2 — alert-evidence mirror restored.** The guard was
  `findmnt -n -o SOURCE "$ARCHIVE_HEALTH"` with `ARCHIVE_HEALTH=/mnt/hdd-archive/health`. `findmnt`
  resolves mount **points**, and that path is a subdirectory of the `/mnt/hdd-archive` mount, so it was
  false on every run since install: the mirror held 420 lines frozen at 2026-10-21 while
  `/var/log/jol-hv01/ALERTS.log` had grown to 718. ⚠ **The tempting fix `findmnt -T` is withdrawn and
  deliberately NOT used**: `-T` resolves any path to its containing mount **including `/`**, so with the
  evidence disk unmounted the guard would PASS and alerts would land on the root filesystem — the exact
  2026-10-21 failure class the guard exists to prevent. Applied instead: **device identity** — write only
  when `stat -c '%d' "$ARCHIVE_HEALTH"` differs from `ROOT_DEV`, otherwise log
  `alert mirror SUPPRESSED … refusing to write alerts onto /` (never `alert()` from inside `alert()` —
  that self-recurses). `ROOT_DEV` moved to the config block because the script is `set -u` and `alert()`
  can run before gate 0. Measured: `/` = 64513; `/mnt/hdd-archive` and `/mnt/hdd-archive/health` = 2050.
  **Positive test**: one run moved the mirror 420 → 422 lines (delta = the 2 real CRITICALs), mirror mtime
  `2026-10-31 23:05:27`. **Negative test**: a temp copy with `ARCHIVE_HEALTH=/var/tmp/negtest/health`
  (device 64513 = root) created **0 files** in the target and logged the suppression reason; run rc
  unchanged (`rc=1` while alerts exist, by design).
- **F-4 — host/repo drift, found by the pre-change sha comparison rather than by design.** Installed
  `/usr/local/bin/jol-health-check.sh` was sha `459de970…` (340 lines) while the repo copy was
  `e6aaba55…` (382 lines): the gate-13 alert-transport rewrite committed 2026-10-24/25 had **never been
  installed**. Independent live proof: before this change the CRITICAL read
  `19 message(s) bounced/deferred`, after it reads `3 outward message(s) bounced/deferred in the last 24 h
  (19 delivery records, retries collapsed)` — 19 records are **3** stuck mails, so the stale host text
  inflated the triage signal 6×. Deployed copy is now sha `ec3709c9…`, byte-identical to the repo, mode
  `750 root:root`, `bash -n` clean. Root cause is the MCP-M3 class (manual install, no reconciliation
  gate) — follow-up: assert repo-sha == host-sha in the runbook's install step.
- Prechange state: `/root/prechange-20261031-230501/jol-health-check.sh.bak` (sha `459de970…`) and
  `ALERTS.log.mirror.bak` (sha `5c3641dc…`). Test artifacts left on the host (volatile `/tmp`, no
  secrets): `/tmp/hc-neg.sh`, `/tmp/hcneg.out`, `/tmp/hc-run.out`, empty `/var/tmp/negtest/health`.

**Target state (design)** — RPO 24 h | RTO 4 h; VM backups `vzdump` → pbs01 `pbs-store` ns `jol-hv01`
(today one 02:00 job for all three VMIDs instead of the designed 02:00/02:15/02:30 stagger — acceptable
at 25–91 s per VM, re-split if the estate grows); host evidence pushed nightly at 03:45 local by
`scripts/maintenance/hv01-archive-to-pbs.sh`.

**History — what was wrong on 2026-10-21** (evidence
`docs/compliance/evidence/hv01-storage-inspection-20261021.txt`): no PBS datastore on this host, one
hand-written `job-vm100-nightly` section whose option lines lacked the mandatory leading TAB (the parser
dropped every option → `missing value for required option 'schedule'` → it had never run), a single manual
14 GB dump stored on the **same NVMe** as the VM it protected, and VMIDs 101/102 never dumped. Kept here
because it is the reason watchdog gates 9/10 (jobs.cfg-vs-scheduler agreement, last-`vzdump` outcome) exist.

## Audit Checklist — Storage and Backup (run before declaring this host operational)

> Run as root on pve-prod-hv01. Never put the PBS token on a command line. Q: is
> there a backup? A: only if the target is a different device AND a restore worked.
>
> **Status 2026-10-31 (read-only re-verification, `docs/compliance/evidence/hv01-backup-baseline-20261031.txt`)**:
> PASS — PBS datastore, job registered, job schedule valid, job covers 100/101/102, next-run armed,
> backups land (7 groups per VMID, all inside 26 h), evidence replicated, retention (`pbs-store-prune`),
> datastore usage < 80 % (measured on pbs01: ~3.5 %), VM data untouched (all `scsi0` on `local-lvm`; the
> repeated `scsi0:` lines are PVE inline snapshot sections, not duplicate options), mounts real, evidence
> fresh, NTP Normal. ✅ vm/100 restore-drilled 2026-10-31T21:58Z (issue #131) and GC is now
> **scheduled** (issue #126, first run 2026-11-07 04:30) — scheduled ≠ proven: the reclaim evidence
> (`last-run-state OK`, `removed-bytes` non-zero) is owed on 2026-11-07. ⚠ NOT verified — the
> restore-without-key negative test ✅ 2026-10-31T22:41Z and a vm/101 drill ✅ the same window
> (issue #135, evidence §10) — leaving only the `pbs01.pw`/`enc` permission pair not re-read this
> session (secret material, location-only).

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
                        ✅ PASSED 2026-10-31T22:41Z (issue #135): `/etc/pve/priv/storage/pbs01.enc`
                        moved aside (copy kept at 600 in the prechange dir), identical qmrestore
                        refused with rc=255 `encryption configured ('47:d6:12:27:…') but no
                        encryption key file found!` — refused at config extraction, before any
                        write. Method note so nobody repeats my ambiguity: this proves the key is
                        MANDATORY; it is not a wrong-key test. Key restored and re-proven by a
                        second successful restore at 22:42:27Z (rc=0), then cmp-equivalent stat
                        (600 root:www-data 255) and `pvesm status` → active.
□ Restore drill:        qmrestore of VMID 100 to scratch VMID 199 (NIC detached),
                        boot, service check, destroy 199 — logged in
                        docs/compliance/evidence/restore-test-<vmid>-<date>.log
                        ✅ vm/100 PASSED 2026-10-31T21:58Z (issue #131, evidence §9a: 107 GB in
                        137.8 s @743 MB/s, agent 80 s, destroyed clean, 4 min 48 s end-to-end);
                        ✅ vm/102 2026-10-22; ✅ vm/101 2026-10-31T22:41Z (issue #135 — 53.7 GB in
                        10.3 s @4.97 GB/s, 91 % zeroes, hostname proven `mcp-prod-lt01` via guest
                        exec, 0 LV residue)
□ Credential fields in  tar xzOf <archive> --wildcards '*/qemu-server/*.conf' \
   the config archive      | grep -cE '^[[:space:]]*cipassword: [^<]'        → 0 (F-3 gate,
                        enforced by the script itself since 2026-11-01: non-zero ⇒ refuse publish;
                        leading whitespace accepted since the same day, finding F-20). Read the
                        counters, do not infer them: the OK line prints
                        `qemu_confs=… cipassword_markers=… cipassword_values_unstripped=0`.
                        Independently watched since 2026-11-01 by watchdog gate 11 (F-18), which
                        also CRITICALs when the archive exposes no conf to inspect.
□ Offline fs check of a
   restored image      e2fsck -fn on loop-mapped partitions of the scratch VM (no `kpartx` on
                       this host → `losetup -f --show -P`), image never booted, `-n` so nothing is
                       repaired. ✅ **ALL THREE VMIDs + their ESPs 2026-11-01T16:06-16:11Z** (issue
                       #137, evidence §12) via `jol-offline-fsck-drill.sh` (repo == host, sha
                       `6dbc6d8a167a7705…`): vm/100 `p1` rc=4 (37 orphan inodes), vm/101 `p1` rc=4
                       (38), vm/102 `p1` rc=4 (35), each with 1 zero-dtime inode + negative
                       block/inode bitmap differences, superblock `state: clean`, 0 severe markers;
                       `p16` (/boot) rc=0 clean on all three; `p14` (BIOS boot) skipped-with-reason;
                       `p15` (ESP, vfat) **rc=1 on all three** — FAT dirty bit set + boot-sector vs
                       backup difference at offset 65 (the earlier "`fsck.vfat` absent, so unchecked
                       by design" sentence was FALSE and is withdrawn; the dirty bit is the finding it
                       hid, accepted as non-severe because the restored copies boot). vzdump logged
                       2 freeze + 2 thaw → quiesced copy with pending deletion work, cleared at mount.
                       Accepted as named residuals, NOT retitled clean; run exit 1 = CHECKED-WITH-RESIDUAL.
                       Teardown must be verified by post-state (run 1 of the old harness leaked a loop
                       mapping and an orphan 50 GB LV because `losetup -lx` is invalid here and
                       `qm destroy --purge` left the LV, pool 5.93 % → 6.47 %): all §12 runs verified
                       `conf_absent=yes lv_count=0 loop_count=0`, pool 5.94 % → 5.94 %.
□ VM data untouched:    grep -h '^scsi0' /etc/pve/qemu-server/*.conf → all local-lvm
```

## Maintenance Notes

- Kernel updates require reboot — schedule with maintenance window
- PVE package updates via no-subscription repository
- All changes tracked via ticket and recorded in change log

## Risk Acceptance

| Risk | Mitigation |
|------|-----------|
| No ECC RAM | nightly backups + PBS checksums (✅ backup path itself proven live 2026-10-22, 9 OK nightlies by 2026-10-31; residual risk is the missing off-site leg) |
| No IPMI/OOB | Physical access documented; netdata alerts — ⚠ netdata is not installed, so this mitigation is currently void; physical access is also what makes a bad firewall change expensive |
| Dual NIC (nic0 spare) | nic1 active on VLAN 60; nic0 available for failover/iSCSI |
| Single PSU | UPS; documented acceptance |
| HDD is consumer 5400 rpm, 2482 power cycles, `brokenfpdmaaa nolpm` quirks | holds no VM data and no backup role; evidence on it is replicated to pbs01 (live since 2026-10-25); `nofail` so its death cannot block boot. F-2 (the dead `ALERTS.log` mirror onto it) **fixed 2026-10-31**, and the replacement guard now *refuses* to write if the disk is unmounted instead of silently falling back to `/` |
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
| 2026-10-22 | **Backup Enabled flipped from NO to live**: `pbs01` datastore activated (token rotated and installed through the no-print pipeline, `priv/storage/pbs01.pw` 600), namespace `jol-hv01` pre-created on pbs01 (`install -d -o backup -g backup -m 750` — the "auto-created on first backup" claim was falsified), `DatastorePowerUser` granted to user **and** token, the malformed `job-vm100-nightly` section removed, and API-created job `hv01-nightly-pbs` registered. First manual `vzdump` OK for VMIDs 100/101/102; restore drill PASSED on vm/102 → scratch VMID 199 → destroyed clean | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §16–§17; `docs/compliance/evidence/incident-20261022-pbs-token-secret-exposure.md` |
| 2026-10-25 | Phase-7 host-evidence push went live: `/etc/cron.d/jol-hv01-archive` (`45 3 * * *` → `hv01-archive-to-pbs.sh`). First archive `host/pve-prod-hv01/2026-10-25T00:45:01Z`; every night through 2026-10-31 present and `completed OK` | `/var/log/jol-hv01/archive-pbs.log`; `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` §4 |
| 2026-10-31 | **Backup baseline re-verified read-only; every "no backup exists" statement on this page and on rag/mcp/her corrected to the live state.** 9 consecutive scheduled OK nightlies; 7 groups per VMID on pbs01; RPO 24 h met (newest 20.6 h). New findings raised, NOT remediated: **F-2** the watchdog's HDD `ALERTS.log` mirror is dead since 2026-10-21 (`findmnt` given a subdirectory instead of the mountpoint — `scripts/maintenance/hv01-health-check.sh:73`); **F-3** `/etc/pve/qemu-server/10*.conf` carry a `cipassword:` sha256crypt hash of the cloud-init user password on the admin plane, which the weekly `/etc/pve` tarball exclusion rule (keys/`priv`) does not cover. Still open: GC unscheduled, no off-site remote sync, mail transport dead, no node_exporter/netdata | `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` |
| 2026-10-31T21:05Z | **PRODUCTION CHANGE (issue #124) — F-2 alert-evidence mirror repaired + F-4 host/repo drift closed.** `findmnt` mount-point guard replaced by a **device-identity** guard (`stat -c '%d'` vs `ROOT_DEV`, `ROOT_DEV` moved into the config block for `set -u` safety), with suppression logged instead of silent skip; the `findmnt -T` recommendation from the 20:45Z entry is **withdrawn** because `-T` resolves to `/` when the disk is unmounted and would have re-opened the 2026-10-21 write-onto-root failure class. Deployed `pve:/usr/local/bin/jol-health-check.sh` sha `459de970…`(340 lines, stale, gate-13 rewrite never installed) → `ec3709c9…` == repo (382 lines), mode 750 root:root. **Positive test**: mirror 420 → 422 lines (delta = 2 real CRITICALs), mtime today. **Negative test**: target forced onto the root device (64513) → **0 files written** + `alert mirror SUPPRESSED … refusing to write alerts onto /`. **Gate-13 proof of reconciliation**: alert text changed from `19 message(s)` to `3 outward message(s) … (19 delivery records, retries collapsed)`. `bash -n` clean, repo-wide `shellcheck` rc=0. Rollback: restore `/root/prechange-20261031-230501/jol-health-check.sh.bak`. Also corrected on this page: the "15 min timer on hv01" wording — the 15-min cadence is the **workstation** `jol-fleet-health.timer` pulling over SSH; hv01's own schedule is `0 6 * * *` (measured: no hv01-side timer). No storage/ACL/firewall/`/etc/pve` change; no secret read or printed | issue #124; `/root/prechange-20261031-230501/`; `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` §8 |
| 2026-10-31T22:20Z | **F-3 made finishable by one operator command, and two of my own claims corrected (issue #128).** Installed `pve:/usr/local/bin/jol-rotate-cipassword.sh` (repo `scripts/maintenance/pve-rotate-cipassword.sh`, sha `6e322a7bf27d…` == repo, `750 root:root`, `bash -n` OK, tree-wide `shellcheck` rc=0 after one SC2012 fix): §0.3 snapshot per VMID → `read -rs` (hidden) → `qm set --cipassword` → change proven by comparing **truncated digests of the line**, never the value → re-runs `hv01-config-backup.sh` into a temp `DEST_DIR` to prove the archive gate still holds → prints the console-proof step and the rollback order. **The script refuses to run without a TTY** (`[[ ! -t 0 ]] → exit 1`), which turns "operator-only" from an instruction into a mechanism: measured, a no-TTY invocation refused with **0** snapshots created and no prechange dir left behind, and the usage/validation paths (`no args`, `VMID 999 has no config`) both exit correctly. **Claims corrected:** (1) I had written that `qm set --help` lists no `cipassword`; that is **withdrawn** — `qm set --help` is not a PVE 9 verb (`Unknown option: help`, 72 bytes of output), so my `grep -c` → 0 measured nothing; (2) the real finding behind it stands — PVE 9's CLIHandler has no interactive-prompt mechanism (`grep -c prompt /usr/share/perl5/PVE/CLIHandler.pm` → 0), therefore `qm set` must receive the value as an argument and the transient `argv` exposure to root-on-this-host is stated as an accepted residual, not hidden; (3) a root-writable helper that prompts for a secret is itself a tamper target — mitigated by mode `750 root:root` and the §3d digest pair, not claimed away. **State of the finding:** replication stopped (archive sanitised, fail-closed), rotation **not yet performed** (measured: conf mtimes still 2026-10-31 02:00, `pre-f3` snapshot count 0 on all three VMIDs, digests unchanged) → #128 stays OPEN until the operator runs the command and proves console login | `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` §9c; issue #128; refusal test transcript 2026-10-31T22:19Z |
| 2026-11-01 16:13Z | **REPO-ONLY (no host touched) — five control defects found in the F-3 close-out material itself, and fixed (follow-ups to issue #128).** Judgement applied to what I had told the operator to verify: (1) **F-17** the "expect 9" figure is a 2026-10-31 *measurement*, not a target — one `cipassword:` line per live stanza plus one per `[snapshot]` stanza (3+4+2 = 9), and because the helper snapshots before `qm set`, the rotation run must show **12**; (2) **F-17** there is no `values=0` field to grep — the OK row printed `mode/size/entries/qemu_confs/cipassword_lines_stripped` only, so the "0 values" claim was provable by absence alone; the OK line now prints `cipassword_markers=` and `cipassword_values_unstripped=` measured on the published archive; (3) **F-16** the rotation helper's own archive check read `archive=none values-unstripped=0 key-entries=0` when no archive existed (both `tar` calls fail against an empty path, `grep -c` prints 0) under a line saying "0 and 0 is the pass condition" — a human-watched security gate satisfiable by a non-measurement; it now refuses unless the archive is present, non-empty and holds ≥1 `qemu-server` conf, and a missing `hv01-config-backup.sh` sets `fail=1`; (4) **F-18** watchdog gate 11 screened archives by NAME (`etc/pve/priv\|\.key$\|\.pem$`) and so could not see F-3 at all — the 2026-10-25 archive passed it while carrying 9 hashes; gate 11 now reads the conf CONTENT and CRITICALs on an unsanitised value, and reports **UNVERIFIED** (not clean) when the archive exposes no conf; (5) **F-20**, found while writing the fixtures: strip, publish gate, gate 11 and the helper counters all anchored to `^cipassword:`, so an indented option line would leak while every gate still reported zero survivors — PVE writes column 0 (measured), so nothing leaked, but all four patterns now accept leading whitespace. **F-15:** the proofs were stranded in gitignored `.staging/`; committed as `scripts/maintenance/tests/test-hv01-config-backup-f3.sh` (18 assertions, green 18/0), `test-pve-rotate-verify.sh` (15, green 15/0 / red 2-of-13 against `main`'s helper) and `test-hv01-gate11.sh` (11, green 11/0 / red 7-of-11 against `main`'s watchdog), driven off-host through two narrow test hooks (`SRC_PATHS`, `JOL_ROTATE_VERIFY_DIR`) and wired into `make test-gates`. My own harness defects found by running them, and fixed: a fixture that passed a mktemp-absolute path into `tar` (the stored layout then did not match the script's lookup, so 12 assertions failed against the *correct* script), a `$(...)` that could not see stderr-only failure lines, and fabricated PEM text in a fixture that would have tripped the repo's own `detect-private-key` hook. **Still operator-only:** the rotation itself, `qm terminal 100` console proof, expiring the pre-change snapshots that keep the old hash, and now printing the residual at close-out. No host, credential, schedule or `/etc/pve` change; `bash -n` clean, tree-wide `shellcheck` rc=0, `yamllint` rc=0, `make lint-changelog` rc=0, `make test-gates` rc=0 | this page §F-3 bullets; `scripts/maintenance/tests/` fixture runs 2026-11-01T16:0x–16:1xZ; `CHANGELOG.md` 2026-11-01T16:13:08Z row |
| 2026-10-31 23:04Z | **The owed offline `e2fsck` leg of the restore drill was executed on VMID 101's restored image (issue #137), and it reported a residual rather than a clean bill.** Method: restore `vm/101/2026-10-31T00:00:10Z` to scratch VMID 199 **without booting**, map partitions with `losetup -f --show -P` (this host has no `kpartx`), then `e2fsck -fn` (never `-y`: nothing on a scratch copy is repaired during a proof exercise). `/boot` (p16) **rc=0 clean**; `/` (p1, 49 G ext4) **rc=4** — 24 inodes on the corrupted orphan list, one deleted inode with zero dtime, negative block/inode bitmap differences, superblock `Filesystem state: clean`, and **zero** hits for the severe classes (UNEXPECTED INCONSISTENCY, "is corrupted", Missing offset, Wrong blocks count, group-descriptor failures). vzdump's task log carries 2 `freeze` + 2 `thaw`, so the image is a quiesced copy holding pending-deletion bookkeeping that ext4 resolves at mount — corroborated by all three restored copies having booted with the agent answering. Recorded as an **accepted, named residual**; not laundered into "clean", and the EFI partition is unchecked because `fsck.vfat` is absent. **Run 1 of my harness leaked a loop mapping and an orphan 50 GB thin LV (pool 5.93 % → 6.47 %)** — `losetup -lx` is not a valid option on this util-linux and `qm destroy --purge` finished "with 1 warning" leaving the LV behind; run 2 detached/cleared it, re-asserted the preconditions the 2026-10-22 attempt had silently skipped (`readlink -f /dev/pve/vm-199-disk-0` must be a block device; the VG is `pve`, not `local-lvm`), captured the full 75-line output, and verified teardown by post-state: `conf_absent=yes`, `lv_count=0`, `loop_count=0`, pool back to 5.93 %, VMs 100/101/102 running throughout. **Owed:** the same offline leg for vm/100 and vm/102. **[SUPERSEDED by the 2026-11-01T16:1xZ row below: all three legs ran, and "`fsck.vfat` is absent so the EFI partition is unchecked by design" was false.]** Rollback: none — scratch destroyed, no production disk was ever opened | `docs/compliance/evidence/hv01-backup-baseline-20261031.txt` §11; issue #137; host `/tmp/jol-e2fsck-full.txt` (75 lines, no secrets) |
| 2026-11-01 16:11Z | **The offline filesystem leg is now complete for all three VMIDs — and completing it required withdrawing a sentence of my own that had been closing the gate.** (1) **The false claim:** §6/§11 recorded "`fsck.vfat` absent on hv01", so the ESP was "unchecked by design". Measured: `/usr/sbin/fsck.vfat`, dosfstools 4.2-1.2, file mtime 2025-02-25 — it has been on this host longer than the fleet existed. Nothing was by design; the leg had simply never been run, and the false sentence was why it would not have been. How I produced the error: I probed for the tools I had already named (`e2fsck`, `dumpe2fs`, `blkid`, `fdisk`) and wrote down a different package's binary as absent without probing for it. (2) **The finding it hid:** with the ESP actually checked, `fsck.vfat -n` returns **rc=1 on all three VMIDs** — "Dirty bit is set. Fs was not properly unmounted" plus a boot-sector/backup difference at offset 65. Read against the mechanism rather than spun: FAT has no journal, so the guest-agent freeze that quiesces ext4 leaves the ESP's dirty marker in the image; the restored copies boot (three drills, agent answering, hostname proven), and clearing the bit would be a **repair**, which a proof exercise must not perform. LOW, accepted and named. (3) **The legs** (new script, scratch VMID 199, never booted): vm/100 `2026-11-01T00:00:01Z` 107 GB in 138.2 s @741 MB/s → `p1` rc=4 (37 orphans + 1 zero-dtime, bitmaps negative, `state: clean`, 299713/12976128 files), `p15` rc=1, `p16` rc=0; vm/101 `...T00:00:04Z` 53.7 GB in 10.6 s → `p1` rc=4 (38 orphans), `p15` rc=1, `p16` rc=0; vm/102 `...T00:00:07Z` 53.7 GB in 9.4 s → `p1` rc=4 (35 orphans), `p15` rc=1, `p16` rc=0. Severe markers 0 everywhere; `p14` (BIOS boot, no fs type) skipped-with-reason. Exit 1 = CHECKED-WITH-RESIDUAL by design. Teardown verified by post-state on every run: `conf_absent=yes`, `lv_count=0`, `loop_count=0` vs baseline 0, thin pool 5.94 % → 5.94 %, VMs 100/101/102 running. (4) **Three more defects in my own harness**, including two that would have laundered a finding — recorded in evidence §12e; the worst is that `[[ $fstype =~ ^fat ]]` does not match `vfat`, so the ESP finding was decoded by the e2fsck classifier and never reached the exit code. (5) **Durable:** `scripts/maintenance/hv01-offline-fsck-drill.sh` installed as `pve:/usr/local/bin/jol-offline-fsck-drill.sh` (sha `6dbc6d8a167a7705…` == repo, `750 root:root`, `bash -n` OK, tree-wide `shellcheck -x` rc=0, `--self-test` 11/11 with a fixture proven RED, `DRY_RUN=1` default verified to mutate nothing). Rollback: `rm /usr/local/bin/jol-offline-fsck-drill.sh` — additive, cronless, no schedule change | evidence §12; issue #137; host logs `/var/log/jol-hv01/offline-fsck-20261101-{180639,180616,181120}.log` (named in HOST LOCAL time = 16:06:39/16:06:16/16:11:20Z) |
