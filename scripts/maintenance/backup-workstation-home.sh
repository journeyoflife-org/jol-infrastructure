#!/usr/bin/env bash
# =============================================================================
# backup-workstation-home.sh — Phase 0: give /home a second copy, and PROVE it
#
# WHY THIS EXISTS. `provision-jolhome-disk.sh` gate 0 refuses to run unless a
# fresh proof artifact exists at $HOME_BACKUP_PROOF. On 2026-11-05 I measured
# that nothing in this repository WRITES that artifact — grep for
# HOME_BACKUP_PROOF returns only the reader. A gate whose input has no producer
# is worse than no gate: it either blocks forever or gets deleted under
# pressure. This script is the producer.
#
# THE UNDERLYING FINDING (measured 2026-11-05):
#   /home is 79 GiB, holds an SSH private key and Tier-1 secret material, is
#   unencrypted at rest (plain ext4, /etc/crypttab has zero entries), and is
#   backed up by NOTHING: `crontab -l | grep -ic home` -> 0. The backup HDD
#   holds only Terraform state. One disk failure, or one bad step in the
#   migration this enables, and it is gone.
#
# WHAT COUNTS AS A BACKUP HERE. Not "rsync exited 0" and not "files are there".
# Three things, all of which must pass before the proof is written:
#   1. the destination is provably a DIFFERENT BLOCK DEVICE than / — checked by
#      device identity, never by `findmnt` on a subdirectory (which resolves to
#      the parent and lies; that is how four nights of state backups were lost);
#   2. a dry-run re-scan reports acceptable churn, counted and printed, never
#      assumed zero;
#   3. a file is copied BACK out of the snapshot and byte-compared. A backup
#      nobody has restored is a hope, not a copy.
#
# Idempotent, DRY_RUN by default, non-destructive. Pruning of old snapshots
# happens ONLY after a new one has been verified, and never below KEEP_MIN.
#
# Exit: 0 backup verified + proof written, 1 backup attempted and FAILED (no
#       proof written), 2 guard (not root / wrong host / target not eligible).
# Usage:
#   sudo DRY_RUN=0 ./backup-workstation-home.sh
#   sudo ./backup-workstation-home.sh --clear      # remove the proof, to prove
#                                                   # gate 0 actually discriminates
#   ./backup-workstation-home.sh --report           # read-only status, no root
# =============================================================================
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# sda1 — the 290 GiB ext4 partition on the internal SATA disk. Resolved by UUID,
# never by an sdXn letter: on 2026-11-05 a single disk removal renumbered every
# NVMe node, and a remembered letter is exactly what made /etc/fstab reference
# /dev/sdb1, a device that has never existed.
TARGET_UUID="${TARGET_UUID:-32f7e56a-b96c-486a-93da-9e1a57567cfc}"
BACKUP_OWNER="${BACKUP_OWNER:-jol}"
SNAP_SUBDIR="${SNAP_SUBDIR:-jol-home-backup}"
SOURCE="${SOURCE:-/home}"
PROOF_FILE="${PROOF_FILE:-/var/lib/jol-workstation/home-backup-proof}"
KEEP="${KEEP:-3}"                     # snapshots retained
KEEP_MIN=1                            # never prune below this
CHURN_MAX="${CHURN_MAX:-500}"         # differing entries tolerated on a live fs
DRY_RUN="${DRY_RUN:-1}"
MODE=backup
case "${1:-}" in
    --clear)  MODE=clear ;;
    --report) MODE=report ;;
esac

say()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { say "FAIL: $*"; say "No proof record written. gate 0 will still refuse."; exit 1; }
guard() { say "ABORT: $*"; exit 2; }
# NOTE: there is deliberately no run() wrapper here. An earlier draft had one, and
# after DRY_RUN was moved to an early exit it acquired ZERO call sites — dead code
# in a checker is its own finding (see the Basilica assert_command() case: defined
# and never called). DRY_RUN is enforced by exiting before the first mutation,
# which is stronger than sprinkling guards at each call site.

