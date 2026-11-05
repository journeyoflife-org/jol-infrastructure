#!/usr/bin/env bash
# =============================================================================
# provision-jolhome-disk.sh — prepare the ADATA LEGEND 900 as the long-term
#                             developer-data volume
#
# WHAT THIS DOES NOT DO: it does NOT touch /home, /etc/fstab's existing lines,
# the OS disk, the SATA HDD, or either USB stick. It provisions the blank disk
# and mounts it at a staging path. The /home cutover is Phase 2 of
# docs/runbooks/workstation-storage-990pro-home-migration.md and needs a rescue
# window — keeping it separate is what makes this script safe to run today.
#
# Every parameter below was chosen from a measurement, not from a default. The
# measurements are in the comments; re-run them if the hardware changes again,
# because on 2026-11-05 a single disk removal renumbered every NVMe node.
#
# Idempotent (each stage checks before mutating), change-logged, DRY_RUN by
# default, non-destructive to existing data.
#
# Usage:
#   sudo ./provision-jolhome-disk.sh                 # plan only (DRY_RUN=1)
#   sudo DRY_RUN=0 ./provision-jolhome-disk.sh       # apply
#   ./provision-jolhome-disk.sh --verify-only        # read-only, any time
#
# Exit: 0 done-or-already-correct, 1 failed (nothing made worse),
#       2 guard (not root / wrong host / target not eligible / gate 0 unmet).
# =============================================================================
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# --- the target is identified by MODEL, never by a device letter -------------
# Measured 2026-11-05: removing one NVMe renumbered all of them (OS disk moved
# nvme0n1 -> nvme1n1). A remembered letter is what made /etc/fstab line 27
# reference /dev/sdb1, a node that has never existed.
TARGET_MODEL="${TARGET_MODEL:-ADATA LEGEND 900}"
STAGING="${STAGING:-/mnt/jolhome-staging}"
MAPPER="${MAPPER:-jolhome_crypt}"
FS_LABEL="${FS_LABEL:-jolhome}"
DRY_RUN="${DRY_RUN:-1}"
VERIFY_ONLY=0
# TPM2 auto-unlock is OFF by default. The box does have a TPM 2.0
# (/dev/tpm0, /sys/class/tpm/tpm0/device/description = "TPM 2.0 Device"), but a
# TPM-bound keyslot trades one failure mode for two others: the volume stops
# opening if the TPM is cleared or the board replaced, and it opens without a
# human on any boot from that machine. Verify initramfs support before relying
# on it; the passphrase keyslot below is mandatory either way.
TPM2_ENROLL="${TPM2_ENROLL:-0}"
# Gate 0 — the backup proof. Written by the Phase 0 restore drill, read here.
# Same mechanism as hv01 gate 13's alert-transport proof: a positive artifact,
# freshness-bounded, never "the job did not complain".
HOME_BACKUP_PROOF="${HOME_BACKUP_PROOF:-/var/lib/jol-workstation/home-backup-proof}"
PROOF_MAX_AGE_DAYS="${PROOF_MAX_AGE_DAYS:-7}"
[[ "${1:-}" == "--verify-only" ]] && VERIFY_ONLY=1

say()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { say "FAIL: $*"; exit 1; }
guard() { say "ABORT: $*"; exit 2; }
run() {
    if [[ "$DRY_RUN" == "1" ]]; then printf 'DRY  : %s\n' "$*"
    else printf 'APPLY: %s\n' "$*"; "$@" || return 1
    fi
}

# --- guards ------------------------------------------------------------------
HOST_ID="$(hostname -s 2>/dev/null || echo unknown)"
for h in pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01; do
    [[ "$HOST_ID" == "$h" ]] && guard "$h is a fleet host; this provisions the custodian workstation's data disk"
done

