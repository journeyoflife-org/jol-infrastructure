# Runbook: Dell PowerEdge R640 — Proxmox VE 9.2 Provisioning (prox01)

> **Scope**: R640 Node 1 (Service Tag JBJ1BW2) → `prox01` on 10.60.60.10/24.
> **Compliance**: SOC 2 Type II / GDPR (EU 2016/679) / ISO 27001:2022.
> **No credentials in this document** — use the secrets manager
> (see `docs/architecture/secret-flow.md`).
> **Reference hardware docs**: `docs/servers/prox01.md`,
> `docs/network/dell-n2048-port-table.md`.

## When to Use

- Fresh Proxmox VE 9.2 install on a Dell PowerEdge R640 with iDRAC9.
- iDRAC9 Storage page is missing the **Controllers** tab (PERC not visible).
- Preparing PERC/HBA storage for a ZFS-based Proxmox install.

## Asset Summary

| Item | Value |
|------|-------|
| Platform | Dell PowerEdge R640, Service Tag **JBJ1BW2** |
| iDRAC | iDRAC9 — 10.10.10.11 (VLAN 10, switch port Gi1/0/40) |
| Proxmox host | prox01 — 10.60.60.10/24 (VLAN 60, switch port Gi1/0/11) |
| Boot disks | 2× HP 480 GB SAS SSD → ZFS mirror (`rpool`) |
| Data disks | 6× HPE 1.92 TB SATA SSD → ZFS data pool (post-install) |
| Goal | Proxmox VE 9.2 (Debian 13 Trixie), ZFS RAID-1 on boot pair |

## Pre-flight (before touching the server)

1. **Change request**: Gi1/0/10/11/40 are "Ready/In provisioning" ports, so no
   formal CR is required (CRs apply to active production ports only — see
   port table §10). Record the work in the change log regardless.
2. **Credential hygiene**: if any OOB password was shared in plaintext
   (chat, ticket, email), treat it as compromised. Rotate it in Phase 4 and
   store the new value only in the secrets manager.
3. Reachability checks from `admin01` (10.10.10.50):
   ```bash
   ping -c 3 10.10.10.11                    # iDRAC up
   ssh root@10.10.10.11 getversion -b       # iDRAC RACADM shell responds
   ping -c 3 10.60.60.1                     # VLAN 60 gateway (MikroTik)
   ```
4. Download the Proxmox VE 9.2 ISO and verify its SHA256 checksum.

---

## Phase 1 — Restore PERC visibility in iDRAC9 (blocking)

### Background