# --- guards ------------------------------------------------------------------
HOST_ID="$(hostname -s 2>/dev/null || echo unknown)"
for h in pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01; do
    [[ "$HOST_ID" == "$h" ]] && guard "$h is a fleet host; this backs up the custodian workstation's /home"
done

if [[ "$MODE" == "clear" ]]; then
    [[ "$(id -u)" -eq 0 ]] || guard "--clear needs root (the proof file is root-owned)"
    rm -f "$PROOF_FILE" && say "Cleared $PROOF_FILE — provision-jolhome-disk.sh gate 0 will now refuse to run."
    exit 0
fi

LINK="/dev/disk/by-uuid/$TARGET_UUID"
[[ -e "$LINK" ]] || guard "$LINK does not exist — the backup disk is not present. Refusing to guess a device name."
REAL="$(readlink -f "$LINK")"

# Where is that device actually mounted? Ask the kernel, not a remembered path.
# This works BOTH now (udisks mounts it at /media/jol/<UUID>) and after
# fix-jol-backup-mount.sh puts it in fstab at /mnt/jol-backup.
MOUNT="$(lsblk -no MOUNTPOINTS "$REAL" 2>/dev/null | grep -v '^$' | head -1)"
if [[ -z "$MOUNT" ]]; then
    guard "$REAL is not mounted anywhere. Run fix-jol-backup-mount.sh, or mount it explicitly, first."
fi
DEST="$MOUNT/$SNAP_SUBDIR"

RDEV="$(stat -c '%d' /)"
MDEV="$(stat -c '%d' "$MOUNT")"
if [[ "$MDEV" == "$RDEV" ]]; then
    guard "$MOUNT resolves to the root filesystem (device $RDEV) — the mount is not real.
       This is the exact condition that silently lost the Terraform state backups.
       Writing a 'backup' here would write it onto the disk it is meant to protect against."
fi

if [[ "$MODE" == "report" ]]; then
    # The df text is built separately. Inlining `awk '{print $2" total, ..."}'` inside a
    # double-quoted say() argument makes the inner quotes CLOSE THE OUTER ONE, so awk
    # received a truncated program and the report printed `source : /home on device 66314 ()`.
    # Measured on the 2026-11-05 run: `awk: line 1: extra ')'`.
    SRC_DF="$(df -h "$SOURCE" 2>/dev/null | tail -1 | awk '{print $2" total, "$3" used, "$4" free"}')"
    say "source     : $SOURCE on device $(stat -c '%d' "$SOURCE") ($SRC_DF)"
    say "destination: $DEST on $REAL device=$MDEV (root device=$RDEV) -> OFF-DISK"
    say "free there : $(df -h "$MOUNT" | tail -1 | awk '{print $4}')"
    # `grep -c` prints 0 AND exits non-zero on no match, so `|| echo 0` appended a SECOND
    # zero. `|| true` keeps the single printed value without the extra one.
    SNAP_COUNT="$(find "$DEST" -maxdepth 1 -type d -name 'home-*' 2>/dev/null | grep -c . || true)"
    say "snapshots  : ${SNAP_COUNT:-0}"
    say "proof      : $(cat "$PROOF_FILE" 2>/dev/null || echo 'ABSENT — gate 0 refuses')"
    exit 0
fi

# Root is needed to READ all of /home and to write the snapshot. It is not needed
# to see the plan: every number below comes from df/stat, which are unprivileged.
# Enforcing root before the DRY_RUN branch would force `sudo` just to read what
# sudo is about to do — which is how people end up running sudo out of habit and
# stop reviewing the plan.
[[ "$(id -u)" -eq 0 || "$DRY_RUN" == "1" ]] || guard "needs root to write the snapshot. Re-run with sudo, or with DRY_RUN=1 (the default) to see the plan, or --report for status."
for bin in rsync df stat find awk; do
    command -v "$bin" >/dev/null 2>&1 || guard "$bin not found — cannot run a backup without it"
done

