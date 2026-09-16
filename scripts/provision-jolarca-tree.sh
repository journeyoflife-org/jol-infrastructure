#!/usr/bin/env bash
# =============================================================================
# provision-jolarca-tree.sh — Provision the marketplace Tier-1 asset tree
#
# Scope:  /opt/jolarca ONLY. The church-platform tree (/opt/jol) is never
#         touched; the two Tier-1 scopes remain segregated. No repository
#         cloning, no data creation, no network access in this step.
# Design: idempotent, change-logged, DRY_RUN-capable, non-destructive.
#         Re-runs are safe; existing directory contents are never deleted.
#
# Compliance: ISO 27001:2022 A.8.13 (separation of information processing
#             facilities), SOC 2 CC6.1 (logical and physical access controls).
#
# Usage (as root):
#   DRY_RUN=1 bash provision-jolarca-tree.sh   # preview only, zero mutations
#   bash provision-jolarca-tree.sh             # apply, tee'd by operator
#
# Change log: /var/log/jolarca-provision/provision-<timestamp>.log (dir 700,
#             file 600) — same discipline as the Tier-1 remediation script.
#
# Supersedes: provision-jolm-tree.sh (renamed 2026-08-31 per change record
#             JOL-RENAME-20260831-01; backup at .bak.20260831).
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
LOG_DIR="/var/log/jolarca-provision"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/provision-$STAMP.log"
BASE="/opt/jolarca"
DEV_USER="jol"
FAILS=0

# --- pre-flight --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "ABORT: must run as root" >&2; exit 1; }
id "$DEV_USER" >/dev/null 2>&1 || { echo "ABORT: user $DEV_USER does not exist" >&2; exit 1; }

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

log() {
  # stdout, not stderr: operator capture relies on `| tee /tmp/...`
  local line
  line="$(date -Is) $*"
  echo "$line" | tee -a "$LOG"
}
abort() { log "ABORT  $*"; exit 1; }

# --- G1: groups --------------------------------------------------------------
ensure_group() { # group why
  local g="$1" why="$2"
  if getent group "$g" >/dev/null; then
    log "OK     group:$g exists ($(getent group "$g"))"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "DRYRUN groupadd --system $g ($why)"; return 0; fi
  groupadd --system "$g" || abort "groupadd --system $g failed"
  log "CHANGED group:$g created (--system) ($why)"
}

# --- U1: service account + developer membership -------------------------------
ensure_user() { # user why
  local u="$1" why="$2"
  if getent passwd "$u" >/dev/null; then
    log "OK     user:$u exists ($(getent passwd "$u" | cut -d: -f3,6,7))"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRYRUN useradd --system -g jolarca -d /nonexistent -s /usr/sbin/nologin $u ($why)"
    return 0
  fi
  useradd --system -g jolarca -d /nonexistent -s /usr/sbin/nologin "$u" \
    || abort "useradd $u failed"
  log "CHANGED user:$u created (--system, primary group jolarca, nologin) ($why)"
}

ensure_membership() { # user group why
  local u="$1" g="$2" why="$3"
  if id -nG "$u" | tr ' ' '\n' | grep -qx "$g"; then
    log "OK     user:$u already member of $g"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "DRYRUN usermod -aG $g $u ($why)"; return 0; fi
  usermod -aG "$g" "$u" || abort "usermod -aG $g $u failed"
  log "CHANGED user:$u added to $g ($why)"
}

# --- D1: directory tree --------------------------------------------------------
ensure_dir() { # path mode owner group why
  local path="$1" mode="$2" owner="$3" group="$4" why="$5"
  local before="(absent)"
  if [ -e "$path" ]; then before="$(stat -c '%a %U:%G' "$path")"; fi
  local desired="$mode $owner:$group"
  if [ "$before" = "$desired" ]; then
    log "OK     $path already $desired"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "DRYRUN $path: $before -> $desired ($why)"; return 0; fi
  install -d -m "$mode" -o "$owner" -g "$group" "$path" || abort "install -d $path failed"
  log "CHANGED $path: $before -> $(stat -c '%a %U:%G' "$path") ($why)"
  if [ -d "$path" ]; then
    local n
    n="$(find "$path" -mindepth 1 -maxdepth 1 | wc -l)"
    if [ "$n" -gt 0 ]; then
      log "NOTE   $path holds $n existing entries (left untouched — non-destructive)"
    fi
  fi
}

# --- V1: built-in segregation verification --------------------------------------
verify() {
  log "== V1 segregation verification =="
  if [ "$DRY_RUN" = "1" ]; then
    log "PREDICT sudo -u $DEV_USER ls $BASE/data  MUST fail  (750 jolarca-app:jolarca; $DEV_USER not in jolarca)"
    log "PREDICT sudo -u $DEV_USER ls $BASE/repos MUST pass  (770 jolarca-app:jolarca-dev; $DEV_USER in jolarca-dev)"
    log "INFO   group membership checks deferred to apply run (dry-run)"
    return 0
  fi
  if sudo -u "$DEV_USER" ls "$BASE/data" >/dev/null 2>&1; then
    log "FAIL   $BASE/data is readable by $DEV_USER — segregation breach (expected denial)"
    return 1
  fi
  log "PASS   $BASE/data denied for $DEV_USER (expected)"
  if sudo -u "$DEV_USER" ls "$BASE/repos" >/dev/null 2>&1; then
    log "PASS   $BASE/repos accessible for $DEV_USER (expected)"
  else
    log "FAIL   $BASE/repos not accessible by $DEV_USER (expected access)"
    return 1
  fi
  local g
  while IFS= read -r g; do log "INFO   $g"; done < <(getent group jolarca jolarca-dev)
  log "HINT   repos is owned by jolarca-app; git 'dubious ownership' guard will fire for $DEV_USER."
  log "HINT   as $DEV_USER run: git config --global --add safe.directory '$BASE/repos/*'"
  return 0
}

# --- main -----------------------------------------------------------------------
log "===== jolarca Tier-1 tree provisioning (DRY_RUN=$DRY_RUN, host=$(hostname)) ====="

log "== G1 groups =="
ensure_group jolarca     "marketplace service group; owns runtime data"
ensure_group jolarca-dev "marketplace developer collaboration group for repos"

log "== U1 service account =="
ensure_user jolarca-app "non-login marketplace service account (PCI/KYC scope)"
ensure_membership "$DEV_USER" jolarca-dev "developer needs rw on $BASE/repos"

log "== D1 directory tree =="
ensure_dir "$BASE"        755 root        root        "scope root; traversable, not list-sensitive"
ensure_dir "$BASE/repos"  770 jolarca-app jolarca-dev "developer rw via jolarca-dev; service owns"
ensure_dir "$BASE/data"   750 jolarca-app jolarca     "runtime data; service-only + jolarca group"
ensure_dir "$BASE/logs"   750 jolarca-app jolarca     "service logs; same envelope as data"
ensure_dir "$BASE/secrets" 700 root        root        "secret material; root-only (Vaultwarden-injected later)"

if ! verify; then
  FAILS=1
fi

if [ "$FAILS" -eq 0 ]; then
  log "===== provisioning complete (DRY_RUN=$DRY_RUN); change log: $LOG ====="
else
  log "===== provisioning finished WITH VERIFICATION FAILURES — investigate before use ====="
fi
chmod 600 "$LOG"
exit "$FAILS"
