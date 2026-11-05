#!/usr/bin/env bash
# =============================================================================
# migrate-home-to-jolhome.sh — Phase 2: move /home onto the encrypted volume.
#
# WHY THIS SCRIPT EXISTS INSTEAD OF THE RUNBOOK'S §4 SNIPPET
# The runbook's original §4.4 had four defects, each of which is a known failure
# shape in this repo, and all four are fixed here rather than in prose:
#
#   1. `sed -i.bak 's|UUID=<old-home-uuid>.*|…|'` contains a LITERAL PLACEHOLDER.
#      A sed pattern that matches nothing is a silent no-op — the same class as
#      every "passed and never ran" gate in this thread. It is replaced by a
#      function that resolves the real UUIDs from the live fstab and refuses if
#      they are ambiguous, and that function is unit-tested.
#
#   2. It wrote `/dev/mapper/jolhome_crypt` as a DEVICE PATH into fstab, which
#      contradicts the rule this repo enforces everywhere else (identity by UUID,
#      never by node) and contradicts §3.3, which mounted the same filesystem by
#      UUID twenty minutes earlier.
#
#   3. It used `nofail`. That is precisely the option that let `/mnt/jol-backup`
#      degrade into an ordinary directory on `/` and silently lose four nights of
#      Terraform state backups. §3.2b of the runbook explicitly rejects `nofail`
#      for this volume; §4.4 reintroduced it. A `/home` that fails to mount MUST
#      be loud, because a silent empty `/home` means no SSH keys, no repos, and
#      a desktop that appears to work.
#
#   4. It never removed the staging line. After the swap the SAME ext4 UUID would
#      be declared at both `/home` and `/mnt/jolhome-staging`, producing two
#      systemd mount units for one device and a fsck pass field applied twice.
#      The correct edit is to REPURPOSE the staging line: same UUID, same
#      options, new mount point. One line out, one line changed, nothing added.
#
# WHY THE CUTOVER CANNOT RUN FROM A DESKTOP SESSION
# Measured 2026-11-05: 204 processes owned by the operator, 58 of them IDE,
# browser or agent processes — including this agent, which lives in
# ~/.qoder. A copy taken while those run is inconsistent, and /home cannot be
# unmounted or swapped underneath them. So the cutover refuses unless /home is
# quiet, and --preflight exists so that everything checkable can be checked now.
#
# Design contract: idempotent, DRY_RUN=1 by default, non-destructive (the old
# /home on nvme1n1p7 is never modified — it IS the rollback), change-logged.
# =============================================================================
set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DRY_RUN="${DRY_RUN:-1}"
MODE="cutover"
[[ "${1:-}" == "--preflight" ]] && MODE="preflight"

STAGING="${STAGING:-/mnt/jolhome-staging}"
MAPPER="${MAPPER:-jolhome_crypt}"
HOME_SRC="${HOME_SRC:-/home}"
FSTAB="${FSTAB:-/etc/fstab}"

# The target must have this much MORE free space than the payload, measured from
# df (never du — du under-reports across mount boundaries and sparse files).
FREE_MARGIN_PCT="${FREE_MARGIN_PCT:-110}"
# How recent the Phase 0 backup proof must be. The copy is only as safe as the
# backup behind it, and a proof from this morning does not describe /home now.
PROOF_MAX_AGE_H="${PROOF_MAX_AGE_H:-6}"
HOME_BACKUP_PROOF="${HOME_BACKUP_PROOF:-/var/lib/jol-workstation/home-backup-proof}"
# Above this many operator-owned processes, /home is not quiet enough to copy.
MAX_BUSY_PROCS="${MAX_BUSY_PROCS:-8}"
# Custody attestation for the LUKS recovery keyslot. Written by
# record-jolhome-custody.sh, which VERIFIES the keyslot opens the volume; this
# script only reads the record. It contains no secret material by construction.
CUSTODY_ATTESTATION="${CUSTODY_ATTESTATION:-/var/lib/jol-workstation/jolhome-custody}"
# An attestation is a measurement, and measurements expire: it proves the slot
# opened on the day it ran, not today. Default matches the quarterly rehearsal
# cadence ratified as D5 in docs/compliance/sops-age-key-custody-plan.md.
CUSTODY_MAX_AGE_D="${CUSTODY_MAX_AGE_D:-90}"
CRYPTTAB="${CRYPTTAB:-/etc/crypttab}"
# The apt unattended-upgrade config is world-readable, so this can be checked without
# root. It is checked because it is the only thing that turns a console passphrase
# prompt from an inconvenience into a machine that is down until someone walks over.
UU_CONFIG_DIR="${UU_CONFIG_DIR:-/etc/apt/apt.conf.d}"

