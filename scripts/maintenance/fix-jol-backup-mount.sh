#!/usr/bin/env bash
# =============================================================================
# fix-jol-backup-mount.sh — repair the off-device backup mount at /mnt/jol-backup
#
# THE DEFECT (measured 2026-11-04): /etc/fstab declares
#     /dev/sdb1  /mnt/jol-backup  ext4  defaults,nofail,noatime  0  2
# and /dev/sdb1 DOES NOT EXIST. sdb is a whole-disk crypto_LUKS container (8,16) with no
# partition table, as is sdc (8,32). The 290 GB ext4 partition that was actually meant to
# hold these backups is /dev/sda1, UUID 32f7e56a-b96c-486a-93da-9e1a57567cfc.
#
# Consequence, in order of severity:
#   * `nofail` let the boot proceed clean, so the missing mount produced no boot error;
#   * /mnt/jol-backup became an empty root-owned DIRECTORY ON / (stat device 66315,
#     identical to /), so the off-device guard in the backup jobs correctly refused to
#     write — which is the guard working, not failing;
#   * the newest Terraform state snapshot on that disk is 2026-10-31. Four days of state
#     for jol-control and jolarca-control are unbacked-up off-device;
#   * the job's own loud failure went to `>/dev/null 2>&1` in cron, and the systemd unit
#     then exhausted StartLimitBurst=10 and is sitting in a failed state that `enabled`
#     and a future `NEXT` both hide.
#
# WHAT THIS SCRIPT DOES
#   1. resolves the destination from /dev/disk/by-uuid/ — NEVER from a remembered sdXn
#      letter, because a remembered letter is exactly how this defect was introduced;
#   2. proves the resolved device is a different block device from / before touching
#      anything (device identity, not findmnt-on-a-subdirectory, which resolves to the
#      parent mount and lies);
#   3. backs /etc/fstab up with a timestamp, rewrites ONLY the device field of the line
#      whose mountpoint is /mnt/jol-backup, and refuses to install the file unless exactly
#      one line changed and the line count is unchanged;
#   4. mounts, re-verifies by device identity, creates the artifact directories if the
#      filesystem does not already provide them;
#   5. clears the start-limit failure so the timer can actuate again.
#
# Idempotent (step 3 is skipped when the mount is already correct), change-logged,
# DRY_RUN by default, non-destructive: it never deletes a backup, never edits any other
# fstab line, and never runs `mount -a` (which would retry every nofail entry on the box).
#
# Exit: 0 repaired-or-already-correct, 1 could not repair (nothing was made worse),
#       2 guard (not root / wrong host / precondition unmet).
# Usage: sudo DRY_RUN=0 ./fix-jol-backup-mount.sh            # plan, then apply
#        ./fix-jol-backup-mount.sh --verify-only             # read-only, safe any time
# Rollback: cp -p <backup printed by step 3> /etc/fstab && mount /mnt/jol-backup
#           (the old line never worked, so rollback restores a broken-but-unchanged state)
# =============================================================================
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# The one fact this script is allowed to hardcode: the filesystem UUID of the 290 GB ext4
# partition on the second disk. UUIDs survive device-letter renumbering; /dev/sdXn does
# not, and the letter is what broke here.
WANTED_UUID="${WANTED_UUID:-32f7e56a-b96c-486a-93da-9e1a57567cfc}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/jol-backup}"
DRY_RUN="${DRY_RUN:-1}"
VERIFY_ONLY=0
[[ "${1:-}" == "--verify-only" ]] && VERIFY_ONLY=1

STATE_DIRS="${STATE_DIRS:-jol-control jol-state-backup}"
FAILED_UNITS="${FAILED_UNITS:-jolarca-state-backup.service jolarca-state-backup.timer}"
BACKUP_OWNER="${BACKUP_OWNER:-jol}"

say()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { say "FAIL: $*"; exit 1; }
guard_abort() { say "ABORT: $*"; exit 2; }

