#!/usr/bin/env bash
# config-backup.sh — git-commit managed /etc state for rollback forensics.
# Idempotent: creates/updates /var/lib/jol/etc-git and mirrors to HDD.
set -Eeuo pipefail

ETC_GIT="/var/lib/jol/etc-git"
BACKUP_DIR="/mnt/backup/config"

FILES=(
  /etc/caddy/Caddyfile
  /etc/jol/ollama-environment
  /etc/logrotate.d/jol-audit
  /etc/audit/rules.d/ollama.rules
  /etc/sysctl.d/99-llm-performance.conf
  /etc/sudoers.d/jol-llm
  /etc/netdata/health.d/ollama.conf
)

log() { printf '[config-backup] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"

if [[ ! -d ${ETC_GIT}/.git ]]; then
  install -d -m 0700 "${ETC_GIT}"
  git -C "${ETC_GIT}" init -q -b main
  git -C "${ETC_GIT}" config user.email "root@$(hostname)"
  git -C "${ETC_GIT}" config user.name "automated config backup"
fi

changed=0
for f in "${FILES[@]}"; do
  [[ -f ${f} ]] || continue
  rel="${f#/}"
  install -d "$(dirname "${ETC_GIT}/${rel}")"
  if ! cmp -s "${f}" "${ETC_GIT}/${rel}"; then
    install -m 0600 "${f}" "${ETC_GIT}/${rel}"
    changed=1
  fi
done

if (( changed )); then
  git -C "${ETC_GIT}" add -A
  git -C "${ETC_GIT}" commit -q -m "config snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "committed config changes"
else
  log "no config changes"
fi

# Mirror the git repo to HDD when mounted
if mountpoint -q /mnt/backup 2>/dev/null; then
  install -d -m 0700 "${BACKUP_DIR}"
  rsync -a --delete "${ETC_GIT}/" "${BACKUP_DIR}/etc-git/"
  log "mirrored to ${BACKUP_DIR}/etc-git"
fi