# --- payload sizing: from df, never from du ----------------------------------
# Unprivileged `du -x /opt/jol` read 26 G where `df` said 138 G, because
# root-owned directories are simply not readable to it and du reports nothing
# about that. df is authoritative for capacity, so capacity decisions use df.
PAYLOAD_KB="$(df -k --output=used "$SOURCE" | tail -1 | tr -d ' ')"
[[ -n "$PAYLOAD_KB" && "$PAYLOAD_KB" != "0" ]] || guard "could not measure the size of $SOURCE"
NEEDED_KB=$(( PAYLOAD_KB * 110 / 100 ))                 # >=110 % of payload, the standing rule
HAVE_KB="$(df -k --output=avail "$MOUNT" | tail -1 | tr -d ' ')"
say "payload $(awk -v k="$PAYLOAD_KB" 'BEGIN{printf "%.1f GiB", k/1048576}'), first snapshot needs $(awk -v k="$NEEDED_KB" 'BEGIN{printf "%.1f GiB", k/1048576}'), destination has $(awk -v k="$HAVE_KB" 'BEGIN{printf "%.1f GiB", k/1048576}') free"
if (( HAVE_KB < NEEDED_KB )); then
    fail "free-space preflight FAILED: $DEST has $(awk -v k="$HAVE_KB" 'BEGIN{printf "%.1f GiB", k/1048576}') but the first full snapshot needs $(awk -v k="$NEEDED_KB" 'BEGIN{printf "%.1f GiB", k/1048576}').
       Note --link-dest makes later snapshots cheap, but the FIRST one does not, and
       a backup that dies half-written is worse than one that never started."
fi

# --- snapshot chain ----------------------------------------------------------
# DRY_RUN must not touch the destination. This was a real defect: when the `run()`
# wrapper was deleted as dead code, its two calls here became UNCONDITIONAL, so a
# plan run created $DEST and chmod'd it 700. Unprivileged it failed harmlessly with
# Permission denied; under sudo it would have mutated the state a dry run promises
# not to touch. Deleting a guard helper means re-checking every call site it guarded.
# (The first repair attempt left an unconditional `mkdir || true` above the guard, so
# as root it still created the directory and merely hid the error. A mutation wrapped
# in `|| true` is still a mutation.)
if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$DEST" || fail "could not create $DEST"
    # 750 root:jol, NOT 700 root:root. The first run used 700 and that made the
    # snapshot invisible to the user-level capacity watchdog, so nothing could tell
    # whether the backup was still running — a control with no monitor is a control
    # that silently stops, which is the whole lesson of this thread. jol already owns
    # every file being copied, so group access grants no reach the source did not
    # already have; it only lets the watchdog stat the newest snapshot directory.
    chmod 750 "$DEST" || fail "could not set mode on $DEST"
    chown root:"$BACKUP_OWNER" "$DEST" || fail "could not set group on $DEST"
fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NEW="$DEST/home-$STAMP"

# Most recent existing snapshot becomes the hardlink reference, so unchanged
# files cost a link rather than a copy. This is what makes 79 GiB affordable on
# a 270 GiB volume with KEEP=3.
PREV="$(find "$DEST" -maxdepth 1 -type d -name 'home-*' 2>/dev/null | sort | tail -1)"
LINK_ARG=()
if [[ -n "$PREV" ]]; then
    LINK_ARG=(--link-dest="$PREV")
    say "link-dest reference: $PREV"
else
    say "no previous snapshot — this first run will consume the full payload"
fi

# DRY_RUN stops HERE, before any rsync. The first draft let DRY_RUN fall through
# into the verification and restore-probe stages, which then inspected a snapshot
# directory that had deliberately never been created — so the dry run failed with
# "no suitable file found in the snapshot", i.e. it reported a backup problem when
# the only problem was the dry run itself. A plan mode must not diagnose its own
# abstention as a defect.
if [[ "$DRY_RUN" == "1" ]]; then
    say "DRY_RUN=1 — no snapshot written. The plan is:"
    printf 'DRY  : would mkdir -p %s (mode 700) if absent\n' "$DEST"
    printf 'DRY  : rsync -aHAXS --delete --numeric-ids %s %s/ %s\n' \
        "${PREV:+--link-dest=$PREV}" "$SOURCE" "$NEW"
    printf 'DRY  : would chmod 750 %s and any pre-existing snapshot (rsync inherits /home 755,\n' "$NEW"
    printf 'DRY  :   which is world-traversable and exposes the filename layout of ~/.ssh and secrets/)\n'
    printf 'DRY  : free-space preflight %s KiB needed vs %s KiB available -> PASS\n' "$NEEDED_KB" "$HAVE_KB"
    printf 'DRY  : verify by dry-run re-scan (ceiling %s differing entries)\n' "$CHURN_MAX"
    printf 'DRY  : restore-probe one file back out and byte-compare it\n'
    printf 'DRY  : diff -rq the secrets tree, status only, contents never read\n'
    printf 'DRY  : prune to KEEP=%s, only after the new snapshot is proven\n' "$KEEP"
    printf 'DRY  : write %s (mode 600) — the artifact provision-jolhome-disk.sh gate 0 reads\n' "$PROOF_FILE"
    exit 0
