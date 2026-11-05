#!/usr/bin/env bash
# =============================================================================
# record-jolhome-custody.sh — prove the LUKS recovery keyslot opens the jolhome
# volume, then write the custody attestation that Phase 2's gate reads.
#
# WHY THIS EXISTS
# migrate-home-to-jolhome.sh used to only PRINT that the recovery keyslot "must
# already be in custody per the SOP". A control that cannot fail is not a control.
# This script supplies the missing evidence, and that script now refuses the
# cutover without it.
#
# WHY IT CANNOT LEAK WHAT IT IS PROOFING
# It never sees, reads, stores, echoes or hashes a passphrase. cryptsetup prompts
# on the operator's own controlling terminal and cryptsetup alone holds the input
# (AGENTS.md §0.1: never pass credentials as arguments or through a pipe this
# script controls). The artifact records that the verification SUCCEEDED plus
# public metadata — the LUKS header UUID, the slot index, the slot count, the
# custody location class — and `secret_recorded=no` states that plainly.
#
# A verification that fails writes NOTHING, so a slot occupied by a passphrase
# nobody can reproduce can never be recorded as custody. Two keyslots existing is
# not the same claim, and that distinction is the whole reason for this script.
#
# Design contract: idempotent, DRY_RUN=1 by default, root-only, change-logged,
# self-checking: the written artifact is re-read through the SAME custody_verdict
# function the gate uses, extracted from the script under test rather than copied,
# so the recorder cannot produce an artifact its own gate would reject.
# =============================================================================
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DRY_RUN="${DRY_RUN:-1}"
MAPPER="${MAPPER:-jolhome_crypt}"
CRYPTTAB="${CRYPTTAB:-/etc/crypttab}"
ATTESTATION="${ATTESTATION:-/var/lib/jol-workstation/jolhome-custody}"
GATE_SCRIPT="${GATE_SCRIPT:-/opt/jol/repos/jol-infrastructure/scripts/maintenance/migrate-home-to-jolhome.sh}"
MIN_SLOTS="${MIN_SLOTS:-2}"

# Location classes the SOP recognises. Anything else is refused rather than
# accepted as free text, because a blank or invented location is exactly what a
# placeholder looks like in an audit — and a placeholder matched nothing once
# already in this repo's runbook.
LOC_CLASSES=(
    "vaultwarden:sops-custody"
    "usb-safe:DR-JOL"
    "offsite-sealed-envelope"
)

say() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '[%s] ABORT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 2; }