FAILURES=0
say()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
info() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
alert() { printf '[%s] ALERT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; FAILURES=$((FAILURES + 1)); }
die()  { printf '[%s] ABORT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 2; }
run() {
    if [[ "$DRY_RUN" == "1" ]]; then printf 'PLAN : %s\n' "$*"; return 0; fi
    printf 'APPLY: %s\n' "$*"; "$@"
}

# -----------------------------------------------------------------------------
# The fstab rewrite, as a PURE FUNCTION so it can be tested without touching a
# real system. This is the one edit in Phase 2 that can prevent the machine from
# booting into a usable state, so it is the part that gets a test rather than a
# review.
#
#   stdin  : fstab contents
#   $1     : the UUID currently mounted at /home          (line gets commented out)
#   $2     : the UUID currently mounted at $STAGING       (mount point becomes /home)
#
# Output is the new fstab. It never adds a line and never deletes one: the old
# /home line is commented in place so the rollback is a visible, greppable edit
# rather than a restoration from backup that might silently fail.
# -----------------------------------------------------------------------------
rewrite_fstab() {
    local old_uuid="$1" new_uuid="$2"
    awk -v oldu="UUID=${old_uuid}" -v newu="UUID=${new_uuid}" -v staging="$STAGING" '
        # comment out the existing /home line, keeping it readable as the rollback
        ($1 == oldu && $2 == "/home") {
            print "# PHASE2-CUTOVER: previous /home retained as rollback (restore by uncommenting)"
            print "# " $0
            next
        }
        # repurpose the staging line: same UUID, same options, new mount point.
        # Fields are rebuilt explicitly rather than substituted in $0, so a
        # staging path that happens to appear in a comment cannot be rewritten.
        ($1 == newu && $2 == staging) {
            out = $1 " /home"
            for (i = 3; i <= NF; i++) out = out " " $i
            print out
            next
        }
        { print }
    '
}

# -----------------------------------------------------------------------------
# The custody gate, a PURE FUNCTION for the same reason rewrite_fstab is one:
# until now the cutover only PRINTED advice that the recovery keyslot "must
# already be in custody". A control with no way to fail is not a control — that
# is the defect class this repo has been eliminating all week, and it was in my
# own script.
#
#   stdin : attestation file contents (may be empty)
#   $1    : the LUKS header UUID this volume REALLY has, read from /etc/crypttab
#   $2    : now, seconds since the epoch
#   $3    : maximum acceptable attestation age, days
#
# Prints exactly one token, and never reads a passphrase — it could not if it
# wanted to, which is the point.
#
# Branch table (every one of these is a fixture in tests/test-home-migration.sh):
#   EMPTY            no recognisable fields — the recorder never completed
#   SECRET_RECORDED  the artifact claims a secret was written into it: refuse,
#                    because custody copy and backup copy being one file on one
#                    disk is precisely the single-copy failure being avoided
#   NO_VERIFY_PASS   the keyslot was never demonstrated to open the volume.
#                    Two keyslots existing is NOT this; it says a slot is
#                    occupied, not that its passphrase is the one on paper
#   NO_REFERENCE_UUID crypttab has no UUID= line for the mapper, so nothing to
#                    bind the attestation to — fail closed rather than skip
#   UUID_MISMATCH    attestation describes a different volume than will be
#                    mounted: catches an artifact copied forward, or left behind
#                    after a re-format, which is how attestations rot
#   SINGLE_SLOT      fewer than 2 keyslots: one passphrase, no recovery path
#   BAD_SLOTS        slots_total is not a number — an unreadable artifact
#   NO_LOCATION      no custody location recorded
#   BAD_STAMP        utc is not a parseable Z stamp
#   FUTURE_STAMP     attestation dated ahead of now — cannot be trusted
#   STALE            older than CUSTODY_MAX_AGE_D: re-run, it re-verifies
#   PASS             all of the above hold
# -----------------------------------------------------------------------------
custody_verdict() {
    local want="${1:-}" now="${2:-0}" maxdays="${3:-90}" k val
    local v_verify='' v_uuid='' v_slots='' v_loc='' v_secret='' v_utc=''
    while IFS='=' read -r k val; do
        case "$k" in
            verify)           v_verify="$val" ;;
            luks_uuid)        v_uuid="$val" ;;
            slots_total)      v_slots="$val" ;;
            custody_location) v_loc="$val" ;;
            secret_recorded)  v_secret="$val" ;;
            utc)              v_utc="$val" ;;
        esac
    done

    if [[ -z "$v_verify" && -z "$v_uuid" && -z "$v_utc" ]]; then
        printf 'EMPTY\n'; return 0
    fi
    if [[ "$v_secret" != "no" ]]; then printf 'SECRET_RECORDED\n'; return 0; fi
    if [[ "$v_verify" != "PASS" ]];   then printf 'NO_VERIFY_PASS\n';  return 0; fi
    if [[ -z "$want" ]];              then printf 'NO_REFERENCE_UUID\n'; return 0; fi
    if [[ "$v_uuid" != "$want" ]];    then printf 'UUID_MISMATCH\n';   return 0; fi
    if [[ -z "$v_slots" ]]; then printf 'BAD_SLOTS\n'; return 0; fi
    case "$v_slots" in
        *[!0-9]*) printf 'BAD_SLOTS\n'; return 0 ;;
    esac
    if (( v_slots < 2 ));   then printf 'SINGLE_SLOT\n';  return 0; fi
    if [[ -z "$v_loc" ]];   then printf 'NO_LOCATION\n';  return 0; fi
    # Age comes from the recorded utc field, never from the file mtime: a
    # written-then-copied artifact carries an inherited mtime, which is exactly
    # how gate 6 reported a 36-minute-old backup as 1875 h stale.
    case "$v_utc" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) printf 'BAD_STAMP\n'; return 0 ;;
    esac
    local then_s age_d
    then_s="$(date -u -d "$v_utc" +%s 2>/dev/null || echo '')"
    if [[ -z "$then_s" ]]; then printf 'BAD_STAMP\n'; return 0; fi
    age_d=$(( (now - then_s) / 86400 ))
    if (( age_d < 0 )); then printf 'FUTURE_STAMP\n'; return 0; fi
    if (( age_d > maxdays )); then printf 'STALE\n'; return 0; fi
    printf 'PASS\n'
}

