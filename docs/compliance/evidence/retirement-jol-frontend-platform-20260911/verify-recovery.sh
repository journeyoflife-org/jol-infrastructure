#!/usr/bin/env bash
# verify-recovery.sh — independently re-prove that the jol-frontend-platform
# retirement evidence can reconstruct the deleted repository.
#
# Change ID: JOL-RETIRE-20260911-01
# Runs WITHOUT the original working copy; needs only git + coreutils.
# Usage: bash verify-recovery.sh          (exit 0 == evidence intact)
set -euo pipefail

EV=$(cd "$(dirname "$0")" && pwd)
cd "$EV"

EXPECTED_SOPS_TIP=24c4e1304f396fac81bd2786933c16acd771ed64
EXPECTED_MAIN_TIP=0ab71a5540985ed347cee78b470ee49c3c7e5445
EXPECTED_SUPERSEDED_TIP=610c8d31cdbac30d0fc064133d4a356ddcc923e6
EXPECTED_OBJCOUNT=14

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "[1/6] fixity of all evidence artifacts"
sha256sum -c SHA256SUMS.txt >/dev/null && pass "SHA256SUMS.txt verifies"

echo "[2/6] bundle self-consistency"
for b in gate8-sops-enablement.bundle gate8-superseded-attempt.bundle; do
  git bundle verify "$b" >/dev/null 2>&1 || fail "$b failed bundle verify"
  pass "$b verifies"
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[3/6] clone both bundles into isolation (no reference to any live repo)"
git clone -q "$EV/gate8-sops-enablement.bundle" "$WORK/one" 2>/dev/null || true
git clone -q "$EV/gate8-superseded-attempt.bundle" "$WORK/two" 2>/dev/null || true
[ -d "$WORK/one/.git" ] || fail "primary bundle did not clone"
[ -d "$WORK/two/.git" ] || fail "superseded bundle did not clone"
pass "both bundles clone"

echo "[4/6] ref layout of an isolated clone (informational)"
echo "  primary clone refs:"; git -C "$WORK/one" for-each-ref --format='    %(refname) %(objectname:short)'
echo "  superseded clone refs:"; git -C "$WORK/two" for-each-ref --format='    %(refname) %(objectname:short)'
# NOTE: a multi-ref bundle checkout materialises only HEAD as a local branch;
# the other refs arrive as refs/remotes/origin/*. Identifiers below are therefore
# asserted as SHA-1 OBJECT presence, which is layout-independent and canonical.

echo "[4b/6] commit identity (SHA-1 must survive the round trip unchanged)"
git -C "$WORK/one" cat-file -e "${EXPECTED_SOPS_TIP}^{commit}" || fail "24c4e13 commit absent from primary bundle"
git -C "$WORK/one" cat-file -e "${EXPECTED_MAIN_TIP}^{commit}"  || fail "0ab71a5 commit absent from primary bundle"
git -C "$WORK/two" cat-file -e "${EXPECTED_SUPERSEDED_TIP}^{commit}" || fail "610c8d31 commit absent from superseded bundle"
[ "$(git -C "$WORK/one" rev-parse "$EXPECTED_SOPS_TIP")" = "$EXPECTED_SOPS_TIP" ] || fail "sops tip mismatch"
[ "$(git -C "$WORK/one" rev-parse "$EXPECTED_MAIN_TIP")" = "$EXPECTED_MAIN_TIP" ] || fail "main tip mismatch"
[ "$(git -C "$WORK/two" rev-parse "$EXPECTED_SUPERSEDED_TIP")" = "$EXPECTED_SUPERSEDED_TIP" ] || fail "superseded tip mismatch"
pass "all three commits present with exact SHA-1 identity"

echo "[5/6] tree identity vs recorded inventories"
git -C "$WORK/one" ls-tree -r "$EXPECTED_SOPS_TIP" > "$WORK/sops.tree"
git -C "$WORK/two" ls-tree -r "$EXPECTED_SUPERSEDED_TIP" > "$WORK/sup.tree"
diff -q source-tree.txt  "$WORK/sops.tree" >/dev/null || fail "24c4e13 tree differs from source-tree.txt"
diff -q dangling-tree.txt "$WORK/sup.tree" >/dev/null || fail "610c8d31 tree differs from dangling-tree.txt"
pass "both trees match their inventories"

echo "[6/6] full object-database coverage (nothing lost)"
{
  git -C "$WORK/one" cat-file --batch-all-objects --batch-check='%(objectname)'
  git -C "$WORK/two" cat-file --batch-all-objects --batch-check='%(objectname)'
} | sort -u > "$WORK/recovered.txt"
awk '{print $3}' source-odb-inventory.txt | sort -u > "$WORK/source.txt"
missing=$(comm -23 "$WORK/source.txt" "$WORK/recovered.txt" | wc -l)
[ "$missing" -eq 0 ] || fail "$missing source objects are NOT recoverable from the bundles"
srccount=$(wc -l < "$WORK/source.txt")
[ "$srccount" -eq "$EXPECTED_OBJCOUNT" ] || fail "ODB inventory has $srccount objects, expected $EXPECTED_OBJCOUNT"
pass "$srccount/$EXPECTED_OBJCOUNT objects recoverable, 0 missing"

echo
echo "RECOVERY_VERIFIED — this evidence is sufficient to rebuild the repository."
