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
| **Purpose**        | Intended VM backup target for pve-prod-hv01 (⚠ not yet connected — see "Pending onboarding"); active model-store backup target for llm-prod-lt01 (since 2026-08-11) |
| **SSH Policy**     | key-only                                   |
| **Backup Enabled** | n/a (IS the backup target)                 |
| **Monitoring**     | node-exporter **running but unscrapeable** — see §Monitoring reality |

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

- nftables: default deny incoming; allow 22/tcp + 8007/tcp from 10.10.10.0/24, 8007 from 10.60.60.0/24, 8007/tcp from 10.30.30.10 (llm-prod-lt01, since 2026-08-11), **and 22/tcp from `192.168.88.249/32`** — the operator workstation, added 2026-10-22 under ADR-008. This is the only SSH widening this host has ever had, and it is a single `/32`, never a segment
- ✅ chrony: **synchronised since 2026-10-22T18:54Z, re-provisioned to fleet convention at 19:04Z** (was broken — see Change History). Sources live in `/etc/chrony/conf.d/jol-sources.conf` — three `pool <zone> iburst maxsources 2` lines (`lt.pool.ntp.org`, `0.ubuntu.pool.ntp.org`, `1.ubuntu.pool.ntp.org`), i.e. the same directive form as `ansible/roles/time_sync/templates/chrony-jol.conf.j2`. ⚠ **The first revision of this fix (18:54Z, `10-jol-upstream.conf`) was under-provisioned**: it used `server lt.pool.ntp.org` + `server pool.ntp.org`, and `server` with a pool zone pins **one resolved address per line** — measured `2 sources online` out of 8 addresses DNS returned. Two sources cannot outvote a falseticker (`chronyc sources` would show it as `x` and the clock would follow it); RFC 5905 §10 and the fleet template both require ≥3, so the drop-in was rewritten and renamed to the Ansible path so a future `time_sync` run converges one file instead of stacking a second. `makestep`/`rtcsync` are deliberately **not** repeated in the drop-in: pbs01's stock `chrony.conf` already carries them (lines 39 and 35) and a duplicate `rtcsync` logs a warning. The dead `10.10.10.50` (admin01) line stays retired with a comment at `chrony.conf:48`.
  Verified after the change: `chronyc activity` → **6 sources online / 0 offline**; `chronyc tracking` → stratum 3, `System time 0.000921 s slow`, `Root delay 54 ms`, `Leap status Normal`, no source flagged `x`; `timedatectl` → `synchronized: yes`, `NTP service: active`; RTC == system time to the second (`hwclock -u -r` 19:05:53 vs `date -u` 19:05:54) so it is **reboot-safe** via `rtcsync`; `journalctl -u chrony -p warning` → *No entries*; chrony/proxmox-backup/fail2ban/nftables/auditd/smartd all `active`; `datastore list` normal; **no clock step** on this restart (offset was already sub-second, so no new audit-timestamp discontinuity). Rollback artifact: `pbs01:/root/prechange-20261022/10-jol-upstream.conf.bak` (+ `.removed`).
  **Fleet sweep (root-cause elimination, measured not assumed): pbs01 was the only host still carrying the admin01 dependency.** pve-prod-hv01 measured 12 sources online / stratum 3 / `System time 0.000022 s fast` / `synchronized: yes` on stock `pool N.debian.pool.ntp.org` with **no** `10.10.10.50` anywhere in `/etc/chrony`; the Ansible-managed hosts take `time_sync_servers` from `group_vars/{ai_services,llm}.yml` (Ubuntu pools). prox01 ⚠ UNVERIFIED — no SSH path from the workstation. The prior claim "NTP synchronisation via 10.10.10.50 (Stratum 3 local peer)" described a peer that was not there
- smartd: active, disk health monitoring
- auditd: active (SOC2/ISO 27001 rules — auth, identity, PBS config, cron, firewall, privileged exec)
- TLS: self-signed RSA-4096 (CN=pbs01.jol.lan), fingerprint pinned on PVE

## Admin SSH Path — Verified Matrix and Decision (2026-10-22)

> ✅ **STATUS: executed and verified 2026-10-22 (ADR-008 Option B).** `tcp dport 22 ip saddr
> 192.168.88.249/32 accept` is live in `/etc/nftables.conf` (line 25) and in the running ruleset, and
> `ssh root@10.10.10.30 hostname` from the workstation returns `pbs01` with key-only auth on the first
> attempt. Verified unchanged by the reload: all four original `accept` rules plus ICMP/ICMPv6 (`accept`
> count 9 → 10 = exactly +1), `nftables.service` still `enabled`, `sshd -T` still
> `passwordauthentication no` / `permitrootlogin without-password` / `allowusers root` / `maxauthtries 3`,
> fail2ban `ignoreip` still `127.0.0.0/8, 10.10.10.0/24` (the workstation is deliberately **bannable** —
> it is not a data-path source), `hv01 → pbs01:8007` still OPEN, ACL table unchanged. Pre-change backup
> `pbs01:/root/prechange-20261022/`; dead-man rollback timer disarmed after verification. Evidence:
> `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt`. Option A (VLAN 10 L2 membership) was **not**
> executed — retained there only as a contingency.

Re-probed from the operator workstation and from pve-prod-hv01 with SYN-only connects
(no auth attempt is ever sent, so the fail2ban SSH jail cannot be tripped):

| Source | Address | :22 | :8007 | Reading |
|--------|---------|-----|-------|---------|
| workstation `ubuntu` | 192.168.88.249 (MikroTik `defconf` bridge) | `rc=124` timeout | `rc=124` timeout | ⚠ **corrected 2026-10-22**: this does NOT mean "no VLAN 10 route". The workstation reaches `10.10.10.2:80/:23`, `10.10.10.11:443` and answers ICMP on pbs01 — the router forwards `defconf → vlan10`. Both pbs01 ports are refused by the **host** rules below, which have no `192.168.88.0/24` accept |
| pve-prod-hv01 | 10.60.60.20 (holds **0** addresses in `10.10.10.0/24`; `ip route get 10.10.10.30` → `via 10.60.60.1 src 10.60.60.20`) | `rc=124` timeout | OPEN (GUI 200, unauthenticated API 401) | routed; the *same* path accepts 8007 and drops 22 |
| admin01 — the designed source | 10.10.10.50 | no TCP | no ICMP | host is off the network |