# The reference UUID comes from the boot configuration itself, not from a device
# node — nvme2n1p1 was nvme0n1p? until the disk was swapped on 2026-11-05, and an
# identity that changes when hardware changes cannot be a security binding.
luks_uuid_reference() {
    awk -v m="$MAPPER" '$1 == m && $2 ~ /^UUID=/ { sub(/^UUID=/, "", $2); print $2; exit }' \
        "$CRYPTTAB" 2>/dev/null
}

# The raw options field for the mapper, as written in crypttab.
luks_crypttab_options() {
    awk -v m="$MAPPER" '$1 == m { print $4; exit }' "$CRYPTTAB" 2>/dev/null
}

# -----------------------------------------------------------------------------
# boot_posture_verdict — turn the TPM2-vs-prompt question (t8) from a decision
# someone made once in chat into a property that is re-checked every run.
#
#   $1: the crypttab options field for the mapper ('' when there is no entry)
#   $2: whether apt will reboot the machine by itself: true | false | unset
#   $3: the configured Automatic-Reboot-Time, or '-'
#
# Why this exists: with key file 'none' the volume unlocks only if a human types
# at the physical console. Measured on this host, BOTH relevant directives in
# 50unattended-upgrades are commented out — line 94 `//...Automatic-Reboot "false";`
# and line 103 `//...Automatic-Reboot-Time "02:00";` — so apt never reboots the machine
# and the prompt only appears when someone is already at the keyboard. The risk is
# therefore prospective, not current: uncommenting the first while the second sits at
# 02:00 gives a nightly automatic reboot into a passphrase prompt that nobody is there
# to answer. That specific pair is what this gate fails on.
# -----------------------------------------------------------------------------
boot_posture_verdict() {
    local opts="${1:-}" reboot="${2:-unset}"
    # $3 (the configured reboot time) is deliberately not consumed: the verdict must
    # stay a stable token for fixtures, and the caller already holds the time for its
    # message. Call sites may still pass it.
    if [[ -z "$opts" ]]; then printf 'NO_CRYPTTAB_ENTRY\n'; return 0; fi
    # tpm2-device= (any value) or a key-file other than 'none' means boot can unlock
    # without a person present.
    case "$opts" in
        *tpm2-device=auto*|*tpm2-device=/dev*) printf 'UNATTENDED_OK_TPM2\n';   return 0 ;;
    esac
    case ",$opts," in
        *,keyscript=*|*,tpm2-device-key=*) printf 'UNATTENDED_OK_KEYSOURCE\n'; return 0 ;;
    esac
    if [[ "$reboot" == "true" ]]; then
        printf 'PROMPT_WITH_AUTOREBOOT\n'; return 0
    fi
    if [[ "$opts" == *,noauto* || "$opts" == *,nofail* ]]; then
        printf 'MANUAL_OR_OPTIONAL_MOUNT\n'; return 0
    fi
    printf 'PROMPT_REQUIRED_NO_AUTOREBOOT\n'
}

# Reads the apt config; returns true|false|unset.
# Two things this must not get wrong, and the first draft got both wrong:
#   - comments must not count. Ubuntu ships `//Unattended-Upgrade::Automatic-Reboot
#     "false";`, so anchoring on the start of the line makes `//` unmatchable.
#   - the directive name is NOT quoted; only its VALUE is. A pattern demanding a quote
#     straight after "Reboot" matches nothing at all, which is worse than a false
#     positive because every branch then silently reports "unset" and half the fixtures
#     pass for the wrong reason.
# Requiring whitespace-then-quoted-value also keeps the -Time directive out of this
# lookup, since there "Reboot" is followed by "-Time", not by a quoted value.
auto_reboot_setting() {
    local hit
    hit="$(grep -hE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]]+"' \
              "$UU_CONFIG_DIR"/* 2>/dev/null | tail -1)"
    if [[ -z "$hit" ]]; then printf 'unset'; return 0; fi
    if [[ "$hit" == *'"true"'* || "$hit" == *'"1"'* ]]; then printf 'true'; else printf 'false'; fi
}

auto_reboot_time() {
    grep -hE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot-Time[[:space:]]+"' \
        "$UU_CONFIG_DIR"/* 2>/dev/null | tail -1 | grep -oE '"[0-9]{1,2}:[0-9]{2}"' | tr -d '"' || true
}

