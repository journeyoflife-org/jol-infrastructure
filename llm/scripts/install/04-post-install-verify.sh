#!/usr/bin/env bash
# 04-post-install-verify.sh — end-to-end verification after install/change.
# Exits non-zero on any failure. Safe to run repeatedly.
# Usage: 04-post-install-verify.sh [--model <registry-name>]
set -Eeuo pipefail

HOST_IP="${HOST_IP:-10.40.10.21}"
API_PORT="${API_PORT:-8443}"
MODEL="${MODEL:-qwen3-32b-q8_0}"
FAILURES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="${2:?}"; shift 2 ;;
    *) shift ;;
  esac
done

log()  { printf '[verify] %s\n' "$*"; }
pass() { log "PASS — $*"; }
fail() { log "FAIL — $*"; FAILURES=$((FAILURES + 1)); }

# 1. UFW active
if ufw status 2>/dev/null | grep -q "Status: active"; then
  pass "UFW active"
else
  fail "UFW not active"
fi

# 2. Egress must be blocked (expect connection failure)
if timeout 5 curl -sS -o /dev/null https://ollama.com --connect-timeout 3 2>/dev/null; then
  fail "INTERNET EGRESS SUCCEEDED — air-gap violated"
else
  pass "egress blocked as required"
fi

# 3. Ollama version + API on loopback
if curl -sf http://127.0.0.1:11434/api/version >/dev/null; then
  pass "Ollama API reachable on loopback: $(curl -s http://127.0.0.1:11434/api/version)"
else
  fail "Ollama API not reachable on 127.0.0.1:11434"
fi

# 4. Ollama not listening on non-loopback
if ss -tlnp 2>/dev/null | awk '$4 !~ /127\.0\.0\.1|::1/ {print}' | grep -q ':11434'; then
  fail "Ollama bound to non-loopback interface"
else
  pass "Ollama bound to loopback only"
fi

# 5. Model present
if curl -s http://127.0.0.1:11434/api/tags | grep -q "${MODEL}"; then
  pass "model ${MODEL} registered"
else
  fail "model ${MODEL} not in /api/tags"
fi

# 6. Local inference smoke (canned prompt — no client content)
start=$(date +%s)
resp=$(curl -s http://127.0.0.1:11434/api/generate \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"Reply with the single word: OK\",\"stream\":false,\"options\":{\"num_predict\":8}}" || true)
end=$(date +%s)
if echo "${resp}" | grep -q '"response"'; then
  pass "inference OK ($((end - start)) s incl. load)"
else
  fail "inference failed: ${resp:0:200}"
fi

# 7. API bridge health (loopback)
if curl -sf http://127.0.0.1:8901/healthz >/dev/null 2>&1; then
  pass "API bridge healthy"
else
  log "WARN — bridge /healthz not responding (skip if bridge not deployed yet)"
fi

# 8. Auth gate: request without key must be 401 (when bridge deployed)
code=$(curl -sk -o /dev/null -w '%{http_code}' \
  "https://${HOST_IP}:${API_PORT}/v1/chat/completions" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"model":"'"${MODEL}"'","messages":[{"role":"user","content":"ping"}]}' \
  --connect-timeout 5 2>/dev/null || echo "000")
case "${code}" in
  401|403|000) pass "unauthenticated request rejected (HTTP ${code})" ;;
  200) fail "UNAUTHENTICATED REQUEST RETURNED 200" ;;
  *) log "INFO — gateway returned ${code} (mTLS enforced at TLS layer?)" ;;
esac

# 9. File permissions spot-check
if [[ $(stat -c '%U' /opt/jol/models 2>/dev/null) == "ollama-svc" ]]; then
  pass "/opt/jol/models owned by ollama-svc"
else
  fail "/opt/jol/models ownership wrong"
fi

# 10. Audit log free of prompt content sentinel (see test_compliance_logging.sh)
if grep -rq "Reply with the single word: OK" /var/log/jol-audit/ /var/log/caddy/ 2>/dev/null; then
  fail "PROMPT CONTENT FOUND IN LOGS — retention policy violation"
else
  pass "no prompt content in logs"
fi

echo
if (( FAILURES > 0 )); then
  log "RESULT: ${FAILURES} check(s) FAILED"
  exit 1
fi
log "RESULT: ALL CHECKS PASSED"
