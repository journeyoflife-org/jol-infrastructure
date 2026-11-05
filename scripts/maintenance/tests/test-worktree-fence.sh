#!/usr/bin/env bash
# =============================================================================
# test-worktree-fence.sh — fixtures for the collision detector.
#
# Scope: `collide` decides the exit status and the whole verdict, so it is the
# part that gets fixtures. The worktree census and the git plumbing around it are
# exercised by running the tool against the real repo, which is the live check
# below; a fixture cannot invent a second worktree without mutating the host.
#
# Convention (per scripts/maintenance/tests/): the function is EXTRACTED from the
# script under test with awk and sourced, never copied, so a fixture cannot drift
# from the implementation. Extraction failure ABORTS with rc=2 — an empty
# extraction that falls through to "0 failed" is the vacuous-gate class.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/../agent-worktree-fence.sh"
# HERE is scripts/maintenance/tests, so the repo root is THREE levels up. The
# first draft used ../.. and every live fixture died with rc=127 — a missing
# script, not a failing gate. 127 must stay distinguishable from 1 (collision).
REPO="$(cd "$HERE/../../.." && pwd)"

PASS=0; FAILED=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

[[ -r "$TARGET" ]] || { echo "cannot read $TARGET"; exit 2; }

FUNC="$(awk '/^collide\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$FUNC" ]] || ! grep -q 'SUBSEP' <<<"$FUNC"; then
    echo "extraction failed: collide not found between its markers in $TARGET"; exit 2
fi
eval "$FUNC"

# Helper: run collide over a literal stream and return sorted output.
run() { printf '%s\n' "$1" | collide; }

echo "=== fixture group 1: the collision itself ==="
check "same path uncommitted in two worktrees is reported" \
    "2	CHANGELOG.md" \
    "$(run 'wt_a	CHANGELOG.md
wt_b	CHANGELOG.md')"
check "a path unique to one worktree is NOT reported" "" \
    "$(run 'wt_a	CHANGELOG.md
wt_b	Makefile')"
check "three worktrees sharing one path report count 3" \
    "3	CHANGELOG.md" \
    "$(run 'wt_a	CHANGELOG.md
wt_b	CHANGELOG.md
wt_c	CHANGELOG.md')"
check "output is sorted by path, not by hash order" \
    "2	a.txt
2	z.txt" \
    "$(run 'wt_a	z.txt
wt_b	z.txt
wt_a	a.txt
wt_b	a.txt')"

echo "=== fixture group 2: distinct worktrees, not lines (the whole point) ==="
# A worktree can legitimately list the same path twice — a file both modified and
# staged shows in `git diff` AND `git diff --cached`. Counting lines would call
# that a collision and make the tool cry wolf on every single-file edit.
check "the same path twice from the SAME worktree is not a collision" "" \
    "$(run 'wt_a	CHANGELOG.md
wt_a	CHANGELOG.md')"
check "…and three copies from one worktree still is not a collision" "" \
    "$(run 'wt_a	CHANGELOG.md
wt_a	CHANGELOG.md
wt_a	CHANGELOG.md')"
check "one worktree plus a second still IS a collision at count 2" \
    "2	CHANGELOG.md" \
    "$(run 'wt_a	CHANGELOG.md
wt_a	CHANGELOG.md
wt_b	CHANGELOG.md')"

echo "=== fixture group 3: malformed input must not fabricate a verdict ==="
check "a line with no tab is ignored" "" "$(run 'CHANGELOG.md with no separator')"
check "an empty worktree id is ignored" "" "$(run '	CHANGELOG.md')"
check "an empty path is ignored" "" "$(run 'wt_a	')"
# One empty-path line alone cannot distinguish the guard, because cnt[""] stays 1
# and is never reported. It takes TWO, from DIFFERENT worktrees, to make the
# missing guard produce a phantom collision — and that is the case that matters.
# A mutation of this guard survived the first version of these fixtures.
# These cases need a tab as the LAST character of a line (that is what an empty
# path IS in a tab-separated stream). Written as literals they are trailing
# whitespace, and the repo's `trim trailing whitespace` pre-commit hook strips them
# silently — which it did on 2026-11-05: the fixtures kept passing while testing a
# different input, turning "empty path" into "no tab at all". ANSI-C quoting keeps
# the byte in the DATA without putting it at end-of-line in the FILE. Do not
# "simplify" these back into literals.
check "two empty paths from two worktrees must not invent a collision" "" \
    "$(run $'wt_a\t\nwt_b\t')"
check "…even alongside a real collision, only the real one is reported" \
    "2	Makefile" \
    "$(run $'wt_a\t\nwt_b\t\nwt_a\tMakefile\nwt_b\tMakefile')"
check "a blank line contributes nothing" "" "$(run '')"
check "whitespace-only input yields empty output" "" "$(run '   ')"
check "a real collision mixed with junk still resolves correctly" \
    "2	Makefile" \
    "$(run $'junkline\nwt_a\tMakefile\n\tMakefile\nwt_a\t\nwt_b\tMakefile')"

echo "=== fixture group 4: path shapes that could break a tab-separated stream ==="
LONGP="scripts/maintenance/tests/test-hv01-config-backup-f3.sh"
check "a deep path round-trips intact" \
    "2	$LONGP" \
    "$(run "wt_a	$LONGP
wt_b	$LONGP")"
check "a path containing a space round-trips intact" \
    "2	docs/a file.md" \
    "$(run 'wt_a	docs/a file.md
wt_b	docs/a file.md')"
check "a path containing a comma is not split" \
    "2	tfvars/prod,eu.csv" \
    "$(run 'wt_a	tfvars/prod,eu.csv
wt_b	tfvars/prod,eu.csv')"
# Not a legal git path today, but the renderer downstream DOES refuse literal
# pipes, so the detector must pass one through unaltered rather than truncate at
# it — a silently mangled path would hide a real collision.
check "a path containing a literal pipe is passed through, not truncated" \
    "2	odd|name.txt" \
    "$(run 'wt_a	odd|name.txt
wt_b	odd|name.txt')"

echo "=== fixture group 5: many paths, selective reporting ==="
MANY="wt_a	CHANGELOG.md
wt_a	Makefile
wt_a	README.md
wt_b	CHANGELOG.md
wt_b	infra.yml
wt_c	Makefile
wt_c	README.md
wt_c	other.txt"
check "exactly the shared paths are reported, and nothing else" \
    "2	CHANGELOG.md
2	Makefile
2	README.md" \
    "$(run "$MANY")"
check "collision count matches expectation" "3" "$(run "$MANY" | grep -c . )"
check "a path shared by two of three worktrees is still a collision" \
    "2	infra.yml" \
    "$(run "$MANY
wt_d	infra.yml" | grep infra.yml)"

echo "=== fixture group 6: census counts — the numbers printed must be measured ==="
# A mutant that broke the census field separator survived the first version of
# this file, because nothing asserted the per-worktree counts at all. Display
# output that is believed and not checked is how a dashboard lies quietly.
CFUNC2="$(awk '/^census\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$CFUNC2" ]] || ! grep -q 'split(lines\[i\], f' <<<"$CFUNC2"; then
    echo "extraction failed: census not found between its markers in $TARGET"; exit 2
