#!/usr/bin/env bash
# =============================================================================
# test-home-migration.sh — fixtures for the Phase 2 fstab rewrite.
#
# Scope: `rewrite_fstab` is the single edit in Phase 2 that decides what the
# machine mounts as /home at the next boot, so it is the part that gets a test
# rather than a review. The rsync, the verification gates and the reboot are
# exercised by the operator against the real host; a fixture cannot simulate a
# 78 GiB copy or a rescue target.
#
# Convention (per scripts/maintenance/tests/): the function is EXTRACTED from the
# script under test with awk and sourced, never copied, so a fixture cannot drift
# from the implementation. The extraction range is bounded by the next section
# marker — an unbounded range silently swallowed a gate once already in this repo.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/../migrate-home-to-jolhome.sh"

PASS=0; FAILED=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi
}

[[ -r "$TARGET" ]] || { echo "cannot read $TARGET"; exit 2; }

# --- extract rewrite_fstab verbatim from the script under test ---------------
FUNC="$(awk '/^rewrite_fstab\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$FUNC" ]] || ! grep -q 'awk -v oldu' <<<"$FUNC"; then
    echo "extraction failed: rewrite_fstab not found between its markers in $TARGET"; exit 2
fi
# STAGING is referenced by the function; the fixtures set it explicitly so a
# change to the script's default cannot silently change what is being tested.
eval "$FUNC"

OLD_UUID="11111111-1111-1111-1111-111111111111"
NEW_UUID="22222222-2222-2222-2222-222222222222"

# A synthetic fstab that reproduces the real one's shape: a /home line by UUID,
# a staging line by UUID created by Phase 1, and noise around both.
mk_fstab() {
    cat <<EOF
# /etc/fstab — synthetic fixture
UUID=aaaaaaaa-0000-0000-0000-000000000003 /               ext4 errors=remount-ro 0 1
UUID=$OLD_UUID /home          ext4 defaults,relatime 0 2
UUID=aaaaaaaa-0000-0000-0000-000000000004 /opt/jol       ext4 defaults 0 2
UUID=$NEW_UUID /mnt/jolhome-staging ext4 defaults,noatime,errors=remount-ro 0 2
EOF
}

echo "=== fixture group 1: the swap itself ==="
STAGING="/mnt/jolhome-staging"
OUT="$(mk_fstab | rewrite_fstab "$OLD_UUID" "$NEW_UUID")"

check "exactly one uncommented line mounts /home" "1" \
    "$(printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {c++} END{print c+0}')"
check "that line carries the NEW uuid" "UUID=$NEW_UUID" \
    "$(printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $1}')"
check "the old /home line is commented, not deleted" "1" \
    "$(printf '%s\n' "$OUT" | grep -c "^# UUID=$OLD_UUID /home")"
check "a rollback marker is present above it" "1" \
    "$(printf '%s\n' "$OUT" | grep -c 'PHASE2-CUTOVER: previous /home retained as rollback')"
check "no line still mounts the staging path" "0" \
    "$(printf '%s\n' "$OUT" | awk -v s="$STAGING" '$2==s && $1 ~ /^UUID=/ {c++} END{print c+0}')"
check "active mount lines go 4 -> 3 (the old /home is retired, not duplicated)" "3" \
    "$(printf '%s\n' "$OUT" | grep -vcE '^\s*(#|$)')"

echo "=== fixture group 2: options are preserved verbatim ==="
# The rewrite must not invent, drop or normalise mount options. noatime was a
# deliberate Phase 1 decision and errors=remount-ro is the fsck behaviour.
check "noatime survived" "1" \
    "$(printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $4}' | grep -c noatime)"
check "errors=remount-ro survived" "1" \
    "$(printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $4}' | grep -c 'errors=remount-ro')"
check "fsck pass field survived as 2" "2" \
    "$(printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $6}')"
check "the old /home's relatime was NOT carried over" "0" \
    "$(printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $4}' | grep -c relatime)"

echo "=== fixture group 3: idempotency ==="
# A second run must not produce a second /home line or re-comment anything.
OUT2="$(printf '%s\n' "$OUT" | rewrite_fstab "$OLD_UUID" "$NEW_UUID")"
check "re-running yields exactly one /home line" "1" \
    "$(printf '%s\n' "$OUT2" | awk '$2=="/home" && $1 ~ /^UUID=/ {c++} END{print c+0}')"