# --- --clear: the negative control, mirroring backup-workstation-home.sh ------
# Removing the artifact must make the gate refuse. An operator can prove that in
# one command, which is the only way to know the gate is alive rather ornamental.
if [[ "${1:-}" == "--clear" ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "--clear needs root (the attestation is root-owned)"
    if [[ -e "$ATTESTATION" ]]; then
        rm -f "$ATTESTATION" || die "could not remove $ATTESTATION"
        say "Cleared $ATTESTATION — migrate-home-to-jolhome.sh will now refuse the cutover."
        say "Re-run this recorder to restore it. The keyslot itself is untouched."
    else
        say "$ATTESTATION was already absent — nothing removed, gate already refuses."
    fi
    exit 0
fi

# DRY_RUN is deliberately reachable WITHOUT root, because "what would this do?" is
# a question the operator should be able to ask before deciding to escalate. Every
# mutating path still requires uid 0. Slot enumeration is a root-only read, so an
# unprivileged plan reports it as NOT MEASURED — never as zero slots, which is the
# absent-measured-as-a-number failure this repo has now been bitten by twice.
if [[ "$DRY_RUN" != "1" && "$(id -u)" -ne 0 ]]; then
    die "needs root for DRY_RUN=0: the artifact is written 600 root:root and cryptsetup must read the LUKS header. Use DRY_RUN=1 to see the plan unprivileged."
fi

say "=== record-jolhome-custody.sh (DRY_RUN=$DRY_RUN, host=$(hostname)) ==="

# --- resolve the volume from the boot config, never from a device node --------
# The node was nvme0n1p? until the disk was swapped on 2026-11-05; an identity
# that changes with hardware cannot be a security binding. crypttab names the
# LUKS header by UUID, and udev symlinks that UUID, so the chain is:
# MAPPER -> crypttab UUID -> /dev/disk/by-uuid/<uuid> -> real node.
LUKS_UUID="$(awk -v m="$MAPPER" '$1 == m && $2 ~ /^UUID=/ { sub(/^UUID=/, "", $2); print $2; exit }' "$CRYPTTAB" 2>/dev/null)"
[[ -n "$LUKS_UUID" ]] || die "$MAPPER has no UUID= line in $CRYPTTAB — Phase 1 did not complete, or crypttab was edited"
case "$LUKS_UUID" in
    *[!0-9a-fA-F-]*|'') die "crypttab gave an unusable UUID for $MAPPER: '$LUKS_UUID'" ;;
esac

BYUUID="/dev/disk/by-uuid/$LUKS_UUID"
[[ -e "$BYUUID" ]] || die "$BYUUID does not exist — udev has not published the LUKS header UUID for this volume"
LUKS_DEV="$(readlink -f "$BYUUID")"
[[ -b "$LUKS_DEV" ]] || die "$BYUUID -> $LUKS_DEV is not a block device"
say "volume: $MAPPER -> UUID=$LUKS_UUID -> $LUKS_DEV"

# --- how many keyslots, and which one is the recovery secret? -----------------
if [[ "$(id -u)" -eq 0 ]]; then
    DUMP="$(cryptsetup luksDump "$LUKS_DEV" 2>&1)" \
        || die "cryptsetup luksDump failed on $LUKS_DEV: $(printf '%s' "$DUMP" | head -1)"
    SLOT_LIST="$(printf '%s\n' "$DUMP" | sed -n '/^Keyslots:/,/^Tokens:/p' | grep -oE '^  [0-9]+: luks2' | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')"
    SLOT_COUNT="$(printf '%s' "$SLOT_LIST" | wc -w)"
    say "keyslots occupied: $SLOT_COUNT ($SLOT_LIST)"
    (( SLOT_COUNT >= MIN_SLOTS )) || die "only $SLOT_COUNT keyslot(s) on $LUKS_DEV. Add a recovery slot first (provision-jolhome-disk.sh step 3); this script will not invent one."
else
    SLOT_LIST=''
    SLOT_COUNT=0
    say "keyslots occupied: NOT MEASURED — cryptsetup luksDump needs root. Plan only; nothing is asserted about the slot count."
fi

if [[ "$DRY_RUN" == "1" ]]; then
    say "PLAN : prompt for the recovery slot index, then run"
    say "       cryptsetup luksOpen --test-passphrase --key-slot <N> $LUKS_DEV"
    say "       (cryptsetup reads the passphrase from YOUR terminal; this script never does)"
    say "PLAN : write $ATTESTATION (mode 600, root:root) with the public metadata only"
    say "PLAN : re-read it through custody_verdict from $GATE_SCRIPT and delete it if not PASS"
    say ""
    say "Nothing was verified and nothing was written. Re-run with DRY_RUN=0."
    exit 0
fi

# --- the interactive part: needs a real terminal, and refuses without one -----
# Silent failure here would be the worst kind: a gate recording a verification
# that never happened.
if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    # One die, not two: die() exits, so a follow-up die is dead code and the
    # operator would have read half a reason. Multi-line strings must live inside
    # a single call.
    die "no usable controlling terminal (/dev/tty). The passphrase must be typed by a human
directly into cryptsetup; running this over 'ssh -T' or from cron is refused, because a
non-interactive run could only read the secret from a pipe or argument — both forbidden."
fi

printf 'Which keyslot holds the RECOVERY secret? [%s] ' "$SLOT_LIST"
read -r SLOT < /dev/tty || die "could not read the slot index from /dev/tty — nothing was written"
case "$SLOT" in
    ''|*[!0-9]*) die "'$SLOT' is not a keyslot number — nothing was written" ;;
esac
if ! printf '%s' " $SLOT_LIST " | grep -q " $SLOT "; then
    die "keyslot $SLOT is not occupied on this volume (occupied: $SLOT_LIST) — nothing was written"
fi

say "Verifying keyslot $SLOT opens $LUKS_DEV."
say "cryptsetup will prompt. This script does not see, capture or store what you type."
if cryptsetup luksOpen --test-passphrase --key-slot "$SLOT" "$LUKS_DEV"; then
    VERIFY=PASS
    say "keyslot $SLOT verified — the secret recorded in custody does open this volume"
else
    VERIFY=FAIL
    say "keyslot $SLOT did NOT open the volume."
    die "verification FAILED — no attestation written. Recording custody of a secret that does
