#!/usr/bin/env bash
# audit-review.sh — parse auditd logs for anomalies on the LLM host.
# Read-only; output is a human review sheet. Run weekly (or on demand).
set -Eeuo pipefail

SINCE="${1:-$(date -u -d '7 days ago' +%Y-%m-%d)}"
OUT="/tmp/audit-review-$(date -u +%Y%m%d-%H%M%S).txt"

log() { printf '[audit-review] %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

{
  echo "=== JOL audit review — since ${SINCE} (host: $(hostname)) ==="

  echo; echo "## Writes to the model store (expected: imports only)"
  ausearch -k jol_models_write --start "$(date -d "${SINCE}" +%m/%d/%Y)" -i 2>/dev/null \
    | grep -E 'type=(SYSCALL|PATH)' | awk '{print $1, $3, $5}' | sort | uniq -c | sort -rn | head -25

  echo; echo "## Ollama binary changes (expected: updates only)"
  ausearch -k jol_binary_change -i 2>/dev/null | tail -20

  echo; echo "## Keystore access (each read should map to a service start)"
  ausearch -k jol_keystore -i 2>/dev/null | tail -20

  echo; echo "## Audit config tampering attempts (must be empty)"
  ausearch -k jol_audit_config -i 2>/dev/null | tail -20

  echo; echo "## sudo usage summary"
  ausearch -m USER_CMD --start "$(date -d "${SINCE}" +%m/%d/%Y)" -i 2>/dev/null \
    | grep -oP 'cmd=\K.*' | sort | uniq -c | sort -rn | head -15

  echo; echo "## Failed auth attempts"
  aureport --auth --failed --summary -i 2>/dev/null

  echo; echo "## Files changed outside AIDE baseline"
  tail -40 /var/log/jol-audit/aide-check.log 2>/dev/null | grep -E '^(Changed|Added|Removed)' | head -30
} > "${OUT}"

log "review sheet written: ${OUT}"
log "action: review each section; any unexpected write to the model store"
log "        or keystore is a SEV3 (incident-response.md §3)."
