#!/usr/bin/env bash
# =============================================================================
# test-installer-guard.sh — fixtures for install-workstation-scripts.sh.
#
# The installer had no test coverage at all, which is how two of its defects stayed
# invisible: a mode of 750 on a script whose documented read-only invocation is meant
# to run without root, and a HEAD:path lookup spelled with a bare filename that
# resolved to nothing for every target — degrading every verdict to "cannot check",
# which looks exactly like a guard that passed.
#
# Convention: functions are EXTRACTED from the script under test and sourced, and an
# empty extraction aborts with rc=2 so the file cannot pass by testing nothing.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/../install-workstation-scripts.sh"
REPO="$(cd "$HERE/../.." && pwd)"

PASS=0; FAILED=0
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

[[ -r "$TARGET" ]] || { echo "cannot read $TARGET"; exit 2; }

DV="$(awk '/^dirty_verdict\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$DV" ]] || ! grep -q 'NOT_IN_GIT' <<<"$DV"; then
    echo "extraction failed: dirty_verdict not found in $TARGET"; exit 2
fi
eval "$DV"

echo "=== group 1: dirty_verdict — the three states must be distinct ==="
check "identical hashes are CLEAN"        "CLEAN"      "$(dirty_verdict abc abc)"
check "different hashes are DIRTY"        "DIRTY"      "$(dirty_verdict abc def)"
# An empty HEAD hash is NOT "clean": it means the lookup failed. Collapsing it into the
# passing branch is the bug that made the guard decorative.
check "missing head hash is NOT_IN_GIT"   "NOT_IN_GIT" "$(dirty_verdict '' abc)"
check "missing worktree hash is NOT_IN_GIT" "NOT_IN_GIT" "$(dirty_verdict abc '')"
# Both empty is still NOT_IN_GIT, never CLEAN: two failed lookups agreeing is not agreement.
check "two failed lookups do not read as CLEAN" "NOT_IN_GIT" "$(dirty_verdict '' '')"

echo "=== group 2: every manifest target must resolve in HEAD at its real path ==="
# This is the invariant the bare-filename bug broke. HEAD:<path> resolves from the REPO
# ROOT while the installer's $src is relative to scripts/maintenance, so a lookup spelled
# with just the filename returned nothing for all six targets and every verdict silently
# became NOT_IN_GIT. Asserting the resolved path per entry catches a future entry whose
# source is uncommitted, misspelled, or moved out of scripts/maintenance.
# Extract the manifest entries and STRIP the surrounding quotes and indent. Printing the
# raw line was the first draft's bug: every field then carried a leading space or a trailing
# quote, so mode compared as 755" and the path lookup failed for all six targets — the same
# "a guard that cannot check looks like a guard that passed" failure being tested for.
# tr is used rather than an awk gsub because the character class kept arriving mangled.
mapfile -t PAIRS < <(awk '/^    "[a-z0-9-]+\.sh\|/' "$TARGET" | tr -d ' "')
check "manifest is not empty (a silently empty loop tests nothing)" "1" "$([[ ${#PAIRS[@]} -gt 0 ]] && echo 1 || echo 0)"
UNCOMMITTED=0; BADMODE=0; BADNAME=0; BADHASH=0; EXPECTED_DIRTY=0; N=0
for pair in "${PAIRS[@]}"; do
    src="${pair%%|*}"; rest="${pair#*|}"; dst="${rest%%|*}"; mode="${rest##*|}"
    N=$((N + 1))
    hh="$(git -C "$REPO" rev-parse -q --verify "HEAD:scripts/maintenance/$src" 2>/dev/null || true)"
    # A resolved lookup must look like a blob id. This is the assertion that catches a
    # lookup spelled wrong at the path level: plain `git rev-parse HEAD:<bad-path>` echoes
    # the literal argument back, so a non-empty but non-hex value is a FAILURE, not a pass.
    if [[ ! "$hh" =~ ^[0-9a-f]{40}$ ]]; then
        bad "HEAD lookup for $src is not a 40-hex blob id: [$hh]"; BADHASH=$((BADHASH + 1)); UNCOMMITTED=$((UNCOMMITTED + 1))
    fi
    wh="$(git -C "$REPO" hash-object "scripts/maintenance/$src" 2>/dev/null || true)"
    if [[ -n "$hh" && -n "$wh" && "$hh" != "$wh" ]]; then EXPECTED_DIRTY=$((EXPECTED_DIRTY + 1)); fi
    # The mode must be one of the two documented values; anything else means a new entry
    # was added without deciding whether its read-only path is reachable.
    case "$mode" in
        750|755) : ;;
        *) bad "$dst has mode [$mode], expected 750 or 755"; BADMODE=$((BADMODE + 1)) ;;
    esac
    case "$dst" in
        jol-*.sh) : ;;
        *) bad "$dst does not follow the jol-*.sh naming"; BADNAME=$((BADNAME + 1)) ;;
    esac
    [[ -f "$HERE/../$src" ]] || { bad "source file missing on disk: $src"; UNCOMMITTED=$((UNCOMMITTED + 1)); }
done
check "all $N target sources resolve in HEAD" "0" "$UNCOMMITTED"
check "all HEAD lookups are 40-hex blob ids"  "0" "$BADHASH"
check "all modes are 750 or 755"              "0" "$BADMODE"
check "all installed names are jol-*.sh"      "0" "$BADNAME"

