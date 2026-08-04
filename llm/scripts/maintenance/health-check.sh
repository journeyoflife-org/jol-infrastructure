#!/usr/bin/env bash
# health-check.sh — systemd/cron health probe. Exit 0 healthy, 1 degraded.
# Flags: --verify-model   additionally re-hash installed GGUF vs manifests.
set -Eeuo pipefail

MODELS_DIR="/opt/jol/models"
VERIFY_MODEL=0
[[ "${1:-}" == "--verify-model" ]] && VERIFY_MODEL=1

fail() { echo "UNHEALTHY: $*"; exit 1; }

# Service liveness
systemctl is-active --quiet ollama || fail "ollama inactive"

# Ollama API answers on loopback
curl -sf --max-time 5 http://127.0.0.1:11434/api/version >/dev/null \
  || fail "ollama API unresponsive"

# RAM floor (capacity-planning.md): at least 12 GiB free
free_gib=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)
(( free_gib >= 12 )) || fail "available RAM ${free_gib} GiB below floor"

# Disk headroom
root_free_gib=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
(( root_free_gib >= 10 )) || fail "root fs free ${root_free_gib} GiB too low"

# Model integrity re-hash (nightly job; ~2 min for 34 GiB on NVMe)
if (( VERIFY_MODEL )); then
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # Manifests live in the jol-llm repository; JOL_LLM_REPO overrides.
  repo_dir="${JOL_LLM_REPO:-${repo_dir}}"
  shopt -s nullglob
  for m in "${repo_dir}/models/manifests/"*.json; do
    name="$(basename "${m}" .json)"
    gguf="${MODELS_DIR}/gguf/${name}.gguf"
    [[ -f ${gguf} ]] || continue   # reserved models may be absent
    expected="$(jq -r '.sha256' "${m}")"
    [[ ${expected} == "0"* ]] && continue  # unpinned placeholder
    actual="$(sha256sum "${gguf}" | awk '{print $1}')"
    [[ ${actual} == "${expected}" ]] || fail "model ${name} SHA256 mismatch"
  done
  echo "model integrity verified"
fi

echo "HEALTHY"