**Judgement (revised 2026-10-22 by measurement): the host rule is the ONLY blocker for the operator
workstation, so a single scoped `/32` accept on pbs01 is sufficient — one device, one line.** Do not widen
`22/tcp` to a *segment*. The accepted change and its gates are
`docs/runbooks/pbs01-admin-ssh-access.md` (Option B); Option A (VLAN 10 L2 membership) is downgraded there
because the L3 path already exists. What is **withdrawn** from the first revision of this section is the
claim that the router also blocks the workstation — see the layer analysis below.

1. **MikroTik inter-VLAN forward matrix** — **measured 2026-10-22: does not block `defconf → vlan10`.**
   The `vlan60 → vlan10:8007`-only summary in `docs/network/vlan-audit-2026-08-29.md` §2 describes the
   **VLAN-60** source and was wrongly generalised to the workstation's bridge. Proof it does not apply
   here: `10.10.10.2:80/:23` (switch) and `10.10.10.11:443` (iDRAC) answer from `192.168.88.249`, and
   pbs01 answers ICMP. Source addresses are preserved — hv01's `ss -tn` lists this operator's session as
   peer `192.168.88.249:43588`, **not** the router — so there is no inter-VLAN masquerade and a `/32`
   source rule on pbs01 can actually match. `/ip firewall filter print` is still owed for the record.
2. **pbs01 host nftables** — `22/tcp` from `10.10.10.0/24` only (this file,
   §Security Controls). **This is the binding layer for every source tested from here.**

Which layer drops first **was undecidable from the probes alone** — and is now settled for the host layer.
Captured 2026-10-22 from a root shell obtained through the PBS Web UI xterm.js console (the UI is reachable
over the permitted 8007 path, so the evidence was gathered without SSH, which is the blocked resource):

```nft
type filter hook input priority filter; policy drop;
tcp dport 22   ip saddr 10.10.10.0/24  accept      # ← the ONLY SSH allowance
tcp dport 8007 ip saddr 10.10.10.0/24  accept
tcp dport 8007 ip saddr 10.60.60.0/24  accept      # ← hv01 backup data path
tcp dport 8007 ip saddr 10.30.30.10    accept      # ← llm-prod-lt01 backup data path
```

**Correction to the judgement above:** this capture proves the **host** nftables is itself a binding layer —
`policy drop` plus no accept for `10.60.60.0/24 → :22` blocks hv01 regardless of what the router does. The
earlier statement that pbs01's rule was "not proven to be the binding layer" is withdrawn. It is also the
**only** binding layer for the workstation: since the router forwards `defconf → vlan10` with the source
intact, one `/32` accept line on pbs01 is sufficient and no router change is required. (For `hv01` the two
layers would still be independent and each sufficient — that path is deliberately left blocked.) The router
side is ⚠ still uncaptured (`/ip firewall filter print` outstanding) but is no longer load-bearing for this
change. Pre-change capture on pbs01:
`/root/prechange-20261022/pbs01-nft.txt` + `etc-pbs.tar.gz` (mode 600).

Why widening to a shared segment is the wrong fix even if it *would* work (this argument is about
`10.60.60.0/24` / `192.168.88.0/24`-style widening, **not** about the scoped options in the runbook):

- **Backup-plane segregation is the point of the rule.** pbs01 holds the only off-VM
  copies of VMIDs 100/101/102 and the `jol-llm` model store. Those VMs run on hv01 and
  the MCP VM has internet egress. Routing `22/tcp` from `10.60.60.0/24` hands every
  workload on the hypervisor — and anything that later compromises one — a network path
  to **root SSH on the box holding their own backups**: the "delete the backups, then
  encrypt" sequence. ISO 27001 A.8.13/A.8.20, SOC 2 CC6.6.
- **fail2ban would then be able to ban the backup path.** The SSH jail bans 24 h with
  `ignoreip 10.10.10.0/24` only. Allow SSH from `10.60.60.0/24` and the tunnel source
  `10.60.60.20` — the address that must reach `8007` for every backup *and* restore —
  becomes bannable, so one mistyped password becomes a 24 h backup outage; adding it to
  `ignoreip` instead removes brute-force protection from that very path. The existing
  acceptance gate in `docs/runbooks/hv01-storage-backup-reconfiguration.md` §6 already
  forbids this ("fail2ban must never be able to ban a backup-path source").
- **It is a cross-VLAN trust-boundary change** → AGENTS.md §1 Dependency Rules 3 requires
  an ADR plus a §0.3 change request with rollback, not an ad-hoc rule edit at a keyboard.

Compliant paths, in preference order:

| Need | Path |
|------|------|
| Namespace / ACL / user / token admin (the actual pending task) | **PBS Web UI over the loopback tunnel via hv01** — zero firewall change: `timeout 900 ssh -f -N -L 127.0.0.1:8444:10.10.10.30:8007 jol-admin@10.60.60.20` → https://localhost:8444 (re-verified live 2026-10-22: GUI `200`, unauthenticated API `401`). Loopback-bound, self-expiring, record as an access deviation, close after use. |
| OS-level work on pbs01 (`nft list ruleset`, `/etc` edits, package/kernel) | **Physical console** on the P4500 — no IPMI exists (§Risk Acceptance). |
| A durable SSH admin path | **One `/32` accept on pbs01 for the workstation** (`tcp dport 22 ip saddr 192.168.88.249/32 accept`), applied as a file edit with `nft check` + a 5-minute `systemd-run` dead-man rollback, and **not** added to fail2ban `ignoreip`. The router already forwards this path with the source intact, so no other device changes. Requires ADR-008 (cross-VLAN, AGENTS.md §1 rule 3) and a DHCP reservation so the `/32` cannot rot. Full package: `docs/runbooks/pbs01-admin-ssh-access.md` §3. The older recommendation — put the workstation inside VLAN 10 on its unused `enp9s0` — is retained there as Option A but downgraded: it needs a physical cable trace and a switch-port change to reach the whole management VLAN when one peer is all that is wanted. admin01 (`10.10.10.50`) remains dead and is also pbs01's documented chrony peer — see the NTP finding below. |

