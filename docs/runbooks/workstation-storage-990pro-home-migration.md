# Workstation storage plan — claim the new NVMe, retire the repartition plan

**Host:** custodian workstation (`hostname -s` = `ubuntu`, called `admin01` in fleet docs)
**Raised:** 2026-11-04, during `/home` capacity triage
**Status:** PLAN — not executed. Every mutating phase needs root, which the operator holds.
**Supersedes:** the 2026-08-22 `jol-home-grow.sh` offline repartition of the OS disk's p7/p8. That plan
is retired, not deferred — see §1.3.

> ## ⚠ 2026-11-05 HARDWARE CHANGE — read before using any device name in this document
>
> The Windows-bearing Samsung 990 PRO was **physically removed** and replaced with an **ADATA LEGEND 900
> 1 TB**. Removing a controller **renumbered every NVMe device node**: the OS disk that this document
> called `nvme0n1` on 2026-11-04 is **`nvme1n1`** today, and the Intel 256 GB that was `nvme1n1` is now
> **`nvme0n1`**. Measured from `/sys/class/nvme/*/model`:
>
> | today | device | model | raw bytes | GiB |
> |---|---|---|---|---|
> | `nvme0n1` | Intel SSDPEKKW256G8 | 256 GB, PCIe **3.0** x4 | 256,060,514,304 | 238.5 |
> | `nvme1n1` | **Samsung 980 PRO 1TB** — the OS disk | PCIe **4.0** x4 @ 16 GT/s | 1,000,204,886,016 | 931.5 |
> | `nvme2n1` | **ADATA LEGEND 900** — the new blank disk | PCIe **4.0** x4 @ 16 GT/s | 1,024,209,543,168 | 953.9 |
>
> Nothing broke, and the reason is the point: **every fstab entry except the known-broken `/dev/sdb1`
> line is UUID-based**, so all 10 block mounts re-validated on their own paths after the renumbering
> (`gate 2: 10 fstab block mount(s) verified`). Swap is active on `nvme1n1p4`. The ESP holds only
> `BOOT` and `ubuntu` — no `Microsoft` directory — so removing the Windows disk did not take the
> bootloader with it.
>
> **The one thing that did break is this document.** Device names in it are stale. This is the same
> failure class that produced the four-day backup outage: a remembered `sdXn`/`nvmeXn1` letter treated
> as a stable identity. **Use UUIDs in every command below, and re-read
> `/sys/class/nvme/*/model` before running anything.** §3 is rewritten accordingly.

---

## 0. The two findings that outrank capacity

Capacity was the question. Measuring it surfaced two defects that matter more, and both change the
plan. Verified 2026-11-04, read-only; no file content was opened.

| # | finding | evidence |
|---|---|---|
| **D-1** | **`/home` has no backup anywhere.** 76 GiB containing IDE config, personal data, SSH private keys and Tier-1 secret material exists in exactly one copy. | `crontab -l \| grep -ic home` → **0**. The backup HDD holds only `jol-control` and `jol-state-backup` (Terraform state). `/opt/jol/backup` holds `tfstate` and `log-residue-20260221`. Nothing reads `/home`. |
| **D-2** | **`/home` is unencrypted at rest and holds key material.** The `/home` partition is plain ext4 — no dm-crypt layer. | `lsblk -o NAME,FSTYPE /dev/nvme1n1p7` → `ext4` (reported as `nvme0n1p7` when measured on 2026-11-04; the node moved in the 2026-11-05 enumeration shift, the finding did not). Present: `/home/jol/.ssh/id_ed25519` (private key), `/home/jol/secrets/` (Tier-1 forbidden path), `/home/jol/.hermes/.env`. |

D-1 and D-2 are why the migration order below is **backup first, then move**. A disk migration is the
worst possible moment to discover that a filesystem was never copied: it converts a single copy into a
single copy on new hardware, and any mistake during the move is unrecoverable.

> **Scope note on D-2:** `/opt/jol` (the Tier-1 church-platform tree, GDPR Art. 9 / PCI-DSS scope) is a
> separate filesystem on `p8` of the OS disk and is NOT part of this migration. `/home/jol/secrets/**` is on the
> Tier-1 FORBIDDEN list — this runbook names its path and never its contents, and no step below reads,
> lists, copies-into-logs or prints anything under it.

---

## 1. Why no purchase and no reinstall

### 1.1 The machine already contains the capacity

Superseded by the hardware change above; retained for the audit trail of what was measured on
2026-11-04. The 990 PRO was removed by the owner rather than repurposed, and an ADATA LEGEND 900 1 TB
took its place — see the banner. Both are PCIe 4.0 x4 and the new one is **larger in usable binary
capacity than the OS disk** (953.9 GiB vs 931.5 GiB).

Measured from `/sys/block/*/device/model`, not from documentation:

| device | model | size | used by Linux? |
|---|---|---|---|
| `nvme0n1` | Samsung **980 PRO** 1TB | 931.5 GiB | yes — the entire OS, **100 % partitioned**, 3504 sectors (1.8 MiB) spare *(this is `nvme1n1` today — see the banner)* |
| `nvme2n1` | Samsung **990 PRO** 1TB | 931.5 GiB | **no** — Windows layout, nothing mounted, absent from `/etc/fstab` |
| `nvme1n1` | Intel SSDPEKKW256G8 | 238.5 GiB | yes — `vgopt` (`/opt/viavitae`, `/opt/jolarca`) |
| `sda` | Seagate ST9320423AS, **5400 rpm** | 298.1 GiB | yes — Terraform state backup target |

`nvme2n1` partition table: `p1` vfat 200 M (EFI) · `p2` 16 M (MSR) · `p3` **ntfs 930.5 G** · `p4` ntfs 846 M (WinRE).
The 990 PRO is a **faster** drive than the 980 PRO the OS currently runs on.

Owner decision recorded 2026-11-04: **the Windows install is not used and may be wiped.**

### 1.2 Total Linux data fits on one of these drives twice over

```
272 GiB used across all Linux filesystems
1074 GiB free across all Linux filesystems
```

