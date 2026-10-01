#!/usr/bin/env bash
# context-load-probe.sh — measure the RAM footprint and prefill/decode timing of
# a model loaded at a TARGET serving context (e.g. 32768), which the sibling
# scripts do NOT cover: benchmark-model.sh pins num_ctx=2048, and memory-profile.sh
# only samples RSS passively. Ollama sizes the KV cache from num_ctx at load time,
# so raising num_ctx to the deployed window is what actually exercises the memory
# that the "Model RAM need > 80 GiB -> reject" admission rule guards.
#
# This is a MEASUREMENT tool, not a report: it never prints a number it did not
# observe. It must run ON llm-prod-lt01 (it reads /proc/<ollama>/status and the
# loopback engine API), which is air-gapped and unreachable from a dev workstation.
#
# Usage (on-box):  context-load-probe.sh [model] [target_ctx]
#   MODEL           default qwen3-32b-q8_0
#   TARGET_CTX      default 32768 (the Phase 1 native window; must match what is
#                   actually deployed — see llm/config/ollama/environment + Modelfile)
#   RSS_CEILING_GIB default 80    (jol-llm docs/04-operations/capacity-planning.md
#                   admission rule: ">80 GiB -> reject on lt01")
#   RUNS            default 3 (median reported)
set -Eeuo pipefail

MODEL="${1:-${MODEL:-qwen3-32b-q8_0}}"
TARGET_CTX="${2:-${TARGET_CTX:-32768}}"
RSS_CEILING_GIB="${RSS_CEILING_GIB:-80}"
RUNS="${RUNS:-3}"
OLLAMA_API="${OLLAMA_API:-http://127.0.0.1:11434}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLM_REPO="${JOL_LLM_REPO:-${REPO_DIR}}"
RESULTS_CSV="${LLM_REPO}/models/benchmarks/lt01-context-load-results.csv"

log()  { printf '[ctxprobe] %s\n' "$*"; }
fail() { printf '[ctxprobe] ERROR: %s\n' "$*" >&2; exit 1; }

command -v ollama >/dev/null || fail "ollama CLI required (run on llm-prod-lt01)"
command -v curl  >/dev/null || fail "curl required"
command -v jq    >/dev/null || fail "jq required"

# Locate the engine process so we can sample its resident memory during load.
pid=$(systemctl show -p MainPID --value ollama 2>/dev/null || true)
if [[ -z "${pid}" || "${pid}" == "0" ]]; then fail "ollama service not running (no MainPID)"; fi

# Canned, content-free filler only — never client content
# (jol-llm security/policies/data-retention-policy.md §3). Built with awk so it
# never trips pipefail via a SIGPIPE'd `yes`. Ollama sizes KV from num_ctx
# regardless; the filler mainly drives realistic prefill work.
N_WORDS=$(( TARGET_CTX * 8 / 10 ))
FILLER=$(awk -v n="${N_WORDS}" 'BEGIN{for(i=0;i<n;i++)printf "filler "}END{printf "\n"}')