> ⚠ **Credential custody, corrected 2026-10-22.** The operator **did** authenticate to the PBS UI as
> `root@pam` through the 8444 tunnel and opened its root shell, so the pbs01 root password is in hand —
> the earlier "unreachable vault ⇒ pbs01 unadministrable ⇒ offline root reset required" conclusion is
> withdrawn. What is **not** resolved is custody: the vault showed *"No items in the vault"*, so the
> working password exists only in the operator's memory. The ACL question is now **answered by read-back**
> (2026-10-22, `proxmox-backup-manager acl list` + `user permissions`): `pve-backup@pbs` exists and holds
> `DatastoreBackup` + `DatastoreAudit` on `/datastore/pbs-store` (`propagate=1`); the token
> `pve-backup@pbs!pve-token` **exists and is enabled** (`expire=never`) but carries **zero ACL rows of its
> own**, and `user permissions` on it returns an empty list — the earlier "it may not exist" hedge is
> withdrawn. Token privileges are the intersection of the token's own rows with the parent user's, so the
> grant must be written for **both** auth-ids. **Update 2026-10-22T20:06Z: that grant is applied** —
> `DatastorePowerUser` on `/datastore/pbs-store/jol-hv01` (`propagate=1`) for `pve-backup@pbs` and
> `pve-backup@pbs!pve-token`; `user permissions` on the token now returns `Datastore.Backup (*)` +
> `Datastore.Prune (*)` (identical in shape to the nightly-working `llm-token`), persisted in
> `/etc/proxmox-backup/acl.cfg`. Evidence §16. What remains custody-only: the token **secret** (rotate it,
> type the one-time value into the PVE storage form). Token secrets are shown once and cannot be re-read, so
> mint a fresh one rather than hunt for the old. That is a credential-custody defect, not a firewall
> problem: no amount of nftables widening logs you into PBS.

> ⚠ **Port `8443` is unusable for the PBS tunnel on this workstation.** The Vaultwarden
> TLS front door binds `127.0.0.1:8443` permanently
> (`scripts/maintenance/vaultwarden-tls-frontdoor.sh`, `HTTPS_PORT=8443`; landed by the
> 2026-10-22T12:10Z change), verified `LISTEN 127.0.0.1:8443` on 2026-10-22. Earlier
> revisions of this file and the runbook prescribed `8443`; following them now fails
> with `bind: Address already in use` — a *local* error that reads like "pbs01 is
> unreachable" and is exactly how a firewall gets widened on a false premise. Use
> `8444`, and check first: `ss -tln | grep -E '8443|8444'`.

## Network Notes

- Gateway 10.10.10.1 (MikroTik VLAN 10) — **operational** via static ARP entry
- Dell N2048 firmware bug: broadcast flooding fails on trunk Gi1/0/48 for VLAN 10
- Workaround: permanent ARP entry `10.10.10.1 → D0:EA:11:4B:67:A0` on nic0
- Internet routing: functional for APT, DNS **and NTP** (all verified 2026-10-22 — NTP only became true
  after the chrony fix; until then this line was false for NTP because the sole configured peer was the
  offline admin01, leaving the clock +65.657 s fast). The failure was a dead source, not the path

## Backup Policy (as target)

- ⚠ **Correction (verified 2026-10-21)**: this document previously stated that pbs01
  "receives nightly VM backups from pve-prod-hv01". It does not. pve-prod-hv01 has
  no PBS datastore registered (`/etc/pve/priv/storage/` absent, `storage.cfg` has
  only `local`, `local-lvm`, `hdd-iso`) and its only backup job is rejected by the
  scheduler parser. Evidence:
  `docs/compliance/evidence/hv01-storage-inspection-20261021.txt`. Expect zero
  backup groups for VMIDs 100/101/102 until the onboarding below is executed.
- Intended VM backups from pve-prod-hv01: namespace `jol-hv01`, groups `vm/100`,
  `vm/101`, `vm/102` — one job, VMs dumped serially inside the 02:00 window
- Intended host-evidence push from pve-prod-hv01: group `host/pve-prod-hv01`,
  `hv01-archive.pxar`, 03:45 UTC (after the 03:00 prune and the 03:15 llm push)
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

## Pending onboarding: pve-prod-hv01 — opened 2026-10-21