A single 931 GiB volume holds everything currently on the machine with ~660 GiB spare. Buying 2 TB adds
capacity the machine already has but has not allocated to the right mount point.

### 1.3 This retires the OS-disk p7/p8 repartition

The 2026-08-22 plan grew `/home` by moving `p8`'s **start** sector, because `p7` and `p8` are contiguous
with 0 gap and the disk has no free space — which means no in-place resize is possible and the only route
was backup → recreate → restore of `/opt/jol` (138 GiB payload, staged to a same-disk target with ~14 GiB
margin).

Claiming `nvme2n1` is strictly better on every axis that mattered in that design:

| | p7/p8 repartition (retired) | 990 PRO migration (this plan) |
|---|---|---|
| touches the disk holding the OS | **yes** | **no** |
| touches the Tier-1 `/opt/jol` tree | **yes** (138 GiB moved) | **no** |
| staging target | same physical disk, ~14 GiB margin | not needed — new disk is empty |
| result for `/home` | 93 → ~193 GiB | 93 → up to ~900 GiB |
| fixes D-2 (encryption) | no | **yes, free** |
| failure blast radius | whole fleet checkout root | `/home` only |

Do not execute `jol-home-grow.sh` if it still exists in `/root`. Its premise is superseded.
⚠ Its existence is **UNVERIFIED** — `/root` is not readable without sudo.

---

## 2. Phase 0 — back up `/home` (blocking; do this before any disk work)

### 2.0 A free capacity win available today, before any migration

`/home` is 93.13 GiB with the ext4 default **5 % reserved for root**. That reserve is ~4.6 GiB
(arithmetic checks out: 79 GiB used + 8.4 GiB available + ~4.6 GiB reserved ≈ 92 GiB), and root
never writes to `/home`. Dropping the reserve to 1 % returns roughly **3.7 GiB immediately** —
which is nearly half of the current free space, for free, with no data movement:

```bash
sudo tune2fs -m 1 /dev/nvme1n1p7
df -h /home        # Avail should rise by ~3.7 GiB
```

This is mitigation, not a fix — `/home` is growing ~3–4 GiB/day and will cross the bar again
within days. Do not apply it to `/` (root does write there, and the reserve is what keeps a
full `/` from locking you out of your own recovery).

Nothing in this runbook proceeds until Phase 0 passes its gate. This is the step that makes every later
step reversible.

### 2.1 Choose the target — corrected by measurement on 2026-11-05

The first version of this section recommended pbs01 via `proxmox-backup-client` and flagged reachability as
unverified. **It has now been verified, and the recommendation was wrong.** Measured from this workstation
(`192.168.88.249` — exactly the address ADR-008 authorises):

| probe | result | meaning |
|---|---|---|
| `ping 10.10.10.30` | **0 % loss, 0.57 ms** | the routed path exists |
| `tcp/22` | **open** | the ADR-008 SSH grant works |
| `tcp/8007` | **rc=124 — timeout** | **the PBS API is firewalled off from this box, by design** |
| `proxmox-backup-client` | **not installed** | the client is absent as well |
| `proxmox-backup-file-restore` | absent | so no local restore drill is possible yet |

ADR-008 added `tcp dport 22 ip saddr 192.168.88.249/32 accept` and **deliberately left 8007 alone** — it
stays restricted to `10.10.10.0/24`, `10.60.60.0/24` and `10.30.30.10`. So the §2.2/§2.3 procedure below
cannot run as written from this machine.

| option | what it takes | protection | status |
|---|---|---|---|
| **A. HDD `sda1`** — `rsync --link-dest` snapshot chain onto the 290 GiB volume | root only. No package, no firewall change | same **machine**, different disk: real protection against drive failure and against a bad migration step; none against theft or fire | **was "available today" — FALSIFIED at 12:58 by a reboot. `sda1` is now unmounted; see §6.1a** |
| **B. pbs01 over an SSH tunnel** — `ssh -N -L 18007:127.0.0.1:8007 pbs01`, client pointed at `localhost:18007` | install `proxmox-backup-client`; **no firewall change**, because it rides the already-granted :22 | genuinely **off-host** — the correct steady state, and the `llm-prod-lt01` / `jol-llm` fleet precedent | needs an apt install |
| C. widen 8007 for the workstation | an ADR-008 amendment, a second `nft -c -f` gate and a dead-man rollback on a host with **no IPMI** | same as B | **rejected — B gets there without touching a firewall** |
| `/opt/jol/data` | — | same **disk** as `/home` | **rejected — a same-device copy is not protection** |

**Therefore: A now, then B.** A is one root command and immediately removes the single-copy risk that makes
every later step dangerous. B is the right end state. Do not let "B is better" delay A.

> **Correction written 2026-11-05 14:20.** "A is one root command" was true only while the desktop
> automounter happened to have mounted `sda1`. The ADATA insertion required a reboot at **12:58**, and
> after it `sda1` came back **unmounted**: `lsblk -no MOUNTPOINTS /dev/sda1` returns empty, `/proc/mounts`
> has no `sda1` entry, and `/media/jol/` now contains only an unrelated `charity-vol` directory — the
> `/media/jol/<UUID>` path itself is gone. So the prerequisite for A is **§6.1a**, and
> `fix-jol-backup-mount.sh` has moved from "should go first" to "blocks everything". The backup script
> caught this itself and refused to proceed rather than guessing a path — which is the guard working.

Two fragilities of B, both already logged as open in ADR-008 and neither hypothetical:

1. **The DHCP reservation was never created** — `192.168.88.249` is still `proto dhcp`, so the `/32` grant
   can rot into intermittent access that reads like a backup regression rather than an address change.
2. A tunnel makes every backup depend on a live SSH session. It needs its own systemd unit and its own
   liveness check, or it becomes the next control that fails silently while looking configured.

### 2.2 Procedure — option A (the HDD), implemented by `scripts/maintenance/backup-workstation-home.sh`

Option B's original procedure is retained below for when the client is installed, but **it does not work
from this host today** — see §2.1. The script is the authoritative version; this is the audit trail.