check "re-running is byte-identical (true idempotence)" "$OUT" "$OUT2"
check "re-running did not add a second rollback marker" "1" \
    "$(printf '%s\n' "$OUT2" | grep -c 'PHASE2-CUTOVER')"

echo "=== fixture group 4: the staging path in a comment must not be rewritten ==="
# This is why the function rebuilds fields explicitly instead of substituting in
# $0: a path appearing in a comment or an option string must never be touched.
COMMENT_FSTAB="$(cat <<EOF
UUID=$OLD_UUID /home ext4 defaults 0 2
# TODO: /mnt/jolhome-staging is the Phase 1 staging mount
UUID=$NEW_UUID /mnt/jolhome-staging ext4 defaults,noatime 0 2
EOF
)"
COUT="$(printf '%s\n' "$COMMENT_FSTAB" | rewrite_fstab "$OLD_UUID" "$NEW_UUID")"
check "the comment line is untouched" "1" \
    "$(printf '%s\n' "$COUT" | grep -c '^# TODO: /mnt/jolhome-staging is the Phase 1 staging mount$')"
check "the real staging line was still repurposed" "1" \
    "$(printf '%s\n' "$COUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $1}' | grep -c "$NEW_UUID")"

echo "=== fixture group 5: unrelated lines are never modified ==="
check "the / line is unchanged" "1" \
    "$(printf '%s\n' "$OUT" | grep -c 'UUID=aaaaaaaa-0000-0000-0000-000000000003 / *ext4 errors=remount-ro 0 1')"
check "the /opt/jol line is unchanged" "1" \
    "$(printf '%s\n' "$OUT" | grep -c 'UUID=aaaaaaaa-0000-0000-0000-000000000004 /opt/jol *ext4 defaults 0 2')"
check "the header comment is unchanged" "1" \
    "$(printf '%s\n' "$OUT" | grep -c '^# /etc/fstab — synthetic fixture$')"

echo "=== fixture group 6: a wrong UUID must not match anything ==="
# Guards against the placeholder defect in the runbook's original §4.4: a UUID
# that matches nothing must leave the fstab unchanged rather than half-edit it.
WOUT="$(mk_fstab | rewrite_fstab "does-not-exist" "$NEW_UUID")"
# TWO lines mounting /home is the correct output of a deliberately dumb function
# given a UUID that matches nothing: the original stays active because it was
# never matched, and the staging line was still repurposed. The safety property
# lives in the CALLER's post-condition (group 7), not in the rewrite. Asserting 1
# here would have encoded a false expectation and hidden the guard's real job.
check "an unmatched old UUID leaves TWO /home lines — the caller must abort on this" "2" \
    "$(printf '%s\n' "$WOUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {c++} END{print c+0}')"
check "an unmatched old UUID still repurposes staging (caller must pre-check)" "1" \
    "$(printf '%s\n' "$WOUT" | awk '$2=="/home" && $1 ~ /^UUID=/ {print $1}' | grep -c "$NEW_UUID")"
WOUT2="$(mk_fstab | rewrite_fstab "$OLD_UUID" "does-not-exist")"
check "an unmatched new UUID leaves /home commented AND unmounted — caller's guard must catch this" "0" \
    "$(printf '%s\n' "$WOUT2" | awk '$2=="/home" && $1 ~ /^UUID=/ {c++} END{print c+0}')"
check "…and the staging line is still present, so the fstab is recoverable" "1" \
    "$(printf '%s\n' "$WOUT2" | awk -v s="$STAGING" '$2==s && $1 ~ /^UUID=/ {c++} END{print c+0}')"

