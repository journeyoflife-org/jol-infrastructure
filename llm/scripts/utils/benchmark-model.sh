#!/usr/bin/env bash
# benchmark-model.sh — tok/sec measurement for a registered model.
# Wraps Ollama's timing fields; appends a CSV row to the benchmark log.
# Usage: benchmark-model.sh <model-name> [runs]
set -Eeuo pipefail

MODEL="${1:?model name required}"
RUNS="${2:-5}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Benchmark log lives in the jol-llm repository (model registry metadata).
# Point JOL_LLM_REPO at a jol-llm checkout when running from jol-infrastructure.
LLM_REPO="${JOL_LLM_REPO:-${REPO_DIR}}"
CSV="${LLM_REPO}/models/benchmarks/llm-prod-lt01-results.csv"
PROMPT="Explain the difference between TCP and UDP in four sentences."

log() { printf '[bench] %s\n' "$*"; }
command -v ollama >/dev/null || { echo "ollama CLI required" >&2; exit 1; }

gen_rates=()
pp_rates=()

for i in $(seq 1 "${RUNS}"); do
  resp=$(curl -s http://127.0.0.1:11434/api/generate -d "{
    \"model\": \"${MODEL}\",
    \"prompt\": \"${PROMPT}\",
    \"stream\": false,
    \"options\": {\"num_predict\": 128, \"num_ctx\": 2048}
  }")
  gen_ns=$(echo "${resp}" | jq -r '.eval_duration // empty')
  gen_tokens=$(echo "${resp}" | jq -r '.eval_count // empty')
  pp_ns=$(echo "${resp}" | jq -r '.prompt_eval_duration // empty')
  pp_tokens=$(echo "${resp}" | jq -r '.prompt_eval_count // empty')
  [[ -n ${gen_ns} && ${gen_ns} -gt 0 ]] || { log "run ${i}: no timing data"; continue; }
  gen_rates+=("$(awk -v t="${gen_tokens}" -v ns="${gen_ns}" 'BEGIN{printf "%.2f", t/(ns/1e9)}')")
  pp_rates+=("$(awk -v t="${pp_tokens}" -v ns="${pp_ns}" 'BEGIN{printf "%.1f", t/(ns/1e9)}')")
  log "run ${i}: gen ${gen_rates[-1]} tok/s, prompt ${pp_rates[-1]} tok/s"
done

(( ${#gen_rates[@]} > 0 )) || { log "no successful runs"; exit 1; }

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
gen_med=$(median "${gen_rates[@]}")
pp_med=$(median "${pp_rates[@]}")

log "median: generation ${gen_med} tok/s, prompt-processing ${pp_med} tok/s"

# Append to the CSV benchmark log
[[ -f ${CSV} ]] || echo "date,host,model,quant,threads,prompt_tok_s,gen_tok_s,notes" > "${CSV}"
quant=$(ollama show "${MODEL}" --modelfile 2>/dev/null | grep -ioP 'q[0-9]_[0-9a-z]+' | head -1 || echo "unknown")
echo "$(date -u +%F),$(hostname),${MODEL},${quant},$(nproc),${pp_med},${gen_med},benchmark-model.sh" >> "${CSV}"
log "appended to ${CSV} — commit with the PR that admits this model"
