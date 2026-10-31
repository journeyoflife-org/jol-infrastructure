# Runbook: pve-prod-hv01 — NVMe / 1 TB HDD / pbs01 Storage & Backup Reconfiguration

> **Status**: **PHASES 1–3 AND 8 EXECUTED 2026-10-21** (host baseline + filesystem
> integrity + truthful watchdog). **PHASES 4–7 PENDING — they require the operator
> in person**, because they need the PBS token secret (see §3.4–3.6 and the secret
> custody rule below). **Date**: 2026-10-21. **Operator**: jol-admin (solo, four-eyes
> against the GitHub issue per §0.3).
> **Compliance**: GDPR Art. 5(1)(f) + Art. 32(1)(b)(c) (availability/resilience,
> restore testing) / ISO 27001:2022 A.8.13 (backup), A.8.14 (redundancy),
> A.5.31/A.5.33 (audit evidence, protection of records) / SOC 2 CC6.5, CC7.2,
> CC8.1, A1.2.
> **Ground truth sources**: live session on pve-prod-hv01 (10.60.60.20) and the
> evidence lines quoted in §1 below. `docs/servers/pve-prod-hv01.md` claims were
> **not** usable as evidence (see §5).
> **No credentials in this document** — token secrets stay in Vaultwarden and
> on-host at `600 root:root` (fleet pattern, `docs/architecture/secret-flow.md`).

## 1. Verified current state (2026-10-21)

| Probe | Output | Conclusion |
|-------|--------|------------|
| `lsscsi`, `lsblk -o TRAN` | `[3:0:0:0] ATA ST1000LM024 HN-M101MBB /dev/sda` (sata, ata4) + `ADATA LEGEND 800 /dev/nvme0n1` 1.8 T | 1 TB HDD reconnected on an **internal SATA port**, not USB |
| `smartctl -i` | `Rotation Rate: 5400 rpm`, `Form Factor: 2.5 inches`, ATA-8, 8 MB cache class | consumer laptop-class drive, **not** a 24/7 backup duty rating |
| `smartctl -A / -H / -l error` | PASSED; reallocated 0, pending 0, uncorrectable 0, CRC 1; `Power_On_Hours 10378`, `Power_Cycle_Count 2482` | mechanically healthy; 2482 power cycles is the real wear driver |
| `dmesg` | `Buffer I/O error on dev sda2, lost sync page write`; `JBD2: I/O error when updating journal superblock for sda2-8`; `ata4: link is slow to respond`; `applying quirks: brokenfpdmaaa nolpm` | the 2026-10-21 removal was a **live unmount-while-mounted** event; journal had to be replayed at reconnection → fsck required before the data is trusted (§3 step 2) |
| `tune2fs -l sda1/sda2` | `Filesystem state: clean`; `Maximum mount count: -1`; `Check interval: 0 (<none>)`; `Last checked: 2026-04-22` | automatic fsck **disabled** on both partitions; ~6 months since last check |
| `findmnt` | `/dev/sda1 → /mnt/hdd-iso (rw,noatime)`, `/dev/sda2 → /mnt/hdd-archive (rw,noatime)` | `data=ordered` + barriers intact (correct — keep) |
| `/etc/fstab` | `UUID=… /mnt/hdd-iso ext4 defaults,noatime 0 2` (+ same for `hdd-archive`), **no `nofail`** | a dead/absent HDD stalls boot into emergency target → availability defect (HIGH) |
| `/etc/pve/storage.cfg` | `dir: hdd-iso`, `path /mnt/hdd-iso`, `content backup,vztmpl,iso` | `backup` content on the single-copy consumer drive = fake-backup vector |
| `pvesm status` during the unplug window (2026-10-21 ~13:06) | `hdd-iso active 93 GB free`; `stat` showed `/mnt/hdd-iso` device == `/`; PVE auto-created `dump/` + `template/` **on the NVMe root filesystem** | with the mount absent, PVE reports the storage as healthy and writes silently to `/` |
| `/etc/pve/jobs.cfg` + `pvesh get /cluster/backup` | section `vzdump job-vm100-nightly` present; parser: every option line reports `ignore config line: …` → `missing value for required option 'schedule'`; API returns `[]`; `PVE/Job/Registry.pm` uninitialized-value warnings. **Root cause proved with `cat -A /etc/pve/jobs.cfg`: the option lines start flush-left — PVE requires each continuation line to begin with a TAB**, so the whole section body was discarded (the `30 3 * * *` schedule itself is a valid PVE cron form). The file was hand-written without tabs. | **the nightly backup job has never run.** Registry-level failure, silent |
| `/var/lib/vz/dump/` | one file only: `vzdump-qemu-100-2026_08_12-23_26_27.vma.zst` (14 GB) + log + notes; nothing for 101/102 | the **only** existing backup artifact of the PRIMARY RAG VM, on the **same device as the VM itself** |
| `/mnt/hdd-iso/dump/` | empty since creation 2026-07-30 | the HDD has never held a VM backup — the "local backup disk" premise is false |
| `/mnt/hdd-iso/template/iso/` | `noble-server-cloudimg-amd64.img` (596 MB) | sole local copy of the provisioning media for VMIDs 100–102 |
| `/mnt/hdd-archive/config-backup/` | `pve-config-202609{20,27}, 202610{04,11,18}.tar.gz` (143 KB each, weekly Sun 03:00) | `/etc/pve`, `/etc/fstab`, `/etc/network/interfaces`, `/etc/lvm/lvm.conf`, ufw/chrony/fail2ban — **single copy, on the HDD** |
| `/mnt/hdd-archive/health/` | ~90 daily `*-health.log` files, newest 2026-10-21 06:00, plus `ALERTS.log` path | CC7.2 monitoring evidence — single copy, on the HDD |
| `/etc/cron.d/jol-config-backup`, `/etc/cron.d/jol-health` | write into `/mnt/hdd-archive`, tar job uses `… 2>/dev/null && find … -delete` | silent-failure by construction: while the HDD is absent these jobs fail with no alert, no exit code, no mail |
| `/etc/pve/qemu-server/*.conf` | `scsi0: local-lvm:vm-10x-disk-0`, `ide2: local-lvm:vm-10x-cloudinit` for 100/101/102 | **no VM data on the HDD** — disconnecting it never endangered VM disks |
| `pvs; vgs; parted /dev/nvme0n1 print free` | PV `nvme0n1p3` 930 G, `PFree 0`; `1000GB → 2000GB Free Space` (1001 GB unallocated) | thin pool is fully provisioned out of the PV; ~1 TB of the NVMe is raw headroom, **not** a backup target |
| TCP `10.10.10.30:8007` from hv01 | reachable (PBS API answers, unauthenticated `/version` → `authentication failed`) | transport path exists; pbs01 nftables already allows 8007 from `10.60.60.0/24` |
| `/etc/pve/priv/storage/`, `/etc/pve/storage.cfg` | directory absent; no `pbs` entry anywhere | **no PBS datastore is registered on pve-prod-hv01** — VM backups to pbs01 are not configured, contrary to the server doc |

⚠ UNVERIFIED — manual check required: the "separate power supply" for the HDD
(physical wiring is not observable from the OS). Note that an independent PSU
rail does **not** create a separate failure domain — the SATA link, controller,
host, board and single building UPS remain shared. The only genuinely separate
domain available today is pbs01.

### 1b. Monitoring control failure discovered while fixing this (HIGH)

The daily watchdog `/usr/local/bin/jol-health-check.sh` (invoked by
`/etc/cron.d/jol-health`, no `PATH=` line) had been producing **only false
positives since 2026-07-31** — 415 lines in `/mnt/hdd-archive/health/ALERTS.log`:
**249** × `VM 10x is  - attempting restart` and **166** × `SMART FAILURE on
/dev/… — replace immediately`, zero genuine alerts.

Root cause (reproduced, not inferred): cron's default `PATH` is `/usr/bin:/bin`.
`lvs`, `smartctl` and `qm` live in `/usr/sbin`, so every probe returned an empty
string, and the script's `[[ "$HEALTH" != "PASSED" ]]` / `[[ "$STATUS" != "running" ]]`
tests treated "command not found" as "drive failed / VM stopped". Verified by
running the original script under `env -i PATH=/usr/bin:/bin` — it emits exactly
the historic alert pattern. Consequences:

1. The "auto-restart a stopped VM" safety net **has never worked** (`qm` not found),
   so no availability behaviour is lost by removing it — a fact worth knowing before
   anyone relied on it.
2. A monitoring channel that screams five criticals every morning is indistinguishable
   from one that is dead. That is precisely why "Backup Enabled: yes" could rot for
   ten weeks: the one class of alert that mattered (no backup has run) was never
   implemented, and the noise made the file itself untrustworthy (SOC 2 CC7.2,
   ISO A.8.16; GDPR Art. 5(2) accountability).
3. Both drives SMART **PASSED** and all three VMs were running the whole time. The
   alarms were fiction in both directions — a real failure would have looked identical.

Fixed in `scripts/maintenance/hv01-health-check.sh` (installed to
`/usr/local/bin/jol-health-check.sh` 750 root:root, SHA256
`fdd1a5fa…32cece`; original preserved in the prechange dir; `PATH=` added to
`/etc/cron.d/jol-health` as defence in depth): explicit PATH, probe-availability
gate that reports "probe unavailable" instead of a fake failure, unknown/blank
statuses never mapped to FAILED, rasdaemon parsed by record block (memory vs
block-device) rather than `grep -c error` — the old MCE gate counted the tool's own
"No Memory errors." headings, so its "22 RAM errors" was also fiction — plus new
gates 0/9/10/11 for mount reality, scheduler-registration drift, last vzdump outcome
and config-evidence freshness.

Verified post-install under a cron-like environment: 3 alerts, all true —
`6 block-device I/O error record(s) today` (the hot-removal event, now detected
automatically), `Backup job drift: 1 section(s) in jobs.cfg but 0 registered`,
`No vzdump task in the cluster task log` — and exit code 1 so the run is not silent.
Negative test `VM_IDS=9999` correctly reports "status unreadable — not assuming
stopped" instead of the old false "is stopped, attempting restart".

### 1c. Further fabricated controls found while checking reachability (MEDIUM/HIGH)

These were surfaced by probing *how* steps (a)/(b) could be automated, and they
change the risk picture more than the disk does. None of them were changed in this
session — each needs its own change record.