fi

RSYNC_ARGS=(-aHAXS --delete --numeric-ids --info=stats2 "${LINK_ARG[@]}")
if ! rsync "${RSYNC_ARGS[@]}" "$SOURCE/" "$NEW/"; then
    fail "rsync returned non-zero. $NEW may be incomplete; leaving it for inspection, writing no proof."
fi

# --- the snapshot directory must NOT inherit /home's mode ----------------------
# `rsync -a` creates $NEW with the SOURCE directory's permissions, and /home is
# 755 root:root — so every snapshot was world-traversable, letting any local user
# enumerate the filenames of an entire home tree including ~/.ssh and secrets/.
# File CONTENTS stay protected by their own preserved modes (the key is still 600),
# but the enumeration is a confidentiality regression against the source, where
# /home/jol itself is 750. Measured 2026-11-05: home-20261105T131022Z was
# drwxr-xr-x root:root while its parent $DEST was correctly drwxr-x--- root:jol —
# the parent had been tightened and the child, created by rsync, had not.
chmod 750 "$NEW" || fail "could not restrict $NEW — refusing to leave a world-traversable backup of /home"
chown root:"$BACKUP_OWNER" "$NEW" || fail "could not set group on $NEW"
say "snapshot mode: $(stat -c '%A %U:%G' "$NEW") — group-traversable for the watchdog, not world-traversable"
# Tighten any snapshot created before this guard existed. Idempotent, and it is the
# only thing that repairs the exposure already on disk without a 25-minute re-copy.
for s in "$DEST"/home-*; do
    [[ -d "$s" ]] || continue
    m="$(stat -c '%a' "$s" 2>/dev/null || echo '')"
    if [[ -n "$m" && "$m" != "750" ]]; then
        chmod 750 "$s" && say "tightened pre-existing snapshot $(basename "$s") from $m to 750"
    fi
done

# --- verification: counted, not assumed --------------------------------------
# /home is LIVE: the IDE, the browser and this agent are all writing to it, so a
# re-scan will always differ somewhat. Demanding zero churn would make this gate
# fail every time and get it disabled. So the count is measured, printed, and
# compared against a stated ceiling.
# --out-format='%n' emits one changed NAME per line, which is countable without
# guessing at rsync's itemise-code alphabet (a first draft grepped '^[<>ch.]' and
# would have silently under-counted anything whose code fell outside that set).
CHURN="$(rsync -ain --delete --numeric-ids --out-format='%n' "${LINK_ARG[@]}" "$SOURCE/" "$NEW/" 2>/dev/null | grep -c . || true)"
say "verification re-scan: $CHURN differing entr$([ "$CHURN" -eq 1 ] && echo y || echo ies) (ceiling $CHURN_MAX)"
if (( CHURN > CHURN_MAX )); then
    fail "churn above ceiling — the copy did not converge. Investigate before trusting it."
fi

# --- restore proof: copy something BACK and byte-compare ---------------------
# A named, stable, non-secret file. Chosen from the snapshot itself so the probe
# cannot pass by comparing a file that was never copied.
PROBE_REL="$(find "$NEW" -maxdepth 3 -type f -size +4k \
    ! -path '*/secrets/*' ! -path '*/.cache/*' ! -name '*.sock' 2>/dev/null | head -1)"
