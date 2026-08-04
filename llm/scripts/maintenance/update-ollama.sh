#!/usr/bin/env bash
# update-ollama.sh — safe Ollama upgrade: backup → update → verify → SBOM.
# Air-gap rule: the NEW binary must already be staged at
# /opt/jol/staging/ollama-linux-amd64 and its checksum pinned in
# llm/infra/group_vars/all/vars.yml BEFORE running this script.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The SBOM lives in the jol-llm repository. Point JOL_LLM_REPO at a jol-llm
# checkout when running from jol-infrastructure.
LLM_REPO="${JOL_LLM_REPO:-${REPO_DIR}}"
STAGED="/opt/jol/staging/ollama-linux-amd64"
BIN="/usr/local/bin/ollama"
RELEASES="/opt/jol/releases"
STATE="/opt/jol/state/last-known-good.json"

log() { printf '[update-ollama] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f ${STAGED} ]] || die "no staged binary (air-gap-procedure.md)"

old_version="$(${BIN} --version 2>/dev/null | awk '{print $NF}' || echo unknown)"
new_version="$(${STAGED} --version 2>/dev/null | awk '{print $NF}' || echo unknown)"
log "current: ${old_version} → staged: ${new_version}"

# --- Pinned checksum gate ---
pinned=$(grep -oP 'ollama_sha256:\s*"\K[0-9a-f]{64}' \
  "${REPO_DIR}/infra/group_vars/all/vars.yml" || true)
[[ -n ${pinned} ]] || die "ollama_sha256 not pinned in vars.yml"
actual=$(sha256sum "${STAGED}" | awk '{print $1}')
[[ ${actual} == "${pinned}" ]] || die "staged binary SHA256 ${actual} != pinned ${pinned}"
log "staged binary checksum verified"

# --- 1. Backup current binary ---
install -d "${RELEASES}"
cp -a "${BIN}" "${RELEASES}/ollama-${old_version}"
log "previous binary archived: ${RELEASES}/ollama-${old_version}"

# --- 2. Swap binary ---
systemctl stop ollama
install -m 0755 "${STAGED}" "${BIN}"
systemctl start ollama

# --- 3. Verify ---
sleep 5
if ! curl -sf --max-time 10 http://127.0.0.1:11434/api/version >/dev/null; then
  log "VERIFY FAILED — rolling back"
  cp -a "${RELEASES}/ollama-${old_version}" "${BIN}"
  systemctl restart ollama
  die "update rolled back to ${old_version}"
fi
"${REPO_DIR}/scripts/install/04-post-install-verify.sh" || {
  log "post-install verify failed — rolling back"
  cp -a "${RELEASES}/ollama-${old_version}" "${BIN}"
  systemctl restart ollama
  die "update rolled back to ${old_version}"
}

# --- 4. Record last-known-good + SBOM reminder ---
cat > "${STATE}" <<EOF
{
  "version": "${new_version}",
  "sha256": "${actual}",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "previous": "${old_version}"
}
EOF

if ! grep -q "${new_version}" "${LLM_REPO}/security/sbom/ollama-sbom.json"; then
  die "SBOM does not list ${new_version} — update security/sbom/ollama-sbom.json in jol-llm (mandatory step)"
fi

log "update complete: ${old_version} → ${new_version}"
