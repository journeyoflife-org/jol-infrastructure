#!/usr/bin/env bash
# =============================================================================
# hv01-verify-alert-transport.sh — PROVE that a failure alert can leave the host
#
# WHY: watchdog gate 13 counts bounced/deferred mail, and that count DECAYS to zero
# whenever nothing is failing (no failing job ⇒ no mail ⇒ no bounce). A quiet fleet
# would therefore read "alert transport OK" without a single test ever having run.
# Absence of failure is not presence of success, so gate 13 additionally requires a
# POSITIVE PROOF RECORD written by this script, and this script only writes one after
# postfix reports an OUTWARD `status=sent` for a message this script injected.
#
# WHAT IT DOES (all on hv01, as root):
#   1. reads root@pam's configured notification address from PVE (never printed);
#   2. injects one probe mail with a unique envelope sender (the nonce is how the
#      queue id is found in the journal — postfix does not log subjects);
#   3. waits for that queue id's delivery record and classifies it:
#        status=sent + relay != local  -> PASS  (proof record written)
#        status=bounced                -> FAIL  (no proof record; reason printed)
#        no record / still deferred    -> UNVERIFIED (no proof record)
#
# Exit: 0 PASS, 1 FAIL, 2 guard (wrong host / not root), 3 UNVERIFIED.
# Side effects: ONE outbound mail attempt (it bounces today — that is the finding),
# and `/var/lib/jol-hv01/alert-transport-proof` (600) on PASS only.
# Usage: sudo /usr/local/bin/jol-verify-alert-transport [--clear]
# =============================================================================
set -uo pipefail
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

PROOF_FILE="${PROOF_FILE:-/var/lib/jol-hv01/alert-transport-proof}"
WAIT_SECS="${WAIT_SECS:-90}"
SUBJECT="JOL alert-transport proof probe (automated, no action needed)"

# --- guards ------------------------------------------------------------------
if [[ "$(hostname -s)" != "pve-prod-hv01" && "$(hostname)" != "pve-prod-hv01" ]]; then
    printf 'ABORT: this script tests the mail transport of pve-prod-hv01 and must run there (this host is %s).\n' "$(hostname)" >&2
    exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ABORT: needs root (reads the postfix journal and PVE user config)." >&2
    exit 2
fi
for bin in pvesh sendmail journalctl; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ABORT: $bin not found — cannot test the transport." >&2; exit 2; }
done

if [[ "${1:-}" == "--clear" ]]; then
    rm -f "$PROOF_FILE" && echo "Cleared proof record: $PROOF_FILE (gate 13 will now report NEVER VERIFIED)."
    exit 0
fi

# --- 1. recipient (never echoed) ---------------------------------------------
RECIPIENT="$(pvesh get /access/users/root@pam --output-format json 2>/dev/null |
    grep -o '"email":"[^"]*"' | head -1 | cut -d'"' -f4)"
if [[ -z "$RECIPIENT" ]]; then
    echo "FAIL: root@pam has no email configured — PVE has nowhere to send a failure alert at all." >&2
    echo "      Set it (Datacenter → Permissions → Users → root@pam) and re-run. No proof written." >&2
    exit 1
fi
printf 'Recipient: SET (%d chars, value not displayed)\n' "${#RECIPIENT}"

# --- 2. inject the probe ------------------------------------------------------
NONCE="jolproof$(date +%s)$$"
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
# `sendmail -i` reads the message from stdin; nothing secret crosses argv, and the
# nonce in the envelope sender is the only handle postfix logs.
if ! printf 'From: Proxmox Backup Monitor <%s>\nTo: %s\nSubject: %s\n\nAutomated end-to-end test of the failure-alert transport (runbook §7.2). This message carries no data.\n' \
        "backup-monitor@pve.prod.lt9" "$RECIPIENT" "$SUBJECT" |
        sendmail -i -f "$NONCE@pve.prod.lt9" "$RECIPIENT"; then
    echo "FAIL: sendmail rejected the injection — the local mail path itself is broken." >&2
    exit 1
