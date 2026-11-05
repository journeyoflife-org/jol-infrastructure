#!/usr/bin/env bash
# =============================================================================
# test-doc-claims.sh — fixtures for check-doc-claims.py (audit §11, F-40..F-47).
#
# WHY THIS WRAPPER EXISTS: the Makefile and infra-validate.yml are both staged and
# unstaged in a concurrent session's index, so neither a `lint-doc-claims` target nor a
# new CI step can be added from here without being reverted by that session's next
# commit. `make test-gates` globs scripts/maintenance/tests/test-*.sh and is ALREADY
# wired into the `changelog-guard` CI job, so dropping this file in gives the checker a
# real enforcement point without touching a single contended path.
#
# Convention (per scripts/maintenance/tests/): a check that has never been observed to
# FAIL is not a check. Groups 3 and 4 therefore build throwaway git repos and prove the
# checker goes red on a new claim and on a new advertised branch glob, and green on a
# clean tree — end to end, not just at function level (that is the self-test's job).
# Anything unreadable or unextractable ABORTS with rc=2, so an empty run can never be
# mistaken for "0 failed".
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/../check-doc-claims.py"
# HERE is scripts/maintenance/tests, so the repo root is THREE levels up. The worktree
# fence suite died with rc=127 on every live fixture when this was ../.. — a missing
# script, not a failing gate. 127 must stay distinguishable from 1.
REPO="$(cd "$HERE/../../.." && pwd)"

PASS=0; FAILED=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

[[ -r "$TARGET" ]] || { echo "cannot read $TARGET"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git not found"; exit 2; }

echo "=== fixture group 1: the detectors exist (extraction guard, not a copy) ==="
for fn in class_a class_b class_c class_d self_test scan _join_comment_wrapped; do
    if grep -q "^def ${fn}(" "$TARGET"; then
        ok "detector ${fn}() is defined in the checker under test"
    else
        bad "detector ${fn}() is MISSING from $TARGET — the suite would pass vacuously"
    fi
done
# A debt baseline that is empty in every class means either the repo is perfect or the
# detectors are blind. The audit measured 12 live debt notes, so assert a floor.
DEBT_TOTAL="$(python3 -c "
import importlib.util
spec=importlib.util.spec_from_file_location('cdc','$TARGET')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m.CLASS_A_DEBT)+len(m.CLASS_B_DEBT)+len(m.CLASS_C_DEBT)+len(m.CLASS_D_DEBT))
" 2>/dev/null)"
if [[ -z "$DEBT_TOTAL" ]]; then
    echo "could not import the checker to read its baselines"; exit 2
fi
if [[ "$DEBT_TOTAL" -ge 12 ]]; then
    ok "the debt baselines are populated ($DEBT_TOTAL entries) — the detectors have work to do"
else
    bad "only $DEBT_TOTAL debt entries; the audit measured 12 live ones, so a detector has gone blind"
fi

echo ""
echo "=== fixture group 2: the checker's own self-test, and the live scan ==="
SELF_OUT="$(cd "$REPO" && python3 "$TARGET" --self-test 2>&1)"
SELF_RC=$?
SELF_OKS="$(grep -cE '^  ok' <<<"$SELF_OUT" || true)"
check "self-test exits 0" "0" "$SELF_RC"
if [[ "$SELF_OKS" -ge 16 ]]; then
    ok "self-test ran $SELF_OKS fixtures (>= 16) — not an empty run reporting 0 failed"
else
    bad "self-test reported only $SELF_OKS fixtures; expected >= 16, so it did not really run"
fi
if grep -q 'self-test passed' <<<"$SELF_OUT"; then
    ok "self-test announces all four classes were observed to fail on synthetic defects"
else
    bad "self-test did not announce passage: $(grep -E 'self-test' <<<"$SELF_OUT" | head -1)"
fi

SCAN_OUT="$(cd "$REPO" && python3 "$TARGET" 2>&1)"
SCAN_RC=$?
check "the live scan of this repository exits 0 (no NEW prose claim contradicts its config)" \
      "0" "$SCAN_RC"
SCAN_NOTES="$(grep -cE '^  [ABCD] debt' <<<"$SCAN_OUT" || true)"
if [[ "$SCAN_NOTES" -ge 12 ]]; then
    ok "the live scan observed $SCAN_NOTES baselined debt note(s) — it is reading the real tree"
else
    bad "only $SCAN_NOTES debt notes; expected >= 12, so the scan is not seeing the known defects"
fi
if grep -q 'DOC-CLAIM CHECK PASS' <<<"$SCAN_OUT"; then
    ok "the scan prints an explicit PASS verdict rather than exiting quietly"
else
    bad "no PASS verdict line: $(tail -1 <<<"$SCAN_OUT")"
fi