```bash
# Option A is executed by the script; the steps it performs, in order, are:
#   1. resolve sda1 by UUID and prove stat -c %d of the mount differs from that of /
#   2. free-space preflight: require >= 110 % of the expected payload before writing anything
#   3. rsync -aHAX --link-dest=<previous> so unchanged files are hardlinks, not copies
#   4. verify with a dry-run rsync diff — an empty diff, not an exit code, is the gate
#   5. PROVE a restore: copy one known file back to scratch and byte-compare it
#   6. prove the secret tree survived WITHOUT printing it: diff -rq on /home/jol/secrets
#   7. only then write the proof artifact that provision-jolhome-disk.sh gate 0 reads
#
#   sudo DRY_RUN=0 scripts/maintenance/backup-workstation-home.sh

# --- retained for option B (blocked today: :8007 filtered, client not installed) ---
# export PBS_REPOSITORY='backup@pbs:<fingerprint>@localhost:18007/jol-workstation'   # via the SSH tunnel
# sudo proxmox-backup-client backup home.pxar:/home --repository "$PBS_REPOSITORY" --allow-shrink
```

`--allow-shrink` is required, not cosmetic: `/home` changes constantly (IDE caches, agent sessions), and
without it a shrinking tree aborts the backup mid-run.

### 2.3 Gate — a backup is not a backup until a restore is proved

```bash
proxmox-backup-client snapshot list --repository "$PBS_REPOSITORY"
proxmox-backup-client snapshot show <latest>            # must list home.pxar with a non-zero size
# then prove readability by restoring ONE file to a scratch path:
sudo proxmox-backup-client restore --repository "$PBS_REPOSITORY" <latest> \
     home.pxar/<some-known-path> /tmp/restore-probe/
diff <(sudo cat /tmp/restore-probe/<file>) <(sudo cat /home/<file>) && echo "RESTORE PROBE PASS"
```

**PASS = a restored file byte-compares equal to the original.** "Snapshot list shows an entry" is not
proof — this fleet has already been bitten by a backup that was registered but never ran.

### 2.4 Rollback
Phase 0 is additive. Rollback = delete the namespace. Nothing on the workstation changed.

---

## 3. Phase 1 — claim the new NVMe

> **Steps §3.1–§3.6 are implemented by `scripts/maintenance/provision-jolhome-disk.sh`**
> (`DRY_RUN=1` by default, `--verify-only` for a read-only report, root refused otherwise). The commands
> below are kept so the procedure is auditable independently of the script, and so a partial or manual run
> is possible. The script additionally enforces **gate 0 in code** — it refuses to run at all unless a fresh
> `/home` backup proof artifact exists — which is the only reason that gate is real rather than advisory.
> Its guard matrix was tested against the OS disk, the LVM-bearing Intel disk, a USB stick and an unknown
> model; three of those four guards were broken in the first draft and are described in the CHANGELOG row.

### 3.1 Pre-flight: identify the disk by UUID, and prove it is blank

The 2026-11-04 revision of this section said "prove the Windows volume is empty before wiping it".
The owner resolved that by removing the disk physically. The equivalent risk today is **wiping the wrong
disk**, because enumeration shifted — so identity is established by model string and by an explicit
empty check, never by a device letter.

> ### ⛔ The machine has SIX block devices, and two of them are not spare capacity
>
> Measured 2026-11-05 via `lsblk -d -o NAME,SIZE,TRAN,ROTA,RO,MODEL` and `/sys/block/*/removable`:
>
> | node | what it is | transport | removable | state |
> |---|---|---|---|---|
> | `nvme0n1` | Intel SSDPEKKW256G8 238.5 GiB — **holds LVM `vgopt`** (`/opt/viavitae`, `/opt/jolarca`) | nvme, PCIe 3.0 | 0 | in use |
> | `nvme1n1` | Samsung 980 PRO 1TB — **the OS disk** | nvme, PCIe 4.0 | 0 | in use |
> | `nvme2n1` | ADATA LEGEND 900 953.9 GiB | nvme, PCIe 4.0 | 0 | **blank — the target** |
> | `sda` | Seagate ST9320423AS 298.1 GiB 5400 rpm, internal ATA (`wwn-0x5000c50029c7d01f`) | sata | 0 | in use (state backups) |
> | `sdb` | "General UDisk" **14.6 GiB USB stick, whole-disk `crypto_LUKS`** | usb | **1** | container **CLOSED** |
> | `sdc` | identical second USB stick, whole-disk `crypto_LUKS`, different serial | usb | **1** | container **CLOSED** |
>
> **Do not touch `sdb` or `sdc`.** Two matching small-capacity USB sticks, each wholly LUKS-encrypted,
> each currently unopened, are the signature of **dual-control key-custody media** — consistent with the
> fleet's SOPS dual-identity custody plan and the dual-account four-eyes control. Their contents were not
> read and must not be read by this procedure; what is known is only that they are encrypted, removable,
> and present. Treat them as the most valuable objects in the building.
>
> This is not a hypothetical: **`/etc/fstab` line 27 already points at `/dev/sdb1`** — one of these two
> sticks. That means the original intent of the `/mnt/jol-backup` mount was plausibly *"the opened LUKS
> volume from removable backup media"*, which is a better off-premises design than the HDD, and it failed
> for three compounding reasons: the stick has **no partition table** (so `sdb1` can never exist), the
> container is **closed** (so no `/dev/mapper/…` exists either), and a removable USB device must never be
> a hard fstab dependency for a scheduled job. §6 item 1 is revised accordingly.

Before selecting anything, print the full inventory and confirm the target is the only blank non-removable
disk:

```bash
# 3.1.0 inventory + hard exclusions. Run this and READ it before continuing.
lsblk -d -o NAME,SIZE,TRAN,ROTA,RO,RM,MODEL,FSTYPE
lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINTS /dev/sd* /dev/nvme*
# A target is only acceptable if ALL THREE hold:
TRAN=$(lsblk -dno TRAN "$CANDIDATE"); RM=$(lsblk -dno RM "$CANDIDATE"); SIG=$(sudo wipefs -n "$CANDIDATE")
[[ "$TRAN" == nvme && "$RM" == 0 && -z "$SIG" ]] \
  || { echo "ABORT: target is transport=$TRAN removable=$RM signature='${SIG:-none}'. Refusing to proceed."; exit 1; }
```

