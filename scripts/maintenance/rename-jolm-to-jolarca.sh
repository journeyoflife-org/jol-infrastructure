#!/usr/bin/env bash
# =============================================================================
# rename-jolm-to-jolarca.sh — scripted in-repo content migration (Phase P3 of
# the Jolarca Rename Migration plan, change record JOL-RENAME-20260831-01).
#
# Design: targeted token list ONLY (never bare "jol-m"/"jolm" bulk replace),
#         longest-match-first, generated/venv dirs excluded, dated sealed
#         audit artifacts excluded via EXCLUDES (immutability rule, ISO
#         A.8.32 lineage — resolved by the rename registry in
#         jol-infrastructure/docs/compliance/rename-registry-jolm-to-jolarca.md).
# Modes:  DRY_RUN=1 → report only, zero mutations (default)
#         APPLY=1   → perform replacements in the working tree (no commit;
#                     review + branch/PR discipline is the operator's step)
# =============================================================================
set -euo pipefail

ROOT="${1:-/opt/jol-m/repos}"
MODE="dry-run"; [ "${APPLY:-0}" = "1" ] && MODE="apply"

# Longest-match-first order is mandatory.
TOKENS=(
  "jol-m-marketplace:jolarca"
  "jol-m-infrastructure:jolarca-infrastructure"
  "jol-m-compliance:jolarca-compliance"
  "jol-m-legal:jolarca-legal"
  "jol-m-data:jolarca-data"
)

# Sealed/dated audit artifacts — immutable, excluded from replacement.
EXCLUDES=(
  "./jol-m-compliance/audits/gate-evidence/G3-payments/evidence-manifest.md"
  "./jol-m-compliance/audits/internal-audit-2026-08-15.md"
)

is_excluded() {
  local f="$1" e
  for e in "${EXCLUDES[@]}"; do [[ "$f" == "$e" ]] && return 0; done
  return 1
}

log() { printf '%s\n' "$*"; }

CHANGED=0 SCANNED=0
while IFS= read -r f; do
  SCANNED=$((SCANNED + 1))
  rel="./${f#"$ROOT"/}"
  if is_excluded "$rel"; then
    log "EXCLUDED (sealed audit artifact): $rel"
    continue
  fi
  # binary guard: skip anything grep treats as binary
  if grep -qI . "$f" 2>/dev/null; then :; else
    log "SKIPPED (binary): $rel"
    continue
  fi
  hits=0
  for t in "${TOKENS[@]}"; do
    n=$(grep -c "${t%%:*}" "$f" || true)   # grep -c exits 1 on 0 matches; tolerated
    hits=$((hits + n))
  done
  if [ "$MODE" = "dry-run" ]; then
    log "WOULD-REPLACE ($hits token hits): $rel"
  else
    for t in "${TOKENS[@]}"; do
      sed -i "s/${t%%:*}/${t##*:}/g" "$f"
    done
    log "REPLACED ($hits token hits): $rel"
  fi
  CHANGED=$((CHANGED + 1))
done < <(grep -rlE "jol-m-(marketplace|infrastructure|compliance|legal|data)" \
  --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules \
  --exclude-dir=__pycache__ --exclude-dir=.idea "$ROOT" 2>/dev/null)

log "=== $MODE complete: scanned=$SCANNED affected=$CHANGED root=$ROOT ==="
