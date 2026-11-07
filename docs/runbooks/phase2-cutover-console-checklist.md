# Phase 2 cutover — console checklist (host `ubuntu`, measured 2026-11-07T17:53Z)

Companion to `workstation-storage-990pro-home-migration.md` §4 and to
`install-and-custody-operator-procedure.md`. Every value below was read from the host at the hour
stated; nothing here is recalled from an earlier run.

Readable while `/home` is offline: this repo lives on `/dev/nvme1n1p8` (`/opt/jol`, fstab line 16,
**no `nofail`** → mounted by `local-fs.target`, which `rescue.target` still pulls). PyCharm, the agent
and the IDE config live **under `/home`** and die at step B1. A printed or `cat`-ed copy of this file is
the only checklist that survives entering the window.

| Fact | Measured value |
|---|---|
| `/home` source | `/dev/nvme1n1p7`, Samsung SSD 980 PRO 1TB, FS UUID `cfe5c075-9637-4b8d-9912-d8e6acdc2472` |
| `/home` payload | 79 GiB used (83,141,136 KiB), 7.2 GiB free, 92 %, **1,095,477 entries**, 6,111,232 inodes |
| Destination | `/dev/mapper/jolhome_crypt` on ADATA LEGEND 900 (`nvme2n1p1`, LUKS header UUID `4fc2ae29-3dd3-43c7-b43b-325ba9ed2690`), ext4 FS UUID `15325864-4913-4983-a8cb-d214aa33f516`, 938 GiB, 62,513,152 inodes, **holds only `lost+found`** |
| Backup disk | `/dev/sda1` = ST9320423AS (320 GB, 5400 rpm), UUID `32f7e56a-b96c-486a-93da-9e1a57567cfc`, 176 GiB free, mounted `/mnt/jol-backup` |
| Newest VALID proof | `utc=20261106T093000Z`, written **2026-11-06T09:33:04Z** — `payload_kib=81480532 entries=1098533 churn=221 probe=byte-identical secrets=match` → **32 h old**, past the 6 h gate |
| Newest snapshot dir | `home-20261107T112927Z` — **INCOMPLETE, no proof**: rsync code 24, unit state `failed` |

---

## A. Close these BEFORE `isolate rescue.target` (they need the IDE, root, or a real tty)

- [ ] **A1 — Install the six tools.** Three are absent (`jol-migrate-home.sh`, `jol-record-custody.sh`,
      `jol-write-bench.sh`); the three present are `750 root:root` rather than the manifest's `755`.
      Verify the wrapper first, then run it **as root** (`sudo sha256sum -c --strict - <<< '<761ede01…>  /usr/local/sbin/install-d3c98ea.sh' && sudo bash /usr/local/sbin/install-d3c98ea.sh`).
      Require the final line `SIX INSTALLED AND VERIFIED … mode 755 root:root`.
- [ ] **A2 — Record the custody attestation.** The cutover **dies** without it; needs `/dev/tty` + root:
      `sudo env DRY_RUN=0 /usr/local/bin/jol-record-custody.sh`
      Type the recovery passphrase only at cryptsetup's prompt. Answer the reachability question `yes`
      ONLY if you can read that passphrase at a physical console with `/home` unmounted.
      Confirm the gate accepts it:
      `sudo /usr/local/bin/jol-migrate-home.sh --check-attestation /var/lib/jol-workstation/jolhome-custody`
      → expect `PASS`, rc 0. The path is **argv[2] and required**; a bare invocation prints `NO_PATH`, rc 2.
- [ ] **A3 — Measure the ADATA plateau (§3.6).** It sizes the whole window:
      `DRY_RUN=1 /usr/local/bin/jol-write-bench.sh` → read the plan → `sudo env DRY_RUN=0 /usr/local/bin/jol-write-bench.sh`
      → then `ls -A /mnt/jolhome-staging/` must show **only `lost+found`** (the script verifies this itself).
      Book from `SUSTAINED_MiBps`, **not** `WINDOW_MIN_FOR_76GIB` — the payload is 79 GiB, not 76.
- [ ] **A4 — Commit and push every repo under `/opt/jol`.** `git -C /opt/jol/repos/jol-infrastructure status --short`
- [ ] **A5 — Physical console + keyboard at the machine, and the root password.** No SSH inside the window.
      `/home` carries **no `nofail`** deliberately: a failed mount drops the boot into emergency mode
      loudly. That is the design, not a regression.