Blocked on operator secret custody: the `pve-backup@pbs!pve-token` secret lives in
the password manager and must be typed into the **PVE Web UI** datastore form, never
into a CLI (`pvesm add pbs --password …` exposes it in argv and shell history —
AGENTS.md §0.1). Step 1 is done in the **PBS Web UI through a session-limited
loopback tunnel** via pve-prod-hv01: `timeout 900 ssh -f -N -L
127.0.0.1:8444:10.10.10.30:8007 <user>@10.60.60.20` → `https://localhost:8444`
(**not** `8443` — the Vaultwarden TLS front door owns it; see §Admin SSH Path).
There is **no shell path yet**: `10.10.10.30:22` is refused for this workstation and for
pve-prod-hv01 by pbs01's own input rules (`policy drop`, SSH from `10.10.10.0/24` only —
captured 2026-10-22, see §Admin SSH Path), while `:8007` is open from `10.60.60.0/24` — which
is also why the backup data path itself is healthy. The router is **not** an obstacle for the
workstation (measured: `defconf → vlan10` forwards with the source preserved), so §Admin SSH
Path records the accepted fix: one scoped `/32` accept on pbs01 per
`docs/runbooks/pbs01-admin-ssh-access.md` Option B.
The `root` credential for that UI is held in the on-prem Vaultwarden, which runs **on
the operator workstation** (container `jol-vaultwarden`, `127.0.0.1:8090`), not on
admin01 — `docs/architecture/secret-flow.md` named the wrong host and was corrected
2026-10-22; see `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §22.
Full plan: `docs/runbooks/hv01-storage-backup-reconfiguration.md`.

1. Establish what is already granted — **in the PBS Web UI**, not a shell.
   Configuration → Access Control → Permissions lists every path / role / auth-id triple (or run
   `proxmox-backup-manager acl list` from the UI shell — it takes **no** path argument and **no**
   `--auth-id` filter in 4.2; pipe it to `grep`). Facts that make the UI the only option:
   - **Login identity:** User name `root`, Realm “Linux PAM standard authentication”,
     pbs01 root password from the password manager (Vaultwarden on the workstation,
     `http://127.0.0.1:8090` — retrieve it there; note the password was rotated on
     2026-08-01, so any earlier one fails by design). `jol-admin` is **not** a PBS
     principal (the only PBS-realm accounts are the backup service principals
     `pve-backup@pbs` and `jol-llm-backup@pbs`, which have no UI rights), so that
     login fails by design.
   - **Do not retry passwords blindly.** pbs01 runs fail2ban (3 retries → 24 h ban,
     `ignoreip 10.10.10.0/24`). Reached through a hv01 tunnel the apparent source is
     **10.60.60.20**, i.e. the address that must reach 8007 for backups and restores —
     a ban would turn a login typo into an outage of the backup path.
   - **SSH is unavailable from everywhere reachable here** (transport-verified,
     not inferred): from hv01, TCP 22 to 10.10.10.30 times out with zero banner bytes
     (`rc=124`, a DROP) while TCP 8007 connects instantly; admin01 (`10.10.10.50`,
     the documented jump host) returns `No route to host` from the workstation.
     Remaining shells: the pbs01 physical console, or a one-off loopback tunnel
     `timeout 900 ssh -f -N -L 127.0.0.1:8444:10.10.10.30:8007 <user>@10.60.60.20`
     → `https://localhost:8444` (verified 2026-10-21 on `8443`, re-verified 2026-10-22 on
     `8444`: GUI 200, unauthenticated API 401; self-expiring; record it as an access
     deviation and close it after use). `8443` is no longer usable here — the
     Vaultwarden TLS front door binds it.
   - **Withdrawn approach:** capturing the token secret into a file on hv01 with
     `read -rs` and probing with `proxmox-backup-client list`. Two attempts on
     2026-10-21 stored pasted command text instead of the secret (measured: 43 bytes,
     then 113 bytes with 34 stray characters), each yielding a misleading
     `authentication failed`; both files were truncated to 0 bytes. **The PVE Add
     Storage form (step 3) is the only place a secret is ever typed**, and phase 7
     reuses PVE's own stored credential (`/etc/pve/priv/storage/pbs01.pw`, 0600 root)
     instead of a second copy.
   Decision rule — **answered by read-back on 2026-10-22, do not re-open it**: `pve-backup@pbs` holds
   `DatastoreBackup` + `DatastoreAudit` (propagate), **not** `DatastorePowerUser`, and the token has no
   rows at all, so step 2 **cannot** be skipped. ⚠ **Corrected against the PBS role definitions**
   (`pbs.proxmox.com/docs/user-management.html`): `DatastoreBackup` = "can backup and restore **owned**
   backups" and `Datastore.Backup` also implies `Datastore.Read` + `Datastore.Verify` for a group the user
   (or its tokens) owns — so the earlier "Backup+Audit is enough to write but **not** to restore" reasoning
   was wrong. The privilege actually missing for this onboarding is **`Datastore.Prune`**, because the PVE
   job is specified with `prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6` and pruning is what
   `DatastorePowerUser` adds over `DatastoreBackup`. Grant `DatastorePowerUser` therefore (it matches the
   `jol-llm` precedent), or, if the nightly `pbs-store-prune` job stays the sole pruner, the tighter
   `DatastoreBackup` + `DatastoreReader` pair is sufficient — record which one was chosen.
2. ACL grant — ✅ **APPLIED 2026-10-22T20:06Z** (`acl update ... DatastorePowerUser --auth-id ...` for both
   auth-ids, rc=0; read-back in evidence §16). ⚠ **PBS 4.2 `proxmox-backup-manager acl` has no `delete`
   subcommand** — unwinding a grant needs the UI (Access Control → Permissions → Remove) or
   `acl update <path> NoAccess --auth-id <id>`.
   The manual path, for future grants: **use the PBS Web UI as `root@pam`** (Configuration → Access Control → Permissions → Add).
   ⚠ **Corrected 2026-10-22 against the live 4.2 UI: there is NO "Namespaces" tab.** The datastore page
   offers only Summary / Content / Prune & GC Jobs / Sync Jobs / Verify Jobs / Options / Permissions, and
   ⚠ **"a namespace is created automatically by the first successful backup" — FALSIFIED 2026-10-22T20:40Z.**
   The first `vzdump` failed with `backup connect failed: command error: namespace not found`, so
   **pre-creation IS a required step**, and this doc's own `jol-llm` entry already said so ("Namespace
   `jol-llm` created (directory-based …)") — the two statements contradicted each other and the wrong one
   was repeated in the runbook. There is no CLI (`proxmox-backup-manager namespace` → *no such command*, and
   so is `snapshot`) and the REST route needs an admin ticket, so create it as root on the host by mirroring
   the working namespace exactly:
   ```bash
   stat -c "%n %a %U:%G" /backup-pool/pbs-store/ns/jol-llm      # → 750 backup:backup (source of truth)
   install -d -o backup -g backup -m 750 /backup-pool/pbs-store/ns/jol-hv01
   ```
   Proven: after that single `install -d`, `vzdump` succeeded and `ns/jol-hv01/vm/{100,101,102}/<date>` exist.
   Rollback is `rmdir` while the namespace is empty. Never satisfy the requirement via *Add: Datastore*
   (that would nest a second datastore inside `/backup-pool/pbs-store` and let two datastores prune
   overlapping ZFS trees).
   **Permissions may be granted on a still-absent namespace path**, so grant on
   `/datastore/pbs-store/jol-hv01` directly; the row appearing in `acl list` before the directory exists
   is expected, not an inert grant. A genuinely *wrong* path string is still the failure class to avoid —
   verify by reading the row back rather than by trusting the typed literal.
   CLI equivalents, for the record (syntax verified against the PBS 4.2 User
   Management docs — the option is **`--auth-id`**, *not* `--userid`):
   ```bash
   proxmox-backup-manager acl update <the-path-the-GUI-shows> DatastorePowerUser --auth-id 'pve-backup@pbs'
   proxmox-backup-manager acl update <the-path-the-GUI-shows> DatastorePowerUser --auth-id 'pve-backup@pbs!pve-token'
   # token privileges are always intersected with the parent user's — both needed
   ```
   Manual directory (only if the GUI is unavailable; must run as root **on pbs01**,
   matching the `jol-llm` precedent — owner `backup:backup`, mode 750):
   ```bash
   install -d -m 750 -o backup -g backup /backup-pool/pbs-store/ns/jol-hv01
   ```
   Verify after granting:
   ```bash
   proxmox-backup-manager acl list | grep -E 'pve-backup|jol-hv01'   # no path arg, no --auth-id in 4.2
   proxmox-backup-manager user list-tokens pve-backup@pbs            # NOT "user token list"
   ls -ld /backup-pool/pbs-store/ns/*   # jol-hv01 appears only AFTER the first successful backup
   ```
   ⚠ Both CLI forms are pbs01-only: pasting them into the workstation shell fails with
   `install: cannot create directory '/backup-pool'` and
   `proxmox-backup-manager: command not found` (observed twice on 2026-10-21) — see
   step 1 for why no remote shell to pbs01 exists.