```bash
# 3.1.1 find the target by MODEL, not by nvmeXn1
for d in /sys/class/nvme/*; do printf '%-9s %s\n' "$(basename $d)" "$(cat $d/model | xargs)"; done
# the ADATA is the one reporting "ADATA LEGEND 900"; capture its node into a variable and use it once
TARGET=$(for d in /sys/class/nvme/*; do [[ "$(cat $d/model | xargs)" == "ADATA LEGEND 900" ]] && basename $d; done)
TARGET="/dev/${TARGET}n1"; echo "TARGET=$TARGET"
# ⚠ Re-read this line before every command below. If it prints anything other than the ADATA, STOP.

# 3.1.2 prove it is blank — no partition table, no filesystem, no data
sudo blkid -o list -w path "$TARGET" 2>/dev/null || true
lsblk -o NAME,FSTYPE,SIZE "$TARGET"
sudo wipefs "$TARGET"          # no-argument form: LIST only, writes nothing

# 3.1.3 health and identity, which cannot be read unprivileged
sudo nvme smart-log "$TARGET"        # critical_warning must be 0; temperature; percentage_used
sudo nvme id-ctrl "$TARGET" | grep -E '^(mn|fr|sn|nn|tnvmcap|vid|ssvid)' \
  || echo "UNVERIFIED: controller identity not readable without root"
```

**Abort conditions:** `wipefs` lists any signature, `smart-log` reports `critical_warning != 0`, or
`percentage_used` is not 0 on a supposedly new drive. Any of those means the disk is not what it appears.

> **Model-revision caveat (not measurable locally):** the LEGEND 900 is a **DRAM-less, HMB** drive with
> TLC NAND, rated 7000/4700–5400 MB/s and **600 TBW / 5 years** for the 1 TB part. Reviewers have
> documented ADATA changing this model's internals mid-production **without announcement**, so two units
> carrying the same name can differ. `sudo nvme id-ctrl` (controller/vendor id) plus the sustained-write
> test in §3.6 is how you establish what *this* unit actually is, rather than trusting the label.

### 3.2 Wipe, encrypt, format

```bash
# $TARGET was resolved by MODEL in §3.1.1 — re-read it here, do not rely on the earlier echo.
sudo wipefs -a "$TARGET"
sudo sgdisk --zap-all "$TARGET"
sudo parted "$TARGET" --script mklabel gpt mkpart jolhome ext4 1MiB 100%
PART="$(lsblk -no NAME "$TARGET" | tail -1)"     # re-derived, never hard-coded

# LUKS first — this is what closes D-2, and it is free because the filesystem is new.
sudo cryptsetup luksFormat --type luks2 "/dev/$PART"
sudo cryptsetup open "/dev/$PART" jolhome_crypt
# -m 1 : reserve 1 % for root instead of the ext4 default of 5 %. On 953.9 GiB that is the
#        difference between 9.5 GiB and 47.7 GiB held hostage from a filesystem whose only
#        writer is an unprivileged user. See §2.0 — the same knob is available on the
#        CURRENT /home today, with no migration at all.
# No stride/width/block-group tuning: this is one drive, not a stripe, and guessing at
# RAID geometry on a single NVMe makes the metadata layout worse, not better.
sudo mkfs.ext4 -L jolhome -m 1 /dev/mapper/jolhome_crypt
sudo tune2fs -c 30 -i 180d /dev/mapper/jolhome_crypt    # matches the hv01 HDD fsck convention
```

### 3.2b Mount options — two of them matter specifically on this drive

```
defaults,noatime,nodiratime
```

- **`noatime`** is not cosmetic here. The LEGEND 900 is **DRAM-less**, so every metadata write
  costs a read-modify-write against the host for mapping; an atime touch on each read is pure
  waste and shows up as unexplained write amplification on a drive with no local cache.
- **Do not put `discard` in fstab.** Continuous TRIM on a DRAM-less controller turns random
  reads into synchronous flushes. Enable the periodic instead:
  `sudo systemctl enable --now fstrim.timer` (weekly, and it will pick up the new mount
  automatically).
- `nofail` is **correct for a data disk** and **wrong for a scheduled backup destination** — the
  `/mnt/jol-backup` outage is what a `nofail` mount does to a job that never checks. If this
  filesystem ever hosts a backup target, the job must verify device identity itself
  (`stat -c %d` vs `/`), which is what `fix-jol-backup-mount.sh` and watchdog gate 2 do.

### 3.2c Layout decision — one filesystem, several directories, never several partitions

**Do not carve this disk into 3–5 partitions.** The whole of this thread is the argument:
`/home` reached 91 % with 8.4 GiB free while `/opt/jol`, **on the same physical disk**, had
383 GiB free. Partitions do not share a free-space pool; directories do. Splitting 953.9 GiB
into fixed slices reproduces that defect on new hardware, and each extra partition also costs
its own LUKS header, UUID, fstab line, mount unit and watchdog threshold — while gate 1's
absolute floor had to be capped at 20 % of each filesystem's own size *precisely because small
partitions mis-alert*.

Separate by **policy**, not by size — and policy differences are what make a directory earn its
place:

| directory | contents (measured in `/home` today) | backup policy |
|---|---|---|
| `tooling/` | JetBrains Toolbox 9.7 G, `.pyenv` 2.8 G, `Applications` 2.2 G, `snap` 3.6 G | **excluded** — reinstallable |
| `cache/` | `.cache` 13 G, regenerable part of `.qoder` 8.5 G | **excluded** — safe to purge |
| `archive/` | `Downloads` 3.6 G, `Documents` 4.4 G, stale worktree `wt-20261008` 0.75 G, `Dropbox` 1.1 G | **included** |
| `agent/` | `.hermes` 3.0 G, `.codex` 0.67 G | mixed — config in, caches out |

**Two exclusions that are not optional:**

