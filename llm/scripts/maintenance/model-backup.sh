#!/usr/bin/env bash
# model-backup.sh — rsync /opt/jol/models to the backup HDD.
# Flags: --restore <manifest-name>   restore one verified model from backup.
set -Eeuo pipefail

MODELS_DIR="/opt/jol/models"
BACKUP_DIR="/mnt/backup/models"
RESTORE=""

[[ "${1:-}" == "--restore" ]] && RESTORE="${2:?model name required}"

log() { printf '[model-backup] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
mountpoint -q /mnt/backup || die "/mnt/backup not mounted"

if [[ -n ${RESTORE} ]]; then
  src="${BACKUP_DIR}/gguf/${RESTORE}.gguf"
  dst="${MODELS_DIR}/gguf/${RESTORE}.gguf"
  [[ -f ${src} ]] || die "backup not found: ${src}"
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # Manifests live in the jol-llm repository; JOL_LLM_REPO overrides.
  manifest="${JOL_LLM_REPO:-${repo_dir}}/models/manifests/${RESTORE}.json"
  expected="$(jq -r '.sha256' "${manifest}" 2>/dev/null || echo "")"
  if [[ -n ${expected} && ${expected} != 0* ]]; then
    actual="$(sha256sum "${src}" | awk '{print $1}')"
    [[ ${actual} == "${expected}" ]] || die "backup SHA256 mismatch — refusing to restore"
  fi
  install -d -m 0750 -o ollama-svc -g ollama-svc "${MODELS_DIR}/gguf"
  install -m 0640 -o ollama-svc -g ollama-svc "${src}" "${dst}"
  log "restored ${RESTORE}"
  exit 0
fi

# --- backup ---
install -d -m 0750 "${BACKUP_DIR}"
log "rsync ${MODELS_DIR} → ${BACKUP_DIR}"
rsync -a --delete --info=progress2 \
  --exclude='.provenance' \
  "${MODELS_DIR}/" "${BACKUP_DIR}/"

# Backup manifest with hashes for restore-time verification
(
  cd "${BACKUP_DIR}"
  find gguf -type f -name '*.gguf' -print0 2>/dev/null \
    | xargs -0 -r sha256sum > .backup-sha256 || true
)
log "backup complete: $(du -sh "${BACKUP_DIR}" | awk '{print $1}')"