# --- GATE 0: a 76 GiB single copy must exist elsewhere before new hardware ----
# This is the control, not the prose. The runbook says back up /home first; a
# script that only says it in a comment will be run anyway. /home holds an SSH
# private key and Tier-1 secret material and, measured 2026-11-05, is backed up
# by nothing: `crontab -l | grep -ic home` -> 0.
# Checked BEFORE the root guard on purpose: an operator who runs this without
# sudo should learn the blocking reason, not just "use sudo", and the gate must
# be exercisable without privileges to prove it actually discriminates.
if [[ "$VERIFY_ONLY" != "1" ]]; then
    if [[ ! -r "$HOME_BACKUP_PROOF" ]]; then
        # Absent and unreadable are different findings. Measured: /var/lib/jol-workstation
        # is 0700 root:root, so a non-root run cannot traverse it and `-r` is false whether
        # or not the proof exists. Reporting "no backup exists" from that would be a false
        # finding about the operator's data — the same conflation corrected in the watchdog
        # gates and in the timer controls, seventh instance.
        if [[ ! -r "$(dirname "$HOME_BACKUP_PROOF")" || ! -x "$(dirname "$HOME_BACKUP_PROOF")" ]]; then
            guard "cannot traverse $(dirname "$HOME_BACKUP_PROOF") from uid $(id -u) — gate 0 is UNVERIFIED, not failed. Re-run with sudo, which the partitioning writes require anyway."
        fi
        guard "no /home backup proof at $HOME_BACKUP_PROOF. Provisioning a migration target before the
       single copy is duplicated is how a capacity task becomes a data-loss event.
       Run Phase 0 of the runbook first, and prove a RESTORE, not just a snapshot listing."
    fi
    if [[ "$(find "$HOME_BACKUP_PROOF" -mtime "-${PROOF_MAX_AGE_DAYS}" 2>/dev/null)" != "$HOME_BACKUP_PROOF" ]]; then
        guard "the /home backup proof is older than ${PROOF_MAX_AGE_DAYS} days: $(cat "$HOME_BACKUP_PROOF")
       A stale proof is not a backup. Re-run Phase 0."
    fi
    say "gate 0 PASS: $(cat "$HOME_BACKUP_PROOF")"
fi

if [[ "$VERIFY_ONLY" != "1" && "$(id -u)" -ne 0 ]]; then
    guard "needs root to partition, encrypt and edit crypttab/fstab. Re-run with sudo, or --verify-only."
fi

# --- resolve the target ------------------------------------------------------
CANDIDATE=""
for d in /sys/class/nvme/*/; do
    [[ -d "$d" ]] || continue
    [[ "$(xargs < "$d/model" 2>/dev/null)" == "$TARGET_MODEL" ]] && CANDIDATE="/dev/$(basename "$d")n1"
done
[[ -n "$CANDIDATE" ]] || guard "no NVMe device reports model '$TARGET_MODEL'. Refusing to guess a node name.
       Present devices: $(for x in /sys/class/nvme/*/; do [ -d "$x" ] && printf '%s=%s ' "$(basename "$x")" "$(xargs < "$x/model")"; done)"