| Control as documented | Live probe 2026-10-21 | Reality |
|-----------------------|-----------------------|---------|
| "Monitoring: yes (node-exporter, netdata)" + inventory `monitoring_enabled: true` | `systemctl list-unit-files` (no node_exporter or netdata unit), `dpkg -l` (neither package), `ls /usr/sbin/netdata /usr/bin/node_exporter` (absent), `ss -tlnp` on 9100/19999 (no listener) | **nothing installed, nothing listening.** The hypervisor carrying GDPR Art. 9 workloads has had no metrics pipeline at all |
| "UFW: default deny incoming, allow 22/tcp, 8006/tcp (mgmt only)" | `ufw status verbose` → `inactive`; `iptables -S` → `-P INPUT ACCEPT -P FORWARD ACCEPT` | **no host firewall.** Inbound safety rests entirely on VLAN segmentation + the MikroTik. Also: the documented rule set would **lock out the operator** — the live SSH session comes from `192.168.88.249` (this workstation via 192.168.88.1), which is in neither allowed mgmt subnet, and the board has no IPMI. Safe enablement requires: allow the real client source, `systemd-run --on-active=5min ufw disable` auto-rollback, console access first. Mitigating fact: `net.bridge.bridge-nf-call-iptables = 0`, so host filtering cannot drag bridged VM traffic into INPUT |
| `mailnotification failure` on backup jobs (and cron mail generally) | `mailq` → 6 deferred requests, oldest `delay=294616` (~3.4 d), reason `connect to …gmail-smtp-in.l.google.com:25: Connection timed out` / IPv6 `Network is unreachable`; `postconf` → `inet_interfaces = loopback-only`, `relayhost` empty; `/var/mail` empty | **no mail has ever been delivered.** Outbound :25 and :587 are blocked by the upstream network; :465 is reachable. Every failure-notification control in the fleet is therefore void, which is the second, independent reason the missing backup job stayed invisible |
| pbs01 reachable for admin | workstation → `10.10.10.30:22`/`:8007` CLOSED; **hv01 → `10.10.10.30:22` also filtered** (pbs01 nftables permits 22 from `10.10.10.0/24` only); hv01 → `:8007` open | step (a) cannot be done over SSH from hv01 either. Legitimate paths: the pbs01 physical/console session, or admin01 (currently unreachable from here — `ping 10.10.10.50` 100 % loss). An SSH tunnel via hv01 to pbs01:8007 *would* work technically but moves a backup-server admin plane onto an undocumented network segment (this workstation is on the router LAN `192.168.88.0/24`, not a mgmt VLAN) — rejected as a habitual path; acceptable only as a one-off with its own access record |
| Weekly `/etc/pve` config backup (SOC 2 CC8.1 evidence) | `tar tzf pve-config-20261018.tar.gz` → `etc/pve/priv/pve-root-ca.key`, `etc/pve/priv/authkey.key`, `etc/pve/pve-www.key`, `etc/pve/nodes/pve/pve-ssl.key`, `etc/pve/priv/authorized_keys`; archive mode **644** on the HDD | **HIGH — the config backup carried the cluster's private keys**, world-readable, and phase 7 would have replicated it off-host nightly. Fixed: `scripts/maintenance/hv01-config-backup.sh` excludes `priv`/`*.key`/`*.pem`/`*.srl`, forces mode 600, and **refuses to publish** if any key entry survives; cron rewritten with `PATH`/`SHELL` and no error suppression. New archive verified: 0 key entries, 9 useful config entries. Key material is now escrow-only (Vaultwarden), never backed up. Five pre-fix tarballs remain — deletion + a rotation decision are open (evidence §18) |

Conclusion for the incident narrative: the disk was the trigger, not the problem.
The controls that were supposed to notice a missing backup (monitoring, alerting,
mail) were each independently absent or broken, and all three were recorded as
working in documentation. Fix order should be backup job → truthful pull-based
detection (done) → notification transport (465 relay or PVE 9 notification target) →
node_exporter + scraper → host firewall with auto-rollback and console cover.

**Procedure-design lesson (learned the hard way, twice in one day):** an operator
runbook step must not depend on interactive stdin inside a pasted block. Two attempts
to capture the PBS token secret with `read -rs` stored pasted command text instead of
the secret (43 bytes, then 113 bytes with 34 stray characters — measured, never
printed), and each produced a misleading `authentication failed`. Both files were
truncated to 0 bytes rather than used. Rule adopted: where a form or API dialog can
capture the secret (PVE Add Storage → Password), prefer it — browsers do not have this
failure mode — and where a file is unavoidable (phase 7), use a newline-tolerant
`cat > file` + `tr -d '\n\r'` capture with a structural check before first use.

## 2. Target design (decision, with rationale)

| Tier | Media | Role | Retention | Copy count |
|------|-------|------|-----------|------------|
| Live | NVMe `ADATA LEGEND 800` 1.8 TB → VG `pve`: `pve-root` 96 G, `local-lvm` thin pool 810 G | host OS + all VM disks and cloud-init drives | — | 1 |
| Headroom | NVMe unallocated 1001 GB | capacity growth only. **Never** a backup target (same device ⇒ zero protection value) | — | — |
| Local cache | HDD `sda1` 400 G `/mnt/hdd-iso`, PVE `dir` storage `hdd-iso` with `content iso,vztmpl` | provisioning media + container templates | n/a | 1 local + optional nightly pxar to pbs01 |
| Local evidence | HDD `sda2` 531 G `/mnt/hdd-archive` | host config tarballs, health/monitoring logs, access/system archives | 30 d rolling on-disk | 1 local + **nightly pxar → pbs01** (authoritative) |
| Authoritative | pbs01 (HP P4500, 6-disk RAIDZ2, 3.27 TB, datastore `pbs-store`, namespace `jol-hv01`) | vzdump of VMIDs 100/101/102 (one job, VMs serially inside the 02:00 window) + host-evidence pxar at 03:45; dedup, client-side encryption, GC, verify, file-level restore | keep-daily=7, keep-weekly=4, keep-monthly=6 | 2 (3rd leg pending remote sync) |

Design rulings (paranoid reading, deliberately conservative):

1. **The HDD does not hold VM backups.** It has never held one, it is inside the
   same failure domain as the hypervisor, it is a 5400 rpm consumer drive with
   2482 power cycles, and it has no dedup/verify/restore tooling. Putting dumps
   there buys an illusion and costs the drive's only real payload (evidence).
2. **The HDD is still necessary** — for provisioning media and host evidence —
   which is exactly why it must stop being *single-copy*. Everything in
   `/mnt/hdd-archive` is compliance evidence and gets a nightly encrypted
   second copy on pbs01.
3. **Remove `backup` from `hdd-iso` content.** Two reasons: the fake-backup
   vector above, and the observed silent fallback to `/` when the mount is
   absent (PVE cannot tell a missing mount from an empty 93 GB datastore).
4. **`nofail` is mandatory** on both HDD mounts. A backup/evidence disk must
   never be able to prevent the hypervisor from booting with its VMs.
   Trade-off accepted: a dead HDD now degrades to "evidence backup missing +
   alert" instead of "RAG/MCP/Hermes offline".
5. **VM backups go to pbs01 only**, and the job must be **created through the API**
   (`pvesh create /cluster/backup`) rather than by editing `jobs.cfg`: the existing
   hand-written section lost every option because its continuation lines lacked the
   mandatory leading TAB, so the parser silently dropped them and the job never ran
   (a non-existent job cannot fail, so `mailnotification failure` produced nothing
   for 10 weeks). The API serialises the file correctly, and `pvesh get
   /cluster/backup` then agrees with `jobs.cfg` — the pair is the drift check now
   enforced by watchdog gate 9.
6. **Residual Art. 17 policy**: backups of VM 100 contain religious-affiliation
   (GDPR Art. 9) document data and are **not** rewritten; they age out at
   keep-monthly=6, with restore-replay of the erasure register mandated —
   same policy text as `docs/runbooks/jol-pilot-backup-plan.md` §3, now declared
   for the AI-service estate.
7. **Known open gaps this runbook does not close** (recorded, not hidden):
   (a) 3-2-1 "one off-site" leg is unmet — pbs01 remote sync (`pbs-jol01`) still
   pending since 2026-08-01; (b) backup traffic runs on the management VLAN
   because VLAN 85 nic2 is uncabled (open decision D6); (c) this host is not
   Ansible-managed (no `inventory/prod/host_vars/pve-prod-hv01.yml`), so drift
   detection is manual — same root-cause class as MCP finding M3.

## 3. Execution phases

Each phase is verify → mutate → verify again. Every mutation writes evidence to
`/var/log/jol-hv01-baseline.log` on the host and is summarised in
`docs/compliance/evidence/`. `DRY_RUN=1` is the default for both scripts.

1. **Pre-change control**: GitHub issue (rollback plan = §4), `qm snapshot` is
   not applicable to the host itself; the state being changed is captured by
   `tar` of `/etc/pve` + copies of `storage.cfg`, `jobs.cfg`, `fstab` to
   `/mnt/hdd-archive/system/prechange-<ts>/`.
2. **Filesystem integrity window** (~3 min, HDD only — no VM impact):
   `umount /mnt/hdd-iso /mnt/hdd-archive` → `e2fsck -fD` both → `tune2fs -c 30
   -i 180d` → remount → verify `Filesystem state: clean`, tarballs readable.
3. **Host config hardening**: `hv01-storage-baseline.sh` — fstab `nofail` +
   timeouts, `pvesm set hdd-iso --content iso,vztmpl`, evidence dirs, fsck
   policy, drift report.
