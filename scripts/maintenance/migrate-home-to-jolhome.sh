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
    say "         This is mitigation, not a fix — it buys roughly a day at the observed growth."

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

    # 6. the consequence that must be a decision, not a surprise --------------
    say ""
    say "CONSEQUENCE OF COMPLETING PHASE 2 — decide before the window, not during it:"
    if grep -qE "^\s*${MAPPER}\b" /etc/crypttab 2>/dev/null; then
        if grep -qE "^\s*${MAPPER}\b.*\btpm2\b" /etc/crypttab 2>/dev/null; then
            say "  crypttab has a TPM2 binding for $MAPPER — boot may unlock unattended."
        else
            say "  crypttab unlocks $MAPPER with 'none' as the key file, so EVERY BOOT PROMPTS"
            say "  for the passphrase on the console. An unattended reboot after a kernel update"
            say "  will sit at that prompt until someone types. TPM2 enrolment was declined on"
            say "  2026-11-05 ('maybe later'); this is the cost of that decision becoming real."
        fi
    else
        alert "$MAPPER is not in /etc/crypttab — /home would not be available at boot at all"
    fi
    say "  Recovery: the keyslot added in Phase 1 step 3 must already be in custody per"
    say "  docs/compliance/sops-age-key-custody-plan.md. If it is not, do that first —"
    say "  after the cutover a lost passphrase means a lost /home, not a lost volume."

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