fi
echo "Injected probe (envelope sender ${NONCE}@…, local time ${START_TS}). Waiting up to ${WAIT_SECS}s for the delivery record…"

# --- 3. read the outcome ------------------------------------------------------
QUEUE_ID=""
OUTCOME=""
deadline=$(( $(date +%s) + WAIT_SECS ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$QUEUE_ID" ]]; then
        QUEUE_ID="$(journalctl -u postfix --since "$START_TS" --no-pager 2>/dev/null |
            grep -F "$NONCE" | grep -oE '^[A-Za-z]{3} [0-9]{2} [0-9:]{8} .* postfix/[a-z]+\[[0-9]+\]: [0-9A-F]+: from=<' |
            grep -oE '[0-9A-F]{10,14}: from=<$' | cut -d: -f1 | head -1)"
        [[ -n "$QUEUE_ID" ]] && echo "Queue id: $QUEUE_ID"
    else
        OUTCOME="$(journalctl -u postfix --since "$START_TS" --no-pager 2>/dev/null |
            grep -E "^.* postfix/smtp(\[[0-9]+\])?: ${QUEUE_ID}: .*status=" | tail -1)"
        [[ -n "$OUTCOME" ]] && break
    fi
    sleep 3
done

if [[ -z "$QUEUE_ID" ]]; then
    echo "UNVERIFIED: postfix never logged the probe in ${WAIT_SECS}s — the message may still be queued."
    echo "Check: sudo mailq ; no proof record written." >&2
    exit 3
fi
if [[ -z "$OUTCOME" ]]; then
    echo "UNVERIFIED: queue id ${QUEUE_ID} has no delivery record yet (deferred/retrying)."
    echo "Check later: sudo journalctl -u postfix | grep ${QUEUE_ID} ; no proof record written." >&2
    exit 3
fi

STATUS="$(printf '%s' "$OUTCOME" | grep -oE 'status=[a-z]+' | cut -d= -f2)"
RELAY="$(printf '%s' "$OUTCOME"  | grep -oE 'relay=[^,]+' | head -1 | cut -d= -f2-)"
echo "Delivery record: status=${STATUS} relay=${RELAY:-?}"
printf '%s\n' "$OUTCOME" | grep -oE 'dsn=[0-9.]+|status=[a-z]+ \(.*' | head -2

case "$STATUS" in
    sent)
        case "$RELAY" in
            local*|none*|"")
                echo "FAIL: delivered only to a LOCAL/internal relay — that is the PVE forwarder hop," >&2
                echo "      not proof that an alert reached an address off this host. No proof written." >&2
                exit 1 ;;
        esac
        mkdir -p "$(dirname "$PROOF_FILE")"
        chmod 700 "$(dirname "$PROOF_FILE")" 2>/dev/null || true
        printf 'PASS utc=%s host=%s queue=%s relay=%s\n' "$(date -u +%FT%TZ)" "$(hostname)" \
            "$QUEUE_ID" "${RELAY%%[*]}" >"$PROOF_FILE"
        chmod 600 "$PROOF_FILE"
        echo "PASS: outward delivery proven. Proof record: $(cat "$PROOF_FILE")"
        echo "      gate 13 now reads this file; it expires after TRANSPORT_PROOF_MAX_AGE_DAYS (default 7)."
        exit 0 ;;
    bounced)
        echo "FAIL: the probe BOUNCED — failure alerts reach nobody. No proof record written." >&2
        exit 1 ;;
    deferred)
        echo "FAIL(deferred): outbound delivery not completed (relay unreachable). No proof record written." >&2
        exit 1 ;;
    *)
        echo "UNVERIFIED: unexpected delivery status '${STATUS}'. No proof record written." >&2
        exit 3 ;;
esac