echo "=== fixture group 7: the caller's post-condition is what catches group 6 ==="
# rewrite_fstab is deliberately dumb. The script asserts on its OUTPUT — exactly
# one UUID line mounting /home — which is the check that turns fixture group 6's
# second case from a bricked boot into an abort. Reproduce that assertion here.
assert_one_home_line() {
    printf '%s\n' "$1" | awk -v m="/home" '$2 == m && $1 ~ /^UUID=/ {c++} END{exit (c+0 == 1 ? 0 : 1)}'
}
if assert_one_home_line "$OUT";  then ok  "post-condition accepts a correct rewrite"; else bad "post-condition rejected a correct rewrite"; fi
if assert_one_home_line "$WOUT2"; then bad "post-condition ACCEPTED a rewrite with no /home — the guard is dead"; else ok "post-condition rejects a rewrite that leaves no /home mounted"; fi
# The two-line case from group 6 is the one that would actually brick a boot:
# two filesystems declared at /home means the second silently shadows the first.
if assert_one_home_line "$WOUT"; then bad "post-condition ACCEPTED two /home lines — the guard is dead"; else ok "post-condition rejects a rewrite that leaves TWO /home lines"; fi
if printf '%s\n' "$OUT" | awk '$2=="/home" && $1 ~ /^UUID=/' | grep -q nofail; then
    bad "the rewritten /home line carries nofail"
else
    ok "the rewritten /home line does not carry nofail"
fi

echo "=== fixture group 8: custody_verdict — extraction is proven, not assumed ==="
# Same rule as rewrite_fstab: extract from the script under test, and ABORT if the
# extraction came back empty. A fixture group that silently extracts nothing is
# how gate 6's fixtures passed while testing nothing.
CFUNC="$(awk '/^custody_verdict\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$CFUNC" ]] || ! grep -q 'SECRET_RECORDED' <<<"$CFUNC"; then
    echo "extraction failed: custody_verdict not found between its markers in $TARGET"; exit 2
fi
eval "$CFUNC"

REF_UUID="4fc2ae29-3dd3-43c7-b43b-325ba9ed2690"
# A fixed "now" keeps the age branches deterministic rather than clock-dependent.
NOW="$(date -u -d '2026-11-05T16:00:00Z' +%s)"
FRESH_UTC="2026-11-05T15:00:00Z"

# Builds a complete, valid artifact; each fixture mutates exactly one field so a
# red fixture names the branch that broke instead of the whole gate.
att() { # att <utc> <luks_uuid> <slots> <verify> <location> <secret_recorded>
    printf 'schema=1\nutc=%s\nhost=ubuntu\nmapper=jolhome_crypt\nluks_uuid=%s\nkeyslot=1\nslots_total=%s\nverify=%s\nverify_cmd=cryptsetup luksOpen --test-passphrase\ncustody_location=%s\nattested_by=jol\nsecret_recorded=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6"
}
check "a complete fresh attestation PASSES" "PASS" \
    "$(att "$FRESH_UTC" "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "an empty artifact is EMPTY, not a silent pass" "EMPTY" \
    "$(printf '' | custody_verdict "$REF_UUID" "$NOW" 90)"

echo "=== fixture group 9: every rejection branch fires, one field at a time ==="
check "the keyslot was never verified -> NO_VERIFY_PASS" "NO_VERIFY_PASS" \
    "$(att "$FRESH_UTC" "$REF_UUID" 2 FAIL vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "an unverified artifact that also leaks a secret is caught as the leak first" "SECRET_RECORDED" \
    "$(att "$FRESH_UTC" "$REF_UUID" 2 FAIL vaultwarden:sops-custody yes | custody_verdict "$REF_UUID" "$NOW" 90)"
check "secret_recorded=yes alone -> SECRET_RECORDED" "SECRET_RECORDED" \
    "$(att "$FRESH_UTC" "$REF_UUID" 2 PASS vaultwarden:sops-custody yes | custody_verdict "$REF_UUID" "$NOW" 90)"
check "a missing secret_recorded field fails closed, not permissively" "SECRET_RECORDED" \
    "$(printf 'utc=%s\nluks_uuid=%s\nslots_total=2\nverify=PASS\ncustody_location=x\n' "$FRESH_UTC" "$REF_UUID" | custody_verdict "$REF_UUID" "$NOW" 90)"