3. Register the datastore on pve-prod-hv01. Either the Web UI (datacenter →
   pve-prod-hv01 → Storage → Add → Proxmox Backup Server) or CLI. Three facts were
   established empirically on 2026-10-21 and they change the procedure:
   - **Content must be `backup`, not `images`** — `PBSPlugin::plugindata` allows only
     `backup`/`none`. An earlier draft of this page said "Disk images"; that would
     have produced a storage vzdump refuses to use.
   - **`pvesm add pbs` validates credentials at creation time** (`error fetching
     datastores - 401 Unauthorized`), and `pvesm`/`pvesh` accept the password only as
     a command-line argument. So a secret-safe CLI registration must add the storage
     **disabled**, deliver the secret over stdin, and only then enable it.
   - **`/etc/pve/priv/storage/` does not exist until the first PBS storage** and PVE
     does not create it for `--encryption-key autogen`
     (`failed to create encryption key: Unable to store key file … No such file or
     directory`). `mkdir -m 700 /etc/pve/priv/storage` first. Cosmetic PVE defect
     observed alongside: `Use of uninitialized value $password … PBSPlugin.pm line 728`.
   Working sequence (executed 2026-10-21; nothing is enabled until the credential lands):
   ```bash
   # as root on hv01 — no secret on any command line
   mkdir -m 700 -p /etc/pve/priv/storage
   pvesm add pbs pbs01 --server 10.10.10.30 --datastore pbs-store \
     --username 'pve-backup@pbs!pve-token' --namespace jol-hv01 \
     --content backup --fingerprint <sha256-hex> --disable 1
   pvesm set pbs01 --encryption-key autogen        # writes pbs01.enc, 600, kdf:null
   # the operator delivers the token secret over stdin (never argv/ps/history):
   #   read -rs S; printf '%s' "$S" | ssh hv01 'sudo tee /etc/pve/priv/storage/pbs01.pw'
   pvesm set pbs01 --disable 0                     # now the connection test can pass
   ```
   Fingerprint `4B:93:A9:7E:0B:9A:89:EE:1A:9F:64:2C:40:E1:8F:3A:4A:91:92:D4:29:ED:F5:A6:1B:1D:B3:26:E6:4C:54:92`
   — **verified live from hv01 on 2026-10-21**, independent of this document
   (`CN=pbs01.jol.lan`, notBefore 2026-07-04, notAfter 3025-11-04). Never disable the
   fingerprint check to make an error disappear.
   ⚠ **Escrow `/etc/pve/priv/storage/pbs01.enc` off-host before the first backup**
   (client-side encryption: without this key the backups are unreadable, and PBS alone
   cannot recover them). Copy it into the password manager from a terminal you are
   looking at — it must never be pasted into chat, a ticket, or a command argument.
   Reading the result: `pvesm status` shows `pbs01 … active` and
   `pvesh get /nodes/<node>/storage/pbs01/status` returns usage ⇒ credential and
   namespace valid. ⚠ **`401` has TWO independent causes here, corrected 2026-10-22 by direct
   measurement** — the earlier "token wrong/disabled/never created" line was incomplete:
   (a) **the token has no privileges at all.** `user list-tokens pve-backup@pbs` shows
   `pve-token` exists, `enable=1`, `expire=never`, but `acl list | grep -c pve-token` → **0** and
   `user permissions 'pve-backup@pbs!pve-token'` returns an **empty** privilege list. PBS tokens do
   **not** inherit the parent user's grants; a token needs its own ACL rows (which are then capped by
   the user's). So a correctly typed secret would **also** have returned 401. Fix = grant the token
   explicitly, not just retype the secret.
   (b) the secret itself: `pbs01.pw` is 1 byte and the original token secret is unrecoverable (shown
   once, vault empty) → **rotate** the token as part of the grant. `namespace … does not exist` /
   `permission denied` ⇒ the grant landed but the namespace path or scope is wrong — see step 2.
4. On pve-prod-hv01 — replace the inert hand-written job with an API-created one.
   The existing `job-vm100-nightly` section never ran because its option lines lack
   the leading TAB that PVE's `jobs.cfg` serialisation requires (`cat -A` proof in
   `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` §8). Prefer the
   scripted path, which gates on step 3 and re-verifies registration:
   ```bash
   sudo DRY_RUN=1 ./hv01-backup-onboard.sh      # preview
   sudo DRY_RUN=0 TEST_VZDUMP=1 ./hv01-backup-onboard.sh
   ```
   Equivalent manual commands (parameter names read from the live PVE 9 schema —
   `id` not `sid`, `comment` not `notes`, and `schedule` is a **pve-calendar-event**,
   i.e. systemd style: `02:00`; a legacy 5-field cron string is not what PVE writes):
   ```bash
   pvesh delete /cluster/backup/job-vm100-nightly
   pvesh create /cluster/backup --id hv01-nightly-pbs --schedule "02:00" \
     --storage pbs01 --mode snapshot --compress zstd --enabled 1 --repeat-missed 1 \
     --vmid 100 --vmid 101 --vmid 102 \
     --prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6 \
     --mailnotification failure --comment "hv01 AI estate nightly -> pbs01 ns jol-hv01"
   pvesh get /cluster/backup/hv01-nightly-pbs --output-format yaml  # must exist
   pvesh get /cluster/next-run | grep -i vzdump                    # must be scheduled
   ```
   Note `mailnotification` is deprecated in PVE 9 in favour of notification
   targets/matchers — until a target exists, failure mail goes nowhere, which is why
   watchdog gate 9/10 (registry + task-log agreement) is the real detection layer.
