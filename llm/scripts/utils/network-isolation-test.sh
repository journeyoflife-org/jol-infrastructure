#!/usr/bin/env bash
# network-isolation-test.sh — assert the air-gap from the inside.
# All probes MUST fail; any success is a firewall regression (exit 1).
set -Eeuo pipefail

FAIL=0
log() { printf '[netiso] %s\n' "$*"; }
pass() { log "PASS — $*"; }
fail() { log "FAIL — $*"; FAIL=1; }

# Targets that LLM runtimes commonly phone home to.
PROBE_HOSTS=(
  ollama.com
  registry.ollama.ai
  huggingface.co
  api.openai.com
  telemetry.example.com
)

# 1. DNS resolution must fail for external names (internal resolver has
#    no route; if it resolves, the resolver itself is a leak).
for h in "${PROBE_HOSTS[@]}"; do
  if getent hosts "${h}" >/dev/null 2>&1; then
    fail "DNS resolved ${h} — external resolver leak"
  else
    pass "DNS blocked: ${h}"
  fi
done

# 2. Direct TCP attempts to well-known IPs (bypass DNS entirely).
for target in "1.1.1.1:443" "8.8.8.8:53" "104.16.0.1:443"; do
  ip="${target%%:*}"; port="${target##*:}"
  if timeout 3 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
    exec 3>&- 3<&- 2>/dev/null || true
    fail "TCP connect succeeded to ${target} — egress open!"
  else
    pass "TCP blocked: ${target}"
  fi
done

# 3. Default route sanity: gateway may exist but must not NAT us out.
log "default route: $(ip route show default 2>/dev/null || echo none)"

# 4. Loopback services must still be reachable (no over-blocking).
if curl -sf --max-time 5 http://127.0.0.1:11434/api/version >/dev/null; then
  pass "loopback Ollama reachable"
else
  fail "loopback Ollama unreachable — firewall over-block"
fi

echo
if (( FAIL )); then
  log "RESULT: ISOLATION VIOLATED — investigate before serving traffic"
  exit 1
fi
log "RESULT: host is correctly isolated"