# =============================================================================
# PREFLIGHT — read-only, safe from the running desktop, answers "are we ready?"
# =============================================================================
preflight() {
    say "=== Phase 2 preflight (read-only; nothing here mutates the host) ==="

    # 1. the free win available before any migration -------------------------
    local size used avail reserved_mib win_mib
    read -r size used avail < <(df -B1 --output=size,used,avail "$HOME_SRC" | tail -1)
    reserved_mib=$(( (size - used - avail) / 1048576 ))
    # 5 % default -> 1 % returns 4 percentage points of the filesystem size.
    win_mib=$(( size * 4 / 100 / 1048576 ))
    say "reserve: $reserved_mib MiB held for root on $HOME_SRC; root never writes there."
    say "         tune2fs -m 1 returns ~${win_mib} MiB immediately, no reboot, reversible."
    # Deliberately no "this buys N days" claim. An earlier version asserted "roughly a
    # day at the observed growth" and the growth figure behind it had been carried from
    # memory: the MiB samples for 2026-11-05 show /home free space moving 8512 -> 8568
    # -> 8563 over the recorded window, i.e. no measurable fill at all. Derive any
    # remaining-time figure from the watchdog's capacity-samples.tsv instead of
    # restating a rate here — see the awk recipe in that script's header.
    say "         This is mitigation, not a fix, and it is not urgent: /home free space"
    say "         is not measurably falling. Measure the trend from"
    say "         ~/.local/share/jol-fleet-health/capacity-samples.tsv, do not restate it."

    # 2. is /home quiet enough to copy? --------------------------------------
    local owner busy gui
    owner="$(stat -c '%U' "$HOME_SRC" 2>/dev/null)"
    [[ -n "$owner" && "$owner" != "root" ]] || owner="$(id -un)"
    busy="$(pgrep -u "$owner" -c . 2>/dev/null || echo 0)"
    gui="$(systemctl is-active graphical.target 2>/dev/null || echo unknown)"
    if (( busy > MAX_BUSY_PROCS )); then
        alert "/home is BUSY: $busy processes owned by $owner (limit $MAX_BUSY_PROCS), graphical.target=$gui."
        # Continuation text is logged with info(), NOT alert(): calling alert()
        # twice for one finding inflates the count, and a summary that says "3
        # findings" when there are 2 teaches the reader to discount the number.
        info "           The cutover must run from rescue.target with the desktop stopped — expected from a session like this one."
    else
        info "/home looks quiet: $busy processes owned by $owner, graphical.target=$gui"
    fi

    # 3. is the target real, off-disk and empty? ------------------------------
    if ! findmnt -rn -o TARGET "$STAGING" >/dev/null 2>&1; then
        alert "$STAGING is not mounted — Phase 1 did not complete, or the volume was not unlocked"
    else
        local sdev rootdev sfs
        sdev="$(stat -c '%d' "$STAGING")"; rootdev="$(stat -c '%d' /)"
        if [[ "$sdev" == "$rootdev" ]]; then
            alert "$STAGING resolves to / — the mount is not real"
        else
            sfs="$(findmnt -no SOURCE,FSTYPE,OPTIONS "$STAGING")"
            info "target mount: $sfs (device id $sdev vs / $rootdev → off-disk)"
            # Empty except lost+found: merging into a populated tree is how a
            # migration ends up with two owners for one path.
            local n
            n="$(find "$STAGING" -mindepth 1 -maxdepth 1 ! -name lost+found 2>/dev/null | wc -l)"
            if (( n == 0 )); then
                info "target is empty apart from lost+found — safe to receive /home"
            else
                alert "target holds $n unexpected top-level entries; refusing to merge into a populated tree"
            fi
        fi
    fi

    # 4. capacity: df on both sides, with the margin applied ------------------
    local payload_kib free_kib need_kib
    payload_kib="$(df -k --output=used "$HOME_SRC" | tail -1 | tr -d ' ')"
    free_kib="$(df -k --output=avail "$STAGING" 2>/dev/null | tail -1 | tr -d ' ')"
    if [[ -n "$free_kib" && "$free_kib" != "-" ]]; then
        need_kib=$(( payload_kib * FREE_MARGIN_PCT / 100 ))
        if (( free_kib >= need_kib )); then
            info "capacity: payload $((payload_kib / 1048576)) GiB, target free $((free_kib / 1048576)) GiB, required ${FREE_MARGIN_PCT}% = $((need_kib / 1048576)) GiB → PASS"
        else
            alert "capacity: target free $((free_kib / 1048576)) GiB is below the ${FREE_MARGIN_PCT}% requirement of $((need_kib / 1048576)) GiB"
        fi
    else
        alert "capacity: could not read free space on $STAGING — UNVERIFIED, not passed"
    fi

    # 5. is the backup behind this copy current? ------------------------------
    if [[ ! -r "$HOME_BACKUP_PROOF" ]]; then
        if [[ ! -r "$(dirname "$HOME_BACKUP_PROOF")" ]]; then
            alert "backup proof at $HOME_BACKUP_PROOF is not readable from uid $(id -u) — UNVERIFIED, not absent"
        else
            alert "no backup proof at $HOME_BACKUP_PROOF — Phase 0 has not run"
        fi
    else
        local pageh
        pageh=$(( ( $(date -u +%s) - $(stat -c '%Y' "$HOME_BACKUP_PROOF") ) / 3600 ))
        if (( pageh > PROOF_MAX_AGE_H )); then
            alert "backup proof is ${pageh} h old (limit ${PROOF_MAX_AGE_H} h) — re-run Phase 0 before the cutover"
        else
            info "backup proof is ${pageh} h old (limit ${PROOF_MAX_AGE_H} h): $(head -c 200 "$HOME_BACKUP_PROOF")"
        fi
    fi

    # 6. is the recovery keyslot VERIFIED, and attested into custody? --------
    # This is the gate that replaces the prose. It is deliberately stricter than
    # "a second keyslot exists": luksDump can say a slot is occupied while the
    # passphrase written down for it does not open the volume, and that is only
    # discoverable at 03:00 when the primary passphrase has already been mistyped.
    local cref cverdict cdir
    cref="$(luks_uuid_reference)"
    cdir="$(dirname "$CUSTODY_ATTESTATION")"
    if [[ ! -r "$CUSTODY_ATTESTATION" ]]; then
        # Branch order matters, and getting it wrong makes the gate assert something
        # it cannot observe. Measured 2026-11-05: /var/lib/jol-workstation is
        # drwx------ root:root, so an unprivileged -e on the artifact is false whether the file
        # exists or not — traverse is denied on the parent. The first version of this
        # gate therefore reported "no custody attestation, the keyslot has never been
        # verified" from a vantage point that could see nothing. Absence, unreadable
        # and no-directory are three different findings and only the third and second
        # are distinguishable; the backup-proof gate above already does this and the
        # wording here is brought into line with it.
        if [[ ! -d "$cdir" ]]; then
            alert "no custody directory $cdir — the recorder has never been run on this host"
        elif [[ ! -r "$cdir" || ! -x "$cdir" ]]; then
            alert "custody attestation cannot be inspected from uid $(id -u): $cdir denies traverse (mode $(stat -c '%a' "$cdir" 2>/dev/null || echo 'unreadable')) — custody is UNVERIFIED, not absent. Re-run with sudo, which the cutover requires anyway."
        elif [[ -e "$CUSTODY_ATTESTATION" ]]; then
            alert "custody attestation exists at $CUSTODY_ATTESTATION but is not readable by uid $(id -u) — UNVERIFIED, not absent"
        else
            alert "no custody attestation at $CUSTODY_ATTESTATION — the recovery keyslot has never been verified to open this volume"
        fi
    elif [[ -z "$cref" ]]; then
        alert "$MAPPER has no UUID= line in /etc/crypttab — nothing to bind the attestation to, so custody is UNVERIFIED"
    else
        cverdict="$(custody_verdict "$cref" "$(date -u +%s)" "$CUSTODY_MAX_AGE_D" < "$CUSTODY_ATTESTATION")"
        if [[ "$cverdict" == "PASS" ]]; then
            # Only the non-sensitive fields are echoed. The artifact is designed
            # to contain none, but a gate should not rely on that holding.
            # Field separator is '=' and the patterns must match it: the artifact
            # is key=value, so a '/^keyslot:/' pattern would never fire and the
            # line would silently report empties as if it had read real values.
            info "custody: PASS — slot $(awk -F= '/^keyslot=/{print $2}' "$CUSTODY_ATTESTATION") of $(awk -F= '/^slots_total=/{print $2}' "$CUSTODY_ATTESTATION") verified against LUKS ${cref:0:8}…, location class $(awk -F= '/^custody_location=/{print $2}' "$CUSTODY_ATTESTATION"), attested $(awk -F= '/^utc=/{print $2}' "$CUSTODY_ATTESTATION")"
        else
            alert "custody attestation REJECTED ($cverdict) — run: sudo jol-record-custody.sh ; the branch table is in custody_verdict above"
        fi
    fi

    # 7. the consequence that must be a decision, not a surprise --------------
    say ""
    say "CONSEQUENCE OF COMPLETING PHASE 2 — decided from the files, not from memory:"
    BOOT_OPTS="$(luks_crypttab_options)"
    UU_REBOOT="$(auto_reboot_setting)"
    UU_TIME="$(auto_reboot_time)"
    BOOT_VERDICT="$(boot_posture_verdict "$BOOT_OPTS" "$UU_REBOOT" "${UU_TIME:--}")"
    say "  crypttab options for $MAPPER: '${BOOT_OPTS:-none}'   apt Automatic-Reboot: $UU_REBOOT${UU_TIME:+ (time would be $UU_TIME)}"
    case "$BOOT_VERDICT" in
        NO_CRYPTTAB_ENTRY)
            alert "$MAPPER is not in $CRYPTTAB — /home would not be available at boot at all" ;;
        UNATTENDED_OK_TPM2)
            info "  boot can unlock unattended via a TPM2 binding — no console prompt" ;;
        UNATTENDED_OK_KEYSOURCE)
            info "  boot can unlock unattended via a key source other than a typed passphrase" ;;
        PROMPT_WITH_AUTOREBOOT)
            # This is the combination that actually costs availability, and it is worth
            # failing on rather than describing in prose: apt reboots the machine with no
            # one there, and the volume cannot open without someone typing.
            alert "boot needs a typed passphrase AND apt is configured to reboot by itself${UU_TIME:+ at $UU_TIME} — an unattended update would leave this machine at a prompt until a person is physically present. Either enrol TPM2 or turn Automatic-Reboot off." ;;
        MANUAL_OR_OPTIONAL_MOUNT)
            info "  entry is noauto/nofail — it will not be mounted at boot without action" ;;
        PROMPT_REQUIRED_NO_AUTOREBOOT)
            info "  EVERY BOOT PROMPTS for the passphrase on the console, but nothing reboots"
            info "  this machine by itself (Automatic-Reboot is $UU_REBOOT), so the prompt only"
            info "  occurs when someone is already at the keyboard. TPM2 enrolment was declined"
            info "  on 2026-11-05; this is that decision, re-checked each run rather than assumed."
            info "  When it is taken up: systemd-cryptenroll, NOT cryptsetup — measured here,"
            info "  cryptsetup advertises no TPM support while systemd-cryptenroll does."
            case "$UU_TIME" in
                '') : ;;
                *) info "  TRIPWIRE: Automatic-Reboot-Time $UU_TIME is ACTIVE while the flag is off,"
                   info "  so nothing reboots today. Enabling Automatic-Reboot without revisiting this"
                   info "  turns a nightly $UU_TIME update into downtime until a person arrives."
                   info "  This gate fails on that pair." ;;
            esac ;;
    esac
    say "  Recovery: the custody gate above is what enforces this now, not this text."
    say "  It verifies the recovery keyslot OPENS the volume and binds that fact to the"
    say "  LUKS header UUID in /etc/crypttab. After the cutover a lost passphrase means a"
    say "  lost /home, not a lost volume — which is why the gate is fatal, not advisory."

    say ""
    if (( FAILURES == 0 )); then
        say "=== PREFLIGHT CLEAN — the cutover window can be booked ==="
    else
        say "=== PREFLIGHT: $FAILURES finding(s). Items marked BUSY are expected from a desktop ==="
        say "    session and clear themselves in rescue.target; the others must be fixed first. ==="
    fi
    return 0
}

