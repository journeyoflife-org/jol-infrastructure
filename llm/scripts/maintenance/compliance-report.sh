#!/usr/bin/env bash
# compliance-report.sh — assemble the ISO 27001 evidence pack.
# Output: /opt/jol/state/compliance-packs/evidence-<date>.tar.gz
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Compliance artifacts (policies, mappings, SBOM, docs) live in the jol-llm
# repository. Point JOL_LLM_REPO at a jol-llm checkout when running from
# jol-infrastructure; copy() skips anything missing.
LLM_REPO="${JOL_LLM_REPO:-${REPO_DIR}}"
OUT_DIR="/opt/jol/state/compliance-packs"
STAGE="$(mktemp -d)"
DATE="$(date -u +%Y%m%d)"
PACK="${OUT_DIR}/evidence-${DATE}.tar.gz"

log() { printf '[compliance] %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

install -d "${OUT_DIR}"

copy() {
  if [[ -e "$1" ]]; then
    cp -r "$1" "${STAGE}/$2"
  else
    log "skip (missing): $1"
  fi
}

log "collecting static compliance artifacts (from jol-llm: ${LLM_REPO})"
copy "${LLM_REPO}/security/compliance"                compliance
copy "${LLM_REPO}/security/policies"                  policies
copy "${LLM_REPO}/security/threat-model"              threat-model
copy "${LLM_REPO}/security/sbom"                      sbom
copy "${LLM_REPO}/docs/03-security"                   docs-security

log "collecting live system evidence"
mkdir -p "${STAGE}/live"
{
  echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) host: $(hostname)"
  uname -a
} > "${STAGE}/live/meta.txt"
ufw status verbose                 > "${STAGE}/live/ufw-status.txt" 2>&1 || true
auditctl -l                        > "${STAGE}/live/audit-rules.txt" 2>&1 || true
systemctl list-units --type=service --state=running --no-pager \
                                   > "${STAGE}/live/services.txt" 2>&1 || true
ss -tlnp                           > "${STAGE}/live/listeners.txt" 2>&1 || true
last -n 50 -F                      > "${STAGE}/live/logins.txt" 2>&1 || true
aureport --auth --summary -i       > "${STAGE}/live/aureport-auth.txt" 2>&1 || true
if command -v lynis >/dev/null; then
  lynis audit system --quick --cronjob --report-file "${STAGE}/live/lynis.dat" \
    > "${STAGE}/live/lynis.txt" 2>&1 || true
fi

log "collecting test evidence (latest runs)"
copy /var/log/jol-audit/maintenance.log live/maintenance.log

log "packaging"
tar -czf "${PACK}" -C "${STAGE}" .
rm -rf "${STAGE}"

sha256sum "${PACK}" > "${PACK}.sha256"
log "evidence pack: ${PACK}"
log "sha256: $(cat "${PACK}.sha256")"
log "transfer the pack (+ .sha256) to the audit archive per retention policy"
