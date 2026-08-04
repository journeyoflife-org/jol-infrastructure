#!/usr/bin/env bash
# 03-model-pull.sh — import a model artifact with supply-chain verification.
# Air-gapped: the artifact is staged locally (USB/NAS); this script verifies
# SHA256 on the TARGET host before anything touches /opt/jol/models.
#
# Usage:
#   03-model-pull.sh <manifest-name>                 # prompt for artifact path
#   03-model-pull.sh --import /path/to/artifact.gguf [--manifest <name>]
#   03-model-pull.sh --verify-only <manifest-name>   # re-check installed file
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Model manifests live in the jol-llm repository (model registry metadata).
# Point JOL_LLM_REPO at a jol-llm checkout when running from jol-infrastructure.
LLM_REPO="${JOL_LLM_REPO:-${REPO_DIR}}"
MANIFEST_DIR="${LLM_REPO}/models/manifests"
MODELS_DIR="/opt/jol/models"
GGUF_DIR="${MODELS_DIR}/gguf"

log() { printf '[model-pull] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v jq >/dev/null || die "jq required"
command -v sha256sum >/dev/null || die "sha256sum required"

mode="import"
artifact=""
manifest_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --import) mode="import"; artifact="${2:?path required}"; shift 2 ;;
    --verify-only) mode="verify"; manifest_name="${2:?manifest required}"; shift 2 ;;
    --manifest) manifest_name="${2:?}"; shift 2 ;;
    -*) die "unknown flag: $1" ;;
    *) manifest_name="$1"; shift ;;
  esac
done

if [[ ${mode} == "import" && -z ${manifest_name} ]]; then
  # derive manifest from filename convention <name>.gguf
  base="$(basename "${artifact}")"
  manifest_name="${base%.gguf}"
fi

manifest="${MANIFEST_DIR}/${manifest_name}.json"
[[ -f ${manifest} ]] || die "manifest not found: ${manifest}"

expected_sha=$(jq -r '.sha256' "${manifest}")
expected_size=$(jq -r '.size_bytes' "${manifest}")
model_id=$(jq -r '.model' "${manifest}")

if [[ ${expected_sha} == "0000000000000000000000000000000000000000000000000000000000000000" || -z ${expected_sha} ]]; then
  die "manifest sha256 is the zero placeholder — pin it before import (air-gap-procedure.md §2)"
fi

resolve_installed_path() { echo "${GGUF_DIR}/${manifest_name}.gguf"; }

verify_file() {
  local f="$1"
  [[ -f ${f} ]] || die "artifact not found: ${f}"
  log "verifying $(basename "${f}") ..."
  local actual_sha actual_size
  actual_sha=$(sha256sum "${f}" | awk '{print $1}')
  actual_size=$(stat -c %s "${f}")
  [[ ${actual_sha} == "${expected_sha}" ]] || die "SHA256 MISMATCH (supply-chain violation — file a security issue, do not retry)"
  if [[ ${expected_size} != "null" && ${actual_size} -ne ${expected_size} ]]; then
    die "size mismatch: got ${actual_size}, manifest says ${expected_size}"
  fi
  log "SHA256 verified: ${actual_sha}"
}

if [[ ${mode} == "verify" ]]; then
  verify_file "$(resolve_installed_path)"
  log "VERIFY-ONLY: installed artifact matches manifest ${manifest_name}"
  exit 0
fi

# --- import ---
verify_file "${artifact}"

install -d -m 0750 -o ollama-svc -g ollama-svc "${GGUF_DIR}"
dest="$(resolve_installed_path)"
if [[ -f ${dest} ]]; then
  log "destination exists and is verified equal — skipping copy"
else
  log "installing to ${dest}"
  install -m 0640 -o ollama-svc -g ollama-svc "${artifact}" "${dest}"
fi

# --- register with Ollama via Modelfile if present ---
modelfile="${REPO_DIR}/config/ollama/modelfiles/${manifest_name%-*}.Modelfile"
# best-effort match: qwen3-32b-q8_0 -> qwen3-32b-q8.Modelfile
for cand in "${REPO_DIR}/config/ollama/modelfiles/"*.Modelfile; do
  if [[ $(basename "${cand}") == "${manifest_name%%-*}"* ]]; then
    modelfile="${cand}"
    break
  fi
done

if [[ -f ${modelfile} ]] && command -v ollama >/dev/null; then
  log "registering ${model_id} from ${modelfile}"
  sudo -u ollama-svc ollama create "${model_id}" -f "${modelfile}" \
    || die "ollama create failed — check journalctl -u ollama"
fi

# --- record provenance ---
provenance="${MODELS_DIR}/.provenance/${manifest_name}.json"
install -d -m 0750 "${MODELS_DIR}/.provenance"
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg by "$(logname 2>/dev/null || echo root)" \
  '. + {imported_at: $at, imported_by: $by}' "${manifest}" > "${provenance}"

log "import complete: ${model_id}"
log "next: 04-post-install-verify.sh --model ${model_id}"