# Run a systemctl --user command in the backup owner's user manager, WITHOUT ever being
# able to block. `su - jol -c 'systemctl --user …'` was the first attempt here and it is
# WRONG: unprivileged, `su` prompts for jol's password on a terminal and the script hangs
# forever (measured — this run had to be killed). `runuser` never prompts and exists for
# exactly this root-to-user direction, and when we are ALREADY that user the call is made
# directly. Every branch is wrapped in `timeout`, because a monitor or repair that can
# hang is indistinguishable from one that succeeded.
userctl() { # $@ = systemctl args (without the leading `systemctl --user`)
    local uid="$1"; shift
    if [[ -z "$uid" ]]; then
        say "NOTE: no uid for the backup owner — cannot query the user manager, reporting UNVERIFIED"
        return 3
    fi
    if [[ "$(id -u)" == "$uid" ]]; then
        timeout 20 systemctl --user "$@"
    elif [[ "$(id -u)" == "0" ]]; then
        timeout 20 runuser -u "$BACKUP_OWNER" -- env \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            systemctl --user "$@"
    else
        say "NOTE: running as $(id -un), not root and not $BACKUP_OWNER — cannot reach that user manager, reporting UNVERIFIED"
        return 3
    fi
}

# --- guards ------------------------------------------------------------------
# Mutations need root; planning does not. Aborting a DRY_RUN on missing root would force
# an operator to sudo simply to READ the plan, which is how people start running
# `sudo bash` out of habit and stop reviewing what they are about to change.

if [[ "$(id -u)" -ne 0 ]]; then
    if [[ "$DRY_RUN" != "1" && "$VERIFY_ONLY" != "1" ]]; then
        guard_abort "refusing to mutate /etc/fstab without root. Re-run with sudo, or with DRY_RUN=1 (the default) to see the plan."
    fi
    say "NOTE: running unprivileged — read-only plan only, nothing will be changed."
fi
HOST_ID="$(hostname -s 2>/dev/null || echo unknown)"
for h in pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01; do
    [[ "$HOST_ID" == "$h" ]] && guard_abort "$h is a fleet host with its own storage layout; this repair is for the custodian workstation"
done

ROOT_DEV="$(stat -c '%d' /)"
say "host=$HOST_ID  device-id-of-/=$ROOT_DEV"

# --- 1. resolve the destination by UUID, not by letter ------------------------
LINK="/dev/disk/by-uuid/$WANTED_UUID"
[[ -e "$LINK" ]] || guard_abort "$LINK does not exist. The backup disk is not present or its UUID changed; refusing to guess a device name. Check: ls -l /dev/disk/by-uuid/"
REAL="$(readlink -f "$LINK")"
[[ -b "$REAL" ]] || guard_abort "$LINK -> $REAL is not a block device"
# lsblk reads the kernel/udev filesystem type and works UNPRIVILEGED. `blkid <device>`
# opens the block special and therefore needs root, which would have made the default
# DRY_RUN plan-only path require sudo for no reason.
FSTYPE="$(lsblk -no FSTYPE "$REAL" 2>/dev/null | head -1)"
[[ -n "$FSTYPE" ]] || FSTYPE="$(blkid -o value -s TYPE "$REAL" 2>/dev/null || echo unknown)"
[[ "$FSTYPE" == "ext4" ]] || guard_abort "$REAL reports fstype=$FSTYPE, expected ext4. This is not the backup partition."
say "resolved: $LINK -> $REAL (fstype=$FSTYPE)"