1. **No marketplace-tree data on this volume.** `/opt/jolarca` deliberately lives on a different
   filesystem from `/opt/jol` (Intel LVM vs `nvme1n1p8`). That separation *is* the AGENTS.md
   §0.2 dual-tree boundary and the ISO 27001 A.8.13 org-transfer rationale. Placing a
   `jolarca*` dataset on a filesystem that also holds church-tier or developer data merges two
   audit surfaces into one and would require a DPIA.
2. **Do not move Docker here.** The data-root is already `/opt/jol/data/docker` (verified in
   `/etc/docker/daemon.json`) on a 152 GiB-free filesystem. Duplicating it creates two images
   stores and an ambiguous `docker context`.

> **If you choose the data-root shape instead of making this disk `/home`:** it works only via
> bind mounts or symlinks, and a bind mount that silently resolves to its parent filesystem is
> exactly what watchdog gate 2 was written to catch. Two consequences to plan for: `du -x` and
> `rsync --one-file-system` will skip the new mount unless it is named explicitly, and a backup
> job that enumerates mount points will quietly stop covering it — the same silent-gap class as
> D-1, which is still open.

**Key custody — do not skip.** The LUKS passphrase is now a Tier-1 secret. It goes into the existing
custody path (Vaultwarden / the SOPS-age custody plan in `docs/compliance/sops-age-key-custody-plan.md`),
entered by the operator, never into a file in a repo, never into `/etc/crypttab` as plaintext, never as a
CLI argument. Add a recovery key with `cryptsetup luksAddKey` and store that separately — a LUKS volume
with one passphrase and no recovery path is a self-inflicted data-loss event.

### 3.3 Mount via `/etc/crypttab` + `/etc/fstab`, by UUID

```bash
sudo blkid "/dev/$PART"        # take the UUID — never write /dev/nvmeXn1pN into fstab or crypttab
```

This is the exact lesson from the `/mnt/jol-backup` defect: a device **letter** in fstab, plus `nofail`,
plus a swallowed stderr, produced four silent days of lost backups. Reference UUIDs, and verify the mount
resolves to a different block device than `/`:

```bash
sudo systemctl daemon-reload
sudo mkdir -p /mnt/jolhome-staging
printf 'jolhome_crypt UUID=<luks-uuid> none luks,discard,noauto\n' | sudo tee -a /etc/crypttab
sudo cryptsetup open --test-passphrase "/dev/$PART" && echo "luks slot OK"
sudo mount /dev/mapper/jolhome_crypt /mnt/jolhome-staging
[ "$(stat -c %d /mnt/jolhome-staging)" != "$(stat -c %d /)" ] && echo "OFF-DEVICE PASS" || echo "FAIL: resolves to /"
```

### 3.5 Gate
`stat -c %d /mnt/jolhome-staging` differs from `stat -c %d /`, and `df` reports ~900 GiB free.

### 3.6 Sustained-write characterisation — run this BEFORE planning the Phase 2 window

The LEGEND 900 is **DRAM-less** and relies on a dynamic SLC write cache. A short burst benchmarks at the
rated ~4.7 GB/s; a large sequential copy runs *past* the cache and drops to native TLC speed. Phase 2 is
a 76 GiB `rsync`, which is exactly the workload that crosses that boundary — so measure it now, on an
empty disk, rather than discovering it mid-migration with `/home` unmounted.

```bash
# Executed by scripts/maintenance/benchmark-jolhome-writes.sh (installed as
# /usr/local/bin/jol-write-bench.sh). Read-only plan first:
bash scripts/maintenance/benchmark-jolhome-writes.sh                    # DRY_RUN=1
# then, as root:
DRY_RUN=0 sudo jol-write-bench.sh
```

The script exists rather than the pasted command because the manual form is three steps
where the middle step is the evidence and the last is the one people skip. It writes
32 GiB as sequential 1 GiB `oflag=direct` steps, **each at its own seek offset** —
rewriting a growing file from offset zero yields a cumulative average that hides the
very cache transition being looked for — records every interval to
`~/.local/share/jol-fleet-health/write-bench-<utc>.tsv`, removes its test file on any
exit path, and **verifies that removal by post-state** rather than by having run `rm`.

Refusals, each its own token and each fixture-tested: the target is not mounted, the
target resolves to `/` (the exact `/mnt/jol-backup` failure from this thread), the
backing source is not `/dev/mapper/jolhome_crypt`, or the target already holds
something. An empty input, one sample, two samples or all-zero rates produce a refusal
token, never a number.

What it reports: peak, **sustained** (the mean of the last third of intervals, not of
all of them — a whole-run mean averages the fast SLC phase into the slow TLC phase and
describes neither), the collapse time, and the resulting copy window for a 76 GiB
payload **rounded up**, because a truncated window is a window that runs out.

> A note on how this section was verified rather than assumed: the first draft of the
> collapse detector scanned for any sample at or below half the eventual maximum, which
> reported a cache cliff at 20 s on synthetic data where the drive was simply speeding
> up from 100 to 1000 MiB/s. A collapse is now only searched for after the last peak
> sample. Eleven mutations of these two functions are recorded red in
> `scripts/maintenance/tests/test-write-bench.sh` (27 fixtures), including the
> whole-run-mean and truncate-instead-of-ceil variants.

**Expected:** a high rate for the first chunk, then a visible plateau. The plateau is
the speed that sets the Phase 2 copy window — at 300 MB/s, 76 GiB is roughly 5 minutes;
if the plateau is near 100 MB/s it is closer to 15, before verification passes. Plan the
rescue-mode window from the measured plateau, not from the vendor's peak figure.

The script's own summary already applies that rule, so the number to write into the
Phase 2 booking is the `WINDOW_MIN_FOR_76GIB` line it prints, not the peak.

> If `fio` is available, `fio --name=seq --rw=write --bs=1M --size=32G --runtime=120 --time_based
> --direct=1 --filename=/mnt/jolhome-staging/.fio` gives the same answer with a per-interval breakdown,
> which makes the collapse point obvious.