[[ "$MODE" == "preflight" ]] && { preflight; exit 0; }

# =============================================================================
# CUTOVER — requires root, a quiet /home, and a current backup
# =============================================================================
[[ "$(id -u)" == "0" ]] || die "needs root. Re-run with sudo, or use --preflight (read-only, no root)."

say "=== Phase 2 cutover (DRY_RUN=$DRY_RUN) ==="

# --- guard: /home must be quiet. This is the guard that makes the difference
# between a consistent copy and a corrupt one, and it is the reason the runbook
# says rescue.target rather than "close your applications".
OWNER="$(stat -c '%U' "$HOME_SRC" 2>/dev/null || echo root)"
BUSY="$(pgrep -u "$OWNER" -c . 2>/dev/null || echo 0)"
GUI="$(systemctl is-active graphical.target 2>/dev/null || echo unknown)"
if (( BUSY > MAX_BUSY_PROCS )) || [[ "$GUI" == "active" ]]; then
    die "/home is not quiet: $BUSY processes owned by $OWNER, graphical.target=$GUI.
       Run:  sudo systemctl isolate rescue.target
       then re-run this script from the rescue shell. Copying a live /home produces
       an inconsistent tree, and swapping fstab underneath a running desktop is how
       a migration turns into a machine that will not log anyone in."