check "attestation for a DIFFERENT volume -> UUID_MISMATCH" "UUID_MISMATCH" \
    "$(att "$FRESH_UTC" "deadbeef-0000-0000-0000-000000000000" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "no crypttab reference UUID -> NO_REFERENCE_UUID (cannot skip)" "NO_REFERENCE_UUID" \
    "$(att "$FRESH_UTC" "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "" "$NOW" 90)"
check "one keyslot means no recovery path -> SINGLE_SLOT" "SINGLE_SLOT" \
    "$(att "$FRESH_UTC" "$REF_UUID" 1 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "a non-numeric slot count is refused, not read as zero" "BAD_SLOTS" \
    "$(att "$FRESH_UTC" "$REF_UUID" two PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "empty custody location -> NO_LOCATION" "NO_LOCATION" \
    "$(att "$FRESH_UTC" "$REF_UUID" 2 PASS '' no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "a tz-hybrid stamp (no Z) -> BAD_STAMP" "BAD_STAMP" \
    "$(att '2026-11-05 15:00' "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "an attestation dated in the future -> FUTURE_STAMP" "FUTURE_STAMP" \
    "$(att '2026-12-01T00:00:00Z' "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"

echo "=== fixture group 10: the age limit actually discriminates at the boundary ==="
# 89 days passes, 91 days fails, against a 90-day limit. Without both sides this is
# another vacuous gate: a limit that can never fire looks identical to a working one.
check "89 days old is still within a 90-day limit" "PASS" \
    "$(att '2026-08-08T16:00:00Z' "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "91 days old is STALE" "STALE" \
    "$(att '2026-08-06T16:00:00Z' "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 90)"
check "the limit is honoured when tightened to 1 day" "STALE" \
    "$(att '2026-11-03T16:00:00Z' "$REF_UUID" 2 PASS vaultwarden:sops-custody no | custody_verdict "$REF_UUID" "$NOW" 1)"

echo "=== fixture group 11: cross-file contract — the recorder writes what the gate parses ==="
# The dangerous direction: the gate reads a field the recorder stopped writing.
# That does not error, it silently degrades to a rejection branch forever, or worse
# to an empty value that a laxer branch accepts. Assert the subset relationship.
REC="$HERE/../record-jolhome-custody.sh"
if [[ ! -r "$REC" ]]; then
    bad "recorder $REC is missing — the custody contract cannot be checked"
else
    # Fields the gate reads, derived from its OWN case labels rather than
    # hardcoded here. Renaming a field in the gate then changes the expectation
    # instead of quietly keeping the fixture green — the same trap that let a
    # placeholder sed pattern pass as a working rewrite.
    PARSED="$(printf '%s\n' "$CFUNC" | awk '/^[ \t]*[a-z_]+\)[ \t]+v_/{ sub(/^[ \t]*/,""); sub(/\).*/,""); print }' | sort -u | tr '\n' ' ')"
    WRITTEN="$(grep -oE "printf '[a-z_]+=" "$REC" | sed "s/printf '//; s/=//" | sort -u | tr '\n' ' ')"
    check "the gate parses exactly the six intended fields" \
        "custody_location luks_uuid secret_recorded slots_total utc verify " "$PARSED"
    check "the gate parses no accidental seventh field" "6" "$(printf '%s' "$PARSED" | wc -w)"
    check "the recorder writes at least as many fields as the gate parses" "1" \
        "$(( $(printf '%s' "$WRITTEN" | wc -w) >= $(printf '%s' "$PARSED" | wc -w) ))"
    MISSING=''
    for f in $PARSED; do
        case " $WRITTEN " in
            *" $f "*) : ;;
            *) MISSING="$MISSING $f" ;;
        esac
    done
    check "every parsed field is written by the recorder (empty means all present)" "" "$MISSING"
fi

echo "=== fixture group 12: boot posture (t8) — a decision turned into a property ==="
BV="$(awk '/^boot_posture_verdict\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$BV" ]] || ! grep -q 'PROMPT_WITH_AUTOREBOOT' <<<"$BV"; then
    echo "extraction failed: boot_posture_verdict not found in $TARGET"; exit 2
fi
eval "$BV"
check "no crypttab entry is its own verdict, not 'prompt'" "NO_CRYPTTAB_ENTRY" \
    "$(boot_posture_verdict '' unset -)"
check "key=none with no unattended reboot -> prompt required, tolerated" "PROMPT_REQUIRED_NO_AUTOREBOOT" \
    "$(boot_posture_verdict 'luks' false -)"
check "key=none with unset reboot is still the tolerated case" "PROMPT_REQUIRED_NO_AUTOREBOOT" \
    "$(boot_posture_verdict 'luks' unset -)"
