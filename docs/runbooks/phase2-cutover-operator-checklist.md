# Phase 2 cutover — offline operator checklist (rescue console)

**Revision this checklist was read from:** `d3c98ea8fa821ff1a39a480843a81688d4a727b3`
(`fix/home-migration-orchestration`, base `caf9e9f`), whose `MANIFEST-d3c98ea.sha256` verifies 19/19.
**Tool paths below assume the Prompt 2 install completed**, so the tools are at `/usr/local/bin`.
If they are not installed, **stop at step 0** — nothing here works without them.

**Entering rescue ends the PyCharm/Qoder session.** This file is readable with `/home` unmounted from:
`/opt/jol/delivery/jol-home-migration-OPERATOR-CHECKLIST.md` (on `/dev/nvme1n1p8`, mounted by fstab,
survives the cutover) and in the repository at `docs/runbooks/`. `/mnt/jol-backup` is also on a
different disk. **Do not rely on anything under `/home` after step 3.**

Print it or photograph it before you start.

---

## Known UUIDs — verify, never trust this table

| Role | Token | Verify with |
|---|---|---|
| Old `/home` filesystem (Samsung 980 PRO, `nvme1n1p7`) | `cfe5c075-9637-4b8d-9912-d8e6acdc2472` | `blkid -U /dev/nvme1n1p7` |
| LUKS header on the ADATA (`nvme2n1p1`) | `4fc2ae29-3dd3-43c7-b43b-325ba9ed2690` | `cryptsetup luksUUID /dev/nvme2n1p1` |
| Inner ext4 filesystem (destination `/home`) | `15325864-4913-4983-a8cb-d214aa33f516` | `blkid -U /dev/mapper/jolhome_crypt` |

The tool refuses when the LUKS UUID equals the filesystem UUID — that equality is the signature of a
device resolved to the wrong side of the mapper. If `lsblk` shows you a `jolhome_crypt` where you wanted a
partition node, you are reading the holder, not the partition: filter on `TYPE=="part"`.

**Device letters are not identifiers.** `nvme2n1` was renumbered once on 2026-11-05 when a drive was
added. Resolve by UUID only, in every command below.

---

## Step 0 — preconditions (do NOT start if any fails)

```
ls -l /usr/local/bin/jol-migrate-home.sh /usr/local/bin/jol-record-custody.sh /usr/local/bin/jol-backup-home.sh
```
All three must exist at mode 755. If any is missing, the cutover cannot run; there is no fallback path.

```
sudo /usr/local/bin/jol-migrate-home.sh --preflight; echo "rc=$?"
```
Expect **rc=0**. Interpretation is from the installed revision, not from memory:

