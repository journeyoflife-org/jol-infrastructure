#!/usr/bin/env bash
# memory-profile.sh — track the model RAM footprint over a timed window.
# Usage: memory-profile.sh [seconds]   (default 60s)
set -Eeuo pipefail

DURATION="${1:-60}"
INTERVAL=5

log() { printf '[memprof] %s\n' "$*"; }

pid=$(systemctl show -p MainPID --value ollama 2>/dev/null || true)
[[ -n ${pid} && ${pid} != "0" ]] || { log "ollama not running"; exit 1; }

log "sampling ollama pid=${pid} RSS for ${DURATION}s (every ${INTERVAL}s)"
log "time_epoch,rss_mib,vm_size_mib,system_free_gib"

end=$(( $(date +%s) + DURATION ))
peak=0
while (( $(date +%s) < end )); do
  rss_kib=$(awk '/VmRSS/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0)
  vm_kib=$(awk '/VmSize/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0)
  free_gib=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  rss_mib=$(( rss_kib / 1024 ))
  (( rss_mib > peak )) && peak=${rss_mib}
  echo "$(date +%s),$(( rss_mib )),$(( vm_kib / 1024 )),${free_gib}"
  sleep "${INTERVAL}"
done

log "peak RSS: ${peak} MiB"
log "interpretation: weights RSS should match manifest size ±KV cache;"
log "unexpected growth across idle periods indicates a leak (file an issue)."