# Peak-RSS sampler: records the max VmRSS (KiB) seen to <tmp>/peak every second.
SAMPLE_DIR=$(mktemp -d)
echo 0 > "${SAMPLE_DIR}/peak"
(
  while :; do
    rss_kib=$(awk '/VmRSS/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)
    [[ -z "${rss_kib}" ]] && break
    cur_peak=$(cat "${SAMPLE_DIR}/peak" 2>/dev/null || echo 0)
    if [[ "${rss_kib}" =~ ^[0-9]+$ ]] && (( rss_kib > cur_peak )); then
      echo "${rss_kib}" > "${SAMPLE_DIR}/peak"
    fi
    sleep 1
  done
) &
SAMPLER=$!
stop_sampler() { kill "${SAMPLER}" 2>/dev/null || true; wait "${SAMPLER}" 2>/dev/null || true; }
trap 'stop_sampler; rm -rf "${SAMPLE_DIR}"' EXIT

prefill_pps=(); gen_pps=(); prefill_s=()
for i in $(seq 1 "${RUNS}"); do
  log "run ${i}/${RUNS}: POST ${OLLAMA_API}/api/generate model=${MODEL} num_ctx=${TARGET_CTX}"
  resp=$(curl -sf "${OLLAMA_API}/api/generate" -d "{
    \"model\": \"${MODEL}\",
    \"prompt\": \"${FILLER}\",
    \"stream\": false,
    \"options\": {\"num_ctx\": ${TARGET_CTX}, \"num_predict\": 32}
  }") || fail "run ${i}: generate failed (model load at num_ctx=${TARGET_CTX} may have been refused)"
  pe_ns=$(echo "${resp}" | jq -r '.prompt_eval_duration // empty')
  pe_n=$(echo "${resp}"  | jq -r '.prompt_eval_count // empty')
  ge_ns=$(echo "${resp}"  | jq -r '.eval_duration // empty')
  ge_n=$(echo "${resp}"   | jq -r '.eval_count // empty')
  if [[ -z "${pe_ns}" || "${pe_ns}" == "0" ]]; then fail "run ${i}: no prompt_eval timing in response"; fi
  prefill_s+=("$(awk -v ns="${pe_ns}" 'BEGIN{printf "%.2f", ns/1e9}')")
  prefill_pps+=("$(awk -v t="${pe_n}" -v ns="${pe_ns}" 'BEGIN{printf "%.1f", t/(ns/1e9)}')")
  if [[ -n "${ge_ns}" && "${ge_ns}" != "0" ]]; then
    gen_pps+=("$(awk -v t="${ge_n}" -v ns="${ge_ns}" 'BEGIN{printf "%.1f", t/(ns/1e9)}')")
  else
    gen_pps+=("0")
  fi
  log "run ${i}: prefill ${prefill_pps[-1]} tok/s (${prefill_s[-1]}s), gen ${gen_pps[-1]} tok/s"
done

stop_sampler
peak_kib=$(cat "${SAMPLE_DIR}/peak" 2>/dev/null || echo 0)
peak_gib=$(awk -v k="${peak_kib}" 'BEGIN{printf "%.1f", k/1024/1024}')

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
pp_med=$(median "${prefill_pps[@]}"); gen_med=$(median "${gen_pps[@]}"); pf_med=$(median "${prefill_s[@]}")

log "MODEL=${MODEL} TARGET_CTX=${TARGET_CTX}"
log "median: prefill ${pp_med} tok/s, generation ${gen_med} tok/s, prefill-wall ${pf_med} s"
log "peak ollama RSS during load: ${peak_gib} GiB (admission ceiling ${RSS_CEILING_GIB} GiB)"

verdict="PASS"
if [[ "$(awk -v p="${peak_gib}" -v c="${RSS_CEILING_GIB}" 'BEGIN{print (p<=c)?1:0}')" == "0" ]]; then
  verdict="FAIL"
fi

# Append the measurement (real observed numbers only) to the jol-llm benchmark log.
[[ -f "${RESULTS_CSV}" ]] || echo "date,host,model,quant,threads,num_ctx,prefill_tok_s,gen_tok_s,prefill_s,peak_rss_gib,ceiling_gib,verdict" > "${RESULTS_CSV}"
quant=$(ollama show "${MODEL}" --modelfile 2>/dev/null | grep -ioP 'q[0-9]_[0-9a-z]+' | head -1 || true)
echo "$(date -u +%F),$(hostname),${MODEL},${quant:-unknown},$(nproc),${TARGET_CTX},${pp_med},${gen_med},${pf_med},${peak_gib},${RSS_CEILING_GIB},${verdict}" >> "${RESULTS_CSV}"
log "appended measurement row to ${RESULTS_CSV}"

if [[ "${verdict}" == "PASS" ]]; then
  log "PASS: ${MODEL} at num_ctx=${TARGET_CTX} peaks at ${peak_gib} GiB <= ${RSS_CEILING_GIB} GiB"
  exit 0
fi
log "FAIL: ${MODEL} at num_ctx=${TARGET_CTX} peaks at ${peak_gib} GiB > ${RSS_CEILING_GIB} GiB ceiling"
log "  -> do NOT route the 32k window to lt01; keep the smaller context or engage the GPU/second-node roadmap (capacity-planning.md)."
exit 1