not unlock the volume is worse than recording nothing, because it makes the cutover look
protected while the recovery path is fiction. Fix the recovery secret first, then re-run."
fi

# --- custody location: an allowlist, not free text ----------------------------
say "Where is the recovery passphrase held? (one class per line)"
for i in "${!LOC_CLASSES[@]}"; do printf '  %s) %s\n' "$((i + 1))" "${LOC_CLASSES[$i]}"; done
printf 'Choose [1-%s]: ' "${#LOC_CLASSES[@]}"
read -r CHOICE < /dev/tty || die "could not read the location choice — nothing was written"
case "$CHOICE" in
    ''|*[!0-9]*) die "'$CHOICE' is not one of the listed classes — nothing was written" ;;
esac
if (( CHOICE < 1 || CHOICE > ${#LOC_CLASSES[@]} )); then
    die "choice $CHOICE out of range (1-${#LOC_CLASSES[@]}) — nothing was written"
fi
LOCATION="${LOC_CLASSES[$((CHOICE - 1))]}"

# --- write atomically, 600 root:root, no secret material ----------------------
ATTEST_DIR="$(dirname "$ATTESTATION")"
[[ -d "$ATTEST_DIR" ]] || { mkdir -p "$ATTEST_DIR" || die "could not create $ATTEST_DIR"; }
chmod 700 "$ATTEST_DIR" 2>/dev/null || true
chown root:root "$ATTEST_DIR" 2>/dev/null || true

TMP_AT="$ATTESTATION.tmp.$$"
UTC_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ATTESTER="${SUDO_USER:-root}"
{
    printf 'schema=1\n'
    printf 'utc=%s\n'        "$UTC_NOW"
    printf 'host=%s\n'       "$(hostname)"
    printf 'mapper=%s\n'     "$MAPPER"
    printf 'luks_uuid=%s\n'  "$LUKS_UUID"
    printf 'keyslot=%s\n'    "$SLOT"
    printf 'slots_total=%s\n' "$SLOT_COUNT"
    printf 'verify=%s\n'     "$VERIFY"
    printf 'verify_cmd=cryptsetup luksOpen --test-passphrase --key-slot %s\n' "$SLOT"
    printf 'custody_location=%s\n' "$LOCATION"
    printf 'attested_by=%s\n' "$ATTESTER"
    printf 'secret_recorded=no\n'
} > "$TMP_AT" || die "could not write $TMP_AT"
chmod 600 "$TMP_AT" || die "could not set mode 600 on the attestation"
chown root:root "$TMP_AT" || die "could not set ownership on the attestation"

# --- self-check: the artifact must satisfy the gate that will read it ---------
# Extracted from the script under test rather than reimplemented here, so the two
# cannot drift. If extraction fails, this aborts rather than writing an unproved
# artifact — a recorder that silently skips its own check is the vacuous-gate class.
FUNC="$(awk '/^custody_verdict\(\) \{/,/^\}/' "$GATE_SCRIPT" 2>/dev/null)"
if [[ -z "$FUNC" ]] || ! grep -q 'SECRET_RECORDED' <<<"$FUNC"; then
    rm -f "$TMP_AT"
    die "could not extract custody_verdict from $GATE_SCRIPT — refusing to write an artifact I cannot check"
fi
# shellcheck disable=SC2034  # MAPPER is consumed by the extracted function's callers
eval "$FUNC"
SELF="$(custody_verdict "$LUKS_UUID" "$(date -u +%s)" "${CUSTODY_MAX_AGE_D:-90}" < "$TMP_AT")"
if [[ "$SELF" != "PASS" ]]; then
    rm -f "$TMP_AT"
    die "the artifact I just wrote would be REJECTED by the gate ($SELF) — nothing installed"
fi

mv -f "$TMP_AT" "$ATTESTATION" || die "could not install $ATTESTATION"
say "attestation installed: $ATTESTATION ($(stat -c '%a %U:%G' "$ATTESTATION"))"
say "recorded: keyslot $SLOT of $SLOT_COUNT, location class $LOCATION, attested by $ATTESTER"
say "NOT recorded: any passphrase. secret_recorded=no is a field the gate enforces."
say ""
say "Next:  bash migrate-home-to-jolhome.sh --preflight   # custody must read PASS"
say "Drill: sudo $0 --clear                               # proves the gate actually refuses"
say "Per SOP: add a §3 row to docs/compliance/sops-age-key-custody-plan.md (locations only)."
