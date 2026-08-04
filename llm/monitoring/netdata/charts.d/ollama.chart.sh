# shellcheck shell=bash
# charts.d fallback collector for the jol-llm exporter — llm-prod-lt01.
#
# Primary ingestion path is the prometheus plugin (see
# monitoring/netdata/python.d/ollama.conf). This charts.d module exists as a
# fallback for hosts where the prometheus plugin is unavailable; it scrapes
# the same loopback exporter and exposes a compact health chart.
#
# Deploy to /etc/netdata/charts.d/ (ollama.chart.sh + ollama.conf).

ollama_update_every=10
ollama_endpoint="${ollama_endpoint:-http://127.0.0.1:9101/metrics}"

ollama_check() {
  command -v curl >/dev/null 2>&1 || {
    error "curl is required for the ollama charts.d collector"
    return 1
  }
  curl -fsS --max-time 5 "${ollama_endpoint}" >/dev/null || {
    error "exporter not reachable at ${ollama_endpoint}"
    return 1
  }
  return 0
}

ollama_create() {
  chart "jol_llm.status" "LLM platform status" "boolean" "ollama" "jol.llm_status" line 84000 ${ollama_update_every}
  dimension "ollama_up" "ollama" absolute 1 1
  dimension "bridge_up" "bridge" absolute 1 1
  dimension "model_resident" "primary model" absolute 1 1

  chart "jol_llm.throughput" "LLM throughput" "tok/s" "ollama" "jol.llm_throughput" area 84010 ${ollama_update_every}
  dimension "tokens_per_second" "generation" absolute 1 1000

  chart "jol_llm.queue" "Bridge queue depth" "requests" "ollama" "jol.llm_queue" line 84020 ${ollama_update_every}
  dimension "queue_depth" "queued" absolute 1 1000
}

# Scrape one metric family value out of the exposition text.
_ollama_metric() {
  local doc="$1" name="$2"
  printf '%s\n' "${doc}" | awk -v m="${name} " '
    index($0, m) == 1 { print $2; found = 1; exit }
    END { if (!found) print 0 }
  '
}

ollama_update() {
  local doc
  doc=$(curl -fsS --max-time 5 "${ollama_endpoint}") || return 1

  local ollama_up bridge_up resident tps queue
  ollama_up=$(_ollama_metric "${doc}" "ollama_up")
  bridge_up=$(_ollama_metric "${doc}" "ollama_bridge_up")
  resident=$(_ollama_metric "${doc}" "ollama_model_resident{model=\"qwen3-32b-q8_0\"}")
  tps=$(_ollama_metric "${doc}" "ollama_generate_tokens_per_second")
  queue=$(_ollama_metric "${doc}" "ollama_bridge_queue_depth")

  # chart jol_llm.status
  set "ollama_up" "$((ollama_up * 1))"
  set "bridge_up" "$((bridge_up * 1))"
  set "model_resident" "$((resident * 1))"

  # chart jol_llm.throughput (dimension divisor 1000 → keep 3 decimals)
  set "tokens_per_second" "$(printf '%.0f' "$(echo "${tps} * 1000" | bc)")"

  # chart jol_llm.queue
  set "queue_depth" "$(printf '%.0f' "$(echo "${queue} * 1000" | bc)")"
  return 0
}