### 3.7 Rollback
`wipefs` and `sgdisk` are destructive to whatever was on that disk — which is why §3.1 proves it is blank
first. Everything after that is recoverable by deleting the partition and reformatting; no Linux data has
been touched yet.

---

## 4. Phase 2 — move `/home`

> **Decision recorded 2026-11-05 (owner): TPM2 auto-unlock is NOT wanted now — "maybe later".**
> `provision-jolhome-disk.sh` already defaults `TPM2_ENROLL=0`, so nothing changes; the opt-in and its two
> failure modes stay documented so a future reader knows this was decided rather than overlooked. The
> volume therefore requires **a human passphrase at every boot**, which means an unattended reboot after a
> kernel update will sit at the unlock prompt until someone types. That is the accepted cost of the
> decision, and it is why the recovery keyslot in §3 step 3 is mandatory rather than optional.

This phase requires `/home` to be quiet. **The IDE, this agent, and every browser are writing to it.**
Do it from a rescue target, not from the running desktop.

> **Executed by `scripts/maintenance/migrate-home-to-jolhome.sh` (installed as
> `/usr/local/bin/jol-migrate-home.sh`).** The steps below are what that script does; run the
> script rather than retyping them. `--preflight` is read-only and safe from the desktop — it
> reports readiness, the free-reserve win, and the boot-prompt consequence.
>
> **Why this section was rewritten on 2026-11-05.** The original §4.4 carried four defects,
> each a failure shape already seen elsewhere in this repo:
>
> 1. **`sed -i.bak 's|UUID=<old-home-uuid>.*|…|'` contained a literal placeholder.** A sed
>    pattern that matches nothing is a *silent no-op* — the same class as every "passed and
>    never ran" gate in this thread. The script resolves both UUIDs from the live fstab and
>    refuses unless each matches **exactly one** line.
> 2. **It wrote `/dev/mapper/jolhome_crypt` as a device path into fstab**, contradicting the
>    identity-by-UUID rule this repo enforces everywhere else — and contradicting §3.3, which
>    mounted the same filesystem by UUID minutes earlier.
> 3. **It used `nofail`** — the exact option that let `/mnt/jol-backup` degrade into an
>    ordinary directory on `/` and silently lose four nights of Terraform state backups.
>    §3.2b rejects `nofail` for this volume on purpose; §4.4 reintroduced it. A `/home` that
>    fails to mount **must** be loud: a silent empty `/home` means no SSH keys, no repos, and
>    a desktop that looks fine.
> 4. **It never removed the staging line.** After the swap the *same* ext4 UUID would be
>    declared at both `/home` and `/mnt/jolhome-staging` — two systemd mount units for one
>    device, and the `0 2` fsck pass applied twice. The correct edit **repurposes** the
>    staging line: same UUID, same options, new mount point. One line commented, one line
>    changed, nothing added. That rewrite is a pure function with 26 fixtures
>    (`tests/test-home-migration.sh`), because it is the one edit here that can stop the
>    machine booting into a usable state.

```bash
# 4.0 from the desktop, now: is the window ready? (read-only, no root needed)
/usr/local/bin/jol-migrate-home.sh --preflight

# 4.1 take the free capacity win first — ~3.7 GiB, no reboot, reversible (§2.0)
sudo tune2fs -m 1 /dev/nvme1n1p7 && df -h /home

# 4.2 refresh the backup so the safety net describes the tree being moved
sudo DRY_RUN=0 /usr/local/bin/jol-backup-home.sh

# 4.3 leave the desktop. rescue.target stops the user sessions; local-fs.target
#     still runs, so the LUKS volume is unlocked and the staging mount is present.
sudo systemctl isolate rescue.target

# 4.4 plan, then execute. The script refuses unless /home is quiet, the staging
#     mount is real and off-disk and EMPTY apart from lost+found, the backup proof
#     is under PROOF_MAX_AGE_H old, and the target has >=110 % of the payload free.
sudo DRY_RUN=1 /usr/local/bin/jol-migrate-home.sh
sudo DRY_RUN=0 /usr/local/bin/jol-migrate-home.sh

# 4.5 REBOOT — deliberately not `mount -a`. The old /home is still mounted from p7
#     while the new fstab points /home elsewhere; `mount -a` would stack the new
#     filesystem over the live one. A reboot resolves both cleanly, and it is where
#     the LUKS passphrase prompt appears on the console.
sudo reboot
```

The script's own verification gate — four independent checks, because the rsync exit code is
the thing being checked, not the check:

```text
verify 1/4  dry-run rsync reports ZERO differing entries
verify 2/4  entry counts: dst >= src (a zero or short count means the copy did not happen)
verify 3/4  mode and owner:group identical for the top two levels
verify 4/4  secret tree byte-identical via `diff -rq` EXIT STATUS ONLY — never printed
```

and its post-condition on the rewritten fstab, which is what turns a bad rewrite into an
abort instead of a machine that will not log anyone in:

```text
exactly ONE UUID line mounts /home  ·  it references the mapper's real UUID  ·  it has NO nofail
```

**Do not delete the old `nvme1n1p7` contents** (this is `p7` on the OS disk — note it was reported as
`nvme0n1p7` on 2026-11-04, before the enumeration shift). Leave them in place as the rollback for at least
a week of normal work. That partition becomes free capacity only after that.

> A cleaner variant of 4.4, preferred if you want it reversible by hand: keep `/home` on `p7` and bind-mount
> the new volume over the specific heavy directories instead. That avoids a rescue-mode window entirely, at
> the cost of `/home` staying small. Decide before §4.0, not during it.

### 4.0 Prerequisites before the window is booked (all measured 2026-11-05)

Each of these is checked by `jol-migrate-home.sh --preflight`, so none of them has to be
remembered. They are listed here because the window is short and a surprise inside it is
expensive.