# ---------------------------------------------------------------------------
# Groups 3 and 4: hermetic throwaway repos. The checker derives its repo root from its
# own file location, so copying it into a temp git repo makes it scan THAT repo. Nothing
# in the real tree is touched, which matters because this tree is shared with a second
# session holding 11 staged and 16 unstaged paths.
# ---------------------------------------------------------------------------
make_repo() {
    local d
    d="$(mktemp -d)" || return 1
    ( cd "$d" && git init -q . >/dev/null 2>&1 ) || { rm -rf "$d"; return 1; }
    mkdir -p "$d/scripts/maintenance" "$d/.github/workflows"
    cp "$TARGET" "$d/scripts/maintenance/check-doc-claims.py" || { rm -rf "$d"; return 1; }
    printf '%s\n' "$d"
}

echo ""
echo "=== fixture group 3: a NEW permanence claim must go red end to end ==="
# The phrase is held QUOTED in this file on purpose: check-doc-claims.py scans every
# tracked .sh, and an unquoted copy here would be a class-B violation in the real tree —
# the fixture would fail the very check it exists to run. Group 3 strips the quotes when
# it writes the throwaway README, so the temp repo gets the ASSERTED form and the real
# tree keeps the quoted form.
BAD_CLAIM='"has never been installed"'
R1="$(make_repo)"
if [[ -z "$R1" || ! -d "$R1" ]]; then
    bad "could not build a throwaway repo — this fixture would pass vacuously"
else
    printf '%s\n' '# Notes' '' "the pre-commit hook ${BAD_CLAIM//\"/} here." > "$R1/README.md"
    ( cd "$R1" && git add -A >/dev/null 2>&1 )
    R1_OUT="$(cd "$R1" && python3 scripts/maintenance/check-doc-claims.py 2>&1)"
    R1_RC=$?
    check "a repo asserting a permanence claim exits non-zero" "1" "$R1_RC"
    if grep -q 'VIOLATION B' <<<"$R1_OUT"; then
        ok "the violation is class B and names the file: $(grep -o 'B: [^ ]*' <<<"$R1_OUT" | head -1)"
    else
        bad "no class-B violation reported: $(tail -2 <<<"$R1_OUT" | head -1)"
    fi
    # The same claim QUOTED must be clean — that is the exemption the checker relies on,
    # and it is what lets the audit and the corrected docstrings discuss the phrase.
    printf '%s\n' '# Notes' '' "F-42 retracts the claim ${BAD_CLAIM}." > "$R1/README.md"
    ( cd "$R1" && git add -A >/dev/null 2>&1 )
    R1Q_OUT="$(cd "$R1" && python3 scripts/maintenance/check-doc-claims.py 2>&1)"
    R1Q_RC=$?
    check "the same phrase quoted for retraction exits 0" "0" "$R1Q_RC"
    if grep -q 'DOC-CLAIM CHECK PASS' <<<"$R1Q_OUT"; then
        ok "the quoted form prints PASS, so the exemption is the reason and not a crash"
    else
        bad "quoted form did not print PASS: $(tail -1 <<<"$R1Q_OUT")"
    fi
    rm -rf "$R1"
fi

echo ""
echo "=== fixture group 4: an advertised branch glob that is not a trigger must go red ==="
R2="$(make_repo)"
if [[ -z "$R2" || ! -d "$R2" ]]; then
    bad "could not build a throwaway repo — this fixture would pass vacuously"
else
    cat > "$R2/.github/workflows/w.yml" <<'YAML'
# Trigger: push/PR to main, develop, feature/*
name: "W"
on:
  push:
    branches:
      - main
      - develop
permissions:
  contents: read
YAML
    ( cd "$R2" && git add -A >/dev/null 2>&1 )
    R2_OUT="$(cd "$R2" && python3 scripts/maintenance/check-doc-claims.py 2>&1)"
    R2_RC=$?
    check "a comment advertising a glob the on: block lacks exits non-zero" "1" "$R2_RC"
    if grep -q 'VIOLATION A' <<<"$R2_OUT"; then
        ok "the violation is class A and names the glob: $(grep -o 'feature/\*' <<<"$R2_OUT" | head -1)"
    else
        bad "no class-A violation reported: $(tail -2 <<<"$R2_OUT" | head -1)"
    fi
    # Widening the config clears it — proving the detector reads the on: block and is not
    # simply pattern-matching the comment.
    cat > "$R2/.github/workflows/w.yml" <<'YAML'
# Trigger: push/PR to main, develop, feature/*
name: "W"
on:
  push:
    branches:
      - main
      - develop
      - feature/*
permissions:
  contents: read
YAML
    ( cd "$R2" && git add -A >/dev/null 2>&1 )
    R2F_OUT="$(cd "$R2" && python3 scripts/maintenance/check-doc-claims.py 2>&1)"
    R2F_RC=$?
    check "adding the glob to the on: block exits 0" "0" "$R2F_RC"
    # Assert on the captured output too: rc=0 alone would also be produced by a checker
    # that crashed before scanning, and an unused capture is what shellcheck SC2034 flags.
    if grep -q 'DOC-CLAIM CHECK PASS' <<<"$R2F_OUT"; then
        ok "the widened config prints PASS — the detector read the on: block, not just the comment"
    else
        bad "widened config exited 0 without a PASS verdict: $(tail -1 <<<"$R2F_OUT")"
    fi
    rm -rf "$R2"
fi

echo ""
echo "doc-claim fixtures: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