check "key=none AND apt rebooting itself -> the failing pair" "PROMPT_WITH_AUTOREBOOT" \
    "$(boot_posture_verdict 'luks' true 02:00)"
# Order matters: a TPM2 binding removes the prompt, so it must be decided BEFORE the
# reboot flag. Reversing these two branches would report a safely-unattended volume as
# a failure, i.e. a false alarm on the one configuration that is actually fine.
check "a TPM2 binding outranks the reboot flag" "UNATTENDED_OK_TPM2" \
    "$(boot_posture_verdict 'luks,tpm2-device=auto' true 02:00)"
check "an explicit tpm2 device path is also unattended-capable" "UNATTENDED_OK_TPM2" \
    "$(boot_posture_verdict 'luks,tpm2-device=/dev/tpmrm0' true -)"
check "a keyscript means no human is needed at boot" "UNATTENDED_OK_KEYSOURCE" \
    "$(boot_posture_verdict 'luks,keyscript=/usr/sbin/foo' true -)"
check "noauto is reported as a manual mount, not a prompt" "MANUAL_OR_OPTIONAL_MOUNT" \
    "$(boot_posture_verdict 'luks,noauto' false -)"
check "bare 'keyscript' text is not mistaken for an option token" "PROMPT_REQUIRED_NO_AUTOREBOOT" \
    "$(boot_posture_verdict 'luks' false -)"

echo "=== fixture group 13: reading apt config — comments must not count as settings ==="
ARS="$(awk '/^auto_reboot_setting\(\) \{/,/^\}/' "$TARGET")"
ART="$(awk '/^auto_reboot_time\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$ARS" ]] || [[ -z "$ART" ]]; then
    echo "extraction failed: auto_reboot_setting/time not found in $TARGET"; exit 2
fi
eval "$ARS"; eval "$ART"
CFG="$(mktemp -d)"; trap 'rm -rf "$CFG"' EXIT
aptcfg() { rm -rf "$CFG"; mkdir -p "$CFG"; printf '%s\n' "$1" > "$CFG/50unattended-upgrades"; }
# Bound for the sourced function, its only consumer; across the `.` the linter cannot
# see the use, so it reads as unused.
# shellcheck disable=SC2034
UU_CONFIG_DIR="$CFG"

# POSITIVE CONTROL FIRST. The first version of auto_reboot_setting had a regex that
# matched nothing, so EVERY case returned "unset" and most assertions passed as a side
# effect of the probe being dead. A negative is only worth anything after the same
# probe has been shown able to say yes.
aptcfg 'Unattended-Upgrade::Automatic-Reboot "true";'
check "PROBE ALIVE: a plainly-enabled directive reads as true" "true" "$(auto_reboot_setting)"

aptcfg '// Unattended-Upgrade::Automatic-Reboot "true";'
check "a COMMENTED-OUT 'true' must read as unset, not true" "unset" "$(auto_reboot_setting)"
aptcfg 'Unattended-Upgrade::Automatic-Reboot "true";'
check "an uncommented true is detected" "true" "$(auto_reboot_setting)"
aptcfg 'Unattended-Upgrade::Automatic-Reboot "false";'
check "an uncommented false is detected as false" "false" "$(auto_reboot_setting)"
aptcfg '//Unattended-Upgrade::Automatic-Reboot-Time "02:00";'
check "the -Time directive must never match the setting lookup" "unset" "$(auto_reboot_setting)"
aptcfg 'Unattended-Upgrade::Automatic-Reboot-Time "02:00";'
# POSITIVE CONTROL for the time reader too, for the same reason.
check "PROBE ALIVE: the reboot time is readable when set" "02:00" "$(auto_reboot_time)"
check "…and the setting itself stays unset when only the time is configured" "unset" "$(auto_reboot_setting)"
aptcfg '//Unattended-Upgrade::Automatic-Reboot-Time "02:00";'
check "a commented -Time yields no time either" "" "$(auto_reboot_time)"
aptcfg '// nothing enabled here'
check "comment-only file reads as unset" "unset" "$(auto_reboot_setting)"
rm -rf "$CFG"; mkdir -p "$CFG"
check "an empty config dir reads as unset, not false" "unset" "$(auto_reboot_setting)"
check "and no reboot time is invented" "" "$(auto_reboot_time)"

echo ""
echo "migration fixtures: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