| # | Precondition | Status | Who closes it |
|---|---|---|---|
| 1 | Recovery keyslot **verified to open the volume** and attested into custody | **OPEN** — no attestation exists; `/var/lib/jol-workstation` is `drwx------ root:root`, so an unprivileged run can only report UNVERIFIED | owner: place the passphrase in Vaultwarden, then `sudo jol-record-custody.sh` |
| 2 | A **current** Phase 0 backup proof (≤ 6 h) | **STALE BY DESIGN** — the 13:10Z snapshot ages out; re-run before the window | owner: `sudo jol-backup-home.sh` |
| 3 | The scripts are actually installed on the host | **FAILING** — `jol-migrate-home.sh` and `jol-record-custody.sh` are absent from `/usr/local/bin`, and the three that exist are still mode `750 root:root`, predating the per-target-mode change. Their content is therefore **UNVERIFIABLE** by uid 1000 — not "drifted", unreadable | owner: one `DRY_RUN=0 sudo jol-install-scripts.sh` (or the repo copy) re-run |
| 4 | §3.6 sustained-write measurement recorded | **OPEN** — tooling now exists (`jol-write-bench.sh`), never executed | owner, as root |
| 5 | Boot posture is not a trap | **PASS** — crypttab options `luks`, and both `Automatic-Reboot` and `Automatic-Reboot-Time` are commented out in `50unattended-upgrades`, so nothing reboots the machine into a prompt nobody is there to answer. The gate fails if the pair ever becomes real | automatic |
| 6 | `tune2fs -m 1` on `/home` | **OPEN, and not urgent** — measured free space moved 8512 → 8568 → 8563 MiB across the recorded samples, i.e. no observable fill. Do this for headroom, not for time | owner, as root |

Item 3 blocks items 1, 2 and 4 in practice: the operator cannot run what is not installed.

### 4.5 Gate
`df -h /home` shows the new volume; `ls -Z`/`stat` permissions match; the IDE starts; the agent starts;
`git -C /opt/jol/repos/jol-infrastructure status` is clean; SSH keys still authenticate
(`ssh -T git@github.com`).

### 4.6 Rollback
The old `/home` on `nvme1n1p7` was never modified — it **is** the rollback:

```bash
sudo cp -p /etc/fstab.bak.<TS> /etc/fstab && sudo systemctl daemon-reload && sudo reboot
```

The script prints the exact backup path and timestamp at the end of every run. Alternatively,
uncomment the line the rewrite marked `# PHASE2-CUTOVER: previous /home retained as rollback`
and comment the new one — the old entry is kept in the file deliberately so the rollback is a
visible, greppable edit rather than a restoration that could silently fail.

---

## 5. Phase 3 — re-derive the compliance surface

A new filesystem is a new audit object. Skipping this is how a machine ends up with a control that looks
configured and measures nothing — the pattern behind gate 10's dead branch and the `/mnt/jol-backup` lie.

| # | action | verification |
|---|---|---|
| 3.1 | **AIDE — NOT APPLICABLE on this workstation.** Verified 2026-11-05: `command -v aide` returns nothing and `/var/lib/aide/` does not exist. The `sudo aide --check` lines in `AGENTS.md` are **fleet-host** controls (`rag-prod-lt01`, `llm-prod-lt01`, `mcp-prod-lt01`), not custodian-workstation controls. This row is kept rather than deleted so the next reader does not go looking for a baseline that was never created — a control listed in a runbook with no producer on the host is the same defect class as gate 0 having no producer. If workstation file-integrity monitoring is wanted, that is a **new decision requiring its own issue**, not a Phase 3 checkbox. | `command -v aide` → empty (documented as absent, not silently skipped) |
| 3.2 | **auditd** — re-apply watches on the secret paths at their new device. Existing rules watch `/opt/jol/rag/.env` and `/etc/jol-mcp/mcp.env`; `/home/jol/secrets` and `/home/jol/.ssh` must be watched too if they are not already. | `sudo auditctl -l \| grep -E 'jol_secrets\|home/jol'` |
| 3.3 | **Backup scope** — add `/home` to the Phase 0 job as a **scheduled** run, not a one-off. A backup taken once during a migration is not a backup policy. | next scheduled snapshot exists and is fresh |
| 3.4 | **Capacity watchdog** — it re-reads `/etc/fstab` and the mount table every run, so gates 1/2/4 adapt automatically. Confirm the new volume appears in its census and that the old `p7` is no longer reported as `/home`. One hardcoded device string does need attention: gate 1's `/home` annotation matches `nvme0n1p7|/home$`, and the first alternative is now stale (the mount field still matches on the second). | `~/.local/bin/jol-workstation-capacity-check.sh` → the new mount is listed |
| 3.5 | **Docs** — update the workstation disk-layout record and `docs/servers/` if it describes this host; the fleet docs call this machine `admin01` while its hostname is `ubuntu`, and that mismatch already caused one near-miss in this thread. | grep the old partition table out of the docs |
| 3.6 | **CHANGELOG** — one CC8.1 row per mutating phase, with the ticket reference raised before close (§0.3). | `check-changelog-table.py` + `check-record-stamps.py` rc=0 |

---

## 6. What this does not fix

Named so nobody mistakes a storage plan for a resolved risk register:

1. **`/mnt/jol-backup` — RESOLVED 2026-11-05T12:33Z, retained as history.** The original defect: `/etc/fstab`
   named `/dev/sdb1`, a node that could never exist (`sdb` is a whole-disk LUKS USB stick with no partition
   table), so the mount silently became an ordinary directory on `/` and four nights of off-device Terraform
   state were lost. `fix-jol-backup-mount.sh` rewrote line 27 to resolve by UUID to `sda1`, added the missing
   `systemctl daemon-reload`, and gate 2 went from 10 mounts + 1 CRITICAL to 11/11 verified. The analysis
   below is kept because the *choice* it records is still live:

   > **`nofail` on this entry is a deliberate decision, and it is the OPPOSITE of the right choice for
   > `/home`.** Line 27 still reads `defaults,nofail,noatime`. That is not an oversight carried over from
   > the original defect. The asymmetry is the point:
   >
   > - **`/home` must fail loudly.** An absent `/home` means no SSH keys, no repos and a desktop that
   >   *looks* fine — so §3.2b and the Phase 2 fstab rewrite both refuse `nofail`, and a failure drops
   >   the boot into emergency mode.
   > - **A backup target must not.** Taking the whole workstation down into emergency mode because a
   >   backup disk is missing is a worse outcome than running without that night's backup.
   >
   > Two compensating layers make `nofail` safe here rather than merely tolerated: the backup service
   > carries `Requires=` on the mount unit, and the capacity watchdog's gate 2 compares each fstab
   > mountpoint's `stat -c %d` against `/` and fires CRITICAL within 15 minutes if the path has degraded
   > into a directory on the root filesystem. **If either layer is ever removed, `nofail` becomes the
   > original defect again.** The two defensible targets discussed at the time were:
   - **`sda1` (the HDD)** — what the existing data says the answer is; simple, always present, same box.
   - **the opened LUKS USB volume** — what the fstab line *says* the answer is; genuinely removable, so
     it is the only option that provides any off-premises protection. Needs a `/dev/mapper/<name>` UUID
     reference, an opener that runs before the timer, and a policy for "stick is absent" that is not
     `nofail`-and-hope.
   Either way the fix must reference a UUID that exists, and the job must keep failing loudly.