# --- exclusions: four independent refusals ------------------------------------
# sdb and sdc are two 14.6 GiB whole-disk crypto_LUKS USB sticks, currently
# closed, whose shape matches dual-control key-custody media. They are excluded
# by transport AND by removability AND by signature, three ways, on purpose.
#
# ⚠ Read removability from sysfs, not `lsblk -o RM`. The first version used
#   lsblk, whose RM column is width-padded, so the value arrived as " 0", the
#   equality test failed, and EVERY disk was refused as "removable" — including
#   the target. Worse, that made the OS-disk refusal unreachable, so test 4
#   passed for the wrong reason and looked like a working guard. A check that
#   always fails is not a check; it is a lockout that hides the checks behind it.
TRAN="$(lsblk -dno TRAN "$CANDIDATE" 2>/dev/null | tr -d '[:space:]')"
RM="$(tr -d '[:space:]' < "/sys/block/${CANDIDATE##*/}/removable" 2>/dev/null)"
# OS-disk identity is tested FIRST: it is the refusal that must never be masked
# by a later one, and its message must name the real reason.
#
# ⚠ This guard was DEAD in the first version and TEST 4 caught it: `lsblk -no
#   PKNAME` was handed a bare name (`nvme1n1p3`) instead of a path, resolved to
#   nothing, and the `|| echo` fallback silently substituted the PARTITION name
#   for the DISK name — so ROOT_DISK became "nvme1n1p3", never equalled
#   "/dev/nvme1n1", and pointing this script at the OS disk sailed through every
#   check on its way to luksFormat. A fallback that invents a plausible value is
#   worse than no fallback: it makes a dead guard look exercised. Refuse instead.
OS_SRC="$(findmnt -no SOURCE --target / 2>/dev/null | tr -d '[:space:]')"
[[ -n "$OS_SRC" ]] || guard "cannot determine which device hosts / — refusing to act without knowing what must NOT be touched"
ROOT_DISK="$(lsblk -no PKNAME "$OS_SRC" 2>/dev/null | head -1 | tr -d '[:space:]')"
[[ -n "$ROOT_DISK" ]] || guard "could not resolve the parent disk of $OS_SRC — refusing to proceed rather than guessing"
[[ "$CANDIDATE" != "/dev/$ROOT_DISK" ]] || guard "$CANDIDATE is the disk hosting / ($OS_SRC) — absolute refusal"
[[ "$TRAN" == "nvme" ]] || guard "$CANDIDATE transport='$TRAN', expected nvme"
[[ "$RM" == "0" ]]      || guard "$CANDIDATE is removable='$RM' — refusing to touch removable media"
# --- blankness, decided from STRUCTURED udev fields --------------------------
# Three attempts were needed to get this right, and each failure is worth recording
# because they are the common shape of a broken safety check:
#   1. `wipefs` text + empty-string test — wipefs cannot open a raw device unprivileged,
#      so every disk looked blank in a read-only run and the guard passed vacuously.
#   2. gating on wipefs' exit status fixed the vacuous pass but left the guard inert
#      without root, and then a regex over its human-readable columns had to guess at
#      layout — fragile, and it would have refused to RESUME this script's own
#      interrupted run, because a GPT is not data.
#   3. udev already publishes exactly the facts wanted, unprivileged and machine-shaped:
#      filesystem on the disk, filesystems on the children, and partition-table type.
#      Those are now the decision. wipefs is corroboration, not the gate.
DISK_FS="$(lsblk -dno FSTYPE "$CANDIDATE" 2>/dev/null | tr -d '[:space:]')"
CHILD_FS="$(lsblk -no FSTYPE "$CANDIDATE" 2>/dev/null | grep -vE '^$' | paste -sd, - || true)"
PTTYPE="$(lsblk -dno PTTYPE "$CANDIDATE" 2>/dev/null | tr -d '[:space:]')"
[[ -z "$DISK_FS" ]] || guard "$CANDIDATE has a filesystem directly on the disk ($DISK_FS) — this is not a blank disk"

# The blankness test has to distinguish THREE states, not two. Proven by the 2026-11-05
# run: an uninitialised-variable abort stopped this script after mkfs.ext4 but before
# crypttab and fstab, leaving a real LUKS volume carrying the operator's passphrase — and
# the next invocation then refused to proceed because the disk "has child filesystems".
# A guard that cannot resume its own half-finished work turns a recoverable interruption
# into a manual repair, and the operator's passphrase is the thing at risk.
#   foreign data  -> refuse
#   our volume    -> RESUME, and let each step's own idempotency check skip what is done
#   blank         -> proceed
OURS_LUKS=0; FOREIGN=""
while read -r c_fs c_lbl; do
    [[ -n "$c_fs" ]] || continue
    if [[ "$c_fs" == "crypto_LUKS" && "$c_lbl" == "$FS_LABEL" ]]; then
        OURS_LUKS=1
    elif [[ "$c_fs" == "ext4" && "$c_lbl" == "$FS_LABEL" ]]; then
        :   # our own filesystem inside the mapper
    else
        FOREIGN="${FOREIGN:+$FOREIGN, }$c_fs($c_lbl)"
    fi
done < <(lsblk -nrno FSTYPE,LABEL "$CANDIDATE" 2>/dev/null)
if [[ -n "$FOREIGN" ]]; then
    guard "$CANDIDATE has filesystem(s) this script did not create: $FOREIGN — refusing. Expected only crypto_LUKS/ext4 labelled '$FS_LABEL'."
elif (( OURS_LUKS == 1 )); then
    say "RESUMING this script's own volume: crypto_LUKS labelled '$FS_LABEL' found, no foreign filesystems. Steps already completed will be skipped individually."
elif [[ -n "$CHILD_FS" ]]; then
    guard "$CANDIDATE has child filesystems ($CHILD_FS) that are not this script's volume — refusing"
fi
# A partition table with no filesystem under it is GEOMETRY, and on 2026-11-05 it is
# geometry this script itself created before cryptsetup's confirmation aborted the run.
# Refusing it would make the tool unable to finish its own interrupted work.
case "$PTTYPE" in
    '')      say "target is raw-blank: no partition table, no filesystem"
             ;;
    gpt|dos) if (( OURS_LUKS == 1 )); then
             say "partition table '$PTTYPE' present over this script's own volume — nothing to re-create"
         else
             say "RESUMING a previous partial run: partition table '$PTTYPE' present, no filesystem on disk or children"
         fi
             ;;
    *)       guard "$CANDIDATE has partition table type '$PTTYPE', which this script does not create — refusing"
             ;;