| rc | Meaning (this revision's own words) | Action |
|---|---|---|
| `0` | `PREFLIGHT CLEAN — the cutover window can be booked` | proceed |
| `1` | `PREFLIGHT NOT YET: N finding(s), all of them the busy-desktop reading` | proceed — they clear in rescue |
| `2` | `PREFLIGHT BLOCKED: N finding(s). <n> clear themselves in rescue.target; the other <m> must be fixed BEFORE the window is booked` | **STOP** |

⚠ `rc=1` means **every** finding is the busy desktop. `rc=2` explicitly notes that *"changing runlevel
does not make an unreadable artifact readable"* — so a `2` is never fixed by entering rescue.

---

## Step 1 — enter rescue (this kills the IDE session)

```
sudo systemctl isolate rescue.target
```

`rescue.target` keeps `local-fs`, so `/opt/jol`, `/mnt/jol-backup` and the `jolhome_crypt` mapping stay
available while the desktop and all its writers stop. You will be at a root shell on the physical console.

**If the LUKS prompt appears, type the volume passphrase.** `crypttab` holds key file `none` (TPM2
enrolment was declined 2026-11-05 and the tool re-checks that decision every run), so **every** boot
prompts. `apt` `Automatic-Reboot` is unset — nothing reboots this machine by itself.

---

## Step 2 — confirm the writers are stopped

```
systemctl is-system-running
findmnt -no SOURCE,FSTYPE,OPTIONS /home            # EXPECT IT STILL MOUNTED, read-write, at this point
ps -eo user,pid,comm | grep -cE 'gnome-shell|chrome|node|pycharm|qoder'
```
Expected: the process count near zero. **`/home` will still be mounted — do not unmount it here.**
Measured on this host: `rescue.target` carries `Requires=sysinit.target` and `sysinit.target` carries
`Wants=local-fs.target`, so `local-fs` is not torn down by entering rescue.

**Ordering rule that decides whether the window produces a proof.** The backup job reads
`SOURCE="${SOURCE:-/home}"` — a **path**. So:

1. Step 4 (fresh proof) runs while `/home` is mounted, and
2. only **after** the proof is `/home` released and staged read-only for the copy (Step 3).

Unmounting `/home` before Step 4 makes the job scan the empty mountpoint directory on `/`; its own guards
fire correctly (`"no suitable file found in the snapshot …"`, `"the snapshot reports 0 entries …"`) and the
run ends with **no proof** — which is exactly the wasted window this correction exists to prevent. The
steps are numbered 3 then 4 because Step 3 also proves the read-only staging works; execute Step 4's proof
before Step 3's `umount`.

The quiescence guard measures **`COPY_SRC`**, not `/home`: it refuses a live read-write copy source above
`MAX_BUSY_PROCS=8`, and `LIVE_RW_SOURCE` is fatal for the fstab-swapping run. Do not "fix" a refusal by
editing that number — make the source read-only instead.

---

## Step 3 — mount the old home READ-ONLY, and only as the copy source

```
mkdir -p /mnt/home-src
mount -o ro /dev/disk/by-uuid/cfe5c075-9637-4b8d-9912-d8e6acdc2472 /mnt/home-src
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/home-src     # OPTIONS must contain ,ro
ls /mnt/home-src                                    # expect jol/ lost+found/ testuser/
```

**The single most important distinction in this procedure.** `COPY_SRC` is where the tree is physically
readable. `HOME_MOUNT` is the fstab identity being rewritten and is **not a knob**. Setting
`HOME_MOUNT=/mnt/home-src` or `HOME_MOUNT=/mnt/jolhome-staging` makes the machine boot wrong. The
reviewed revision accepts `HOME_SRC` as a synonym for `COPY_SRC` only, precisely because an earlier
document conflated them and the offline form could not run at all.

```
export COPY_SRC=/mnt/home-src        # NOT HOME_MOUNT
```

Confirm the destination before copying anything:

```
findmnt -no SOURCE,FSTYPE /mnt/jolhome-staging      # /dev/mapper/jolhome_crypt ext4
df -h /mnt/jolhome-staging                          # expect ~928 GiB free
find /mnt/jolhome-staging -mindepth 1 -not -name lost+found | wc -l    # expect 0
```
A non-zero count means a previous interrupted run left entries; the tool will report
`RESUME_NOT_AUTHORIZED` and you must decide deliberately whether to `RESUME=1` or clear them.

---

## Step 4 — re-check backup freshness, and refresh if required

The gate is `PROOF_MAX_AGE_H=6`: the proof must be **less than 6 hours old**, or the cutover dies.

```
sudo /usr/local/bin/jol-backup-home.sh --report
ls -l /var/lib/jol-workstation/home-backup-proof
```

**Known blocker as of 2026-11-07:** every scheduled run exits `1` because `rsync` returns **24** ("some
files vanished") on a live `/home`, and the script treats any non-zero as failure and writes no proof.
The last run (11:31:37Z) copied 1,104,456 files and 8.90 GB successfully and still reported FAILURE.

### ⚠ Correction — do NOT unmount `/home` before taking the proof

An earlier version of this step said taking the proof from rescue, with `/home` unmounted, would now
succeed because nothing can vanish. **That is wrong, and it would have wasted the window.** The backup
script reads a **path**, not a device:

```
backup-workstation-home.sh:51   SOURCE="${SOURCE:-/home}"
```

Unmount `/home` and it reads the **empty mountpoint directory on the root filesystem**, not the Samsung.
Two guards then fire, correctly and loudly, and no proof is written:

```
:250  fail "no suitable file found in the snapshot to restore-probe — the copy looks empty"
:277  fail "the snapshot reports 0 entries — an empty measurement is not a backup"
```

So the empty-source trap is genuinely guarded — an unmounted `/home` cannot certify a backup. But the
procedure must still keep the Samsung mounted **at the path the script reads** while the proof is taken.

### Correct rescue-mode sequence for a fresh proof

`/mnt/home-src` is created later, for the copy. For the proof, mount the Samsung at `/home` itself:

```bash
mount /home                                   # fstab line 14, by-uuid cfe5c075-… — or mount -o ro it
findmnt -no SOURCE,FSTYPE /home               # MUST show /dev/nvme1n1p7, NOT a directory on /
ls /home | head -3                            # MUST show jol/ and testuser/, never empty
sudo env DRY_RUN=1 /usr/local/bin/jol-backup-home.sh     # plan first; check the source line names device 66314
sudo env DRY_RUN=0 /usr/local/bin/jol-backup-home.sh     # run; require rc=0
sudo cat /var/lib/jol-workstation/home-backup-proof      # read the snapshot id it names
```

With nothing writing to `/home`, `rsync` cannot lose files to churn, so exit 24 should not recur and rc=0
should produce a proof. **The job's own verification already does what this step asks of it:** it measures
churn against a stated ceiling (`:232`, using `--out-format='%n'` so the count is names, not itemise
codes), restores **a file chosen from the snapshot itself** into a `mktemp -d` scratch and byte-compares it
(`:250-262` — the probe cannot pass by comparing a file that was never copied), and proves the Tier-1
secrets tree survived using only `diff -rq`'s **exit status**, with contents never read or printed
(`:264-275`).

Then, and only then, set up the read-only copy source at `/mnt/home-src` (Step 3) — the same device may be
mounted read-only at both paths, which is safe precisely because neither is writable.

**If it still fails: STOP.** Do not substitute a hand-rolled copy for the reviewed job and do not delete the
proof gate. Note the residual the probe leaves open: its file selection excludes `secrets/`, `.cache/` and
`*.sock` but **not** `.ssh/`, `.aws/`, `.kube/` or `.config/gh`, so it may briefly duplicate one credential-
bearing file into root-owned `mktemp -d` scratch (mode 700, removed afterwards). Low risk, worth narrowing
as a separate change rather than a blocker here.

---

## Step 5 — run the reviewed plan, and read it

```
sudo env DRY_RUN=1 COPY_SRC=/mnt/home-src /usr/local/bin/jol-migrate-home.sh
```

This prints the fstab line it intends to write and the identity resolution, and mutates nothing. Read the
UUIDs against the table at the top. **Verify 3/6 needs `getfacl`; if `attr` is absent the tool dies with
rc=127 rather than reporting ACLs as preserved** — install `attr` or set `STRUCT_VERIFY=0` knowingly, and
understand that declines ACL/xattr verification and is recorded as *declined, not passed*.

## Step 6 — copy the full tree

```
sudo env DRY_RUN=0 COPY_SRC=/mnt/home-src /usr/local/bin/jol-migrate-home.sh
```

Defaults in force: `CONTENT_VERIFY=sample` (rsync `-c` over the whole tree **plus** a sha256 manifest over
`CRITICAL_SUBPATHS=.ssh .gnupg .aws .kube .config/gh`), `STRUCT_VERIFY=1` (type, mode, owner:group, link
count and symlink target for every entry, plus recursive ACL and xattr dumps, plus hard-link group
comparison both sides — a collapsed hard link changes no path, mode, owner, content or count, so the five
earlier checks would all pass on a silently destroyed topology). `CONTENT_VERIFY=off` is **refused**:
declining to compare bytes is a decision that must be named, never a default.

`ALLOW_LIVE_SOURCE` exists only for rehearsal and is **never appropriate for the run that swaps fstab**.

**Stop condition:** any verify failure. The copy is resumable — the state marker
`.jol-home-migration-state` records `schema`, `src_uuid`, `dst_uuid`, `state`, and `--partial-dir` keeps
truncated files out of the destination tree. Fix the cause and re-run; do not lower the verify level to
get a green.

## Step 7 — the boot configuration changes only on an explicit token

```
sudo env DRY_RUN=0 CONFIRM_CUTOVER=1 COPY_SRC=/mnt/home-src /usr/local/bin/jol-migrate-home.sh
```

Without `CONFIRM_CUTOVER=1` the tool refuses to install a new fstab and says so: *"The plan above is what
would be written. Re-run with CONFIRM_CUTOVER=1 once you have read it."* The write is atomic (the earlier
`printf > fstab` truncation, which could leave a machine with no readable fstab, is fixed), it writes the
`UUID=` form, and it **comments the old `/home` line in place** rather than deleting it, tagged
`# PHASE2-CUTOVER: previous /home retained as rollback (restore by uncommenting)`.

**Confirm before you reboot.** Do not eyeball this — count it, with a test that works for *any* source
form (`/dev/disk/by-uuid/…`, `UUID=…`, `LABEL=…`), because the retired line on this host uses the by-uuid
path form and a check keyed to `^UUID=` would report one active line while two exist:

```bash
sudo awk '!/^#/ && $2=="/home"' /etc/fstab | tee /dev/stderr | wc -l   # MUST print 1
# Compare the UUID, not the syntax. rewrite_fstab() normalises BOTH `UUID=` and
# `/dev/disk/by-uuid/` prefixes to a bare UUID (its own `sub(/^UUID=/,"")` and
# `sub(/^\/dev\/disk\/by-uuid\//,"")`), so asserting a particular literal form is a
# check that can fail on a correct file. Extract the 36-char UUID from whichever form
# the line uses and compare that.
sudo awk '!/^#/ && $2=="/home" {print $1}' /etc/fstab \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'      # MUST be 15325864-4913-4983-a8cb-d214aa33f516
```

If the count is not exactly `1`, **do not reboot.** Two active `/home` lines is not a warning — the second
silently shadows the first, and the reviewed tool's own history records a guard that counted only
`^UUID=` lines, saw `1`, and passed over a fstab with two (#6 in its defect list). Verify with the tool,
not with your eyes:

```
sudo /usr/local/bin/jol-migrate-home.sh --preflight; echo "rc=$?"    # rc=0 required before reboot
umount /mnt/home-src     # do NOT leave the old home mounted under two names
```

Also record the fstab you are about to leave behind, off `/home`, so recovery is possible if the root fs is
the only thing left mounted:

```
sudo cp -a /etc/fstab /etc/fstab.pre-cutover-$(date -u +%Y%m%dT%H%M%SZ)
sudo cp -a /etc/fstab /mnt/jol-backup/fstab.pre-cutover-$(date -u +%Y%m%dT%H%M%SZ)
```

---

## Recovery — depends entirely on which side of Step 7 you failed on

### A. Failure BEFORE the fstab was written (steps 2–6)

Nothing in the boot configuration changed. The machine still mounts `/home` from the Samsung.

```
umount /mnt/home-src 2>/dev/null
sudo systemctl isolate multi-user.target
```
Then investigate at the desktop. The destination may hold a partial copy; that is inert until fstab points
at it. If you intend to retry, decide about `.jol-home-migration-state` explicitly (`RESUME=1` to continue,
or clear the destination's entries) rather than letting the tool guess.

### B. Failure AFTER the fstab was written (step 7 onward)

The Samsung is untouched and still holds a complete, unmodified `/home`. Step 7 saved two copies of the
original fstab — one on the root filesystem, one on the backup HDD, which is a different device and
therefore survives a root-filesystem problem. **Restoring a known-good copy is the primary action**; hand-
editing is the fallback, and hand-editing is exactly where the two-active-`/home`-lines defect lives.

### B1. Restore the saved fstab (primary)

```
sudo ls -1 /etc/fstab.pre-cutover-* /mnt/jol-backup/fstab.pre-cutover-* 2>/dev/null
F=$(sudo ls -1t /etc/fstab.pre-cutover-* 2>/dev/null | head -1)
[ -n "$F" ] || F=$(sudo ls -1t /mnt/jol-backup/fstab.pre-cutover-* 2>/dev/null | head -1)
echo "restoring from: $F"
sudo cp -a /etc/fstab "/etc/fstab.failed-$(date -u +%Y%m%dT%H%M%SZ)"   # keep the broken one for review
sudo cp -p  "$F" /etc/fstab                                            # restore the ORIGINAL, byte-for-byte
```

If neither glob yields a file, **do not improvise** — go to B2. An absent saved copy is itself a finding
worth recording: Step 7 was supposed to create two.

Then verify the restored file is the original, before anything tries to mount it:

```
sudo diff "$F" /etc/fstab && echo "IDENTICAL to the saved original"
sudo awk '!/^#/ && $2=="/home"' /etc/fstab | wc -l     # MUST print 1
sudo awk '!/^#/ && $2=="/home" {print $1}' /etc/fstab \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'   # MUST be cfe5c075-…
sudo systemctl daemon-reload
sudo systemctl isolate multi-user.target
```

### B2. Hand-edit the fstab (only if no saved copy exists)

```
sudo cp -a /etc/fstab /etc/fstab.failed-$(date -u +%Y%m%dT%H%M%SZ)
# in /etc/fstab: uncomment the line tagged "# PHASE2-CUTOVER: previous /home retained as rollback"
#                 AND comment the new UUID=15325864-… line.
#                 Uncommenting alone leaves TWO active /home entries — which is the very defect
#                 this rollback path would then reintroduce.
sudo awk '!/^#/ && $2=="/home"' /etc/fstab | wc -l         # MUST print 1
sudo awk '!/^#/ && $2=="/home" {print $1}' /etc/fstab \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'   # MUST be cfe5c075-9637-4b8d-9912-d8e6acdc2472
sudo systemctl daemon-reload
sudo systemctl isolate multi-user.target
```

If the count is not `1`, fix the file before rebooting. Do not let systemd resolve it: whichever line
mounts last wins and the other is silently shadowed rather than reported.

If the machine will not boot at all, edit the line at the GRUB command line (read-only `init=` break to a
shell, `mount -o remount,rw /`, fix fstab, reboot) or boot from removable media and edit
`/dev/nvme1n1p3`'s `/etc/fstab` directly. **Do not `mkfs`, `wipefs` or delete anything on `nvme1n1p7` —
it is the rollback, not scratch space.** Keep it unmodified until you have decided, with evidence, that
the new `/home` is trustworthy.

If the new `/home` mounts but the passphrase is lost: the recovery keyslot is the path, and the custody
attestation is what proves it works. `systemd-cryptenroll`, **not** `cryptsetup`, is the tool for adding a
slot later — measured on this host, `cryptsetup` advertises no TPM support while `systemd-cryptenroll`
does.

---

## Step 8 — after reboot, verify (paste-ready, run from the desktop)

```
findmnt -no SOURCE,FSTYPE,OPTIONS /home        # expect /dev/mapper/jolhome_crypt ext4, no ,ro
lsblk /dev/nvme2n1p1                           # partition -> jolhome_crypt -> /home
df -h /home                                    # expect ~938 GiB total
id; ls ~; du -sh ~/repos 2>/dev/null
```
`/opt/jol/repos` must be present and unchanged (`git -C /opt/jol/repos/jol-infrastructure status` should
show the same staged/unstaged picture you left). Then application access, and:

```
sudo /usr/local/bin/jol-backup-home.sh --report          # backup coverage still passes
systemctl list-timers | grep -E 'jol-home-backup|jol-workstation-capacity|jol-fleet-health'
# Capacity monitoring is NOT one of the six installed tools. The installer manifest names
# exactly: jol-backup-home, jol-fix-backup-mount, jol-provision-home-disk, jol-migrate-home,
# jol-record-custody, jol-write-bench. Capacity runs as a SYSTEMD USER timer with the script
# at ~/.local/bin/jol-workstation-capacity-check.sh. The path
# /usr/local/bin/jol-workstation-capacity.sh does not exist and never will — an earlier
# revision of this checklist told you to run it, and a "command not found" there would have
# looked like a monitoring failure rather than a wrong path.
~/.local/bin/jol-workstation-capacity-check.sh --report; echo "rc=$?"
systemctl --user is-active jol-workstation-capacity.timer
```

Two coverage gaps created by this migration, both must be closed deliberately:
1. **`/home` is now `/dev/nvme2n1p1`, not `nvme1n1p7`.** Any monitoring, backup job, fstab comment or
   evidence file naming the old partition is now describing a device that no longer holds `/home`.
2. **A job that enumerates mount points will silently stop covering `/home`** if it keys on the mount
   rather than the device — the same silent-gap class as the open D-1 finding.

---

## What this checklist does not cover

- **Issue #156** (plaintext Tier-1 secrets and an SSH private key on an unencrypted on-host HDD) is
  **unresolved and has no agreed disposition.** It is not a cutover blocker — the rollback is the untouched
  Samsung, not the backup — but the cutover does not close it either, and D-2 remains true on the backup
  disk after `/home` is encrypted. Report it separately.
- **§3.6 sustained-write characterisation has never been run** on this drive, so the window length below
  is a bracket, not a measurement.
- **The install (Prompt 2) and the rsync-24 fix are prerequisites of Step 0**, not part of this window.

## Time bracket for the window

Payload measured 79 GiB / 1,093,580 live paths (1,075,380 in the proof snapshot). The copy is **not** the
dominant term and an earlier version of this checklist said it was; corrected here.

| Phase | Basis | Estimate |
|---|---|---|
| Copy 79 GiB | DRAM-less TLC sustained 150–500 MB/s (unmeasured) | 3–9 min, 18 min at an 80 MB/s collapse |
| `CONTENT_VERIFY=sample` | `rsync -c` hashes **both sides** of 1.09 M files / 79 GiB | 10–25 min |
| `STRUCT_VERIFY=1` | type/mode/owner/link-count/symlink manifest + recursive `getfacl` and xattr dumps over 1.09 M entries, on both sides | **15–40 min** |
| Reboot + passphrase + settling | console, one factor | 5–10 min |
| Rollback margin | | 10 min |

**Planning figure: 60–120 minutes, and verification dominates it.** Booking 30 minutes because "76 GiB at
4.7 GB/s is under two minutes" would be a serious mis-plan: 4.7 GB/s is the SLC-cache burst, and this
copy runs straight past it.

⚠ **This is a bracket, not a measurement.** §3.6 has never been run on this drive, and `write-bench-*.tsv`
files on this host: **0**. If the 32 GiB test never reaches a flat tail, the sustained rate is not merely
unknown but **unbounded below**, and the window must be re-planned from the plateau the tool prints
(`<76> GiB at the SUSTAINED rate = <N> min of copy time`). Until that line exists, treat 60–120 as a
booking ceiling and not as an estimate with a measured middle.