echo "=== group 3: every advertised read-only invocation must be reachable ==="
# The defect that shipped: the manifest installed jol-fix-backup-mount.sh at 750 while the
# installer's own help text advertised a no-root invocation of it. The check is written in
# the direction that FIRES today — for each read-only invocation the help text promises, its
# target's mode must be 755. The obvious opposite form ("for each 750 target, assert no
# promise exists") is vacuous the moment no target is 750, and a vacuous group is exactly
# how this class of defect survived in the first place.
ADVERTISED=0; UNREACHABLE=0
# SC2016 is expected on the process substitution below: $BIN_DIR is matched as LITERAL text
# from the installer's help lines, which is exactly what makes the promise testable. An
# expanding quote would match nothing and the group would pass vacuously.
# shellcheck disable=SC2016
while read -r dst flag; do
    [[ -n "$dst" ]] || continue
    ADVERTISED=$((ADVERTISED + 1))
    mode=""
    for pair in "${PAIRS[@]}"; do
        rest="${pair#*|}"; cand="${rest%%|*}"; [[ "$cand" == "$dst" ]] && mode="${pair##*|}"
    done
    if [[ -z "$mode" ]]; then
        bad "help text advertises $dst $flag but no TARGETS entry installs it"; UNREACHABLE=$((UNREACHABLE + 1))
    elif [[ "$mode" != "755" ]]; then
        bad "$dst is mode $mode yet the help text promises '$dst $flag' without root"; UNREACHABLE=$((UNREACHABLE + 1))
    else
        ok "$dst $flag is reachable at 755"
    fi
done < <(grep -oE '\$BIN_DIR/(jol-[a-z-]+\.sh)[[:space:]]+(--report|--verify-only|--preflight)' "$TARGET" \
          | sed 's|\$BIN_DIR/||' | awk '{print $1, $2}')
check "the help text advertises at least one read-only invocation" "1" "$([[ $ADVERTISED -gt 0 ]] && echo 1 || echo 0)"
check "every advertised invocation is reachable without root" "0" "$UNREACHABLE"

echo "=== group 4: the fleet-host guard must list the hosts it names ==="
# An installer that would run on a hypervisor is worse than one that fails: these are the
# custodian workstation's scripts, and the guard is the only thing enforcing that.
MISSING=0
for h in pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01; do
    grep -q "$h" "$TARGET" || { bad "fleet-host guard does not name $h"; MISSING=$((MISSING + 1)); }
done
check "all six fleet hosts are guarded" "0" "$MISSING"

echo "=== group 5: integration — the guard must ENGAGE, and refuse ONLY what is dirty ==="
# Groups 1-4 test the pure function and the manifest. Neither caught the bug measured here.
# The first draft looked HEAD up as `git rev-parse "HEAD:<bare-filename>"`, which does NOT
# fail quietly: git prints the LITERAL argument to stdout while exiting non-zero, and a
# `$( … || echo '' )` cannot retract output that was already captured. So HEADHASH became the
# text "HEAD:fix-jol-backup-mount.sh", every target compared unequal to a real hash, and the
# installer refused ALL SIX — including the clean ones — with a nonsense head= value. My first
# version of this group accepted any non-zero rc as "the guard working", so it passed over a
# mutant that broke the guard completely. The refusal count must be predicted independently.
# DRY_RUN=1 is the default and touches nothing outside the repo.
bash "$TARGET" > "$TMP_OUT" 2>&1
INTEG_RC=$?
NPLANNED="$(grep -c 'DRY  : install -m' "$TMP_OUT")"
NREFUSED="$(grep -c 'FAIL: .*differs from HEAD' "$TMP_OUT")"
NTOT=${#PAIRS[@]}

# Expected refusals are computed above from git itself, not from the installer's output.
if [[ "$EXPECTED_DIRTY" -eq 0 ]]; then
    check "clean manifest: installer exits 0"  "0" "$INTEG_RC"
    check "clean manifest: every target planned" "$NTOT" "$NPLANNED"
    check "clean manifest: nothing refused"       "0" "$NREFUSED"
else
    check "dirty manifest: installer exits 1" "1" "$INTEG_RC"
    check "dirty manifest: refuses exactly the $EXPECTED_DIRTY dirty source(s)" \
          "$EXPECTED_DIRTY" "$NREFUSED"
    check "dirty manifest: still plans the other $(( NTOT - EXPECTED_DIRTY ))" \
          "$(( NTOT - EXPECTED_DIRTY ))" "$NPLANNED"
fi

# A head= value in any message must be a blob id. This is the direct assertion against the
# echoed-literal failure mode; it fails loudly instead of being laundered into a refusal.
BADHEADMSG=0
while read -r hv; do
    [[ -n "$hv" ]] || continue
    [[ "$hv" =~ ^[0-9a-f]{40}$ ]] || BADHEADMSG=$((BADHEADMSG + 1))
done < <(grep -oE 'head=[^[:space:]]+' "$TMP_OUT" | cut -d= -f2)
if grep -q 'head=' "$TMP_OUT"; then
    check "every head= value printed by the guard is a real blob id" "0" "$BADHEADMSG"
else
    ok "no refusal messages emitted (nothing to check head= against)"
fi

if grep -q 'cannot be compared with HEAD' "$TMP_OUT"; then
    bad "the HEAD comparison degraded to NOT_IN_GIT — dirty-guard is decorative"
else
    ok "the HEAD comparison resolved for every target"
fi
if grep -qE "ABORT: .*is a fleet host" "$TMP_OUT"; then
    bad "the fleet-host guard fired on the workstation itself"
else
    ok "the fleet-host guard did not fire on this host"
fi

echo ""
echo "installer-guard fixtures: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