# --- 2. prove it is a different PHYSICAL DISK from the one holding / ---------
# The whole point of the mount is off-DISK separation, so the comparison must be between
# disks. Two traps, both hit while writing this:
#   * `stat -c %d` on a BLOCK SPECIAL returns the id of the filesystem that holds the
#     NODE (/dev, devtmpfs id 7) — not the device's identity. Compared against
#     `stat -c %d /` it differs for EVERY disk on the machine, so the check passes
#     vacuously and proves nothing.
#   * two partitions on the same physical drive are not off-device separation at all.
# The sound probe is the kernel's own topology: the parent disk under /sys/class/block.
CAND_BLK="$(basename "$REAL")"
CAND_PARENT="$(basename "$(dirname "$(readlink -f "/sys/class/block/$CAND_BLK")")")"
CAND_DEVNO="$(cat "/sys/class/block/$CAND_BLK/dev" 2>/dev/null)"
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
ROOT_BLK="$(basename "$(readlink -f "$ROOT_SRC")" 2>/dev/null)"
ROOT_PARENT="$(basename "$(dirname "$(readlink -f "/sys/class/block/$ROOT_BLK")")" 2>/dev/null)"
say "candidate $REAL is parent disk '$CAND_PARENT' (kernel $CAND_DEVNO); / is on parent '$ROOT_PARENT'"
if [[ -z "$CAND_PARENT" || -z "$ROOT_PARENT" ]]; then
    guard_abort "cannot resolve the parent disks — refusing to guess that this is off-device separation"
fi
if [[ "$CAND_PARENT" == "$ROOT_PARENT" ]]; then
    guard_abort "$REAL lives on the same physical disk as / ($CAND_PARENT) — mounting it buys no separation"
fi
say "device identity OK: $CAND_PARENT and $ROOT_PARENT are different physical disks"

# --- 3. idempotency: is the repair already done? ------------------------------
# "Mounted today" is NOT the same as "configured correctly", and the difference IS the
# defect. A bare /dev/sdXn in fstab works only while the kernel happens to enumerate the
# disks in the same order. Measured 2026-11-05: plugging a new SATA drive into a lower
# port shifted the backup HDD from sda back to sdb, and the `/dev/sdb1` entry that had
# been broken for five days started working again BY ACCIDENT. An idempotency check that
# only asks "is it mounted?" would then declare the system correct and leave a letter-
# based reference in place to break on the next hardware change. So this is two-part:
#   (a) is it actually mounted from a different device than / ?
#   (b) is the DEFINITION an identity rather than an enumeration order?
MOUNTED_OK=0
MP_DEV=""
if findmnt -rn -o TARGET --target "$MOUNTPOINT" 2>/dev/null | grep -qx "$MOUNTPOINT"; then
    MP_DEV="$(stat -c '%d' "$MOUNTPOINT")"
    [[ "$MP_DEV" != "$ROOT_DEV" ]] && MOUNTED_OK=1
