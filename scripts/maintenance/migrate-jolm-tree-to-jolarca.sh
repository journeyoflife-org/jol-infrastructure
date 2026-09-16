#!/usr/bin/env bash
# =============================================================================
# migrate-jolm-tree-to-jolarca.sh — Phase P5 of the Jolarca Rename Migration
# (change record JOL-RENAME-20260831-01).
#
# Scope: host-level rename of the marketplace asset tree and OS identities.
#        NAMES ONLY — UIDs/GIDs preserved, so filesystem ownership bits are
#        unaffected. The church tree /opt/jol is never touched (AGENTS.md §0.2
#        segregation; ISO 27001 A.8.13).
#
# Pre-conditions (MANDATORY — the script refuses to apply without them):
#   1. Host backup or ZFS snapshot covering /opt/jol-m (CC8.1 rollback point)
#      -> pass evidence with SNAPSHOT_OK=1
#   2. Run as root
#   3. DRY_RUN=1 first; review; then apply
#
# Compliance: SOC 2 CC8.1 (change control), ISO 27001:2022 A.8.32 (change
#             mgmt), A.8.13 (segregation preserved — re-verified in V1),
#             GDPR Art. 5(1)(f) (integrity of the marketplace scope).
#
# Usage (as root):
#   DRY_RUN=1 bash migrate-jolm-tree-to-jolarca.sh          # preview
#   SNAPSHOT_OK=1 bash migrate-jolm-tree-to-jolarca.sh      # apply
#
# Rollback (sub-5-minute, fully reversible):
#   reverse the repo-dir renames under repos/ (jolarca* -> jol-m-*)
#   mv /opt/jolarca /opt/jol-m
#   groupmod -n jolm jolarca && groupmod -n jolm-dev jolarca-dev
#   usermod -l jolm-app jolarca-app
#   restore prior git safe.directory entries for user jol
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
OLD_TREE="/opt/jol-m"
NEW_TREE="/opt/jolarca"
DEV_USER="jol"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/jolarca-provision"
LOG="$LOG_DIR/rename-$STAMP.log"
FAILS=0

[ "$(id -u)" -eq 0 ] || { echo "ABORT: must run as root" >&2; exit 1; }
if [ "$DRY_RUN" != "1" ] && [ "${SNAPSHOT_OK:-0}" != "1" ]; then
  echo "ABORT: apply mode requires SNAPSHOT_OK=1 (backup/snapshot evidence, CC8.1 rollback point)" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR"
log() { local line; line="$(date -Is) $*"; echo "$line" | tee -a "$LOG"; }

# --- Step 1: OS identities (names only; UID/GIDs preserved) -------------------
rename_group() { # old new gid
  local old="$1" new="$2" gid="$3"
  if getent group "$new" | grep -q ":$gid:"; then
    log "OK     group $new already exists with GID $gid"; return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "DRYRUN groupmod -n $new $old (GID $gid preserved)"; return 0; fi
  groupmod -n "$new" "$old" || { log "FAIL   groupmod $old -> $new"; FAILS=1; return 1; }
  log "CHANGED group $old -> $new (GID $gid preserved)"
}
rename_user() { # old new uid
  local old="$1" new="$2" uid="$3"
  if getent passwd "$new" | grep -q ":$uid:"; then
    log "OK     user $new already exists with UID $uid"; return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "DRYRUN usermod -l $new $old (UID $uid preserved)"; return 0; fi
  usermod -l "$new" "$old" || { log "FAIL   usermod $old -> $new"; FAILS=1; return 1; }
  log "CHANGED user $old -> $new (UID $uid preserved)"
}

log "===== jol-m -> jolarca tree migration (DRY_RUN=$DRY_RUN, host=$(hostname)) ====="
rename_group jolm     jolarca     984
rename_group jolm-dev jolarca-dev 983
rename_user  jolm-app jolarca-app 997

# --- Step 2: tree move (same filesystem => atomic metadata change) ------------
if [ -d "$NEW_TREE" ] && [ ! -d "$OLD_TREE" ]; then
  log "OK     tree already at $NEW_TREE"