The missing **Storage → Controllers** tab is a known iDRAC9 inventory bug.
Dell KB [000388426](https://www.dell.com/support/kbdoc/en-us/000388426)
documents the workaround below (originally for firmware 7.20.60.50 /
7.20.70.50 / 7.20.80.50 with external HBA355e storage, but Dell states there
is *no downside to leaving the attribute Enabled* — safe for internal-only
configurations like this R640).

> Note: no Virtual Console `CTRL+ALT+F2` trick is needed. The iDRAC9 SSH
> shell **is** the RACADM shell — SSH to 10.10.10.11 directly.

### Option A — RACADM workaround (recommended)

```bash
ssh root@10.10.10.11            # enter iDRAC root password interactively

# --- inside the iDRAC RACADM shell ---
getversion -b                   # record iDRAC / BIOS / Lifecycle Controller versions
set system.storage.LimitExternalHBATopology Enabled

# Power-cycle the *server* (not the iDRAC) so storage re-enumerates
serveraction powercycle

# After reboot (~5 min), SSH again and verify:
get system.storage.LimitExternalHBATopology     # expect: Enabled
storage get controllers                         # PERC/HBA must appear here
hwinventory | grep -A 8 -i "RAID\|HBA"
```

Then refresh the web UI: **Storage → Controllers** tab should be visible.

### Option B — escalation path (if Option A does not restore the tab)

Work in order; each step is non-destructive unless noted:

1. **License check** — full Storage management UI requires iDRAC9
   Enterprise/Datacenter:
   ```bash
   getlicense -s
   ```
2. **Restart iDRAC** (UI down ~5 min; does not reboot the server):
   ```bash
   racreset hard
   ```
3. **Clear stuck inventory jobs**:
   ```bash
   jobqueue get
   jobqueue delete --all
   ```
4. **Firmware alignment** — update in order via **Maintenance → System
   Update**: iDRAC → BIOS → PERC/HBA. Current iDRAC9 releases supersede the
   buggy 7.20.x line entirely. Record final versions in
   `docs/servers/prox01.md`.
5. **Flea-power drain** (server off): `serveraction powerdown`, unplug both
   PSUs for 2 min, hold front power button 30 s, reconnect, wait ~5 min for
   iDRAC boot.
6. **POST-level check** — F2 → **Device Settings**. If the PERC is absent
   there too, the fault is hardware (reseat PERC Mini card / backplane
   cable), not iDRAC.

### Exit criteria

- `storage get controllers` lists the controller with correct model/firmware.
- Web UI **Storage** page shows Controllers, Physical Disks, Virtual Disks.

---

## Phase 2 — Storage configuration for ZFS

### Step 1 — Identify the controller

```bash
storage get controllers
```

### Step 2 — Decision matrix

| Controller found | Action |
|---|---|
| **HBA330 / HBA335 Mini** | ✅ True passthrough — nothing to configure. All 8 disks pass directly to Proxmox. |
| **PERC H330 / H730 / H740 (any variant)** | ⚠️ No true HBA/JBOD mode exists on 14G PERC RAID controllers (Dell supports non-RAID passthrough only on HBA330/HBA335). Apply the workaround below. |

**PERC workaround** (only if no HBA330 is available):

- Do **not** build a hardware RAID-1 for boot — it would silently bypass the
  ZFS mirror and its checksums.
- Create **one single-disk RAID-0 virtual disk per physical disk** (all 8)
  via **Storage → Virtual Disks → Create** (iDRAC) or `CTRL+R` at POST.
- Per VD: **Write Policy = Write Through**, **Read Policy = No Read Ahead**,
  **Disk Cache = Enabled**. Write-Through disables the controller write
  cache, preserving ZFS ZIL integrity.
- Recommended long-term fix: install an **HBA330 Mini** (the Dell-endorsed
  ZFS path for 14G servers).

**Drive vendor note**: HP/HPE-branded disks in a Dell backplane are
functional but reported as non-certified. If fans run louder than expected:
`set system.thermalsettings.ThirdPartyPCIeResponse Default` and verify
`FanSpeedOffset` is at default.

### Step 3 — Pre-install verification

All **8 disks** (2× 480 GB SAS + 6× 1.92 TB SATA) must be individually
visible — under **Storage → Physical Disks** (HBA) or as 8 single-disk VDs
(PERC workaround).

---

## Phase 3 — Install Proxmox VE 9.2

### Step 1 — Attach installer via iDRAC

1. iDRAC web UI → **Virtual Console → Launch Virtual Console**.
2. **Map CD/DVD → Map File** → attach the verified PVE 9.2 ISO.
3. Power on → **F11** at POST → Boot Manager → **One-shot BIOS Boot Menu →
   Virtual Optical Drive**.

### Step 2 — Installer choices

1. **Install Proxmox VE (Graphical)**.
2. **Target Harddisk → Options**:
   - Filesystem: **ZFS (RAID1)**
   - Select **only the 2× 480 GB drives** (leave the 6× 1.92 TB untouched)
   - Advanced: `ashift=12`, `compress=zstd`, `checksum=on`
3. **Network** (aligned with port table):
   - Management interface: NIC with link on Gi1/0/11 / VLAN 60
   - Hostname: `prox01`
   - IP: **10.60.60.10/24**, Gateway: **10.60.60.1**, DNS: internal resolver
4. Set root password + SSH key, finish, reboot, detach ISO.

### Step 3 — Post-install verification (SSH to 10.60.60.10)

```bash
zpool status rpool        # mirror-0 ONLINE with both 480 GB drives
lsblk                     # 6× 1.92 TB disks visible, unused
ip -br a                  # vmbr0 = 10.60.60.10/24
```

### Step 4 — Repositories and baseline hardening

Align with the `pve-prod-hv01` baseline (`docs/servers/pve-prod-hv01.md`):

```bash
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt -y dist-upgrade
```

- SSH: key-only, `PermitRootLogin prohibit-password`, fail2ban, idle timeout
- Firewall: default deny; allow 22/tcp + 8006/tcp from management VLANs only
- chrony NTP, auditd, node-exporter + netdata (monitoring standard)

---

## Phase 4 — Permanent iDRAC management & hardening

### Step 1 — Rotate the exposed credential (do this first)

```bash
ssh root@10.10.10.11
set idrac.users.2.password '<NEW-STRONG-PASSWORD>'   # root = user index 2
```

Store the new password in the secrets manager only. Follow
`docs/runbooks/secret-rotation.md` for the rotation record.

### Step 2 — Hardening (iDRAC RACADM shell)

```bash
set idrac.telnet.enable 0                        # telnet off
set idrac.ssh.enable 1                           # SSH is the only OOB path
set idrac.webserver.sslprotocol TLS1.2+          # TLS >= 1.2 only
set idrac.ntp.ntp1 <internal-NTP>                # correct SEL timestamps
set idrac.time.timezone <TZ>
```

### Step 3 — Permanent RACADM workflow (from admin01)

The iDRAC9 SSH shell is RACADM — no separate tooling needed:

```bash
ssh root@10.10.10.11 racadm getversion -b
ssh root@10.10.10.11 racadm storage get controllers
ssh root@10.10.10.11 racadm getsysinfo
```

> Do not install Dell OpenManage/OMSA on the PVE host — Dell does not
> support it on Proxmox/Debian Trixie. All OOB needs are covered by iDRAC
> SSH on VLAN 10.

### Step 4 — Backup iDRAC configuration

```bash
ssh root@10.10.10.11 racadm systemconfig export --clone -t xml \
  -f idrac-JBJ1BW2-backup.xml
# Store OUTSIDE the repo (secrets manager / backup share), per secret-flow.md
```

---

## Phase 5 — Integration with existing infrastructure

1. **Inventory**: `prox01` entry already staged in
   `inventory/prod/hosts.yml` — activate monitoring/backup tooling once the
   host is reachable.
2. **Backups**: create nightly PBS job on `pbs01`
   (`docs/servers/pbs01.md`): encrypted, keep-daily=7, keep-weekly=4,
   keep-monthly=6. ZFS mirror is **not** a backup.
3. **Data pool** (when AI-service VMs land here): create `raidz2` ZFS pool
   from the 6× 1.92 TB disks via PVE web UI (Disks → ZFS) — tolerates 2
   simultaneous disk failures.
4. **Second NIC** (Gi1/0/10): keep un-addressed until a bond is configured
   (active-backup preferred; LACP requires port-channel on the N2048).
5. **iSCSI** (Gi1/0/23 → 10.70.70.20): defer until the P4500 migration
   decision D6 is closed (port table §8).
6. Update `docs/servers/prox01.md` with final CPU/RAM/firmware values from
   `racadm hwinventory` and `getversion -b`.

## Troubleshooting — installer: "No Hard Disk found"

Symptom: PVE installer aborts with *No Hard Disk found*; debug shell
(CTRL+ALT+F2) shows no storage devices (`lsblk -S` empty). The
`pci id ... 102b:0536` lines are the Matrox iDRAC VGA — normal, ignore.
Combined with a missing iDRAC Storage → Controllers tab this indicates the
storage **controller** is not detected, not a disk fault.

Diagnose in the installer debug shell:

```bash
lspci -nn | grep -iE "0104|0106|0107"
dmesg | grep -iE "megaraid|mpt3sas|ahci"
lsblk -S
```

| Result | Cause | Fix |
|---|---|---|
| No SAS/RAID device in `lspci` | PERC/HBA disabled, not seated, uncabled, or absent (common on used R640s) | Flea-power drain; reseat PERC/HBA Mini + mini-SAS backplane cables; verify presence in F2 → Device Settings; if absent, install HBA330 Mini (SAS boot disks cannot attach to onboard SATA) |
| `megaraid_sas` present, `lsblk -S` empty | RAID mode with no VDs, or Foreign config | Clear foreign config; create 8× single-disk RAID-0 VDs (Write Through, No Read Ahead) via iDRAC web UI or PERC HII — the interactive racadm shell on iDRAC9 7.00.x has no `storage createvd` (RAC917); see Phase 2 |
| Only Intel `ahci`, no disks | S140 RAID mode hiding SATA disks | F2 → Integrated Devices → SATA Mode: RAID → AHCI; SAS disks still require HBA/PERC |

Cross-check from admin01: `ssh root@10.10.10.11 racadm storage get
controllers` — iDRAC sees exactly what the BIOS sees; when the controller
returns here, the installer sees the disks too.

## Rollback

- Install failure: nothing external depends on the host yet — re-run the
  installer; ZFS target disks can be wiped (`zpool labelclear`) and reused.
- iDRAC misconfiguration: restore the Phase 4 Step 4 XML backup via
  `racadm systemconfig import`, or factory-reset iDRAC
  (`racadm set idrac.reset`) and re-apply network settings.
- Wrong VD layout on PERC: delete VDs in `CTRL+R` / iDRAC and recreate
  (data disks are empty at this stage).

## Acceptance checklist

- [ ] iDRAC Storage UI shows Controllers, Physical Disks, Virtual Disks
- [ ] `system.storage.LimitExternalHBATopology = Enabled` (or firmware fixed)
- [ ] All 8 disks individually visible to the installer
- [ ] PVE 9.2 installed; `rpool` = mirror of 2× 480 GB, state ONLINE
- [ ] vmbr0 = 10.60.60.10/24, gateway 10.60.60.1 reachable
- [ ] Web UI https://10.60.60.10:8006 reachable from management VLAN only
- [ ] iDRAC password rotated; telnet off; TLS 1.2+; NTP configured
- [ ] iDRAC config backup stored outside repo
- [ ] SSH key-only access enforced on PVE host
- [ ] `docs/servers/prox01.md` updated with final hardware/firmware facts
- [ ] PBS backup job created and first run successful

## Professional recommendations (engineering judgement)

1. **Rotate the iDRAC credential immediately** — it was shared in plaintext
   outside the secrets manager (SOC 2 CC6.1, GDPR Art. 32). This repo has
   prior art for exactly this cleanup (port table §12).
2. **Get an HBA330 Mini** if the server has a PERC RAID card. Single-disk
   RAID-0 VDs work but add a firmware layer between ZFS and the disks;
   true passthrough is the ZFS-correct design.
3. **Never mix hardware RAID-1 with ZFS mirroring** — pick one. The chosen
   design (ZFS mirror on passthrough disks) is correct.
4. **Record firmware versions** (iDRAC, BIOS, PERC) in the server doc after
   Phase 1 — this makes future "Controllers tab missing"-style regressions
   diagnosable in minutes.
5. **ZFS is not a backup**: the boot mirror survives one disk failure, but
   PBS on pbs01 (already in the fleet) is the required protection.
6. **Keep Gi1/0/10 un-addressed** until a bond exists; two switch ports with
   the same host IP cause MAC-flapping and port-security violations on the
   N2048.
7. **Reuse the pve-prod-hv01 hardening baseline verbatim** (SSH, firewall,
   fail2ban, auditd, chrony, no-subscription repo) so both hypervisors stay
   audit-identical.