fi

# --- guard: the target must be the real encrypted volume, off-disk, and empty
findmnt -rn -o TARGET "$STAGING" >/dev/null 2>&1 || die "$STAGING is not mounted — run Phase 1 first"
SDEV="$(stat -c '%d' "$STAGING")"; ROOTDEV="$(stat -c '%d' /)"
[[ "$SDEV" != "$ROOTDEV" ]] || die "$STAGING resolves to / ($ROOTDEV) — the mount is not real"
SSRC="$(findmnt -no SOURCE "$STAGING")"
[[ "$SSRC" == "/dev/mapper/$MAPPER" ]] || die "$STAGING is backed by $SSRC, expected /dev/mapper/$MAPPER"
NEXTRA="$(find "$STAGING" -mindepth 1 -maxdepth 1 ! -name lost+found 2>/dev/null | wc -l)"
(( NEXTRA == 0 )) || die "$STAGING holds $NEXTRA unexpected entries — refusing to merge into a populated tree"

# --- guard: the backup behind this copy must be current
[[ -r "$HOME_BACKUP_PROOF" ]] || die "no readable backup proof at $HOME_BACKUP_PROOF — run Phase 0 first"
AGE_H=$(( ( $(date -u +%s) - $(stat -c '%Y' "$HOME_BACKUP_PROOF") ) / 3600 ))
(( AGE_H <= PROOF_MAX_AGE_H )) || die "backup proof is ${AGE_H} h old (limit ${PROOF_MAX_AGE_H} h) — re-run Phase 0"
say "gate: backup proof ${AGE_H} h old, within the ${PROOF_MAX_AGE_H} h limit"

# --- guard: the recovery keyslot must be VERIFIED and attested into custody.
# Fatal, and fatal before anything is copied. The cutover makes the encrypted
# volume the only way to read /home; an unverified recovery secret means one
# mistyped passphrase is a total, irreversible loss of the operator's home tree.
CREF="$(luks_uuid_reference)"
[[ -r "$CUSTODY_ATTESTATION" ]] || die "no readable custody attestation at $CUSTODY_ATTESTATION.
   Run first:  sudo jol-record-custody.sh
   It makes cryptsetup verify on your own terminal that the recovery keyslot opens
   this volume (the script never sees the passphrase), then records the attestation
   that this gate reads. Nothing was copied and fstab was not touched."
[[ -n "$CREF" ]] || die "$MAPPER has no UUID= line in /etc/crypttab — cannot bind the attestation to this volume"
CVERDICT="$(custody_verdict "$CREF" "$(date -u +%s)" "$CUSTODY_MAX_AGE_D" < "$CUSTODY_ATTESTATION")"
[[ "$CVERDICT" == "PASS" ]] || die "custody attestation rejected: $CVERDICT — re-run sudo jol-record-custody.sh (branch table in custody_verdict)"
say "gate: custody attestation PASS — recovery keyslot verified against LUKS UUID ${CREF:0:8}…"