elif [ -d "$OLD_TREE" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    log "DRYRUN mv $OLD_TREE $NEW_TREE"
  else
    mv "$OLD_TREE" "$NEW_TREE" || { log "FAIL   tree move"; exit 1; }
    log "CHANGED tree $OLD_TREE -> $NEW_TREE"
  fi
else
  log "FAIL   neither $OLD_TREE nor $NEW_TREE present"; FAILS=1
fi

# --- Step 2b: local clone directory names follow the repo rename --------------
REPO_MAP=("jol-m-marketplace:jolarca" "jol-m-infrastructure:jolarca-infrastructure" \
          "jol-m-compliance:jolarca-compliance" "jol-m-legal:jolarca-legal" \
          "jol-m-data:jolarca-data")
for pair in "${REPO_MAP[@]}"; do
  old="$NEW_TREE/repos/${pair%%:*}"; new="$NEW_TREE/repos/${pair##*:}"
  [ "$DRY_RUN" = "1" ] && { log "DRYRUN mv $old $new (if old exists)"; continue; }
  if [ -d "$new" ]; then
    log "OK     repo dir already ${pair##*:}"
  elif [ -d "$old" ]; then
    mv "$old" "$new" || { log "FAIL   repo dir rename ${pair%%:*}"; FAILS=1; }
    log "CHANGED repo dir ${pair%%:*} -> ${pair##*:}"
  else
    log "NOTE   neither repo dir present: ${pair%%:*} / ${pair##*:}"
  fi
done

# --- Step 3: permission envelope re-assertion (baseline 2026-08-31) -----------
envelope() { # path mode owner group
  local p="$1" m="$2" o="$3" g="$4"
  [ "$DRY_RUN" = "1" ] && { log "DRYRUN ensure $p = $m $o:$g"; return 0; }
  [ -d "$p" ] || { log "FAIL   $p missing"; FAILS=1; return 1; }
  if ! chmod "$m" "$p" || ! chown "$o:$g" "$p"; then
    log "FAIL   perms on $p"; FAILS=1; return 1
  fi
  log "OK     $p = $(stat -c '%a %U:%G' "$p")"
}
envelope "$NEW_TREE"         755 root        root
envelope "$NEW_TREE/repos"   770 jolarca-app jolarca-dev
envelope "$NEW_TREE/data"    750 jolarca-app jolarca
envelope "$NEW_TREE/logs"    750 jolarca-app jolarca
envelope "$NEW_TREE/secrets" 700 root        root

# --- Step 4: git safe.directory for DEV_USER (scoped entries only) -------------
if [ "$DRY_RUN" = "1" ]; then
  log "DRYRUN as $DEV_USER: drop stale /opt/jol-m/** entries, add $NEW_TREE/repos/* scoped wildcard"
else
  sudo -u "$DEV_USER" git config --global --unset-all safe.directory '/opt/jol-m/.*' || true
  sudo -u "$DEV_USER" git config --global --add safe.directory "$NEW_TREE/repos/*"
  log "CHANGED safe.directory for $DEV_USER -> $NEW_TREE/repos/* (stale /opt/jol-m entries removed)"
fi

# --- V1: segregation re-proof (A.8.13 control re-certified post-rename) --------
if [ "$DRY_RUN" = "1" ]; then
  log "PREDICT sudo -u $DEV_USER ls $NEW_TREE/data  MUST fail (750 jolarca-app:jolarca)"
  log "PREDICT sudo -u $DEV_USER ls $NEW_TREE/repos MUST pass (770 jolarca-app:jolarca-dev)"
else
  if sudo -u "$DEV_USER" ls "$NEW_TREE/data" >/dev/null 2>&1; then
    log "FAIL   $NEW_TREE/data readable by $DEV_USER — segregation breach"; FAILS=1
  else
    log "PASS   $NEW_TREE/data denied for $DEV_USER (expected)"
  fi
  if sudo -u "$DEV_USER" ls "$NEW_TREE/repos" >/dev/null 2>&1; then
    log "PASS   $NEW_TREE/repos accessible for $DEV_USER (expected)"
  else
    log "FAIL   $NEW_TREE/repos not accessible by $DEV_USER"; FAILS=1
  fi
fi

if [ "$FAILS" -eq 0 ]; then
  log "===== migration complete (DRY_RUN=$DRY_RUN); log: $LOG ====="
else
  log "===== migration finished WITH FAILURES — investigate before use ====="
fi
[ "$DRY_RUN" = "1" ] || chmod 600 "$LOG"
exit "$FAILS"