5. Gates: one manual `vzdump 100 --storage pbs01`, `pbs list` on pbs01 shows
   `vm/100`/`vm/101`/`vm/102` under `jol-hv01`, negative encryption test (restore
   without key fails), and a `qmrestore` drill to scratch VMID 199 with the NIC
   detached. Evidence to `docs/compliance/evidence/`.
6. Capacity: 3 VMs at ~14 GB first full + incremental, retention 7/4/6 ⇒ projected
   well under 500 GB against 3.27 TB RAIDZ2 (currently holds the 22 GB `jol-llm`
   archive). Alert at 80 % — ZFS needs headroom for GC and `pbs-store-verify`.
   `proxmox-backup-client` is already installed on pve-prod-hv01 (verified 2026-10-21),
   so the evidence push needs no package install.
7. Still open after this onboarding: remote sync to a second site (`pbs-jol01`) —
   without it the 3-2-1 "one off-site" leg is unmet; VLAN 85 `nic2` uncabled
   (decision D6), so backup traffic shares the management VLAN.

## Monitoring reality (corrected 2026-10-22)

The header previously asserted "active (node-exporter :9100)". Measured from the pbs01 root shell:

```text
systemctl is-active prometheus-node-exporter → active
ss -tln | grep 9100                          → LISTEN *:9100        (all three NICs)
grep -c 9100 <nft list ruleset capture>      → 0                    (no accept rule)
```

So the exporter runs but **nothing can scrape it**: the input chain is `policy drop` with no `9100` accept,
and the only documented fleet Prometheus ran **on admin01** (`docs/runbooks/llm-prod-lt01-deployment.md`
§"Fleet Prometheus (`jol-prometheus` … admin01)") — the box now off the network. VM 204
`jol-observ-pilot-lt01` is planned, its gate is ⚠ UNVERIFIED.
**Deliberately NOT fixed by opening 9100**: adding an accept rule for a scraper that does not exist buys
attack surface for zero monitoring. Correct sequence is stand up the collector, then open `9100` to that
one source. Compliance impact meanwhile: SOC 2 CC7.2 and ISO A.8.16 monitoring evidence for pbs01 is
absent, not merely untested. Side note: `*:9100` on a box with a VLAN 70 (iSCSI) NIC is contained only by
nftables — consider `--web.listen-address=127.0.0.1:9100` or a nic0 bind if a collector is never deployed.

## Change History