# --- guard: the boot posture must not be a trap after the swap ----------------
# Before Phase 2 an unopenable volume costs an empty disk. After it, the same
# event means no /home, so no SSH key, no repos and no user login. A machine that
# reboots itself with nobody there cannot answer a console passphrase prompt, so
# that pair is refused here rather than left as a line of advice in a preflight.
BOOT_OPTS="$(luks_crypttab_options)"
UU_REBOOT="$(auto_reboot_setting)"
UU_TIME="$(auto_reboot_time)"
BOOT_VERDICT="$(boot_posture_verdict "$BOOT_OPTS" "$UU_REBOOT" "${UU_TIME:--}")"
if [[ "$BOOT_VERDICT" == "PROMPT_WITH_AUTOREBOOT" && "${ALLOW_UNATTENDED_REBOOT:-0}" != "1" ]]; then
    die "boot needs a typed passphrase for $MAPPER AND apt is set to reboot unattended${UU_TIME:+ at $UU_TIME}.
   After this cutover that means an unattended update leaves the machine unable to mount
   /home until someone is physically at the console. Choose one, then re-run:
     a) enrol a TPM2 key with systemd-cryptenroll (cryptsetup has no TPM support here), or
     b) set Unattended-Upgrade::Automatic-Reboot to 'false' in $UU_CONFIG_DIR.
   Deliberately overriding this once: ALLOW_UNATTENDED_REBOOT=1 (record it in the ledger)."
fi
say "gate: boot posture $BOOT_VERDICT (crypttab options '${BOOT_OPTS:-none}', apt Automatic-Reboot $UU_REBOOT)"

# --- guard: capacity, from df
PAYLOAD_KIB="$(df -k --output=used "$HOME_SRC" | tail -1 | tr -d ' ')"
FREE_KIB="$(df -k --output=avail "$STAGING" | tail -1 | tr -d ' ')"
NEED_KIB=$(( PAYLOAD_KIB * FREE_MARGIN_PCT / 100 ))
(( FREE_KIB >= NEED_KIB )) || die "target free ${FREE_KIB} KiB is below the ${FREE_MARGIN_PCT}% requirement of ${NEED_KIB} KiB"
say "gate: payload $((PAYLOAD_KIB / 1048576)) GiB, target free $((FREE_KIB / 1048576)) GiB, margin ${FREE_MARGIN_PCT}%"

# --- resolve the two UUIDs from the LIVE fstab. Never a placeholder, never a
# device path. Refusing on ambiguity is better than guessing: this is the edit
# that decides what the machine mounts as /home at the next boot.
OLD_HOME_LINE="$(awk -v m="$HOME_SRC" '$2 == m && $1 ~ /^UUID=/ {print; c++} END{if (c+0 != 1) exit 1}' "$FSTAB")" \
    || die "expected exactly one UUID= line mounting $HOME_SRC in $FSTAB — refusing to guess which"
OLD_HOME_UUID="${OLD_HOME_LINE%% *}"
STAGING_LINE="$(awk -v u="$OLD_HOME_UUID" -v m="$STAGING" '$2 == m && $1 ~ /^UUID=/ {print; c++} END{if (c+0 != 1) exit 1}' "$FSTAB")" \
    || die "expected exactly one UUID= line mounting $STAGING in $FSTAB"
NEW_HOME_UUID="${STAGING_LINE%% *}"
[[ "$OLD_HOME_UUID" != "$NEW_HOME_UUID" ]] || die "both fstab lines reference $OLD_HOME_UUID — that is one filesystem declared twice"
# And the UUID we are about to make /home must be the one the mapper really has.
LIVE_UUID="$(blkid -s UUID -o value "$SSRC" 2>/dev/null)"
[[ "$LIVE_UUID" == "${NEW_HOME_UUID#UUID=}" ]] \
    || die "fstab says $NEW_HOME_UUID but $SSRC reports UUID=$LIVE_UUID — refusing to write a boot entry that will not match"
say "identity: /home is ${OLD_HOME_UUID} → becomes ${NEW_HOME_UUID} (confirmed against $SSRC)"

# --- 1. copy with full attribute fidelity
# --numeric-ids because names may not resolve identically in rescue.target.
# -H hardlinks, -A ACLs, -X xattrs, -S sparse. No --delete: the target is empty
# and --delete against a wrong target path is an unnecessary hazard.
say "=== step 1: copy $HOME_SRC → $STAGING ==="
run rsync -aHAXS --numeric-ids --info=stats2 "$HOME_SRC/" "$STAGING/" || die "rsync failed"

# --- 2. verify BEFORE swapping. Four independent checks, because the rsync exit
# code is not the gate — it is the thing the gate exists to check.
say "=== step 2: verify (the gate, not the rsync exit code) ==="
DIFF_OUT="$(rsync -aHAXn --numeric-ids --out-format='%n' "$HOME_SRC/" "$STAGING/" 2>/dev/null)"
DIFF_N="$(printf '%s' "$DIFF_OUT" | grep -c . || true)"
if (( DIFF_N == 0 )); then
    say "verify 1/4: dry-run rsync reports zero differing entries — PASS"
else
    die "verify 1/4 FAILED: $DIFF_N entries differ, e.g. $(printf '%s\n' "$DIFF_OUT" | head -3 | tr '\n' ' ')"
fi

SRC_N="$(find "$HOME_SRC" -xdev 2>/dev/null | wc -l)"
DST_N="$(find "$STAGING" -xdev 2>/dev/null | wc -l)"
if (( SRC_N > 0 )) && (( DST_N >= SRC_N )); then
    say "verify 2/4: entry counts src=$SRC_N dst=$DST_N (dst >= src, lost+found accounts for the difference) — PASS"