esac
# Corroboration, structured only — and this is the THIRD distinct way this one guard was
# wrong, which is why it no longer parses text at all. `wipefs` prints a HUMAN TABLE: a
# header row (`DEVICE OFFSET TYPE UUID LABEL`) and a TYPE column holding tokens like
# `gpt` and `PMBR`. On 2026-11-05 the regex intended to exclude partition-table
# signatures matched none of those tokens, so the header and the gpt/PMBR rows all
# survived the filter and the script REFUSED TO RESUME ITS OWN INTERRUPTED RUN — the same
# class of failure as the 415-line `ras-mc-ctl` channel that counted the word "error"
# inside its own "No Memory errors." headings.
# The gate is now blkid's structured TYPE field. But rc=2 means BOTH "no such tag" AND
# "could not open the device", so reading 2 as corroboration is a vacuous pass — the
# fourth distinct defect in this one guard, and the same class as every other check in
# this repo whose "passed" and "never ran" share an exit code. Corroboration is only
# claimed when the probe's REACH is proven first, by reading a filesystem we know exists.
# ⚠ FIFTH failure of this same guard, and the cause never changed: I kept inferring
# meaning from an exit code I had assumed rather than measured. Measured just now, AS
# ROOT, on a GPT-only disk:
#     blkid -p -o value -s TYPE /dev/nvme2n1   ->  exit 0, EMPTY output
# so `rc == 0` does NOT mean "a filesystem was found" for this invocation form either.
# The previous version therefore refused the run with an empty parenthesis — a guard
# announcing that it does not know what it found. The VALUE is the only trustworthy
# signal here, so the decision is made on the value alone, and a real disagreement
# between the two probe sources becomes a human decision instead of either a silent
# block or a silent pass.
BLKID_FS="$(blkid -p -o value -s TYPE "$CANDIDATE" 2>/dev/null || true)"
BLKID_FS="$(printf '%s' "$BLKID_FS" | tr -d '[:space:]')"
REACH_DEV="$(findmnt -no SOURCE --target / 2>/dev/null | tr -d '[:space:]')"
REACH_FS="$( { [[ -n "$REACH_DEV" ]] && blkid -p -o value -s TYPE "$REACH_DEV" 2>/dev/null; } | tr -d '[:space:]' || true)"
if [[ -z "$REACH_FS" ]]; then
    say "NOTE: blkid has no probe reach from uid $(id -u) — it could not read the known filesystem on ${REACH_DEV:-<none>}."
    say "      Cross-check is UNVERIFIED, not passed. The decision rests on the udev fields above."
elif [[ -z "$BLKID_FS" ]]; then
    say "blkid cross-check agrees: no filesystem signature on $CANDIDATE (reach proven: $REACH_DEV reports '$REACH_FS')"
elif [[ "$BLKID_FS" == "$DISK_FS" ]]; then
    say "blkid cross-check agrees with udev: '$BLKID_FS'"
else
    say "DISAGREEMENT: blkid reports filesystem '$BLKID_FS' on $CANDIDATE where udev published '${DISK_FS:-none}'."
    if [[ "${BLKID_MISMATCH_OK:-0}" == "1" ]]; then
        say "PROCEEDING under BLKID_MISMATCH_OK=1 — an explicit human decision, recorded in this run's output."
    else
        guard "the two probe sources disagree about this disk. Verify it yourself (sudo blkid -p $CANDIDATE; lsblk -f $CANDIDATE), then re-run with BLKID_MISMATCH_OK=1 if you accept blkid's answer."
    fi
fi
if SIG="$(wipefs -n "$CANDIDATE" 2>/dev/null)"; then
    printf '  wipefs (record only, NOT a gate): %s\n' "$(printf '%s' "$SIG" | tr '\n' ' ' | tr -s ' ')"
else
    say "NOTE: wipefs could not open $CANDIDATE from uid $(id -u); not gating on it either way"
fi
say "target=$CANDIDATE model='$TARGET_MODEL' transport=$TRAN removable=$RM pttype='${PTTYPE:-none}' disk-fs='${DISK_FS:-none}' child-fs='${CHILD_FS:-none}' (OS disk=$ROOT_DISK)"