[[ -n "$PROBE_REL" ]] || fail "no suitable file found in the snapshot to restore-probe — the copy looks empty"
SCRATCH="$(mktemp -d)"
PROBE_SRC="${PROBE_REL#"$NEW/"}"
if ! cp -a "$NEW/$PROBE_SRC" "$SCRATCH/probe-copy" 2>/dev/null; then
    rm -rf "$SCRATCH"; fail "could not read $PROBE_SRC back out of the snapshot — the copy is not usable"
fi
if ! cmp -s "$SOURCE/$PROBE_SRC" "$SCRATCH/probe-copy"; then
    rm -rf "$SCRATCH"; fail "restore probe byte-compared DIFFERENT for $PROBE_SRC — the snapshot is not a faithful copy"
fi
say "restore probe PASS: '$PROBE_SRC' copied back out of the snapshot and byte-compared equal"
rm -rf "$SCRATCH"

# --- prove the secret tree survived, WITHOUT reading or printing it ----------
# Tier-1 forbidden path: contents are never opened. `diff -rq` emits names of
# differing files only, so redirect it and use the EXIT STATUS alone.
SECRETS_STATUS="not-present"
if [[ -d "$SOURCE/jol/secrets" ]]; then
    if diff -rq "$SOURCE/jol/secrets" "$NEW/jol/secrets" >/dev/null 2>&1; then
        SECRETS_STATUS="match"
    else
        fail "the secrets tree in the snapshot does not match the source. Not writing a proof.
       (Contents were not read or printed — only the comparison status.)"
    fi
    say "secrets tree comparison: $SECRETS_STATUS (contents never read or displayed)"
fi

FILE_COUNT="$(find "$NEW" 2>/dev/null | grep -c . || true)"
(( FILE_COUNT > 0 )) || fail "the snapshot reports 0 entries — an empty measurement is not a backup"
say "snapshot $NEW holds $FILE_COUNT entries"

# --- prune only AFTER the new one is proven ----------------------------------
SNAPS="$(find "$DEST" -maxdepth 1 -type d -name 'home-*' 2>/dev/null | sort)"
COUNT="$(printf '%s\n' "$SNAPS" | grep -c . || true)"
if (( COUNT > KEEP )); then
    for old in $(printf '%s\n' "$SNAPS" | head -n $(( COUNT - KEEP ))); do
        if (( COUNT <= KEEP_MIN )); then break; fi
        # Never prune the link-dest reference still backing a surviving snapshot:
        # deleting it would silently turn that snapshot's hardlinks into orphans and
        # quietly inflate its footprint.
        if [[ -n "$PREV" && "$old" == "$PREV" ]]; then
            say "keeping $old — it is the hardlink reference for a surviving snapshot"
            continue
        fi
        rm -rf "$old" && say "pruned old snapshot $old" && COUNT=$((COUNT - 1))
    done
fi

# --- write the proof, and only now -------------------------------------------
PROOF="$(printf 'PASS utc=%s host=%s dest=%s dev=%s payload_kib=%s entries=%s churn=%s probe=byte-identical secrets=%s' \
    "$STAMP" "$HOST_ID" "$DEST" "$MDEV" "$PAYLOAD_KB" "$FILE_COUNT" "$CHURN" "$SECRETS_STATUS")"
if [[ "$DRY_RUN" == "1" ]]; then
    say "DRY_RUN=1 — nothing was written. Would have written to $PROOF_FILE:"
    say "  $PROOF"
    exit 0
fi
mkdir -p "$(dirname "$PROOF_FILE")"
chmod 700 "$(dirname "$PROOF_FILE")" 2>/dev/null || true
printf '%s\n' "$PROOF" > "$PROOF_FILE.new" || fail "could not write the proof file"
chmod 600 "$PROOF_FILE.new"
mv "$PROOF_FILE.new" "$PROOF_FILE"
say "PROOF WRITTEN: $PROOF_FILE"
say "  $PROOF"
say "provision-jolhome-disk.sh gate 0 will now accept this for PROOF_MAX_AGE_DAYS (default 7)."
exit 0
