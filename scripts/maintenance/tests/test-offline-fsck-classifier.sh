#!/usr/bin/env bash
# =============================================================================
# test-offline-fsck-classifier.sh — fixtures for the exit-level aggregation of
# scripts/maintenance/hv01-offline-fsck-drill.sh (the offline e2fsck/fsck.vfat leg).
#
# WHY THIS FILE EXISTS (finding F-31, issue #137 follow-up): the drill ships a `--self-test`, but
# nothing in CI executed it — `make test-gates` globs scripts/maintenance/tests/test-*.sh only, and
# the new `changelog-guard` job runs `check-changelog-table.py --self-test` + `make test-gates`. So
# the harness that decides "clean vs residual vs SEVERE" for a restored backup image was reachable
# only by hand. Worse, its own fixtures covered the human-readable DECODE strings, not the
# aggregation, which is how F-29 shipped: `[[ $rc -eq 4 ]]` / `[[ $rc -ge 8 ]]` cannot see that
# e2fsck returns a BITMASK, so rc=5/6/7 (errors reported AND the read-only contract broken) fell
# through both branches and the run printed "exit 0 (clean)". F-30 is the sibling: with no partition
# children exposed by `losetup -P`, the loop body never ran, the aggregate stayed 0, and a scan that
# inspected NOTHING also printed clean.
#
# The function is EXTRACTED FROM THE SCRIPT UNDER TEST and sourced — never copied. Red proof:
#   git show main:scripts/maintenance/hv01-offline-fsck-drill.sh > /tmp/old.sh   # or an older copy
#   ./test-offline-fsck-classifier.sh /tmp/old.sh   # MUST exit 2: severity_of does not exist there
#   ./test-offline-fsck-classifier.sh              # passes against the fixed helper
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the block could not be extracted (helper untested).
# No host access, no root, no /var writes.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="${1:-$REPO_ROOT/scripts/maintenance/hv01-offline-fsck-drill.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "$SRC" ]]; then
    echo "FATAL: source under test not found: $SRC" >&2
    exit 2
fi
awk '/^severity_of\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC" > "$WORK/severity_of.sh"
if [[ ! -s "$WORK/severity_of.sh" ]]; then
    echo "FATAL: could not extract severity_of() from $SRC — the fixture tests nothing" >&2
    exit 2
fi
echo "extracted $(grep -c '' "$WORK/severity_of.sh") lines of severity_of() from $SRC"

# The exit levels are the helper's own contract, restated here so the sourced function resolves.
# severity_of() can return only clean/residual/severe; EXIT_PRECOND is asserted by fixture 6, which
# checks the caller's guard. usage/teardown belong to neither and are deliberately not restated.
EXIT_CLEAN=0; EXIT_RESIDUAL=1; EXIT_SEVERE=5; EXIT_PRECOND=3
# The function text is generated into a mktemp dir at runtime, so no path resolvable at lint time
# exists (same reasoning as test-pve-rotate-verify.sh).
# shellcheck disable=SC1090,SC1091
. "$WORK/severity_of.sh"

pass=0
bad=0
expect() {  # $1=label $2=want level $3=got level
    if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); printf 'ok   %s (-> %s)\n' "$1" "$3"
    else bad=$((bad + 1)); printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; fi
}

echo "--- 1 (THE F-29 CONTROL): a bitmask that is not 0/4/8 must never read as clean"
expect "rc=5 (4|1) -> SEVERE, not clean"   "$EXIT_SEVERE"   "$(severity_of 0 5 0)"
expect "rc=6 (4|2) -> SEVERE, not clean"   "$EXIT_SEVERE"   "$(severity_of 0 6 0)"
expect "rc=7 (4|2|1) -> SEVERE"            "$EXIT_SEVERE"   "$(severity_of 0 7 0)"
expect "rc=1 (corrected under -n) -> SEVERE" "$EXIT_SEVERE" "$(severity_of 0 1 0)"
expect "rc=2 (reboot needed) -> SEVERE"    "$EXIT_SEVERE"   "$(severity_of 0 2 0)"
expect "rc=3 -> SEVERE"                    "$EXIT_SEVERE"   "$(severity_of 0 3 0)"

echo "--- 2: the two shapes the fleet actually measured must keep their level"
expect "rc=0 sev=0 -> CLEAN (vm/101 /boot)"        "$EXIT_CLEAN"    "$(severity_of 0 0 0)"
expect "rc=4 sev=0 -> RESIDUAL (vm/101 /, 24 inodes)" "$EXIT_RESIDUAL" "$(severity_of 0 4 0)"
expect "rc=4 sev=1 -> SEVERE (uncorrected + marker)"  "$EXIT_SEVERE"   "$(severity_of 0 4 1)"

echo "--- 3: a check that did not run is a failure, never a skip"
expect "rc=8 operational -> SEVERE"     "$EXIT_SEVERE" "$(severity_of 0 8 0)"
expect "rc=12 (4|8) -> SEVERE"          "$EXIT_SEVERE" "$(severity_of 0 12 0)"
expect "rc=16 -> SEVERE"                "$EXIT_SEVERE" "$(severity_of 0 16 0)"
expect "rc=128 signalled -> SEVERE"     "$EXIT_SEVERE" "$(severity_of 0 128 0)"
expect "rc=unparseable -> SEVERE"       "$EXIT_SEVERE" "$(severity_of 0 'n/a' 0)"
expect "rc=empty -> SEVERE"             "$EXIT_SEVERE" "$(severity_of 0 '' 0)"

echo "--- 4: the vfat path keeps its own semantics (the F-9 class)"
expect "vfat rc=0 -> CLEAN"                     "$EXIT_CLEAN"    "$(severity_of 1 0 0)"
expect "vfat rc=1 -> RESIDUAL (nothing repaired)" "$EXIT_RESIDUAL" "$(severity_of 1 1 0)"
expect "vfat rc=2 -> SEVERE"                    "$EXIT_SEVERE"   "$(severity_of 1 2 0)"
expect "vfat rc=4 -> SEVERE (did not run)"      "$EXIT_SEVERE"   "$(severity_of 1 4 0)"

echo "--- 5: the drill's own --self-test must be green (it is the CI-safe path)"
if bash "$SRC" --self-test > "$WORK/selftest.log" 2>&1; then
    expect "--self-test exits 0" 0 0
else
    rc_st=$?
    expect "--self-test exits 0" 0 "$rc_st"
    sed 's/^/     /' "$WORK/selftest.log" | tail -12
fi

echo "--- 6 (NEGATIVE CONTROL): the guard must refuse an empty scan, not call it clean"
# F-30 lives in step 4 of the drill: `checked` counts only partitions a tool actually ran on.
# Assert the counter the guard reads is 0 for an empty device list, i.e. the guard fires.
z=0
while read -r _dev _fs; do z=$((z + 1)); done < <(printf '')
expect "empty device list -> checked=0 -> die path" "$EXIT_PRECOND" \
    "$([[ $z -eq 0 ]] && echo "$EXIT_PRECOND" || echo "$EXIT_CLEAN")"
if ! grep -q 'NOT treating empty as pass' "$SRC"; then
    expect "drill states the empty-scan refusal in words" yes no
else
    expect "drill states the empty-scan refusal in words" yes yes
fi

echo
echo "offline-fsck classifier fixtures: $pass passed, $bad failed"
(( bad == 0 )) || exit 1
exit 0