else
    die "verify 2/4 FAILED: src=$SRC_N dst=$DST_N — a zero or short count means the copy did not happen"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
find "$HOME_SRC"     -xdev -maxdepth 2 -printf '%m %u:%g %P\n' 2>/dev/null | sort > "/tmp/perm-old.$TS"
find "$STAGING" -xdev -maxdepth 2 -printf '%m %u:%g %P\n' 2>/dev/null | sort > "/tmp/perm-new.$TS"
if diff -q "/tmp/perm-old.$TS" "/tmp/perm-new.$TS" >/dev/null; then
    say "verify 3/4: mode and owner:group identical for the top two levels — PASS"
else
    die "verify 3/4 FAILED: permissions or ownership differ; $(diff "/tmp/perm-old.$TS" "/tmp/perm-new.$TS" | head -5 | tr '\n' ' ')"
fi

# Secret material is compared by exit status only. Its contents are never
# printed, never listed, never hashed into a log — Tier-1 rule.
if [[ -d "$HOME_SRC/jol/secrets" ]]; then
    if diff -rq "$HOME_SRC/jol/secrets" "$STAGING/jol/secrets" >/dev/null 2>&1; then
        say "verify 4/4: secret tree byte-identical (contents not displayed) — PASS"
    else
        die "verify 4/4 FAILED: the secret tree does not match. Do NOT swap fstab."
    fi
else
    say "verify 4/4: no $HOME_SRC/jol/secrets to compare — skipped, not passed"
fi

# --- 3. swap fstab. One line commented, one line repurposed, nothing added.
say "=== step 3: fstab swap ==="
run cp -p "$FSTAB" "${FSTAB}.bak.${TS}" || die "could not back up $FSTAB"
NEW_FSTAB="$(rewrite_fstab "${OLD_HOME_UUID#UUID=}" "${NEW_HOME_UUID#UUID=}" < "$FSTAB")"
[[ -n "$NEW_FSTAB" ]] || die "rewrite_fstab produced empty output — refusing to write it"
# Post-condition on the rewrite itself, independent of the diff: exactly one line
# must mount /home, it must carry the new UUID, and it must NOT carry nofail.
HOME_LINES="$(printf '%s\n' "$NEW_FSTAB" | awk -v m="$HOME_SRC" '$2 == m && $1 ~ /^UUID=/ {c++} END{print c+0}')"
[[ "$HOME_LINES" == "1" ]] || die "the rewritten fstab has $HOME_LINES UUID lines mounting $HOME_SRC, expected exactly 1"
printf '%s\n' "$NEW_FSTAB" | awk -v m="$HOME_SRC" '$2 == m && $1 ~ /^UUID=/' | grep -q 'nofail' \
    && die "the new /home line carries nofail — that is the option that silently lost four nights of state backups"
printf '%s\n' "$NEW_FSTAB" | awk -v m="$HOME_SRC" '$2 == m && $1 ~ /^UUID=/' | grep -q "${NEW_HOME_UUID#UUID=}" \
    || die "the new /home line does not reference ${NEW_HOME_UUID}"
if [[ "$DRY_RUN" == "1" ]]; then
    say "PLAN : the /home line would become:"
    printf '%s\n' "$NEW_FSTAB" | awk -v m="$HOME_SRC" '$2 == m && $1 ~ /^UUID=/ {print "         " $0}'
else
    printf '%s\n' "$NEW_FSTAB" > "$FSTAB" || die "could not write $FSTAB"
    say "fstab written; backup at ${FSTAB}.bak.${TS}"
fi
run systemctl daemon-reload || true

# --- 4. reboot, do NOT mount -a
say ""
say "=== step 4: REBOOT — deliberately not 'mount -a' ==="
say "The old /home is still mounted from its original partition and the new fstab now"
say "points /home elsewhere. 'mount -a' would stack the new filesystem over the live"
say "one while $BUSY processes hold it open. A reboot resolves both cleanly, and it is"
say "also where the LUKS passphrase prompt appears on the console."
if [[ "$DRY_RUN" != "1" ]]; then
    say "When ready:  sudo reboot"
    say "At the prompt, type the LUKS passphrase for $MAPPER."
fi

say ""
say "=== post-reboot verification (run these, do not assume) ==="
say "  findmnt -no SOURCE,FSTYPE,OPTIONS /home     # must be /dev/mapper/$MAPPER, ext4, noatime"
say "  df -h /home                                  # ~900 GiB, not 92 GiB"
say "  ssh -T git@github.com                        # the SSH key survived and authenticates"
say "  git -C /opt/jol/repos/jol-infrastructure status"
say "  start the IDE, then this agent"
say "  ~/.local/bin/jol-workstation-capacity-check.sh   # gate 1 must list /home on the mapper"
say ""
say "ROLLBACK (the old /home was never modified — it is the rollback):"
say "  sudo cp -p ${FSTAB}.bak.${TS} ${FSTAB} && sudo systemctl daemon-reload && sudo reboot"
say "Do NOT delete the old partition's contents for at least a week of normal work."
say ""
if (( FAILURES == 0 )); then
    say "=== CUTOVER PREPARED (DRY_RUN=$DRY_RUN) ==="
else
    say "=== CUTOVER PREPARED with $FAILURES alert(s) (DRY_RUN=$DRY_RUN) ==="
fi
exit 0
