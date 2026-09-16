#!/usr/bin/env bash
# JOL-RETIRE-20260911-01 — remove the jol-frontend-platform working copy.
# Guarded: refuses to act unless the evidence is proven recoverable and the
# target path resolves to exactly the intended directory.
set -euo pipefail

TARGET=/opt/jol/repos/jol-frontend-platform
EV=/opt/jol/repos/jol-infrastructure/docs/compliance/evidence/retirement-jol-frontend-platform-20260911

echo "### gate 1 — recovery evidence must verify end-to-end"
bash "$EV/verify-recovery.sh" | tail -3
echo "gate 1 passed"

echo
echo "### gate 2 — target must resolve to exactly the intended path"
[ -d "$TARGET" ] || { echo "target absent already — nothing to do"; exit 0; }
REAL=$(readlink -f "$TARGET")
echo "readlink -f => $REAL"
[ "$REAL" = "$TARGET" ] || { echo "ABORT: resolved path differs from expected"; exit 1; }
case "$REAL" in
  /opt/jol/repos/jol-frontend-platform) : ;;
  *) echo "ABORT: unexpected path"; exit 1 ;;
esac
# belt-and-braces: confirm it is the repo we audited, by its main tip
[ "$(git -C "$TARGET" rev-parse main)" = "0ab71a5540985ed347cee78b470ee49c3c7e5445" ] \
  || { echo "ABORT: main tip is not the audited 0ab71a5 — wrong directory?"; exit 1; }
echo "gate 2 passed (path + main tip identity confirmed)"

echo
echo "### removing $REAL"
rm -rf -- "$REAL"

echo
echo "### gate 3 — post-conditions"
if [ -e "$REAL" ]; then
  echo "STILL PRESENT — removal failed"
  exit 1
fi
echo "confirmed absent: $REAL"
echo
echo "remaining repos under /opt/jol/repos:"
ls -1 /opt/jol/repos
echo
echo "evidence retained:"
du -sh "$EV"
ls -1 "$EV"
echo
echo "RETIREMENT_COMPLETE"