# --- current state of that disk ----------------------------------------------
# ⚠ The partition must be selected by TYPE, never by tree position.
# `lsblk -nro NAME | tail -1` returns the DEEPEST node, which is the partition only
# while the mapper is CLOSED. Measured on 2026-11-05 after the volume was created:
#     lsblk -nro NAME /dev/nvme2n1  ->  nvme2n1 / nvme2n1p1 / jolhome_crypt
# so tail -1 yielded `jolhome_crypt` and PARTNODE became `/dev/jolhome_crypt`, a
# path that does not exist. The bug is created by the script's OWN SUCCESS: it can
# only appear on the resume path, which is exactly the path least exercised.
# The cascade is the part worth recording — `luksDump` on the bogus node returns
# nothing, so the keyslot counter read 0 and step 3 re-prompted for a THIRD key
# instead of skipping; and had luksAddKey succeeded, line `MAPPER_UUID=blkid $PARTNODE`
# would have read the ext4 UUID of the MAPPER rather than the LUKS UUID of the
# partition and written THAT into /etc/crypttab. A crypttab entry keyed to the wrong
# UUID fails at boot with no obvious cause — the same `UUID=` hazard this script was
# written to prevent, reintroduced through a different path.
PART_NODE="$(lsblk -nrpo NAME,TYPE "$CANDIDATE" 2>/dev/null | awk '$2=="part"{print $1; exit}')"
ALREADY_PARTITIONED=0
[[ -n "$PART_NODE" ]] && ALREADY_PARTITIONED=1
# Defence in depth: the value written into crypttab depends on this node being the
# partition of THIS disk and not a holder of it.
if [[ -n "$PART_NODE" ]]; then
    case "$PART_NODE" in
        /dev/mapper/*) guard "resolved '$PART_NODE' as the partition of $CANDIDATE — that is a dm-crypt holder, not a partition"
                       ;;
        "$CANDIDATE"*) : ;;
        *)             guard "resolved '$PART_NODE', which is not a child of $CANDIDATE"
                       ;;
    esac
fi
# Two different questions, and only one of them is answerable without root.
# `cryptsetup status` REQUIRES root, so as uid 1000 it returns nothing and an earlier
# version of this report printed `mapper=closed` for a mapper that was demonstrably open
# (lsblk showed jolhome_crypt carrying ext4 at the same instant). The device link under
# /dev/mapper is world-visible and is the unprivileged answer; cryptsetup's output is
# kept as root-only corroboration, never as the finding.
MAPPER_LINK="no"
[[ -e "/dev/mapper/$MAPPER" ]] && MAPPER_LINK="yes"
OPEN_MAPPER="$(cryptsetup status "$MAPPER" 2>/dev/null | awk '/device:/{print $2}')"
FS_UUID="$(blkid -p -s UUID -o value "/dev/mapper/$MAPPER" 2>/dev/null || true)"
FS_UUID="${FS_UUID:-}"
# MAPPER_UUID is deliberately NOT resolved here. The partition may not exist
# yet — it is created in step 1 — and reading it early produced an empty UUID
# that would have been written straight into /etc/crypttab as `UUID=`. It is
# resolved immediately before use instead.

if [[ "$VERIFY_ONLY" == "1" ]]; then
    say "verify-only report for $CANDIDATE:"
    lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINTS "$CANDIDATE"
    printf '  mapper-link=%s  cryptsetup-status=%s\n' "$MAPPER_LINK" "${OPEN_MAPPER:-not readable from uid $(id -u)}"
    printf '  fs_uuid=%s\n' "${FS_UUID:-not readable from uid $(id -u) (blkid needs read access; try sudo)}"
    printf '  mount=%s  dev_id=%s (root=%s)\n' "$STAGING" \
        "$(stat -c '%d' "$STAGING" 2>/dev/null || echo unmounted)" "$(stat -c '%d' /)"
    exit 0
fi

# =============================================================================
# 1. partition — GPT, one partition, 1 MiB alignment
#    Partitioned rather than whole-disk LUKS: the whole-disk form is what made
#    `/dev/sdb1` a node that could never exist. A named partition plus a UUID
#    reference keeps the identity unambiguous.
# =============================================================================
if (( ALREADY_PARTITIONED )); then
    say "step 1 skip: $CANDIDATE already has $PART_NODE"
else
    run parted --script "$CANDIDATE" mklabel gpt mkpart "$FS_LABEL" 1MiB 100% || fail "parted failed"
    run partprobe "$CANDIDATE" || true
    PART_NODE="$(lsblk -nrpo NAME,TYPE "$CANDIDATE" 2>/dev/null | awk '$2=="part"{print $1; exit}')"
    [[ -n "$PART_NODE" ]] || fail "partition did not appear on $CANDIDATE"
fi
PARTNODE="$PART_NODE"

# =============================================================================
# 2. LUKS2
#    cryptsetup 2.7.0 on this host defaults to LUKS2 + argon2id, so the
#    parameters are stated rather than inherited: a default that changes with
#    the package is not a configuration.
#      aes-xts-plain64 / 512-bit key  = AES-256 XTS (2 x 256)
#      sha512 as the LUKS hash
#      --iter-time 2000 so argon2id is calibrated to 2 s, not the 1 s default
# =============================================================================
if [[ -n "$OPEN_MAPPER" ]]; then
    say "step 2 skip: /dev/mapper/$MAPPER is already open from $OPEN_MAPPER"
elif [[ "$MAPPER_LINK" == "yes" ]]; then
    # Reached when the mapper is open but cryptsetup could not confirm it (no root).
    # luksFormat must NOT run against an active volume under any reading of the state.
    say "step 2 skip: /dev/mapper/$MAPPER exists — the volume is already open (cryptsetup status unavailable from uid $(id -u))"
elif blkid "$PARTNODE" 2>/dev/null | grep -q crypto_LUKS; then
    say "step 2 skip: $PARTNODE is already a LUKS2 container"
else
    say "You will be prompted for the passphrase TWICE (volume key, then recovery key). Enter values"
    say "chosen by you — this script never sees, stores or echoes either one."
    # ⚠ THE CONFIRMATION IS TAKEN OVER HERE, ON PURPOSE.
    # cryptsetup's own prompt reads:  Are you sure? (Type 'yes' in capital letters):
    # and then REJECTS the lower-case string it just displayed. That wording has cost two
    # consecutive runs on 2026-11-05 — the operator answered exactly what the message
    # said, cryptsetup printed "Operation aborted", and the script reported a generic
    # "luksFormat failed". Telling the operator harder is not a fix; a prompt that
    # contradicts itself is. So cryptsetup runs --batch-mode (which suppresses only the
    # confirmation, never the passphrase prompts) and this script asks ONE question, in
    # its own words, validating the answer itself.
    # This is safe to make non-interactive because the decision is already over-
    # determined: model-matched target, transport=nvme, removable=0, no filesystem on the
    # disk or any child, partition table absent or created by this script, OS disk refused
    # by name, and gate 0 requiring a restore-proven /home backup before any of it runs.
    if [[ "$DRY_RUN" != "1" && "${ASSUME_YES:-0}" != "1" ]]; then
        # TTY_DEV defaults to the real controlling terminal and is only overridable so
        # this branch can be tested. An untested safety gate is the recurring finding in
        # this thread, so the gate is made observable rather than left trusted.
        TTY_DEV="${TTY_DEV:-/dev/tty}"
        if [[ ! -r "$TTY_DEV" || ! -w "$TTY_DEV" ]]; then
            guard "no controlling terminal ($TTY_DEV) to confirm an irreversible write on $PARTNODE."
        fi
        printf 'Type YES to irreversibly initialise LUKS on %s (blank, model-matched, not the OS disk): ' "$PARTNODE"
        CONFIRM=""
        # `read` exits non-zero when input ends without a delimiter (EOF-without-newline),
        # which is a benign condition, not a refusal — measured in the branch test, where
        # every answer was rejected as "could not be read". Treating that status as fatal
        # conflates a harness quirk with a real no-answer, so the status is dropped and the
        # VALUE decides: empty means nothing was supplied, anything else is judged below.
        read -r CONFIRM < "$TTY_DEV" || true
        if [[ -z "$CONFIRM" ]]; then
            fail "no confirmation was supplied (nothing read from $TTY_DEV) — nothing was written to $PARTNODE"
        fi
        if [[ "$CONFIRM" != "YES" ]]; then
            # Wording measured against the branch test, not assumed: `read` strips
            # surrounding IFS whitespace, so "YES " IS accepted. An earlier draft told the
            # operator "no trailing space", which the code does not enforce — a message
            # that misdescribes its own gate is the same defect class as the rest of this
            # thread. The token must be YES; surrounding whitespace is ignored.
            fail "confirmation was '${CONFIRM}', not the word YES (case-sensitive; surrounding whitespace is ignored). Nothing was written to $PARTNODE."
        fi
        say "confirmation accepted"
    elif [[ "${ASSUME_YES:-0}" == "1" ]]; then
        say "ASSUME_YES=1 set — confirmation skipped by explicit operator choice, recorded here."
    fi
    run cryptsetup luksFormat --batch-mode --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --pbkdf argon2id --iter-time 2000 --label "$FS_LABEL" "$PARTNODE" \
        || fail "luksFormat failed"
fi

# =============================================================================
# 3. a SECOND keyslot, offline, stored in custody
#    One passphrase and no recovery path is a self-inflicted data-loss event:
#    a forgotten passphrase, a failed keyboard during an unlock, or a firmware
#    update that changes the TPM state all destroy the volume.
#    ⚠ Do NOT store this on the sdb/sdc USB sticks until what they hold is
#      confirmed — they look like existing dual-control custody media.
# =============================================================================
KEYSLOTS="$(cryptsetup luksDump "$PARTNODE" 2>/dev/null | grep -cE '^\s+[0-9]+: (luks2|argon2id)')" || KEYSLOTS=0
if (( KEYSLOTS >= 2 )); then
    say "step 3 skip: $KEYSLOTS keyslots present"
else
    say "Add a recovery key now and put it into the existing custody process"
    say "(docs/compliance/sops-age-key-custody-plan.md), not into a repo, not into /etc, not as a CLI argument."
    run cryptsetup luksAddKey "$PARTNODE" || fail "could not add a recovery keyslot"
fi

if [[ "$TPM2_ENROLL" == "1" ]]; then
    say "step 3b: TPM2 enrolment requested — verify initramfs support BEFORE rebooting, and keep both"
    say "         passphrase keyslots; a TPM-bound volume that cannot unseal is indistinguishable from a lost one."
    run systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$PARTNODE" || fail "systemd-cryptenroll failed"
fi

# =============================================================================
# 4. open + mkfs.ext4
#    Deliberately WITHOUT `stride`/`stripe-width`: those tune for RAID chunk
#    geometry and this is a single direct-attached SSD — setting them from a
#    generic guide makes allocation worse, not better.
#    e2fsprogs 1.47.0 already enables metadata_csum, 64bit and flex_bg by
#    default, so nothing has to be added for checksumming.
#    -m 1: the 5 % default would reserve 47.7 GiB of a 953.9 GiB volume for
#    root. On a data/home filesystem that is pure waste; 1 % (9.5 GiB) keeps
#    headroom for root-owned recovery work.
#    Inode ratio left at the default: measured on the current /home, inodes are
#    only 18 % used (1,086,421 of 6,111,232), so there is no exhaustion pressure
#    to buy back space for.
# =============================================================================
# Idempotent on both halves. `cryptsetup open` on an already-active name fails with
# "Device jolhome_crypt already exists", and on the 2026-11-05 resume path that would have
# aborted a run whose only remaining work was writing crypttab and fstab.
if [[ -e "/dev/mapper/$MAPPER" ]]; then
    say "step 4 skip: /dev/mapper/$MAPPER is already open"
else
    run cryptsetup open "$PARTNODE" "$MAPPER" || fail "cryptsetup open failed"
fi
if blkid "/dev/mapper/$MAPPER" 2>/dev/null | grep -q 'TYPE="ext4"'; then
    say "step 4 skip: /dev/mapper/$MAPPER already holds ext4"
else
    run mkfs.ext4 -L "$FS_LABEL" -m 1 "/dev/mapper/$MAPPER" || fail "mkfs.ext4 failed"
fi
run tune2fs -c 30 -i 180d "/dev/mapper/$MAPPER" || true   # matches the fleet's HDD fsck convention

# =============================================================================
# 5. mount options — two decisions that come from measurements on THIS host
#
#  noatime: every existing mount here runs `relatime` (measured on /, /home and
#     /opt/jol). A developer tree is dominated by stat-heavy traversal — git
#     status across a monorepo, IDE indexing, node_modules walks — and each
#     access-time update is a write. On a DRAM-less TLC drive those writes are
#     not free, so noatime reduces both latency and endurance consumption.
#
#  NO discard: `fstrim.timer` is enabled and already ran 2026-11-02, next
#     2026-11-09. Batch weekly TRIM already keeps the SSD's free-block list
#     current, so mount-time `discard` buys nothing here while costing two real
#     things: per-allocation synchronous TRIM latency, and — because this is
#     LUKS — a discard information leak that tells an observer which blocks are
#     in use. Leaving `allow-discards` out of crypttab is the deliberate choice.
#
#  NO nofail: this is the direct lesson of /mnt/jol-backup. `nofail` on a mount
#     whose device is absent lets the boot continue and the path become an
#     ordinary directory on /, which is how four nights of state backups were
#     silently lost. For a data volume, failing loudly at boot is correct.
#     The capacity watchdog's gate 2 is the second layer, not the first.
# =============================================================================
FS_UUID="$(blkid -s UUID -o value "/dev/mapper/$MAPPER" 2>/dev/null)"
[[ -n "$FS_UUID" ]] || fail "could not read the new filesystem UUID"
# MAPPER_UUID is resolved below, immediately before it is written. There was an earlier
# line here reading `[[ -n "$MAPPER_UUID" ]] || ...` before any assignment existed, and
# under `set -u` that ABORTED the script at line 382 — after luksFormat, luksAddKey,
# cryptsetup open, mkfs.ext4 and tune2fs had all succeeded, and before crypttab and fstab
# were written. The result was a real LUKS volume holding the operator's passphrase that
# would not unlock at boot. A reference to an uninitialised variable is not a guard; it is
# a time bomb placed after the irreversible steps.
run mkdir -p "$STAGING"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
# Resolved now, after partitioning and luksFormat, so it can never be empty.
MAPPER_UUID="$(blkid -s UUID -o value "$PARTNODE" 2>/dev/null)"
[[ -n "$MAPPER_UUID" ]] || fail "could not read the LUKS UUID of $PARTNODE — refusing to write an empty crypttab entry"
# The two UUIDs MUST differ: MAPPER_UUID identifies the LUKS header on the partition,
# FS_UUID identifies the ext4 inside the mapper. Equality means PARTNODE resolved to the
# mapper rather than the partition — the exact failure mode measured on 2026-11-05, which
# would have written the ext4 UUID into crypttab and produced a boot-time unlock failure
# with no obvious cause. This is a cheap invariant that catches the whole class.
if [[ "$MAPPER_UUID" == "$FS_UUID" ]]; then
    fail "the LUKS UUID and the filesystem UUID are identical ($FS_UUID) — $PARTNODE resolved to the mapper, not the partition. Refusing to write crypttab."
fi
say "identity: LUKS UUID=$MAPPER_UUID (partition $PARTNODE) / ext4 UUID=$FS_UUID (mapper) — distinct, as required"
if ! grep -q "$MAPPER" /etc/crypttab 2>/dev/null; then
    run cp -p /etc/crypttab "/etc/crypttab.bak.$TS" || fail "could not back up crypttab"
    run bash -c "printf 'jolhome_crypt UUID=%s none luks\\n' '$MAPPER_UUID' >> /etc/crypttab" \
        || fail "could not write crypttab"
    say "crypttab: added jolhome_crypt by LUKS UUID (no allow-discards, by design)"
else
    say "step 5 skip: crypttab already references $MAPPER"
fi

if ! grep -q "$FS_UUID" /etc/fstab 2>/dev/null; then
    run cp -p /etc/fstab "/etc/fstab.bak.$TS" || fail "could not back up fstab"
    run bash -c "printf 'UUID=%s %s ext4 defaults,noatime,errors=remount-ro 0 2\\n' '$FS_UUID' '$STAGING' >> /etc/fstab" \
        || fail "could not write fstab"
    say "fstab: added $STAGING by filesystem UUID (no nofail, by design)"
else
    say "step 5 skip: fstab already references $FS_UUID"
fi

run systemctl daemon-reload || true
run mount "$STAGING" || fail "mount $STAGING failed — check /etc/fstab.bak.$TS"

# =============================================================================
# 6. verification — by post-state, never by having reached a line
# =============================================================================
say "=== post-state ==="
MDEV="$(stat -c '%d' "$STAGING" 2>/dev/null || echo absent)"
RDEV="$(stat -c '%d' /)"
[[ "$MDEV" != "$RDEV" && "$MDEV" != "absent" ]] || fail "$STAGING resolves to / ($RDEV) — mount is not real"
say "mount identity : $STAGING device=$MDEV, / device=$RDEV  → OFF-DISK PASS"
say "capacity       : $(df -h "$STAGING" | tail -1)"
say "mount options  : $(findmnt -no OPTIONS "$STAGING")"
say "scheduler      : $(cat "/sys/block/$(basename "$CANDIDATE")/queue/scheduler")  (nothing set — already 'none' on all NVMe here)"
say "trim policy    : batch=$(systemctl is-enabled fstrim.timer 2>/dev/null) mount-discard=$(findmnt -no OPTIONS "$STAGING" | grep -c discard) crypttab-allow-discards=$(grep -c allow-discards /etc/crypttab 2>/dev/null)"
say "keyslots       : $(cryptsetup luksDump "$PARTNODE" 2>/dev/null | grep -cE '^\s+[0-9]+: (luks2|argon2id)') (need >= 2)"
say "fs features    : $(dumpe2fs -h "/dev/mapper/$MAPPER" 2>/dev/null | awk -F': ' '/Filesystem features/{print $2}')"
say "reserved       : $(dumpe2fs -h "/dev/mapper/$MAPPER" 2>/dev/null | awk -F': ' '/Reserved block count/{print $2}') blocks"
say ""
say "Next: Phase 2 of the runbook moves /home here from rescue mode. Nothing above touched /home."
say "Rollback: umount $STAGING; cryptsetup close $MAPPER;"
say "          cp -p /etc/fstab.bak.$TS /etc/fstab; cp -p /etc/crypttab.bak.$TS /etc/crypttab;"
say "          (wiping the LUKS header is the only destructive part, and it holds no prior data)"
exit 0