fi
eval "$CFUNC2"

CTABLE="wt_a	live	branchA	/path/a
wt_b	live	branchB	/path/b
wt_c	prunable	branchC	/path/c"
CSTREAM="wt_a	x.txt
wt_a	y.txt
wt_a	x.txt
wt_b	z.txt"
COUT="$(census "$CTABLE" "$CSTREAM")"
# Passed without a synthetic trailing newline: `$'\n'` inside double quotes does
# not expand, it appends the literal text. awk's split() needs none.
check "worktree with two distinct paths counts 2, not 3 lines" "1" \
    "$(printf '%s\n' "$COUT" | grep -c '/path/a .* 2 path(s)')"
check "second live worktree counts 1" "1" \
    "$(printf '%s\n' "$COUT" | grep -c '/path/b .* 1 path(s)')"
check "a worktree absent from the stream reports 0, not blank" "1" \
    "$(printf '%s\n' "$COUT" | grep -c '/path/c .* 0 path(s)')"
check "every live worktree appears in the census" "3" "$(printf '%s\n' "$COUT" | grep -c '^  /path/')"
check "an empty stream still lists all three worktrees at zero" "3" \
    "$(census "$CTABLE" '' | grep -c ' 0 path(s)')"

echo "=== fixture group 7: live check against the real repository ==="
# The detector is only worth anything if it finds what was measured by hand on
# 2026-11-05: CHANGELOG.md uncommitted in more than one worktree of this repo.
LIVE_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"
if (( LIVE_WT < 2 )); then
    ok "live check skipped — only $LIVE_WT worktree(s), no second to compare against"
else
    [[ -r "$REPO/scripts/maintenance/agent-worktree-fence.sh" ]] \
        || { bad "live check cannot reach the tool at $REPO/scripts/maintenance/agent-worktree-fence.sh"; }
    STATUS_OUT="$(cd "$REPO" && bash scripts/maintenance/agent-worktree-fence.sh status 2>&1)"
    STATUS_RC=$?
    case "$STATUS_RC" in
      0) ok "live status rc=0 (clear) — census reported it as clear" ;;
      1) if grep -q 'CHANGELOG.md' <<<"$STATUS_OUT"; then
             ok "live status correctly flags CHANGELOG.md as a cross-worktree collision"
         else
             bad "live status rc=1 but CHANGELOG.md is not in the reported collision set"
         fi ;;
      *) bad "live status exited $STATUS_RC — expected 0 (clear) or 1 (collision), never a measurement failure" ;;
    esac
    # An unknown subcommand must be rc=2, not rc=0. A gate that succeeds on its
    # own typo is how a mis-typed check looks like a pass.
    (cd "$REPO" && bash scripts/maintenance/agent-worktree-fence.sh definitely-not-a-mode >/dev/null 2>&1)
    check "an unknown subcommand exits 2, not 0" "2" "$?"
    (cd "$REPO" && bash scripts/maintenance/agent-worktree-fence.sh check >/dev/null 2>&1)
    check "check with no paths exits 2 rather than claiming clear" "2" "$?"
fi

echo ""
echo "fence fixtures: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