1a. **NEW, and it raises the urgency of item 1: `sda1` is no longer mounted at all.** The reboot at
    **2026-11-05 12:58** (required by the ADATA insertion) came back with the backup disk unmounted —
    `lsblk` reports no mountpoint, `/proc/mounts` has no `sda1` line, and `/media/jol/<UUID>` no longer
    exists. The volume was never in `/etc/fstab`; it was riding on **udisks desktop automounting**, which
    is session-scoped and does not survive a reboot into a non-desktop state.

    Consequences, in order:
    - The most recent off-device Terraform state copies are on a disk the OS cannot currently see.
      Nothing is lost, but **nothing is restorable until it is mounted**.
    - `jolarca-state-backup.service` last activated `2026-11-05 12:02:15`, is `inactive`, and will retry at
      `Fri 09:17` — where it will fail the same way, exhaust `StartLimitBurst` again, and halt. The cycle
      is now self-repeating.
    - This is the empirical proof of the warning in §2.1 about option B: **a removable or automounted
      device is not a backup dependency.** It also means my own watchdog, which correctly alerts, is
      reasoning from the wrong premise — `gate 2` only audits devices that are *in fstab*, so a disk that
      was never declared cannot be reported missing. `gate 5` catches it by artifact absence instead,
      which is why the alert fired at all.

    Fix: run `fix-jol-backup-mount.sh`, which puts `sda1` into fstab by UUID at `/mnt/jol-backup` so it
    mounts at boot rather than when a desktop feels like it.
2. **The HDD remains a ~2009 5400 rpm consumer drive** holding the only off-device Terraform state. This
   plan gives `/home` a fast disk; it does not make the backup chain durable. If money is eventually
   spent, that is the device to replace.
3. **`REQUIRE_OFF_HOST` still means "different block device", not "different machine."** Same PSU, same
   UPS, same building. pbs01 remote sync (the off-site leg) has been pending since 2026-08-01.
4. **`/home` growth is not stopped, only housed.** The consumers found on 2026-11-04 were regenerable
   caches — an abandoned JetBrains update extraction (3.6 G), an orphaned Go build cache (4.2 G with no Go
   toolchain installed), Chrome's on-device model (4.0 G). A bigger partition delays the problem; the
   watchdog's trend gate is what actually detects it.

---

## 7. Order of operations

```
1. fix-jol-backup-mount.sh           DONE 2026-11-05T12:33Z — fstab by UUID, gate 2 clean
2. Phase 0  back up /home + restore  DONE 2026-11-05T13:10Z — proof accepted by gate 0
   └ daily recurrence                 DONE — jol-home-backup.timer 03:40, gate 6 monitors it
3. Phase 1  provision-jolhome-disk   DONE 2026-11-05T14:29Z — LUKS2 + ext4 + crypttab + fstab,
                                        boot chain verified
   └ §3.6 sustained-write test       TOOLING DONE 2026-11-05 (jol-write-bench.sh, 27 fixtures,
                                        11 mutants red); EXECUTION still owner action
   └ custody gate (t6)               DONE — record-jolhome-custody.sh + a 12-branch
                                        custody_verdict; Phase 2 refuses without verify=PASS
4. Phase 2  move /home               PENDING — blocked on §4.0 items 1–4; jol-migrate-home.sh
5. Phase 3  re-derive AIDE / auditd / backup scope / watchdog / docs / CHANGELOG
```

One correction to this section's own history: it previously referred to a "§4.1" for the
`tune2fs -m 1` capacity win. **No §4.1 exists** in this document — that content is in
§2.0. A todo citing §4.1 was written from recollection of an edit rather than from the
file's actual headings, which is the same remembered-letter failure this runbook
documents at §3.1 and in the `/mnt/jol-backup` outage.

List items 1–3 (the backup-mount repair, Phase 0 and Phase 1) are complete and independently verified,
including the boot chain (cryptsetup.target → device → fsck → mount, all present in
`/run/systemd/generator/`). **Item 4 — the Phase 2 cutover — is the only remaining storage work, and it
is the only step that can leave the machine unable to log anyone in**, which is why it is scripted,
gated, fixture-tested and rehearsed in DRY_RUN rather than typed at a prompt. Item 5 (Phase 3,
re-deriving the compliance surface) follows it and is not started.

**D-2 does not close until item 4 completes.** Phase 1 produced an *empty* encrypted volume; as
long as `/home` is still `nvme1n1p7` plain ext4, the SSH private key and the Tier-1 secret material
remain unencrypted at rest. A correction to an earlier claim in this runbook's history: provisioning
the container is not the same as protecting the contents.

One consequence of Phase 1 that is already live and must be planned around: `/etc/crypttab` unlocks
`jolhome_crypt` with `none` as the key file, so **every boot now prompts for the passphrase on the
console**. An unattended reboot after a kernel update will sit at that prompt until someone types.
TPM2 enrolment was declined on 2026-11-05 ("maybe later"); §3.2 keeps the opt-in documented, and the
recovery keyslot from §3 step 3 is what makes that decision survivable.
