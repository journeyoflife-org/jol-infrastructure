#!/usr/bin/env bash
# rotate-logs.sh — manual/scheduled audit-log rotation with integrity checks.
# Wraps logrotate (config/logrotate/jol-audit) and archives rotations to HDD.
# Flags: --dry-run
set -Eeuo pipefail

AUDIT_DIR="/var/log/jol-audit"
ARCHIVE_DIR="/mnt/backup/audit"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '[rotate-logs] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -d ${AUDIT_DIR} ]] || die "audit dir missing: ${AUDIT_DIR}"

# --- Content guard: refuse to rotate a log containing prompt content ---
# (defense in depth; the bridge must never write bodies)
SENTINEL_HITS=0
for f in "${AUDIT_DIR}"/*.log; do
  [[ -f ${f} ]] || continue
  if grep -qE '"(prompt|messages|content)"\s*:' "${f}" 2>/dev/null; then
    SENTINEL_HITS=1
    log "SUSPECT CONTENT in ${f} — quarantine and follow incident-response.md §4"
  fi
done
(( SENTINEL_HITS == 0 )) || die "content guard tripped; rotation aborted"

# --- Rotate via logrotate ---
if (( DRY_RUN )); then
  logrotate -d /etc/logrotate.d/jol-audit
  exit 0
fi
logrotate -f /etc/logrotate.d/jol-audit
log "logrotate forced run complete"

# --- Integrity manifest for rotated files ---
manifest="${AUDIT_DIR}/.rotation-sha256"
(
  cd "${AUDIT_DIR}"
  find . -maxdepth 1 -name '*.log-*' -print0 | xargs -0 -r sha256sum >> "${manifest}"
)
log "rotation hashes appended to ${manifest}"

# --- Archive rotations older than 7 days to HDD ---
if mountpoint -q /mnt/backup 2>/dev/null; then
  dest="${ARCHIVE_DIR}/$(date +%Y)/$(date +%m)"
  install -d -m 0750 "${dest}"
  find "${AUDIT_DIR}" -maxdepth 1 -name '*.log-*.gz' -mtime +7 -print0 \
    | while IFS= read -r -d '' f; do
        mv "${f}" "${dest}/"
        log "archived $(basename "${f}")"
      done
else
  log "WARN: /mnt/backup not mounted — archives kept locally"
fi

log "rotation complete"