## B. In the window (root shell on the console)

- [ ] **B1** `systemctl isolate rescue.target`
- [ ] **B2** Confirm what the cutover depends on is actually up:
      `findmnt -no SOURCE,OPTIONS /opt/jol` → `nvme1n1p8` · `findmnt -no SOURCE /mnt/jolhome-staging` → `/dev/mapper/jolhome_crypt`
- [ ] **B3** Take the source quiet and read it **AT `/home`** (the backup job resolves `SOURCE=/home` by path):
      `mount -o remount,ro /home` → `findmnt -no OPTIONS /home` **must contain `,ro`**
      If busy: `fuser -mv /home`, stop those, retry. A read-only source makes rsync code 24 structurally
      impossible — which is exactly why the proof is taken here and not from the desktop.
      Runbook variant: `umount /home; mount -o ro /dev/disk/by-uuid/cfe5c075-… /mnt/home-src`, then pass
      `HOME_SRC=/mnt/home-src`. Both shapes are accepted (`OK_READONLY_MOUNT` / `OK_OFFLINE_RO`).
- [ ] **B4** Fresh proof, timed close to the copy:
      `sudo env DRY_RUN=1 /usr/local/bin/jol-backup-home.sh` → `sudo env DRY_RUN=0 /usr/local/bin/jol-backup-home.sh`
      `cat /var/lib/jol-workstation/home-backup-proof` — require all three claims on the one line:
      `PASS` prefix · `utc=<the new dir suffix>` · `probe=byte-identical` **and** `secrets=match`.
      Cross-check the name: `ls -1d /mnt/jol-backup/jol-home-backup/home-* | tail -1`
- [ ] **B5** `sudo /usr/local/bin/jol-migrate-home.sh --preflight; echo rc=$?` → require **0**, or **1** only
      when every remaining finding is desktop activity. **2 = stop and name the blocker.**
- [ ] **B6** Plan, then execute:
      `sudo DRY_RUN=1 /usr/local/bin/jol-migrate-home.sh`
      `sudo DRY_RUN=0 CONFIRM_CUTOVER=1 /usr/local/bin/jol-migrate-home.sh`
      Never set `ALLOW_LIVE_SOURCE=1` for the real cutover.
- [ ] **B7** `reboot` — **never `mount -a`** (it would stack the new filesystem over the live one).

## C. First boot after the cutover

- [ ] `findmnt -no SOURCE,FSTYPE,OPTIONS /home` → `/dev/mapper/jolhome_crypt ext4 … noatime`, **not `nofail`**
- [ ] `df -h /home` → 938 GiB class, not 92 GiB · `df -i /home` → 62.5M inodes
- [ ] `grep -c PHASE2-CUTOVER /etc/fstab` → **1** (0 means the rewrite matched nothing) ·
      `awk '$2=="/home" && $1 !~ /^#/ {n++} END{print n}' /etc/fstab` → **exactly 1**
- [ ] `ls -ld /home/jol /home/jol/.ssh` · `ssh -T git@github.com` · `git -C /opt/jol/repos/jol-infrastructure status`
- [ ] `ls -A /mnt/jolhome-staging` → no `.wtest` residue, no stale state marker
- [ ] Rollback for **at least a week**: `nvme1n1p7` was never modified — it IS the rollback:
      `sudo cp -p /etc/fstab.bak.<TS> /etc/fstab && sudo systemctl daemon-reload && sudo reboot`
      Writes made to the new `/home` before a rollback decision exist **only** there; salvage them first.

## D. STOP conditions — report, do not improvise

- rsync non-zero / `code 24` in the backup → **no proof is written**, by design. Do not relax the policy;
  take the source read-only (B3) instead.
- `FOREIGN_DATA` / `ORPHAN_PARTIAL` / `RESUME_NOT_AUTHORIZED` → stop and name the entries. Nothing is
  merged or erased without an explicit `RESUME=1`.
- cryptsetup rejects the recovery passphrase → **change no keyslot**: no `luksAddKey`, no `luksKillSlot`,
  no reformat. `systemd-cryptenroll`, not `cryptsetup`, is the tool for adding a slot later.
- Any failure **after** `fstab installed atomically` is a rollback, not an abort.