| Date | Change | Evidence |
|------|--------|----------|
| 2026-08-01 | First audit: P0/P1/P2 hardening, prune+verify jobs, `pve-backup@pbs` user/token created; "PVE client config" explicitly left outstanding | this file, First Audit section |
| 2026-08-11 | llm-prod-lt01 model store onboarded (ns `jol-llm`, 8007/tcp opened for 10.30.30.10, restore drill PASS) | `docs/servers/llm-prod-lt01.md`, `scripts/maintenance/backup-ollama-models.sh` |
| 2026-10-21 | Corrected the false claim that pbs01 receives nightly VM backups from pve-prod-hv01 (it does not: no datastore on the client). Added the pending-onboarding procedure for `jol-hv01`. No change executed on pbs01 in this session — pbs01 (10.10.10.30) is not reachable from the workstation and its SSH path via hv01 is not authorised, so steps 1–7 above are ⚠ UNVERIFIED until the operator runs them | `docs/compliance/evidence/hv01-storage-inspection-20261021.txt` |
| 2026-10-22 | **Admin SSH path evidence captured from the UI root shell, and three doc defects corrected.** (1) `nft list ruleset` captured verbatim (prechange dir `/root/prechange-20261022/`): `policy drop` + `tcp dport 22 ip saddr 10.10.10.0/24 accept` proves the **host** is independently binding for `:22` — my earlier "pbs01's nftables not proven to be the binding layer" statement is **withdrawn**; the router remains ⚠ UNVERIFIED and both layers are each sufficient, so a one-sided change still buys nothing. (2) `fail2ban-client get sshd ignoreip` → `127.0.0.0/8, 10.10.10.0/24`, 0 failed / 0 banned — confirms widening `:22` to any backup-path source would make that source bannable; the workstation is **not** such a source, which is what makes a scoped admin path defensible while `10.60.60.0/24` is not. (3) **Recommendation for the operator's "enable SSH" task: do not widen — join VLAN 10 L2 on the workstation's unused, already-linked `enp9s0`** (zero firewall change, no ADR); full package in `docs/runbooks/pbs01-admin-ssh-access.md`. (4) CLI syntax corrected against the live host: `acl list` accepts **no** path argument and **no** `--auth-id` filter (it errored `got additional arguments`), tokens are `user list-tokens` / `user generate-token`. (5) **No "Namespaces" tab exists in PBS 4.2** and a namespace is auto-created on first backup, while ACLs may be pre-granted on an absent path — step 2 rewritten; the operator had opened *Add: Datastore* from my wrong instruction and cancelled before creating anything. (6) "Monitoring: active (node-exporter :9100)" retired → exporter is active and bound `*:9100` but has no firewall accept and no live scraper (Prometheus lived on the offline admin01); recorded as a CC7.2/A.8.16 gap, deliberately **not** fixed by opening a port. (7) Credential custody corrected: `root@pam` login succeeded, so the password is in hand but uncustodied (vault empty), and `pve-backup@pbs` has **no token ACL row** | `/root/prechange-20261022/pbs01-nft.txt`; probes + UI shell 2026-10-22 |
| 2026-10-22 | Admin SSH path re-probed after the "SSH is blocked by the nftables `10.10.10.0/24` rule" premise was raised: **premise not supported as a sole cause**. SYN-only probes show the workstation (192.168.88.249, `defconf` bridge) times out on **every** pbs01 port including `8007`, hv01 (10.60.60.20, no `10.10.10.0/24` address) gets `8007` OPEN / `22` DROP over the identical routed path, and admin01 (10.10.10.50, the designed SSH source) answers nothing at all. The documented MikroTik rule `vlan60 → vlan10:8007` alone explains the hv01 result, so pbs01's nftables is not proven to be the binding layer and widening it would buy no access. **Decision: do not widen** `22/tcp` — backup-plane segregation (A.8.13/A.8.20) plus the fail2ban self-ban hazard for `10.60.60.20`, the source that must reach `8007` for all backups and restores, which runbook §6 already forbids; cross-VLAN change would need an ADR (§1 rule 3). Compliant routes recorded: PBS UI over the loopback tunnel (admin plane, no change), physical console (OS level), restore admin01 with the N2048 VLAN-10 permanent-ARP workaround (durable SSH). **Doc defect fixed:** the prescribed tunnel port `8443` has been bound by the Vaultwarden TLS front door since the 2026-10-22T12:10Z change, so the documented command failed `bind: Address already in use` — corrected to `8444` here and in `docs/runbooks/hv01-storage-backup-reconfiguration.md` §3 step 4 / §3b. No firewall change on any device; no credentials handled | this file §Admin SSH Path; probes 2026-10-22 (workstation + hv01, SYN-only) |
| 2026-10-22 (chrony) | **HIGH finding closed: pbs01 had no working time source.** Sole chrony peer was `server 10.10.10.50 iburst` = the offline admin01 (`Reach 0`, `Reference ID 00000000`, `Ref time 1970-01-01`, `System clock synchronized: no`), and the clock measured **+65.657 s fast** via one-shot `chronyd -Q "server lt.pool.ntp.org iburst"` — which also proved NTP egress worked, so this was a dead-source defect the docs had recorded as "NTP synchronisation via 10.10.10.50 … working". **Fix:** drop-in `/etc/chrony/conf.d/10-jol-upstream.conf` (lt.pool.ntp.org + pool.ntp.org, iburst), dead line replaced by a retirement comment at `chrony.conf:48`, backup at `/root/prechange-20261022/chrony.conf.bak`, `systemctl restart chrony` (resets the `makestep 1 3` budget so the ~65 s step applied immediately rather than slewing for ~37 h). **Verified:** stratum 3, offset 0.4 ms, `synchronized: yes`, `^* b14.vu.lt` + `^- host.ostkom.lv`, dead peer gone; **reboot-safe** — `rtcsync` is set and `hwclock -u -r` equals `date -u` to the second; chrony/proxmox-backup/fail2ban/nftables/auditd/smartd all still `active` and `datastore list` healthy. ⚠ Recorded for auditors: `audit.log` timestamps are **non-monotonic across ~18:37–18:54Z** because the clock stepped backward — expected, not tampering. **Second finding raised:** the hv01 `401` is not only a missing secret — `pve-backup@pbs!pve-token` exists and is enabled but has **zero ACL rows**, and PBS tokens do not inherit their parent's privileges, so a correctly typed secret would still 401; step 3's diagnosis rewritten. Self-correction: the `sed` used to retire the peer contained a second no-op expression (self-referential) — harmless, and the intended substitution did land, but it should not have been in the block | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §13–§14 |
| 2026-10-22 (final) | **ADR-008 Option B EXECUTED AND VERIFIED — pbs01 is now SSH-reachable from the operator workstation, and the premise that blocked this for two sessions was retired.** Added `tcp dport 22 ip saddr 192.168.88.249/32 accept` to `/etc/nftables.conf` behind `nft -c -f` syntax gate + a 5-min `systemd-run` dead-man (disarmed after verify). **Why one line was enough:** measurement falsified the router-blocking theory — `10.10.10.2:80/:23`, `10.10.10.11:443` and ICMP to pbs01 all answer from `192.168.88.249`, and hv01 `ss -tn` shows peer `192.168.88.249` (no inter-VLAN masquerade), so pbs01's host rule was the sole blocker; my two earlier judgements ("do not widen, the router blocks too" and "join VLAN 10 at L2 instead") are **withdrawn** as over-inference from a `:8007` timeout that pbs01 refused anyway. Post-change verification over the new path: ruleset intact (`accept` 9→10, icmp/icmp6 + all four original accepts present), `nftables` `enabled`, `sshd -T` key-only unchanged (`passwordauthentication no`, `permitrootlogin without-password`, `allowusers root`, `maxauthtries 3`), fail2ban `ignoreip` untouched and counters still 0/0, `hv01→8007` still OPEN, ACL table unchanged, first SSH attempt succeeded with no failed-auth event. **NEW HIGH finding raised:** pbs01 has **no working time source** — sole chrony peer `10.10.10.50` is the offline admin01, `Reach 0`, never synced since boot, clock **+65.657 s fast** (measured by `chronyd -Q` against `lt.pool.ntp.org`, which also proves NTP egress works); auditd/snapshot/prune timestamps on the fleet's backup custodian are therefore wrong by ~1 minute — SOC 2 CC7.2 / ISO A.8.16. Not fixed in this change: a 65 s backward step is a separate §0.3 mutation, gated on no PBS task running. Also corrected: "NTP all working" in §Network Notes was false | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` (§1–§9); `pbs01:/root/prechange-20261022/nftables.conf.bak`; ADR-008 |
| 2026-10-22 (chrony, re-provisioned) | **The 18:54Z chrony fix was necessary and correct, but under-provisioned — raised from 2 sources to 6 and renamed to the fleet path.** `server <pool-zone>` pins one resolved address per line (measured: `2 sources online` while DNS returned 8 candidates), which leaves no quorum to reject a falseticker; `/etc/chrony/conf.d/10-jol-upstream.conf` was replaced by `/etc/chrony/conf.d/jol-sources.conf` with `pool lt.pool.ntp.org / 0.ubuntu.pool.ntp.org / 1.ubuntu.pool.ntp.org iburst maxsources 2` — the same directive form `ansible/roles/time_sync/templates/chrony-jol.conf.j2` produces, and the same filename, so a future `time_sync` application to pbs01 converges this file instead of leaving an unmanaged second drop-in (pbs01 is in `inventory/prod/hosts.yml` under group `backup`, but no playbook targets it today). `makestep`/`rtcsync` intentionally omitted (already in stock `chrony.conf` lines 39/35; duplicate `rtcsync` warns). Config was validated **before** the mutation with a non-disruptive one-shot (`chronyd -Q '<proposed lines>'` → rc=0, 13.7 ms), no PBS data task was running, the old file was moved (not deleted) to `/root/prechange-20261022/`. Verified: 6 sources online, stratum 3, offset 0.9 ms, `Leap status Normal`, no `x` flag, `journalctl -u chrony -p warning` empty, RTC == system time, all six services active, `datastore list` normal, **no clock step** (no second audit-timestamp discontinuity). Fleet sweep: hv01 healthy (12 sources, 22 µs, no admin01 reference) and Ansible hosts use pool NTP, so **pbs01 was the only host with the dead-admin01 dependency**; prox01 ⚠ UNVERIFIED. Also corrected in this file: the "restore is impossible with Backup+Audit" reasoning (per official role definitions `DatastoreBackup` *does* restore owned backups; the missing privilege is `Datastore.Prune`), the "token may not exist" hedge (it exists, enabled, with zero rows), and `inventory/prod/hosts.yml` `pbs01.monitoring_enabled: true` → `false` to match the verified unscrapeable reality | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §15 |
| 2026-10-22 (grants) | **PRODUCTION CHANGE: `DatastorePowerUser` granted on `/datastore/pbs-store/jol-hv01` (`propagate=1`) to BOTH `pve-backup@pbs` and `pve-backup@pbs!pve-token`** — closing blocker (a) of the hv01 datastore registration. Executed from the workstation over the ADR-008 SSH path after the operator authorised it; both `acl update` calls returned rc=0, and verification is by read-back rather than exit code: `user permissions 'pve-backup@pbs!pve-token'` went from **empty** to `Datastore.Backup (*)` + `Datastore.Prune (*)`, and the rows are on disk in `/etc/proxmox-backup/acl.cfg` (0640 root:backup). **Reference check:** the nightly-working `jol-llm-backup@pbs!llm-token` reports the same two-privilege shape per path, so `DatastorePowerUser` deliberately does not list Read/Verify/Audit explicitly (restore of owned groups is implied by `Datastore.Backup`) — the grant matches a control already proven in production. The grant was accepted on the **absent** namespace path as documented (`ns/` still holds only `jol-llm`, which is correct until the first backup). **New limitation recorded in §Pending step 2 and in the runbook §4:** PBS 4.2 `proxmox-backup-manager acl` offers no `delete`, so rollback is a UI removal or a `NoAccess` override — the runbook previously had no phase-4 rollback row at all. Remaining blocker is credential custody only: `hv01:/etc/pve/priv/storage/pbs01.pw` is 1 byte, so `pvesm status | grep pbs01` still returns `401 Unauthorized` until the token is rotated and the one-time secret typed into the PVE form. No secret was read, printed or handled | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §16 |
| 2026-10-22 (onboarding landed) | **hv01 off-host backup is live, and three claims in this file were falsified by execution.** (1) *Namespace auto-creation* — wrong: the first `vzdump` returned `command error: namespace not found`; `ns/jol-hv01` had to be created on the host with `install -d -o backup -g backup -m 750` (mirroring `ns/jol-llm`, verified `750 backup:backup`). (2) *`acl update` on the absent namespace path was inert* — no: it was accepted and became effective the moment the directory existed, exactly as documented. (3) *Token rotation preserves grants* — wrong and this one cost a cycle: `user delete-token` **prunes the token's own ACL rows**, so the regenerated `pve-token` came back with zero privileges; the read-back proof is the error class change — `401 Unauthorized` (no credential) → `Cannot find datastore 'pbs-store'` (credential valid, no grants) → `active` (after re-grant). Credential installed via the no-print rotate-and-install pipeline of `docs/runbooks/hv01-storage-backup-reconfiguration.md` §3 step 5, so no secret was ever displayed (INC-20261022-TOKEN-EXPOSURE containment; the earlier exposed value is dead because the token was deleted). Measured end state: `pvesm status` → `pbs01 pbs active`; `pvesh get /nodes/pve-prod-hv01/storage/pbs01/content --content backup` lists `pbs-vm` for **vmid 100 (107 GB), 101 (54 GB), 102 (54 GB)**; vzdump times 91 s / 25 s / 24 s at 1.1–2.1 GiB/s with `backup is sparse` 67–91 %; job `hv01-nightly-pbs` created via the API (`^I`-indented options, `schedule 02:00`, `vmid 100,101,102`, `prune-backups keep-daily=7,keep-weekly=4,keep-monthly=6`, `repeat-missed 1`, `next-run` set). **Restore drill PASSED:** `qmrestore pbs01:backup/vm/102/2026-10-22T20:42:23Z 199 --storage local-lvm --unique 1` → task `OK`, 50 GiB written in 9.44 s (5.4 GB/s, decrypted with the stored key), scratch VM booted with `net0` deleted and its **guest agent answered after 80 s** (proves image → filesystem → init → agent), then `qm stop/destroy 199 --purge` — `qm list` back to 100/101/102 and `lvs | grep -c vm-199` = 0. Two cosmetic self-inflicted failures recorded honestly: `lvs -o lv_path local-lvm/vm-199-disk-0` returned empty (wrong VG/LV naming, so the offline `e2fsck` leg never ran) and `qm guest info` / `guest-fsinfo` / `guest-get-disks` are not valid verbs (correct: `qm guest cmd <vmid> get-fsinfo`). ⚠ The malformed `job-vm100-nightly` section could **not** be left "as evidence": its TAB-less option lines made the job registry die on every write (`unknown section type ''`, `pvesh delete` → *No such job*), so job creation was impossible until `/etc/pve/jobs.cfg` was emptied by file edit (backup `hv01:/root/prechange-20261022/jobs.cfg.bak-20261022-2345`) | `docs/compliance/evidence/pbs01-admin-ssh-20261022.txt` §17; `docs/compliance/evidence/incident-20261022-pbs-token-secret-exposure.md` |
| 2026-10-21 (later) | Onboarding procedure corrected after the operator ran the CLI drafts on the wrong host (workstation `ubuntu`/192.168.88.249: `install: cannot create directory '/backup-pool'`, `proxmox-backup-manager: command not found`): (a) the ACL option is **`--auth-id`**, not `--userid` (verified against PBS 4.2 User Management docs, which show `proxmox-backup-manager acl update /datastore/store1 DatastoreAdmin --auth-id john@pbs`); (b) namespace ACL paths are documented only as the template `/datastore/{store}/{ns}`, so the GUI path picker is prescribed over a guessed literal path; (c) a "check what is already granted" step was added first — if `pve-backup@pbs` already has `DatastorePowerUser` on `/datastore/pbs-store` with propagate, the namespace is optional hygiene and backups could start immediately; (d) reachability restated: SSH filtered even from hv01, `:8007` open from hv01 only, admin01 silent → console or a logged, session-limited `ssh -L 8443:10.10.10.30:8007` tunnel via hv01 | PBS 4.2 docs `user-management.html`; evidence §11 |