fi
FSTAB_FIELD="$(awk -v mp="$MOUNTPOINT" '!/^[[:space:]]*#/ && NF>=2 && $2==mp { print $1; exit }' /etc/fstab)"
STABLE_REF=0
case "$FSTAB_FIELD" in
    UUID=*|PARTUUID=*|LABEL=*|/dev/disk/by-uuid/*|/dev/disk/by-label/*|/dev/disk/by-partuuid/*|/dev/mapper/*)
        STABLE_REF=1 ;;
esac
RESIDUAL=0
if (( MOUNTED_OK == 1 && STABLE_REF == 1 )); then
    say "ALREADY CORRECT: $MOUNTPOINT is mounted from device $MP_DEV and fstab identifies it as '$FSTAB_FIELD'."
    say "Nothing to do. Use --verify-only any time to re-check."
    RESIDUAL=1
elif (( MOUNTED_OK == 1 )); then
    say "MOUNTED BY LUCK: $MOUNTPOINT works right now (device $MP_DEV), but fstab names '$FSTAB_FIELD'."
    say "That is a kernel enumeration letter, not an identity. It already broke once for five days and"
    say "will break again the next time a disk is added or removed — a USB stick is enough."
    say "Rewriting the field to a UUID. The live mount is left alone, so nothing running is disturbed."
else
    say "$MOUNTPOINT is NOT a real mount — it is an ordinary directory on / (device ${MP_DEV:-$ROOT_DEV})."
fi

if [[ "$VERIFY_ONLY" == "1" ]]; then
    say "verify-only: fstab names $MOUNTPOINT as '${FSTAB_FIELD:-ABSENT}' — $( (( STABLE_REF )) && echo 'stable identity reference' || echo 'ENUMERATION LETTER, not stable')"
    say "verify-only: newest artifacts under $MOUNTPOINT:"
    for d in $STATE_DIRS; do
        newest="$(find "$MOUNTPOINT/$d" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r | head -1 | cut -d' ' -f2-)"
        if [[ -z "$newest" ]]; then
            say "  $MOUNTPOINT/$d : NO ARTIFACTS (absent or empty)"
        else
            say "  $MOUNTPOINT/$d : $newest"
        fi
    done
    exit 0
fi

# --- 4. rewrite the fstab device field, narrowly ------------------------------
if [[ "${RESIDUAL:-0}" != "1" ]]; then
    TS="$(date -u +%Y%m%dT%H%M%SZ)"
    BAK="/root/fstab.bak.$TS"
    # Count candidates FIRST so the refusal message states a measured number instead of
    # re-deriving it from a second grep embedded in the failure string.
    CANDIDATES="$(awk -v mp="$MOUNTPOINT" '!/^[[:space:]]*#/ && NF>=2 && $2==mp { c++ } END { print c+0 }' /etc/fstab)"
    (( CANDIDATES == 1 )) || fail "expected exactly 1 fstab line with mountpoint $MOUNTPOINT, found $CANDIDATES - refusing to rewrite"

    awk -v uuid="UUID=$WANTED_UUID" -v mp="$MOUNTPOINT" '
        /^[[:space:]]*#/ { print; next }
        {
            n=split($0, f, /[ \t]+/)
            if (n>=2 && f[2]==mp) { sub(/^[^ \t]+/, uuid); hits++ }
            print
        }
        END { if (hits != 1) exit 3 }
    ' /etc/fstab > "/tmp/fstab.new.$TS" || { rm -f "/tmp/fstab.new.$TS"; fail "fstab rewrite aborted; nothing was changed"; }

    old_lines="$(grep -c '' /etc/fstab)"
    new_lines="$(grep -c '' "/tmp/fstab.new.$TS")"
    changed="$(diff <(cat /etc/fstab) "/tmp/fstab.new.$TS" | grep -cE '^[<>]')"
    [[ "$old_lines" == "$new_lines" ]] || { rm -f "/tmp/fstab.new.$TS"; fail "line count changed ($old_lines -> $new_lines); refusing"; }
    (( changed == 2 )) || { rm -f "/tmp/fstab.new.$TS"; fail "expected exactly one modified line (2 diff rows), got $changed; refusing"; }

    say "the only fstab change:"
    diff -u /etc/fstab "/tmp/fstab.new.$TS" | sed -n '3,99p' | sed 's/^/    /'

    if [[ "$DRY_RUN" == "1" ]]; then
        say "DRY_RUN=1 — would write $BAK and install the patched fstab. Nothing changed."
        rm -f "/tmp/fstab.new.$TS"
        say "Re-run with: sudo DRY_RUN=0 $0"
        exit 0
    fi

    # Explicit if, not `cp && chmod || fail`: with the A && B || C shape a chmod failure
    # and a cp failure produce the same message, and a partially-written backup would be
    # reported as "could not write" when it was actually written with the wrong mode.
    if cp -p /etc/fstab "$BAK"; then
        chmod 600 "$BAK" || fail "$BAK written but chmod 600 failed - fix the mode before proceeding"
        say "backup: $BAK (mode 600)"
    else
        fail "could not write $BAK - aborting before any change"
    fi
    install -m 644 -o root -g root "/tmp/fstab.new.$TS" /etc/fstab || fail "install failed"
    rm -f "/tmp/fstab.new.$TS"
    say "fstab patched"

    # systemd builds .mount units from /etc/fstab at startup and caches them. Without
    # a reload it keeps acting on the OLD table — `mount` said this out loud on the
    # 2026-11-05 run ("your fstab has been modified, but systemd still uses the old
    # version") and the first version of this script ignored its own tool's hint. The
    # edit is not actually in effect until this runs, so it belongs before the mount.
    systemctl daemon-reload || say "NOTE: daemon-reload failed — the fstab edit is saved but systemd still holds the old table; run it manually before relying on boot behaviour"

    # --- 5. mount and re-verify by device identity ---
    # Do NOT re-mount a working mount: `mount <mp>` on an already-mounted path exits
    # non-zero ("already mounted"), which would abort a run that had just succeeded, and
    # unmounting to force it would disturb the backup job mid-write.
    mkdir -p "$MOUNTPOINT"
    if (( MOUNTED_OK == 1 )); then
        say "live mount left in place; the corrected fstab line takes effect on next boot"
    else
        mount "$MOUNTPOINT" || fail "mount $MOUNTPOINT failed — check dmesg and $BAK for rollback"
    fi
    NEW_DEV="$(stat -c '%d' "$MOUNTPOINT")"
    [[ "$NEW_DEV" != "$ROOT_DEV" ]] || fail "post-mount: $MOUNTPOINT still resolves to / ($ROOT_DEV) — mount did not take"
    say "MOUNTED: $MOUNTPOINT is device $NEW_DEV (root is $ROOT_DEV)"
fi

# --- 6. artifact directories (the HDD already holds them; create only if truly absent) ---
for d in $STATE_DIRS; do
    if [[ -d "$MOUNTPOINT/$d" ]]; then
        say "present: $MOUNTPOINT/$d (existing snapshots are now visible at the correct path)"
    elif [[ "$DRY_RUN" == "1" ]]; then
        say "DRY  : would mkdir $MOUNTPOINT/$d (700 $BACKUP_OWNER)"
    else
        if mkdir -p "$MOUNTPOINT/$d" && chmod 700 "$MOUNTPOINT/$d" && chown "$BACKUP_OWNER":"$BACKUP_OWNER" "$MOUNTPOINT/$d"; then
            say "created: $MOUNTPOINT/$d (700 $BACKUP_OWNER)"
        else
            fail "could not create $MOUNTPOINT/$d"
        fi
    fi
done

# --- 7. clear the start-limit failure so the timer can actuate again -----------
# A unit that exhausted StartLimitBurst stays in 'failed' and the timer's next activation
# is refused; `enabled` plus a populated NEXT does NOT mean it can run.
RUNUSER_UID="$(id -u "$BACKUP_OWNER" 2>/dev/null || echo '')"
if [[ -n "$RUNUSER_UID" ]]; then
    for u in $FAILED_UNITS; do
        if [[ "$DRY_RUN" == "1" ]]; then
            say "DRY  : would reset-failed $u for uid $RUNUSER_UID"
        else
            if userctl "$RUNUSER_UID" reset-failed "$u" 2>/dev/null; then
                say "reset-failed: $u"
            else
                say "NOTE: could not reset-failed $u (not permitted from here, or it is not in a failed state)"
            fi
        fi
    done
else
    say "NOTE: user '$BACKUP_OWNER' has no uid — cannot clear the start-limit failure. Do it as that user."
fi

# --- 8. final verification, by post-state not by having run -------------------
say "=== post-state ==="
say "mount: $(findmnt -no SOURCE,TARGET --target "$MOUNTPOINT" 2>/dev/null || echo 'NOT A MOUNT')"
say "device id: $(stat -c '%d' "$MOUNTPOINT") (root=$(stat -c '%d' /))"
for d in $STATE_DIRS; do
    newest="$(find "$MOUNTPOINT/$d" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    say "newest in $d: ${newest:-NONE}"
done
say "next scheduled run: $(userctl "${RUNUSER_UID:-}" list-timers jolarca-state-backup.timer --no-pager 2>/dev/null | sed -n '2p' || echo UNVERIFIED)"
say "Now re-run: ~/.local/bin/jol-workstation-capacity-check.sh   (gates 2 and 5 must go green)"
say "Rollback:   cp -p ${BAK:-<no backup written in this run>} /etc/fstab"
exit 0