4. **pbs01 side (operator)**: **first find out what is already granted — without a
   pbs01 shell.** pbs01 drops TCP 22 from every reachable host in this environment
   (verified at transport level: `exec 3<>/dev/tcp/10.10.10.30/22` → rc=124 timeout,
   no banner, while 8007 connects instantly), and its GUI must be entered as
   **`root` + Linux PAM** — `jol-admin` is not a PBS principal, so that login fails by
   design. ⚠ Do **not** retry passwords through the hv01 tunnel: pbs01's fail2ban
   (3 retries → 24 h) would ban `10.60.60.20`, i.e. the very address that must reach
   8007 for backups and restores — a login typo becoming an availability incident.
   The credential-free-by-design probe (secret only ever in a 600 file) is documented
   in `docs/servers/pbs01.md` step 1: `proxmox-backup-client list --repository
   'pve-backup@pbs!pve-token@10.10.10.30:pbs-store' --ns jol-hv01` run on hv01, whose
   result distinguishes *grants sufficient* / *ACL missing* / *namespace absent*.
   Then read existing grants in the PBS Web UI (Configuration → Access Control →
   Permissions) or, with a console shell, `proxmox-backup-manager acl list | grep …`
   (guarded by
   `[ -x /usr/bin/proxmox-backup-manager ] || echo "NOT a PBS host"`). ⚠ Corrected
   2026-10-22 against the live host: `acl list` takes **no** path argument and **no**
   `--auth-id` filter in PBS 4.2 (it errors `got additional arguments`), and tokens are
   managed by `user list-tokens` / `user generate-token`, not `user token list`.
   **Measured state 2026-10-22** (`acl list`, `user permissions`): `pve-backup@pbs` holds
   `DatastoreBackup` + `DatastoreAudit` on `/datastore/pbs-store` with `propagate=1`, and the token
   `pve-backup@pbs!pve-token` exists (`enable=1`, `expire=never`) but has **no ACL row of its own**, so its
   effective privilege list is empty — step 2 therefore cannot be skipped. ⚠ **Reasoning corrected against
   the published role definitions** (`pbs.proxmox.com/docs/user-management.html`): `DatastoreBackup` "can
   backup and restore **owned** backups", and the `Datastore.Backup` privilege "also provides the
   privileges of `Datastore.Read` and `Datastore.Verify`, but only if the backup group is owned by the user
   or one of its tokens". The earlier claim here — "enough to *write* backups but **not** enough to restore,
   so the `qmrestore` drill cannot pass" — is **withdrawn** as wrong. What is actually missing is
   **`Datastore.Prune`**, because step 6 creates the job with
   `prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6`; `DatastoreBackup` does not carry Prune and
   `DatastorePowerUser` does. **PBS 4.2 has no "Namespaces" tab and no `namespace create` CLI — the
   namespace is created automatically by the first successful backup**, so do not pre-create it and never
   satisfy this step via *Add: Datastore* (that nests a second datastore inside `/backup-pool/pbs-store` and
   lets two datastores prune overlapping ZFS trees). Grant `DatastorePowerUser` on
   `/datastore/pbs-store/jol-hv01` — **permissions may be pre-granted on the still-absent namespace path**,
   and the row appearing in `acl list` before the directory exists is expected, not inert — to **both** the
   user and the token (`--auth-id`, *not* `--userid`; a token's effective privileges are its own rows
   intersected with the parent user's, so a token-only grant stays capped at Backup+Audit and **both**
   entries are required). CLI equivalents, for the record (run **on pbs01**):
   ```bash
   proxmox-backup-manager acl update /datastore/pbs-store/jol-hv01 DatastorePowerUser --auth-id 'pve-backup@pbs'
   proxmox-backup-manager acl update /datastore/pbs-store/jol-hv01 DatastorePowerUser --auth-id 'pve-backup@pbs!pve-token'
   ```
   Least-privilege alternative (choose one and record it): leave all pruning to the existing daily
   `pbs-store-prune` job (`root@pam`), drop `prune-backups` from the PVE job, and grant only
   `DatastoreBackup` + `DatastoreReader` on the namespace — that gives backup + restore without handing the
   backup data path any delete capability, which matters because `10.60.60.20` is reachable on `8007` from
   every VM on this host. Confirm `pbs-store-prune` / `pbs-store-verify`
   still cover the new groups and note datastore free space.
   Verified access route for this step (one-off, self-expiring, loopback-bound,
   recorded in evidence §13; re-verified 2026-10-22 on port **8444**, not `8443` — the
   Vaultwarden TLS front door binds `127.0.0.1:8443` since the 2026-10-22T12:10Z change,
   so the documented command fails `bind: Address already in use`, a *local* error that
   must not be read as "pbs01 unreachable" and used to argue for a firewall widening —
   see `docs/servers/pbs01.md` §Admin SSH Path): `timeout 900 ssh -f -N -L
   127.0.0.1:8444:10.10.10.30:8007 <user>@10.60.60.20` → `https://localhost:8444`
   (returned HTTP 200 GUI / 401 on the
   unauthenticated API call on 2026-10-21, proving both the admin path and that
   pbs01's firewall already permits 8007 from `10.60.60.0/24`).
5. **Install the PBS credential on hv01.** The storage stanza already exists, so this is a credential
   write, not a re-registration. ⚠ **Approved form (2026-10-22, after INC-20261022-TOKEN-EXPOSURE):**
   rotate and install in **one pipeline**, so the one-time value is never printed to a screen, never typed,
   never enters shell history and never reaches a chat/ticket —
   ```bash
   # [WORKSTATION] run as ONE line; the value flows stdout -> sed -> ssh stdin and is consumed
   # ⚠ corrected against the live host: generate-token REJECTS --output-format in PBS 4.2, its default
   #   output is '"value": "<uuid>"' (note the space), and remote stderr must stay OFF the pipe.
   ssh pbs01 'proxmox-backup-manager user delete-token pve-backup@pbs pve-token 2>&1 1>/dev/null;
              proxmox-backup-manager user generate-token pve-backup@pbs pve-token --expire 0
              --comment "hv01 vzdump push ns jol-hv01"' 2>/tmp/gen.err \
     | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
     | ssh pve "sudo tee /etc/pve/priv/storage/pbs01.pw >/dev/null"
   # ⚠ MANDATORY FOLLOW-UP: 'delete-token' PRUNES THE TOKEN'S ACL ROWS, so the grant must be re-applied
   #   or the credential authenticates with zero privileges ("Cannot find datastore 'pbs-store'").
   ssh pbs01 'proxmox-backup-manager acl update /datastore/pbs-store/jol-hv01 DatastorePowerUser --auth-id "pve-backup@pbs!pve-token" --propagate 1'
   # verify structurally only — a token value is a UUID: 36 valid chars (37 bytes with the trailing newline,
   # which PVE's plugin tolerates — proven by the auth result, not assumed)
   ssh pve "sudo wc -c /etc/pve/priv/storage/pbs01.pw; sudo sh -c \"tr -cd 'A-Za-z0-9-' < /etc/pve/priv/storage/pbs01.pw | wc -c\"; sudo stat -c '%a %U:%G' /etc/pve/priv/storage/pbs01.pw"
   ssh pve -t 'sudo pvesm status | grep pbs01'        # inactive -> active
   ```
   A failed install is **fail-closed** (no token, empty credential ⇒ 401), never an open door.
   `0` bytes ⇒ the `sed` did not match (re-check the `2>/tmp/gen.err` capture for the real error). `37` is
   the **normal** result (36-char UUID + the newline `sed` appends) and authenticates fine; anything else
   (e.g. a much larger size) means the paste/pipe was contaminated — the historical 1-byte file was a bare
   newline written by an interactive `read` that had swallowed the next pasted line. Alternative if you prefer the browser: PVE UI (https://10.60.60.20:8006, user
   `root`, realm *Linux PAM standard authentication*, type `root` — **no** `@pam` suffix in the name field) →
   pve-prod-hv01 → Storage → select `pbs01` → Edit → **Password** → paste → OK. Never CLI:
   `pvesm add pbs --password <secret>` / `pvesm set … --password` put the token in argv, `ps` and shell
   history, violating §0.1. Verified against the live PVE 9 source
   (`PVE::Storage::PBSPlugin::pbs_password_file_name`): PVE stores the secret at
   `/etc/pve/priv/storage/pbs01.pw` mode **0600**, and an optional client encryption
   key at `/etc/pve/priv/storage/pbs01.enc` — not any `.ps1` file. TLS fingerprint
   pinned (pin re-verified live from hv01 on 2026-10-21).
6. **Backup job**: delete the malformed `job-vm100-nightly` through the API, then
   create `hv01-nightly-pbs` for VMIDs 100/101/102 — `mode snapshot`, zstd,
   `--repeat-missed 1`, `prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6`.
   Parameter names and formats were read from the live PVE 9 schema, not assumed:
   the create endpoint takes **`id`** (not `sid`), **`comment`** (not `notes`), and
   **`schedule` as a pve-calendar-event** (systemd style, e.g. `02:00`) — a legacy
   5-field cron string is not what PVE 9 writes, which is a second reason the old
   hand-written section could never register. `mailnotification` is deprecated in
   favour of notification targets/matchers; with no target configured a job failure
   mails nobody, so watchdog gates 9–10 remain the actual detection layer.
   Use `scripts/maintenance/hv01-backup-onboard.sh` (it gates on the datastore
   existing, creates the job, re-checks `jobs.cfg` vs scheduler counts, and can run
   the first pipe-test vzdump).
7. **Evidence replication**: install `hv01-archive-to-pbs.sh` +
   `/etc/cron.d/jol-hv01-archive` (03:45 UTC) — staggered after the 02:00–02:30
   VM window, the 03:00 datastore prune and the 03:15 llm-prod-lt01 push so the
   single P4500 target is never contended.
8. **Detection**: extend `/usr/local/bin/jol-health-check.sh` with the four
   freshness gates in §6 and remove the `2>/dev/null` error suppression from
   `jol-config-backup` so a failed tar is loud.
9. **Docs**: correct `docs/servers/pve-prod-hv01.md` hardware + backup claims,
   `docs/servers/pbs01.md` (new namespace/group), Change History rows.

### 3b. Execution status (2026-10-21)

| Phase | State | Evidence |
|-------|-------|----------|
| 1 pre-change capture | **DONE** | `/mnt/hdd-archive/system/prechange-20261021-152255/` (fstab, storage.cfg, jobs.cfg, cron.d/jol-config-backup, jol-health, jol-health-check.sh.orig) + `/etc/fstab.bak.20261021-152255` |
| 2 fsck window | **DONE** | `e2fsck -f -p /dev/sda1` rc=0 (17 files, 2078677 blocks), `/dev/sda2` rc=0 (111 files); both `Filesystem state: clean`; 5/5 config tarballs `tar tzf` OK; cloud image SHA256 readable. Note: the `fuser -q` pre-check used an unsupported flag and did not actually evaluate busyness — unmounts succeeded regardless |
| 3 host baseline | **DONE** | `hv01-storage-baseline.sh` with `DRY_RUN=1` previewed, then `DRY_RUN=0`: fstab `nofail`+timeouts on both HDD lines (`mount -a` rc=0 after), `pvesm set hdd-iso --content iso,vztmpl` (storage.cfg now `content vztmpl,iso`), `tune2fs -c 30 -i 180d` on both. Log `/var/log/jol-hv01/baseline-20261021-152255.log` |
| 4 pbs01 namespace + ACL | **DONE — grant applied 2026-10-22T20:06Z; only the token rotation is left** | `DatastorePowerUser` on `/datastore/pbs-store/jol-hv01` (`propagate=1`) granted to **both** `pve-backup@pbs` and `pve-backup@pbs!pve-token`; both `acl update` calls rc=0. Read-back: `acl list` shows the two rows and `user permissions 'pve-backup@pbs!pve-token'` went from **empty** to `Datastore.Backup (*)` + `Datastore.Prune (*)` — the same shape the nightly-working `jol-llm-backup@pbs!llm-token` reports, so the grant matches a control already proven in production. Persisted in `/etc/proxmox-backup/acl.cfg` (0640 root:backup). The namespace directory is still absent on disk, which is **expected** (auto-created by the first backup). Baseline before the change was captured in evidence §16 (four pre-existing rows only). ⚠ **The "SSH is DROPped from everywhere reachable / two layers enforce it / fixing the pbs01 nftables rule is not a valid single-step remedy" statement in this row is withdrawn** — ADR-008 Option B measured the router forwarding `defconf → vlan10` with the source preserved, and one `/32` on pbs01 was sufficient: `ssh pbs01` is live and every probe in this row was run over it. Admin plane over the UI tunnel (`127.0.0.1:8444`) remains the out-of-band fallback. See evidence §14–§15 |
| 5 PBS datastore registration | **DONE 2026-10-22T20:39Z — datastore `pbs01` is `active`** | Both blockers closed. (a) *token privileges*: closed by the §3b row-4 grant, then **had to be re-applied after rotation** — ⚠ **new fact learned: `user delete-token` prunes the token's own ACL rows**, so a regenerated token comes back with zero privileges; the grant for `pve-backup@pbs!pve-token` was re-run (rc=0) and read back as `Datastore.Backup (*)` + `Datastore.Prune (*)`. (b) *secret*: installed by the no-print rotate-and-install pipeline of §3 step 5 (INC-20261022-TOKEN-EXPOSURE containment — the exposed value was invalidated by the delete, and the replacement was never displayed). Result file: `/etc/pve/priv/storage/pbs01.pw` 37 bytes (36-char UUID + newline, tolerated by the plugin — auth succeeded), mode `600 root:www-data`. Error-class trail that proves each layer: `401 Unauthorized` (no credential) → `Cannot find datastore 'pbs-store'` (credential valid, grants missing) → `pvesm status` → `pbs01 pbs active`. Evidence §17; incident record `docs/compliance/evidence/incident-20261022-pbs-token-secret-exposure.md` |
| 6 vzdump job | **DONE 2026-10-22T20:44Z — `hv01-nightly-pbs` registered, scheduled, and proven by a real run** | Created through the API with the exact §3 parameters; `jobs.cfg` now shows a `vzdump: hv01-nightly-pbs` section with **TAB-indented** options (`^Ischedule 02:00`, `^Ivmid 100,101,102`, `^Istorage pbs01`, `^Imode snapshot`, `^Icompress zstd`, `^Iprune-backups keep-daily=7,keep-monthly=6,keep-weekly=4`, `^Irepeat-missed 1`, `^Imailnotification failure`, `^Ienabled 1`, base64 comment) and `pvesh get /cluster/backup` reports it with `next-run` populated. ⚠ **The "leave the malformed section as evidence" advice in this row and in `hv01-backup-onboard.sh` is WITHDRAWN — it is not survivable:** `job-vm100-nightly`'s TAB-less option lines made the PVE 9 job registry die on *every* write (`unknown section type ''` at `PVE::Job::Registry.pm:73`, `pvesh create /cluster/backup` failed, `pvesh delete /cluster/backup/job-vm100-nightly` answered *No such job* because the parser could not see it). Job creation was therefore impossible until `/etc/pve/jobs.cfg` was emptied by direct file edit — the one case where "do NOT edit by hand" has to yield, because the API cannot repair a file the API cannot parse. Pre-change backup: `hv01:/root/prechange-20261022/jobs.cfg.bak-20261022-2345`; the evidence copy of the malformed content is also preserved in `docs/compliance/evidence/hv01-storage-inspection-20261021.txt`. First real run: `vzdump 102` 24 s, `vzdump 100 101` 91 s + 25 s, all `Backup job finished successfully`. |
| 7 evidence replication | **INSTALLED, CRON PENDING** | `/usr/local/bin/hv01-archive-to-pbs.sh` (750 root:root, sha256 `cad7c2ecb910`, host == repo). Credential and key are now **reused from PVE's own files** (`/etc/pve/priv/storage/pbs01.pw` / `.enc`) so no secret is typed twice and there is exactly one client-side key per datastore; fallbacks stay available. The onboard script writes `/etc/cron.d/jol-hv01-archive` (03:45 UTC) and can push once with `PUSH_EVIDENCE=1`. |
| 8 watchdog made truthful | **DONE** | §1b; installed `750 root:root`, SHA256 `fdd1a5fa…32cece`, `PATH=` added to `/etc/cron.d/jol-health`; verified under `env -i PATH=/usr/bin:/bin` — 3 true alerts, rc=1 |
| 9 docs corrected | **DONE** | `docs/servers/pve-prod-hv01.md`, `docs/servers/pbs01.md`, `docs/servers/rag-prod-lt01.md`, `docs/servers/mcp-prod-lt01.md`, `docs/servers/her-prod-lt01.md`, `docs/architecture/trust-boundaries.md`, `docs/runbooks/jol-pilot-backup-plan.md`, `inventory/prod/hosts.yml`, `AGENTS.md` §2.1, `ansible/roles/backup_client` header |

### 3c. Why steps (a) and (b) are operator-only — probed, not asserted

| Claim | Probe (2026-10-21) | Result |
|-------|--------------------|--------|
| pbs01 unreachable from the workstation | `bash -c '/dev/tcp/10.10.10.30/22'` and `/8007` | closed **on 2026-10-21**, and the 2026-10-22 generalisation drawn from it ("`:8007` times out too, so this source has no path to VLAN 10 *at all* — a pbs01 SSH-rule change cannot help it") is **WITHDRAWN**: pbs01 has no accept for `192.168.88.0/24` on 8007 either, so the *host* rules explain both timeouts, while `10.10.10.2:80/:23` (switch), `10.10.10.11:443` (iDRAC) and ICMP to `10.10.10.30` all answer from `192.168.88.249`, and hv01 `ss -tn` lists this operator's session as peer `192.168.88.249` — source preserved, no inter-VLAN masquerade. Measured conclusion (ADR-008): pbs01's own input rule was the **sole** blocker for this source, one `/32` fixed it, and `ssh pbs01` now works. ⚠ For **hv01** the two layers remain independent and each sufficient; that path is deliberately left blocked |
| hv01 cannot SSH into pbs01 | `ssh -o BatchMode=yes root@10.10.10.30 hostname` **from hv01** | no output. ⚠ **Cause corrected 2026-10-22**: an `/dev/tcp/10.10.10.30/22` connect from hv01 times out with `rc=124` (zero banner bytes) while `:8007` on the same host and same routed path connects instantly — so the session never reaches authentication, and key custody (`hv01 holds no key on pbs01`) is **not** the reason. The fleet SSH chain `admin01 → pbs01` is still the documented design |
| which layer drops `hv01 → :22` | read-only capture, 2026-10-22 (`ip -4 addr` count, `ip route get`) | **UNDISTINGUISHABLE from here.** hv01 holds no `10.10.10.0/24` address (`ip route get 10.10.10.30` → `via 10.60.60.1 src 10.60.60.20`), and `docs/network/vlan-audit-2026-08-29.md` §2 records the MikroTik matrix as `vlan60 → vlan70 and vlan10:8007` with no `vlan60 → vlan10:22` — that router rule alone explains the observation. Proving it needs `nft list ruleset` on the pbs01 console **and** `/ip firewall filter print` on the router |
| admin01 (the documented jump host) unavailable | `ping 10.10.10.50` | 100 % packet loss from this workstation (re-verified 2026-10-22: no ICMP, no TCP 22) — the *absence of a VLAN 10 source*, not a firewall defect, is what leaves PBS without an SSH path |
| PVE API/GUI reachable but not usable by me | `/dev/tcp/10.60.60.20/8006` | **OPEN** — but authenticating to it means handling your web credentials, which §0.1 and the Tier-1 forbidden list put out of bounds; the PBS token secret likewise must never cross a command line (`pvesm add pbs --password …` writes it to argv and shell history) |
| The documented TLS pin is current | `openssl s_client -connect 10.10.10.30:8007` from hv01 | `sha256 4B:93:A9:…:54:92` **matches** `docs/servers/pbs01.md`; `CN=pbs01.jol.lan`, valid 2026-07-04 → 3025-11-04 |
| Phase 7 needs no package install | `command -v proxmox-backup-client` on hv01 | present at `/usr/bin/proxmox-backup-client` |

So: **you** run (a) on pbs01 and (b) in the Web UI; everything downstream is scripted
and verifiable from hv01 (`hv01-backup-onboard.sh`, currently gated off at gate 1 with
"datastore 'pbs01' is not registered on this host" — proven, no changes made).

### 3d. Installed-script drift gate (added 2026-10-31, closes the F-4 root cause)

**Why this exists:** every script in phase 7/8 is installed by hand (`scp` + `chmod 750`) and no step
compared the installed bytes to the repo. On 2026-10-31 the §0.3 pre-change sha check required before
mutating `jol-health-check.sh` found the host running `459de970e312…` (340 lines) while the repo held
`e6aaba5550da…` (382 lines) — the gate-13 rewrite committed 2026-10-24/25 (`dba6075`, `5e94787`) had
**never been installed**, so for a week the fleet's own alert numbers were produced by the pre-fix
code (live symptom: `19 message(s)` where the fixed gate says `3 outward message(s) … (19 delivery
records, retries collapsed)`). This is the same root-cause class as MCP finding **M3** (manual deploy,
no reconciliation) and it is now a **gate**, not a habit:

```bash
# [WORKSTATION] before AND after any script install — the two lines must print the same digest
sha256sum scripts/maintenance/<script>.sh
# [HOST] same file, installed path
ssh pve 'sha256sum /usr/local/bin/<installed-name>'
# if they differ, the install did not happen (or happened from a worktree that was never committed)
diff -u <(ssh pve 'cat /usr/local/bin/<installed-name>') scripts/maintenance/<script>.sh
```

Rules that make the comparison meaningful:
1. The digest must be taken from the **committed** file (`git show HEAD:<path> | sha256sum` if the
   worktree is dirty) — a worktree sha is not a deliverable; the 2026-10-25 note in §7.2 recorded
   exactly that mistake (`46d67e1975d6…`, "never committed").
2. Record BOTH digests in the change entry (repo == host), never the intent.
3. Owner/mode are part of the gate: `stat -c '%a %U:%G'` → `750 root:root`.
4. The pbs01 counterpart is the same command against `pbs01:/usr/local/bin/jol-pbs01-health-check.sh`
   (`ad056ff3979e…` as shipped), and the workstation pull script is checked with
   `sha256sum ~/.local/bin/jol-fleet-health-pull.sh`.
5. A script that is *supposed* to be identical on several hosts must be diffed across them, not just
   against the repo — the watchdog's own `probe unavailable`/gate text differs silently otherwise.

Current state measured 2026-10-31T23:05Z: `pve:/usr/local/bin/jol-health-check.sh` == repo
`ec3709c993c9…`, `750 root:root` (issue #124). The gate is manual until it is wired into
`hv01-backup-onboard.sh` / a future Ansible role — until then, treat "deployed" as UNVERIFIED
unless a host `sha256sum` line is present in the entry claiming it.

## 4. Rollback

| Phase | Rollback |
|-------|----------|
| 2 fsck | none needed (offline check is non-destructive); if `e2fsck` reports unrepairable damage, stop and restore `/mnt/hdd-archive` contents from the first pbs01 pxar (Phase 7) or from `prechange-<ts>` tar |
| 3 fstab | `cp -a /etc/fstab.bak.<ts> /etc/fstab && systemctl daemon-reload && mount -a` |
| 3 storage content | `pvesm set hdd-iso --content backup,vztmpl,iso` |
| 4 pbs01 ACL grant | ⚠ **`proxmox-backup-manager acl` has NO `delete` subcommand in PBS 4.2** (only `list` and `update`), so the CLI cannot unwind this grant. Rollback = PBS UI → Configuration → Access Control → Permissions → select the `jol-hv01` rows → Remove; or `acl update <path> NoAccess --auth-id <id>` to neutralise without deleting. Baseline captured before the change: `acl list` showed only the four pre-existing rows (evidence §16), and `/etc/proxmox-backup/acl.cfg` (0640 root:backup) is the on-disk record |
| 5 datastore | `pvesm remove pbs01` (PVE deletes `/etc/pve/priv/storage/pbs01.pw` and `.enc`) |
| 6 jobs | `pvesh delete /cluster/backup/hv01-nightly-pbs`; restore `jobs.cfg` from `prechange-<ts>/jobs.cfg` |
| 7 cron | `rm /etc/cron.d/jol-hv01-archive`; snapshots on pbs01 remain (harmless, pruned by retention) |
| any VM impact | none by design — no VM disk, bridge, or guest config is touched |

Forward-only rule: do **not** delete
`/var/lib/vz/dump/vzdump-qemu-100-2026_08_12-23_26_27.vma.zst` until a pbs01
snapshot of VMID 100 exists **and** its restore drill passed.

## 5. Documentation defects found (must be corrected, not silently rewritten)

- `docs/servers/pve-prod-hv01.md`: `Backup Enabled: yes (PBS — HP P4500)` and
  "VM backups via Proxmox Backup Server, nightly 02:00, RPO 24 h" are **false**
  (no datastore registered, job invalid, last dump 2026-08-12 by hand).
- Same file: `Storage: 1TB NVMe SSD + 1TB HDD` — actual NVMe is 1.8 TB
  (`ADATA LEGEND 800`), HDD is `ST1000LM024` split 400 G/531 G.
- `docs/servers/rag-prod-lt01.md` audit checklist: `VM backup: PBS nightly job on
  pve-prod-hv01 (RPO 24 h / RTO 4 h)` and `Snapshot present: qm listsnapshot 100
  | grep pre-rag-deploy-…` — unverified against the above.
- `docs/runbooks/jol-pilot-backup-plan.md` §1: "client-side encrypted (fleet
  pattern, **verified for hv01** and llm-prod-lt01)" — not verified for hv01.
- `inventory/prod/hosts.yml`: `pve-prod-hv01: backup_enabled: true` — false.
- Impact of correcting these is documentation-only; no downstream repo reads
  them at runtime, but `jol-rag-server`/`jol-mcp-servers`/`jol-hermes-agents`
  audit gates quote them, so those checklists inherit the error until fixed.

## 6. Acceptance gates (all must show output, §0.4)

```text
□ Mount survivability     umount /mnt/hdd-archive; mount -a; reboot-free test
                          → fstab has nofail; host boot path unaffected
□ FS integrity            e2fsck -f /dev/sda1 /dev/sda2 → rc=0, "clean"
                          tune2fs -l | grep -E "Maximum mount count|Check interval" → 30 / 180d
□ No fake backup target   pvesm status | grep hdd-iso → content no longer offers backup
                          qm set 100 --unused0 … not needed; storage.cfg has no
                          `content backup` on hdd-iso
✔ PBS grants:         DatastorePowerUser on /datastore/pbs-store/jol-hv01, propagate=1, for BOTH
                          `pve-backup@pbs` and `pve-backup@pbs!pve-token` (applied 2026-10-22T20:06Z, rc=0).
                          Read-back: `user permissions 'pve-backup@pbs!pve-token'` → Datastore.Backup (*) +
                          Datastore.Prune (*) — previously EMPTY. Matches the proven-working llm-token shape.
                          ⚠ CORRECTED: the namespace directory is NOT auto-created — the first vzdump failed
                          with `command error: namespace not found`, so `install -d -o backup -g backup
                          -m 750 /backup-pool/pbs-store/ns/jol-hv01` is a required step; and the grant had to
                          be re-applied after token rotation because `delete-token` prunes the token's ACL rows.
✔ Datastore registered pvesm status | grep pbs01 → `pbs01 pbs active`; /etc/pve/priv/storage/pbs01.pw →
                          600 root:www-data (37 bytes); pvesh storage status query accepted by pbs01
✔ Job valid + scheduled pvesh get /cluster/backup → hv01-nightly-pbs present, schedule 02:00, enabled 1,
                          next-run set; jobs.cfg section (TAB-indented) == 1 scheduler entry == 1
✔ Backup actually runs    vzdump 102/100/101 --storage pbs01 --mode snapshot --compress zstd → tasks OK;
                          on pbs01: ns/jol-hv01/vm/{100,101,102}/<date> present
✔ All three VMs           pvesh get /nodes/pve-prod-hv01/storage/pbs01/content --content backup → pbs-vm
                          vmid 100 (107 GB), 101 (54 GB), 102 (54 GB)  [2026-10-22T20:47Z]
✔ Evidence replicated   /var/log/jol-hv01/archive-pbs.log (03:45 EEST): "backup to pbs01 completed OK",
                          816.31 KiB pushed as hv01-archive.pxar.didx using PVE's own pbs01.enc
                          (fingerprint 47:d6:12:27:…), "No previous manifest available" (correct for a
                          first push). On pbs01: ns/jol-hv01/host/pve-prod-hv01/2026-10-23T00:45:01Z.
                          No secret was typed at any point — the script reuses the PVE credential files.
✘ Alert transport       Proven DEAD by injection through sendmail→postfix: mail-to-root delivers to
                          proxmox-mail-forward (sent) but the outward hop BOUNCES — gmail MX returns
                          "550-5.7.1 [62.212.207.81] The IP … is not authorized". So backup-failure
                          notifications reach nobody. FALSIFIES the 2026-10-21 ":25 blocked" note (port 25
                          works; sender authorisation fails). Fix plan + channel options: §7.2. Evidence §21b.
                          **This gap is now SELF-DETECTING (2026-10-23):** hv01 watchdog gate 13 counts
                          bounced/deferred deliveries and fires `rc=1` while the transport stays dead, and the
                          workstation pull surfaces it as a desktop alert. The gate is still ✘ until a push
                          channel with a credential exists — detection ≠ delivery.
□ Negative encryption     restore without key file → FAILS (proves client-side crypto)
✔ Restore drill       qmrestore pbs01:backup/vm/102/2026-10-22T20:42:23Z 199 --storage local-lvm
                          --unique 1 → task OK (50 GiB in 9.44 s @5.4 GB/s, decrypted with the stored
                          key); scratch VM booted with net0 deleted and guest agent RESPONSIVE after 80 s
                          (image → fs → init → agent); then qm stop + destroy 199 --purge → no residue.
                          NOT yet done: the negative-encryption test and the offline e2fsck leg (the
                          `lvs -o lv_path local-lvm/vm-199-disk-0` lookup returned empty — wrong VG/LV name).
✔ Backup-freshness alerting   gate 10 was DEAD CODE (probed `/cluster/tasks`, which rejects
                          `--typefilter`/`--type`/`--limit` → `400`; `2>/dev/null || true` turned that
                          into an empty result read as "no backups"). It produced a permanent FALSE
                          CRITICAL and could NEVER fire the staleness alert. Fixed to the node endpoint
                          `/nodes/<node>/tasks`; proven three ways 2026-10-23T00:32Z — normal `rc=0`/0
                          alerts, `VZDUMP_MAX_AGE_HOURS=0` → `rc=1` "Newest vzdump task is 1 h old",
                          bogus node → `rc=1` "…UNVERIFIED (query failed)". Host copy == repo sha
                          `62c99bd956baca9e…`, 750 root:root. Evidence §20.
⚠ Injection variant NOT used: the `touch /var/lib/jol-hv01/fail-missing-backup` marker test below was
                          superseded — threshold injection via `VZDUMP_MAX_AGE_HOURS=0` exercises the real
                          code path rather than a synthetic file, so it proves more and mutates nothing.
□ Freshness alerting (legacy marker test): touch /var/lib/jol-hv01/fail-missing-backup →
                          jol-health-check.sh exits non-zero + ALERTS.log line
✔ Retention authority: `pbs-store-prune` (03:00, keep-last=1 + 7/4/6) has an EMPTY `ns` field and
                          provably acts across namespaces — `ns/jol-llm/host` holds exactly 11 snapshots
                          (7 daily + 4 weekly) under it. So the PBS job IS the effective pruner for
                          ns/jol-hv01 as well; the PVE job's identical 7/4/6 is a second pruner on the
                          same groups. Values agree today ⇒ no loss; the hazard is DRIFT (change one,
                          not both → retention silently becomes the intersection). Single-source it.
✔ Garbage collection   SCHEDULED 2026-10-31T21:25Z (issue #126) — `datastore update pbs-store
                          --gc-schedule "sat 04:30"` rc=0; read-back: `garbage-collection list` →
                          `schedule sat 04:30`, `next-run Sat Nov  7 04:30:00 2026` (local);
                          `datastore show --output-format json` → `{"gc-schedule":"sat 04:30",…}`;
                          persisted at `datastore.cfg:2` with the leading TAB PBS writes itself.
                          ⚠ Writing the schedule did NOT start a GC (`upid: null`, no new task) —
                          the §7.1 open question answered by observation, not assumption.
                          ⚠ **F-5, the reason gate 3 (`pending-bytes` > 50 GiB) cannot fire yet:**
                          `garbage-collection status` is the **last GC run's** tally — with no run
                          ever executed it returns all zeros (`disk-bytes 0`, `pending-bytes 0`) even
                          though prunes have already deleted groups. So that gate reads "0 GiB pending"
                          = healthy, which is an **absence of measurement rendered as a number**. It
                          becomes meaningful after 2026-11-07 04:30. Historical text kept for the
                          record: the fix is `datastore update --gc-schedule`; there is **no**
                          `garbage-collection create` verb in PBS 4.2.
✔ Integrity verify     `pbs-store-verify` already exists (`*-*-01 04:00:00`, outdated-after 30,
                          ignore-verified 1) — monthly. Raised as a FREQUENCY gap, not a missing job.
✘ Off-site copy        `remote list` and `sync-job list` → none. 0 off-site copies (3-2-1 unmet).
□ Usage headroom       `df -h /backup-pool` → 69 G / 2.2 T = 4 % (gate: < 80 %) — PASS, but see GC above.
                          Now covered continuously by pbs01 watchdog gate 2 (> 70 % CRITICAL) + gate 3
                          (GC pending-bytes > 50 GiB CRITICAL).
✔ Admin path durable:   pbs01 administration is reachable over SSH from the operator workstation
                          (ADR-008 Option B executed 2026-10-22: `tcp dport 22 ip saddr 192.168.88.249/32`
                          on pbs01 — a single /32, no segment, no router change; the UI tunnel and the
                          physical console remain out-of-band fallbacks). The second half of this gate is
                          INTACT BY DESIGN: fail2ban `ignoreip` is still `127.0.0.0/8, 10.10.10.0/24`, so
                          neither backup-path source (`10.60.60.20`, `10.30.30.10`) is reachable on :22 and
                          neither can ever be banned by an operator typo. Evidence:
                          `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt`
✔ Docs + change record    pve-prod-hv01.md, pbs01.md, hosts.yml corrected. **CC8.1 change record RAISED
                          2026-10-24: issue #116 `JOL-BACKUP-20261021-01`** — risk level High (with one
                          Critical sub-action: the `/etc/pve/jobs.cfg` file edit), blast radius, per-change
                          rollback and verification, secret-handling disclosure incl. INC-20261022-TOKEN-EXPOSURE,
                          and the open items this record does NOT close. The 16 CHANGELOG rows written during
                          this thread had carried `TBD (CC8.1 issue — raise before close)` since 2026-10-21 —
                          an open change-management violation, now referenced to #116 in the Ticket column.
                          ⚠ Remaining debt: **21 older CHANGELOG rows** in other threads (prox01, cable audit,
                          rename, jol-pilot) still say `TBD (CC8.1 issue)` and need their own records.
                          **PR #117** opened 2026-10-24 against `main` (`Closes #116`, `MERGEABLE`) — the
                          branch is now pushed, so these artifacts no longer live on the single laptop disk
                          that this incident started with. "Issue closed" still requires that merge.
```

## 7. Next change window — §7.1 **EXECUTED 2026-10-31**, §7.2/§7.3 still open (authored 2026-10-23T19:45Z)

Two controls were missing and both were sized by measurement, not assumption. **§7.1 (GC schedule) was
applied 2026-10-31T21:25Z under issue #126 — see the executed record below §7.1.** §7.2/§7.3 (the
failure-alert transport) remain open: detection exists, delivery does not.

### 7.1 Schedule garbage collection on `pbs-store` (HIGH)

**Why**: `proxmox-backup-manager garbage-collection list` shows schedule / next-run / last-run-state all
empty and `pending-bytes 0 B` — the zero is only because no prune has deleted anything yet (verified:
2 snapshots per group, the 00:00Z `prunejob` removed nothing). Once rotation starts deleting (first daily
ages out ≈ 2026-10-29), every prune leaves orphaned chunks that are **never** reclaimed, and a 2.2 T pool
fills slowly and silently — while the alert transport (§7.2) is itself dead.

**Mechanism (corrected against the live host)**: there is **no `garbage-collection create`** verb — the
only subcommands are `list`, `start`, `status`. GC is a *datastore property*, set with
`datastore update … --gc-schedule <calendar-event>` (verified present in `datastore update --help`,
alongside `--gc-on-unmount`, `--notify`, `--notify-user`, `--notification-mode`; `datastore show pbs-store`
currently returns only `name` + `path`, i.e. none of them are set).
⚠ `--max-used-percent` / `--behavior-on-used-full` are **not** datastore options in PBS 4.2 (absent from
`datastore update --help`) — so capacity defence must come from the watchdog gate below, not from PBS.

```bash
# [PBS01] pre-checks (all must pass before mutating)
proxmox-backup-manager task list --all --limit 5 | grep -cE "running"      # 0 — no data task in flight
proxmox-backup-manager garbage-collection status pbs-store                 # note the digest-free baseline
proxmox-backup-manager datastore show pbs-store --output-format json       # → {"name","path"} only
# apply (PBS schedules are evaluated in the HOST'S LOCAL calendar — same trap as §19b)
proxmox-backup-manager datastore update pbs-store --gc-schedule "sat 04:30"
# verify
proxmox-backup-manager garbage-collection list | grep -A3 pbs-store
proxmox-backup-manager datastore show pbs-store --output-format json       # gc_schedule present
```

> ✅ **EXECUTED 2026-10-31T21:25:08Z (local) under issue #126, verbatim from the procedure above.**
> Pre-checks: no task `running` (newest were `backup`/`prune`/`prunejob`, all `OK`); baseline
> `garbage-collection list` → schedule/next-run/last-run-state EMPTY, `pending-bytes 0 B`; baseline
> `datastore show pbs-store --output-format json` → `{"name":"pbs-store","path":"/backup-pool/pbs-store"}`
> (no `gc-schedule` key); `zfs list` → 73.6 G used / 2.04 T avail.
> Apply: `datastore update pbs-store --gc-schedule "sat 04:30"` → rc=0, no output.
> Read-back: `garbage-collection list` → `schedule sat 04:30`, `next-run Sat Nov  7 04:30:00 2026`;
> `datastore show … --output-format json` → `{"gc-schedule":"sat 04:30","name":…, "path":…}`;
> `datastore.cfg:2` → `\tgc-schedule sat 04:30` (TAB-prefixed, written by PBS itself — the very
> serialisation rule that silently killed the hand-edited PVE `jobs.cfg` section, see §3b row 6);
> `garbage-collection status pbs-store --output-format json` → `next-run: 1794018600`
> (= 2026-11-07T02:30:00Z = 04:30 EET) and `upid: null`, i.e. **the schedule write did not start an
> immediate GC** — that open question from the issue body is now answered by measurement.
> **Why `sat 04:30` and not the daily slot proposed in chat**: `pbs-store-verify` fires
> `*-*-01 04:00:00`, i.e. tomorrow 2026-11-01 04:00 local; a daily 05:00 GC would have started an hour
> into that monthly verify, which this section explicitly forbids. Nov 1 2026 is a Sunday, so the
> weekly Saturday window skips the collision entirely.
> **Rollback**: `proxmox-backup-manager datastore update pbs-store --delete gc-schedule` (then re-read
> `garbage-collection list` → schedule empty).
> **Not yet proven**: that GC actually reclaims — first execution is 2026-11-07 04:30; until then
> `removed-bytes` stays blank and watchdog gate 3 stays blind (F-5 above). Verify after that run with
> `garbage-collection list` (`last-run-state OK`, `removed-bytes` non-zero) and
> `/var/log/jol-pbs01/<date>-health.log` showing no `WARN: garbage collection is NOT scheduled`.

**Window choice**: Saturday 04:30 local — after the nightly 03:00 prune so garbage exists to collect, off
the monthly verify path (`*-*-01 04:00:00`), and outside the 02:00 vzdump and 03:45 archive pushes.
**Rollback**: `proxmox-backup-manager datastore update pbs-store --delete gc-schedule`.
**Risk**: GC is I/O- and CPU-bound while reading the whole chunk index; at 69 G used it is trivial today,
and the pool is on NVMe. Do not run it concurrently with verify; if the datastore were ever on a removable
mount, `--gc-on-unmount` matters too (not applicable: `/backup-pool` is a fixed ZFS mount).
**Capacity gates — SHIPPED 2026-10-23** in the pbs01 watchdog (`scripts/maintenance/pbs01-health-check.sh`,
gates 2 + 3): `df /backup-pool/pbs-store` > `POOL_ALERT_PCT` (70) is CRITICAL, GC `pending-bytes` >
`GC_PENDING_ALERT_G` (50 GiB) is CRITICAL, and an unscheduled GC is a WARN. PBS gives us no datastore
capacity knob in 4.2 (`--max-used-percent` / `--behavior-on-used-full` are not accepted), so the watchdog is
the only place this can be enforced.

### 7.2 Repair the failure-alert transport (HIGH — proven dead, not suspected)

**Measured 2026-10-23T19:43Z**, by injecting through the real production path (`sendmail` → postfix):

| Queue id | Recipient | Result |
|---|---|---|
| `1ABD0321485` | `root@pve.prod.lt9` | `status=sent (delivered to command: /usr/libexec/proxmox-mail-forward)` → `notified via target 'mail-to-root'` |
| `1FDE03214F7` | `mr.gintaras@gmail.com` (root@pam's address) | **`status=bounced`** — `relay=gmail-smtp-in.l.google.com:25`, `550-5.7.1 [62.212.207.81] The IP you're using to send mail is not authorized to send email directly to our servers` — then `removed` |

So: the PVE notification plumbing is intact and the *only* target is `mail-to-root` (builtin, `sendmail`),
and Gmail rejects direct SMTP from this IP. Every `backup-failed` / `mailnotification failure` event
therefore dies in a bounce that nobody reads.

> ⚠ **2026-10-24 correction — the sentence above that claimed this "falsifies the 2026-10-21 note that
> outbound `:25` is blocked" was itself over-inference, and is withdrawn.** Re-measured over 48 h of the
> postfix journal instead of one sample: **two independent defects coexist** —
> (a) `status=deferred`, `connect to alt2.gmail-smtp-in.l.google.com[…]:25: Connection timed out` (IPv4) and
> `Network is unreachable` (IPv6) ≈ **104 records in 48 h** ⇒ :25 IS partially blocked, as originally noted;
> and (b) the attempts that do connect `status=bounced` with `550-5.7.1 … IP … not authorized` / `550-5.7.26
> sender unauthenticated … SPF [pve.prod.lt9] … did not pass`. One success proves reachability, not
> reachability-of-the-route-you-will-need; a `mailq` that drains is still not a working transport.
> Consequence for the fix: an authenticated submission relay (465) addresses both; Telegram avoids both.

**Gate 13 was also unsound, and is fixed (2026-10-24).** Counting bounced/deferred mail is a *failure*
signal that **decays to zero when nothing is failing** — no failing job ⇒ no mail ⇒ no bounce ⇒ the gate
would have reported "transport fine" on a fleet where no test had ever run. Absence of failure is not
presence of success. Gate 13 now requires BOTH: (a) zero bounced/deferred in 24 h, and (b) a positive
**proof record** at `/var/lib/jol-hv01/alert-transport-proof`, written only by
`scripts/maintenance/hv01-verify-alert-transport.sh` (`/usr/local/bin/jol-verify-alert-transport`) after
postfix logs an **outward** `status=sent` (a `relay=local` hop is explicitly rejected as non-proof).
Proved today: `sudo jol-verify-alert-transport` injected a probe (envelope-sender nonce → queue id
`8E54B321566`), read `status=bounced relay=gmail-smtp-in.l.google.com[…]:25 dsn=5.7.26`, exited **1**, and
wrote **no** proof file — so gate 13 stays red, which is the truth. Gate branches proved in both directions
by overriding `PROOF_FILE` / `TRANSPORT_PROOF_MAX_AGE_DAYS` (never by planting fake evidence on the host):
absent → `NEVER VERIFIED`, synthetic fresh → that alert clears while the bounce alert remains, synthetic +
`…MAX_AGE_DAYS=0` → `proof is STALE` naming the record, and the synthetic file was removed afterwards.

> ⚠ **2026-10-24, later the same day — gate 13 was wrong twice more, found by reading its own
> output instead of trusting its verdict.** (1) **The count was contaminated by the verifier.**
> `jol-verify-alert-transport` injects with envelope sender `<nonce>@pve.prod.lt9`, and
> `myhostname` is in `mydestination`, so a Gmail rejection generates a DSN back to that sender
> and `postfix/local` answers `status=bounced (unknown user: "jolproof…")`. **One probe mail
> therefore wrote two bounce records**, so the gate's number was one higher than the number of
> failed messages. Measured live, both pipelines against the same journal: as-deployed **5**,
> outward-only **4**; the extra record is queue `7E5F3321572`, `relay=local`. (2) **The "cannot
> read the journal" branch was dead code** — `grep -c` always prints a number, so a failed
> `journalctl` (errors swallowed by `2>/dev/null`) produced `0` and the gate read an
> *unreadable* journal as "transport fine": gate 10's dead branch in a new costume, and exactly
> the silent-pass class this gate exists to prevent.
>
> Both fixed in `scripts/maintenance/hv01-health-check.sh` (worktree sha `46d67e1975d6…`, which was **never
> committed** — superseded by the 2026-10-25 note below; **not deployed** — the host still runs
> `459de970e312…`, byte-identical to `git show HEAD:scripts/maintenance/hv01-health-check.sh`), so that
> paragraph described a worktree state, not live state. (a) now counts OUTWARD records only, excluding
> `relay=local` — the same
> refusal (b) already applies to a `relay=local` `status=sent`, so the two halves of the gate
> are now consistent about what "the transport" means. Readability is decided by journalctl's
> **exit status**, proved to discriminate: rc=1 on a real failure, rc=0 on a unit that is merely
> quiet, so a day with no mail at all still reads as zero failures and (b) keeps the bar.
> Trade-off stated: a broken LOCAL mailbox on the `mail-to-root` hop is no longer counted here,
> because that hop is not an off-host alert; `relay=none` defers — 70 records in the 48 h
> window, the real :25 timeouts — are deliberately still counted as failures.
>
> **Fixtures (the control the gate previously had none of):** `scripts/maintenance/tests/
test-hv01-gate13.sh`
> sources the gate text **out of the script under test** (never a copy, so it cannot
> drift into proving nothing) and runs 8 cases against a stubbed `journalctl`. Against `HEAD` it
> reports **5 passed, 3 failed** — the failures are precisely the contamination (a probe-only
> journal counted as 1, a mixed journal as 3) and the dead branch (unreadable journal → zero
> alerts). Against the fix: **8 passed, 0 failed**, `shellcheck -x` clean at CI severity. Two
> defects in my own first harness were also fixed, both of the "control that cannot fail" class:
> a `printf` of *filenames* where *contents* were meant, and a single shared `PROOF_FILE` path
> that let an earlier case's fresh proof satisfy a later case asserting "no proof record".

> ⚠ **2026-10-25 — defect 3, found by reading the alert the gate emitted rather than the gate itself.** The
> count is **delivery records, not messages**: a deferred mail writes one record per retry attempt. Measured
> live on `pve-prod-hv01` in the 24 h window — **14 records = 3 distinct queue ids** (`70268321566` retried
> 12× plus two Gmail bounces), so the desktop dialog read "14 message(s)" for three lost alerts. A number
> that inflates with retry churn is the wrong triage signal: it looks like a spreading failure when it is one
> stuck mail. The gate now collapses to distinct queue ids and names the record total beside it
> (`3 outward message(s) … (14 delivery records, retries collapsed)`). Proved against live data, not only
> against fixtures: the same pipelines over the same journal return `records=14 messages=3`.
> **Fallback (case 10, negative control):** a `status=` record whose queue id the pattern cannot read falls
> back to the record count, so an unexpected log format can only ever **over**-count — never silently
> under-count, which is the class of bug this gate exists to catch.
>
> **Fixture evidence, both directions:** the harness is now 10 cases / 11 assertions → **`11 passed,
> 0 failed`** against the fix (`e6aaba5550da…`) and **`6 passed, 5 failed`** against `HEAD`
> (`459de970e312…`), the `HEAD` failures being cases 1, 4, 6 and 9 — every defect this gate has ever had is
> now covered by a control that demonstrably FAILS on the broken version (the 8-case counts quoted above are
> the 2026-10-24 state, superseded). A harness that passes against both versions proves nothing, so the
> before/after run is part of the evidence. `shellcheck -x` on both files: clean. **The exact CI command**
> (`find scripts/ -name '*.sh' -exec shellcheck -x {} +`) **exits 1 on inherited findings in
> `scripts/audit/verify-basilica-{exit-gates,preflight}.sh`** (SC2034/SC2317, present on `origin/main`),
> zero in this branch's files — `git diff --name-only origin/main..HEAD -- scripts/audit/` is empty, so the
> lint job is red before and after this change, not because of it.
>
> ⚠ **Nothing in this paragraph repairs the transport.** Gate 13 became a sounder measurement of a transport
> that is still dead. Re-measured 2026-10-25 on hv01: `relayhost` **empty**, the only notification endpoint
> is the builtin `mail-to-root` (`sendmail`), `/var/lib/jol-hv01/` **does not exist** (no proof record has
> ever been written), 2 × `status=bounced` (`550-5.7.26 … SPF [pve.prod.lt9] did not pass`, source
> `62.212.195.151`) and 12 × `status=deferred relay=none` in 24 h, and 1 message stuck in `mailq`. Both
> CRITICALs the operator is being shown are therefore **true**, not monitor noise.

**Professional opinion (2026-10-23, after the operator asked me to choose and implement):** the target state
is **Telegram** (`type=telegram`, bot token from @BotFather). Rationale: it needs no IP-reputation
relationship to repair — Gmail's `550-5.7.1` rejection is permanent for this class of source IP, and an
SMTP relay only moves the problem onto a provider account that can silently lapse; it is the only channel
that pushes to a phone the operator carries, which is what an RTO-4 h control actually requires; PVE 9
supports it natively, so no new collector enters the trust boundary. *(⚠ **withdrawn 2026-10-25** — the last
clause is false on this host: `pve-manager/9.2.10` exposes no `telegram` endpoint type, see the correction
under "Remaining" below.)* It costs **one secret that the operator
must create and must never paste into a chat, ticket or shell history** (§0.1) — so it cannot ship tonight.
The design was therefore split into three layers that need **zero credentials**; all three are shipped:

| Layer | What | Where | Proof |
|---|---|---|---|
| 1 | watchdog **gate 13** — alert-transport liveness; counts `status=(bounced\|deferred)` in the postfix journal, never queue depth. **Revised 2026-10-24:** a decay-to-zero count is not proof, so it now ALSO requires a positive outward-delivery proof record (`jol-verify-alert-transport`) newer than 7 d | `scripts/maintenance/hv01-health-check.sh` → `pve:/usr/local/bin/jol-health-check.sh`, sha `459de970e312…` ⚠ **stale citation — superseded 2026-10-31T23:05Z by `ec3709c993…` (issue #124: F-2 mirror guard + the never-installed gate-13 rewrite); see §3d** | fired `rc=1` with 2 CRITICALs: `ALERT TRANSPORT BROKEN: 4 message(s) …` + `alert transport NEVER VERIFIED end-to-end …` |
| 2 | **pbs01 got a watchdog of its own** (10 gates: chrony quorum/offset, pool %, GC, prune+verify existence, per-group freshness parsed from UTC snapshot *names*, ACL drift, auditd local-only, fail2ban, services) | `scripts/maintenance/pbs01-health-check.sh` → `pbs01:/usr/local/bin/jol-pbs01-health-check.sh`, sha `ad056ff3979e…`, cron `15 6 * * *` | normal run `rc=0` + GC `WARN`; forced thresholds → 7 CRITICALs `rc=1`; executed on hv01 → `rc=2` host-guard abort |
| 3 | **workstation pull** — runs both watchdogs over SSH every 15 min and raises a desktop alert | `scripts/maintenance/fleet-health-pull.sh` + `install-fleet-health-timer.sh` → `~/.local/bin/jol-fleet-health-pull.sh`, sha `2591b5b36fdd…`, `jol-fleet-health.timer` enabled | installer's own proof: service exits `rc=1` while transport is broken; every run logged to `~/.local/share/jol-fleet-health/pull.log` |

Two defects found and fixed *while building layer 3* — either one would have made the new monitoring lie:

1. **Both watchdogs emitted their completion marker only to the log file.** `info()` appends to `$LOG`; only
   `alert()`/`warn()` tee to stdout — so the pull's gate-coverage check could never find
   `HEALTH CHECK COMPLETE` and would have raised a permanent false *UNVERIFIED* alert on **both** hosts. Each
   script now prints an explicit stdout marker. Proved in both directions: markers present on live runs,
   `ONLY=pbs01` subset run refuses to claim a fleet-wide green.
2. **An alert without an age is untriageable, and a 15-minute repeat becomes ignorable noise.** The pull now
   records last-green per host (`last OK: 37 h ago`) and notifies **on change of the alert set only** —
   digits masked, so `81 message(s)` → `82 message(s)` stays the same failure — and announces recovery when a
   previously-noted set clears. Proved: first run notifies; immediate re-run logs `same alert set as already
   notified — desktop notification suppressed`; seeded-recovery run raises
   `-u normal … JOL fleet health — recovered` and clears the signature file.

**Known limits — do not mistake them for health:**
- `Linger=no` on the workstation ⇒ the user manager (hence the timer) exists only while the operator is
  logged in, and nothing fires while the laptop is off. `loginctl enable-linger jol` widens this; layer 3 is
  a second pair of eyes, never a substitute for a push channel.
- `systemctl --user is-failed jol-fleet-health.service` is the **expected steady state** while any gate is
  red: `Type=oneshot` + `rc=1` *is* the alert. Never "fix" it by forcing exit 0 — that is gate 10's dead
  branch again, in a new costume.
- pbs01's watchdog writes evidence to `/var/log/jol-pbs01` on the root filesystem only, never into
  `/backup-pool` (self-referential blindness already fixed on hv01).

**Remaining (needs the operator's token, typed at a prompt — never into chat):** create a Telegram target on
PVE and match the failure events to it, then mirror the same liveness gate onto pbs01. Exact `pvesh` option
names for `--type telegram` targets/matchers MUST be read back from the host's own help output before
executing — I will not guess a schema that touches a credential. ⚠ UNVERIFIED until then.

> ⚠ **2026-10-25 — that paragraph is superseded: the Telegram premise is false on this host.** Measured with
> `pvesh ls /cluster/notifications/endpoints` on `pve-manager/9.2.10`: the endpoint types are **`gotify`,
> `sendmail`, `smtp`, `webhook` — there is no `telegram`**. So "PVE 9 supports it natively, no new collector
> enters the trust boundary" does not hold; Telegram would need an external collector/bot bridge, i.e. the
> thing the rationale claimed to avoid. Re-probed egress from hv01: **`smtp.gmail.com:465` and `:587` are
> OPEN**, `:25` times out — so the blocked port is not an obstacle to an authenticated submission relay.
>
> **Revised recommendation: an authenticated submission smarthost in postfix** —
> `relayhost = [smtp.<provider>]:465`, `smtp_sasl_password_maps = hash:/etc/postfix/sasl/passwd`
> (`postmap`, file `600 root:root`), `smtp_sasl_auth_enable = yes`, `smtp_tls_security_level = encrypt`,
> `smtp_sasl_security_options = noanonymous`, then `systemctl reload postfix`. Why this over the PVE-native
> options:
> - it fixes **both** measured defects at once — the `5.7.26` unauthenticated-sender rejection (the relay
>   authenticates and aligns SPF/DKIM with the provider's domain) and the blocked direct-`:25` route;
> - it keeps `mail-to-root` → postfix as the **single** alert path, so gate 13 and
>   `jol-verify-alert-transport` keep measuring the route alerts actually take;
> - **rejected: the PVE `smtp` endpoint** — PVE sends it directly and bypasses postfix, which would leave
>   gate 13 counting a journal that no longer carries alert traffic (a vacuous green, the exact failure
>   class this gate was built to stop) and the verifier proving a dead path;
> - **rejected: `gotify`/`webhook`** today — both need a collector service that does not exist yet, and a
>   collector on the same host cannot prove the host's own alerting (self-referential blindness, already
>   fixed once for pbs01's log path).
>
> Credential rule unchanged: the relay account and password are created and typed by the operator — never
> into chat, a ticket, a commit or shell history (§0.1); `postmap` the file, keep it `600 root:root`, and
> never pass it as a CLI argument. Rollback: comment the four `relayhost`/`smtp_sasl_*` lines,
> `systemctl reload postfix` (returns to today's known-broken-but-honest state).

### 7.3 Verification checklist for the transport fix (run after §7.2 is applied)

```bash
# [PVE] all four must be true before the change is called done
sudo postconf -n | grep -E '^(relayhost|smtp_sasl_auth_enable|smtp_tls_security_level)'   # relay set, auth on, encrypt
sudo jol-verify-alert-transport                       # rc=0 and it writes the proof record
sudo cat /var/lib/jol-hv01/alert-transport-proof      # PASS line with an OUTWARD relay, not relay=local
sudo /usr/local/bin/jol-health-check.sh; echo "rc=$?" # gate 13 green; overall rc reflects remaining gates
journalctl -u postfix --since "-15 min" | grep -cE 'status=(bounced|deferred)'   # 0
```

⚠ A green gate 13 after this means *one* probe left the host. It does not mean every failure event has a
recipient: confirm in the PVE GUI (Datacenter → Notification → Matchers) that `backup-failed`,
`mailnotification failure` and node-level errors still route to the target you just repaired.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-10-21 | Runbook created from live read-only inspection of pve-prod-hv01 + pbs01 reachability test | this document; `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` |
| 2026-10-21 | Phases 1–3 executed (prechange capture, offline fsck both partitions rc=0, fstab `nofail`+timeouts, `hdd-iso` content → `iso,vztmpl`, `tune2fs -c 30 -i 180d`). Phase 8 executed after discovering the watchdog had emitted 415 false CRITICALs since 2026-07-31 (§1b) — replaced with `hv01-health-check.sh`, PATH fixed in cron. Phases 4–7 pending operator secret custody | evidence file §2–§6; `/var/log/jol-hv01/baseline-20261021-152255.log` |
| 2026-10-21 | Root cause of the dead backup job corrected after `cat -A /etc/pve/jobs.cfg`: the section's option lines lack the mandatory leading TAB, so PVE dropped every one of them — the `30 3 * * *` schedule was never the problem. Remediation unchanged (create the job via `pvesh`, never by hand), plus watchdog gate 9 now compares `jobs.cfg` sections against the scheduler registry | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §8 |
| 2026-10-22 | pbs01 admin SSH enabled (ADR-008 Option B, one `/32` on pbs01 only) and pbs01's chrony fixed (was +65.657 s fast, dead peer admin01 → upstream pool, verified stratum 3 / 0.4 ms / `rtcsync` reboot-safe) — both via `docs/runbooks/pbs01-admin-ssh-access.md` and `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt`. §6 "Admin path durable" gate now ✔. **§3b row 5 corrected: the datastore has TWO blockers, not one** — the token exists and is enabled but carries zero ACLs, and PBS tokens do not inherit the user's privileges, so the secret alone could never have activated it | evidence §13–§14; `ssh pbs01` verification battery 2026-10-22 |
| 2026-10-22 | Onboard script made a true one-command finish and two of my own defects fixed: (a) `set -e` + a bare `[[ … ]] && …` statement plus a `pipefail`-tainted `$(… | grep -o … | wc -l)` made the DRY run abort silently before the gate table — it now reports honestly and exits 0; (b) gate 1 claimed "registered and active" without probing, which is exactly the overclaim this incident is about — it now prints `not probed (DRY_RUN)` unless the PBS status query actually succeeded. Added: snapshot proof via PVE's own storage-content API (no pbs01 admin needed), reuse of PVE's `.pw`/`.enc` instead of second copies, cron installation for the evidence push, optional `PUSH_EVIDENCE=1` run, and a post-run watchdog pass. All four host scripts byte-identical to the repo (`20286c5e057b`, `cad7c2ecb910`, `c1a56589d717`, `440d40de0be1`), shellcheck clean. | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §23 |
| 2026-10-22 | PBS state captured from a root shell obtained via the UI xterm.js console (no SSH needed): nftables is `policy drop` with `22` from `10.10.10.0/24` only, so the **host** independently blocks SSH (the earlier one-sided router attribution is withdrawn); fail2ban `ignoreip` is `127.0.0.0/8, 10.10.10.0/24` with 0 failed / 0 banned. ACL read-back: `pve-backup@pbs` = `DatastoreBackup` + `DatastoreAudit` on `/datastore/pbs-store` propagate, **no token row** ⇒ backups possible, **restore drill impossible**, RTO 4 h unmet until `Restore`/`DatastorePowerUser` is granted. Step 4 corrected on three points proven against the live 4.2 host: `acl list` takes no path/`--auth-id` argument; tokens are `user list-tokens`/`user generate-token`; **there is no Namespaces tab** — the namespace is auto-created by the first backup and ACLs may be pre-granted on the absent path (the operator had opened *Add: Datastore* from the previous instruction and cancelled safely). Operator authenticated as `root@pam`, so the "credential lost ⇒ offline reset" conclusion is superseded, but the vault is empty ⇒ the password is uncustodied. Admin-SSH question answered in `docs/runbooks/pbs01-admin-ssh-access.md` (recommended: join VLAN 10 on the workstation's unused `enp9s0`, zero firewall change) | `/root/prechange-20261022/pbs01-nft.txt`; `docs/servers/pbs01.md` §Admin SSH Path, §Monitoring reality |
| 2026-10-22 | Admin SSH premise tested and rejected as a one-layer fix; tunnel port corrected. SYN-only re-probe: workstation `192.168.88.249` times out on pbs01 `:22` **and** `:8007` (no VLAN 10 route at all), hv01 `10.60.60.20` gets `:8007` OPEN / `:22` DROP over the identical routed path while holding **0** addresses in `10.10.10.0/24`, admin01 `10.10.10.50` answers nothing. Because the documented MikroTik rule `vlan60 → vlan10:8007` (vlan-audit §2) alone explains the hv01 result, pbs01's nftables is not proven to be the binding layer — widening it risks a weakened control with still-broken access. Decision recorded: **do not widen** (backup-plane segregation A.8.13/A.8.20; and the `ignoreip 10.10.10.0/24`-only jail would gain the power to ban `10.60.60.20`, the address every backup and restore must reach — forbidden by the §6 gate "fail2ban must never be able to ban a backup-path source"); cross-VLAN would need an ADR. §3c cause corrected from "auth fails / hv01 holds no key" to TCP DROP. **Fixed the tunnel port `8443` → `8444`** in §3 step 4 and §3b: `8443` has been bound by the Vaultwarden TLS front door since 2026-10-22T12:10Z, so the documented command failed `bind: Address already in use`. No firewall change on any device; no credentials handled; tunnel re-verified live (GUI 200, unauth API 401) | `docs/servers/pbs01.md` §Admin SSH Path + Change History |
| 2026-10-22 | **pbs01 chrony fix audited: necessary and correct, but under-provisioned — and two of my own claims in this runbook were wrong.** (1) The 18:54Z drop-in used `server <pool-zone>`, which pins one resolved address per line: measured `2 sources online` out of 8 DNS candidates, i.e. no quorum to reject a falseticker (RFC 5905 §10). Re-provisioned to `/etc/chrony/conf.d/jol-sources.conf` = `pool lt.pool.ntp.org / 0.ubuntu.pool.ntp.org / 1.ubuntu.pool.ntp.org iburst maxsources 2` (6 sources online, stratum 3, 0.9 ms, no `x`, no journal warning, no clock step, RTC == system time, all services active), validated by `chronyd -Q` before the mutation and with the old file moved to `/root/prechange-20261022/` rather than deleted; the filename now matches `ansible/roles/time_sync` so a future `time_sync` run converges it. (2) Fleet sweep proves the defect was **isolated to pbs01**: hv01 has 12 sources / 22 µs / no `10.10.10.50` reference; Ansible hosts take Ubuntu pools from `group_vars`. (3) **Withdrawn:** "`DatastoreBackup` + `DatastoreAudit` is enough to write but not enough to restore, so the `qmrestore` drill cannot pass" — per the published role definitions `DatastoreBackup` *does* restore owned backups (`Datastore.Backup` implies `Datastore.Read`/`Verify` for owned groups); the privilege the onboarding actually lacks is **`Datastore.Prune`** (`prune-backups` in step 6). Step 4 rewritten with both grant commands and a least-privilege alternative. (4) **Withdrawn:** §3c row 1 ("workstation has no path to VLAN 10 at all") and the §3b row-4 "two layers / nftables is not a valid single-step remedy" statement — ADR-008 measured the opposite and `ssh pbs01` is now the working admin path used for this verification | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §15; `docs/servers/pbs01.md` §Security Controls + Change History |
| 2026-10-22 (grants) | **PRODUCTION CHANGE on pbs01 (PBS access control): the `jol-hv01` namespace grant is applied, closing blocker (a) of the datastore registration.** `DatastorePowerUser` on `/datastore/pbs-store/jol-hv01` with `propagate=1` granted to `pve-backup@pbs` **and** `pve-backup@pbs!pve-token` (`acl update` rc=0 for both). Verified by read-back rather than by exit code: the token's effective privileges moved from **empty** to `Datastore.Backup (*)` + `Datastore.Prune (*)`, and the rows are in `/etc/proxmox-backup/acl.cfg` (0640 root:backup) so they survive a restart. **Reference check settled a surprise:** `user permissions` on the nightly-working `jol-llm-backup@pbs!llm-token` shows the same two-privilege shape, confirming `DatastorePowerUser` does not list Read/Verify/Audit explicitly — restore of owned groups is implied by `Datastore.Backup`. So the grant is *identical in shape to a control already proven in production*, not a guess. ⚠ **New rollback gap found and filled in §4:** PBS 4.2 `proxmox-backup-manager acl` has **no `delete`** subcommand, so unwinding a grant needs the UI (or `NoAccess`) — §4 had no phase-4 row at all before this. §3b rows 4–5 restate the remaining single blocker: `pbs01.pw` = 1 byte, so the token must be **rotated** (secret typed into the PVE form, never a shell) before `pvesm status` can go `active`. No credentials read or printed in this session | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §16 |
| 2026-10-21 | Onboarding procedure made host-agnostic after the pbs01-only CLI was pasted into the workstation shell twice (§13): PBS Web UI is now the prescribed path (Permissions and Namespaces views answer the same questions with no CLI), a `[ -x /usr/bin/proxmox-backup-manager ]` guard precedes any CLI form, the ACL option is corrected to `--auth-id`, namespace ACL paths must come from the GUI picker, and a verified self-expiring loopback tunnel via hv01 is documented as the one-off access route (recorded as an access deviation) | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §12–§13 |
| 2026-10-23 | **Alerting made self-detecting without any credential (3 layers), and §6/§7.1 corrected again.** Layer 1 = hv01 watchdog gate 13 (postfix `status=(bounced\|deferred)` count, never queue depth) → live `rc=1` "81 message(s) bounced/deferred". Layer 2 = new **pbs01 watchdog** (10 gates) installed `750 root:root` + cron `15 6 * * *`; green `rc=0` + GC WARN, forced thresholds 7 CRITICALs `rc=1`, host guard `rc=2`. Layer 3 = workstation **fleet-health pull** on a 15-min systemd user timer. Two defects caught by testing before deploy: (a) both watchdogs wrote their `HEALTH CHECK COMPLETE` marker to the log file only (`info()` never touched stdout) so the pull's gate-coverage check would have raised a **permanent false UNVERIFIED alert on both hosts**; (b) the pull's `STATE` variable was declared "for silence detection" but never used — it now reports alert age (`last OK: 37 h ago`), notifies only on **change of the alert set** (digits masked) and announces recovery, because 96 identical dialogs a day train the operator to ignore the real one. Also corrected here: §6's GC gate still told the operator to run `garbage-collection create`, **a verb that does not exist in PBS 4.2** (§7.1 had already been corrected the same evening) — GC is a datastore property (`datastore update --gc-schedule`) | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §22; host shas `34799462193c…` / `ad056ff3979e…` / `2591b5b36fdd…` |
| 2026-10-25 | **Gate 13 defect 3 fixed (repo + docs only, nothing deployed): the alert counted delivery RECORDS, not messages.** Measured live on hv01 — 14 records in the 24 h window = **3 distinct queue ids** (mail `70268321566` retried 12× plus two Gmail bounces), so the dialog said "14 message(s)" for three lost alerts. The gate now collapses to distinct queue ids, names the record total beside it, and falls back to the record count when a queue id cannot be parsed (can only over-count, never silently under-count). Fixtures → 10 cases / 11 assertions, run **both** directions: `11 passed, 0 failed` on the fix (`e6aaba5550da…`) vs `6 passed, 5 failed` on `HEAD` (`459de970e312…`, failing cases 1/4/6/9) — the controls demonstrably fail on the broken version. `shellcheck -x` clean on both files; the repo-wide CI command stays red only from pre-existing `scripts/audit/verify-basilica-*.sh` findings also on `origin/main`. **Also corrected: the §7.2 Telegram target state is impossible on this host** — `pvesh ls /cluster/notifications/endpoints` on PVE 9.2.10 offers `gotify/sendmail/smtp/webhook`, **no `telegram`** — so the fix is re-recommended as an authenticated postfix submission relay on `:465`/`:587` (both measured OPEN from hv01 while `:25` times out; new §7.3 verification checklist), which repairs both defects and keeps gate 13 + the verifier on the path alerts actually take. **Transport still dead after this change and both CRITICALs are true** (`relayhost` empty, only builtin `mail-to-root`, `/var/lib/jol-hv01/` absent, 1 mail stuck in `mailq`). ⚠ **Compliance gap flagged, not silently backfilled:** the 2026-10-23/24 watchdog deployments (a production change on two hosts) are recorded here and in evidence §22 but have **no `CHANGELOG.md` row**. No credential read, printed or handled; no production mutation in this session | this §7.2/§7.3; `scripts/maintenance/tests/test-hv01-gate13.sh`; workstation `~/.local/share/jol-fleet-health/pull.log` 2026-10-25 |
| 2026-10-31 | **§3d installed-script drift gate added; PR #117 merged so §6's "Docs + change record" gate can finally close its last clause.** (1) The §0.3 pre-change sha check on `jol-health-check.sh` found the host 42 lines behind the repo — the gate-13 rewrite of 2026-10-24/25 had never been installed — so the fleet's alert numbers were still being produced by the pre-fix code (`19 message(s)` vs the fixed `3 outward message(s) … (19 delivery records …)`). That is F-4, the same manual-deploy class as MCP M3, and §3d turns the spot check that found it into a repeatable gate with 5 rules (committed-file digest, both sides recorded, mode/owner, pbs01 + workstation counterparts, cross-host diff). (2) **§7.2's stale sha citations are marked superseded in place** (`459de970e312…` → `ec3709c993…`, issue #124) rather than rewritten, and the 2026-10-25 note "the CI command stays red from pre-existing `verify-basilica-*.sh` findings" is now closed: those SC2034/SC2317 findings were fixed by deleting the dead code (`780b3e6`), and the tree-wide command is `rc=0`. (3) **PR #117 squash-merged 2026-10-31T21:16:48Z as `fe13218`**, so the 12 commits of this thread are on `main` and issue #116's "Issue closed still requires that merge" condition is met; the merge was attempted **without** `--admin` first and refused by the required-approval ruleset, then bypassed by the repository owner — disclosed in `CHANGELOG.md` (2026-10-31T21:16:48Z row) because it overrides a CC8.1 control. Post-merge `main` CI: run `41242841101` = success, 7/7 jobs. (4) Still open in this runbook: §6 ✘ Garbage collection (§7.1, executed later tonight — see the next row if present), ✘ Off-site copy (3-2-1), ✘ Alert transport (§7.2/§7.3, `:465` relay recommendation awaiting the operator), □ Negative encryption test, □ vm/100 + vm/101 restore drills | this §3d; `CHANGELOG.md` 2026-10-31 rows; `git rev-list --count 2a9a040..caa4988` = 12; `gh pr view 117` / `gh run view 41242841101` |
| 2026-10-31 21:25Z | **§7.1 EXECUTED — garbage collection scheduled on `pbs-store` (issue #126).** `proxmox-backup-manager datastore update pbs-store --gc-schedule "sat 04:30"` rc=0 over the ADR-008 SSH path, after the documented pre-checks (no running task; baseline `garbage-collection list` schedule empty, `pending-bytes 0 B`; baseline `datastore show` = `{name,path}` only; `zfs list` 73.6 G / 2.04 T). Read-back: `schedule sat 04:30`, `next-run Sat Nov 7 04:30:00 2026` (`next-run: 1794018600` = 2026-11-07T02:30Z), `datastore show --output-format json` carries `gc-schedule`, persisted TAB-indented at `datastore.cfg:2`. **Two facts established rather than assumed:** (1) writing the schedule does **not** start a GC (`upid: null`, no new task); (2) **F-5 — pbs01 watchdog gate 3 (`pending-bytes` > 50 GiB) has been unreadable all along**: `garbage-collection status` reports the *last run's* tally, which on a datastore that has never run GC is structurally all-zero, so the gate renders "0 GiB pending" as health — an absence of measurement wearing a number, the same class as gate 10's dead branch. §6's GC gate flips ✘ → ✔ with that caveat; §7 heading updated (§7.1 executed, §7.2/§7.3 open). The chat-proposed daily `05:00` slot was **rejected** in favour of the documented `sat 04:30`, because `pbs-store-verify` runs `*-*-01 04:00` and a daily GC would have collided with tomorrow's monthly verify. Rollback: `datastore update pbs-store --delete gc-schedule`. Nothing reclaimed yet — first run 2026-11-07, and the reclaim proof is owed then | issue #126; `proxmox-backup-manager garbage-collection list` + `status pbs-store --output-format json` read back at 21:25Z; §7.1 executed record |
