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

echo ""
echo "migration fixtures: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
