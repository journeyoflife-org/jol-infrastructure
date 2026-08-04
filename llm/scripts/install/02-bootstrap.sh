#!/usr/bin/env bash
# 02-bootstrap.sh — one-command bare-metal setup via Ansible (local apply).
# Idempotent: re-runnable; converges host to the site.yml state.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="${REPO_DIR}/infra"
LIMIT="${1:-}"

log() { printf '[bootstrap] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root (or via sudo)" >&2; exit 1; }

for tool in ansible-playbook python3; do
  command -v "${tool}" >/dev/null || {
    log "missing dependency: ${tool} — install ansible-core first"
    exit 1
  }
done

# Air-gap hosts have no pip; ansible must be pre-installed from the kiosk
# bundle (deb or venv). Refuse to touch the network here.
export ANSIBLE_LOCALHOST_WARNING=False

log "applying site.yml to $(hostname) ${LIMIT:+(--limit ${LIMIT})}"
cd "${INFRA_DIR}"
ANSIBLE_CONFIG=ansible.cfg ansible-playbook \
  -i "localhost," -c local \
  ${LIMIT:+-e "target_limit=${LIMIT}"} \
  playbooks/site.yml

rc=$?
if [[ $rc -ne 0 ]]; then
  log "FAILED (rc=${rc}) — inspect output above; see rollback-procedures.md"
  exit "$rc"
fi

log "bootstrap complete. Next: 03-model-pull.sh <manifest-name>"
log "Then:   04-post-install-verify.sh"
