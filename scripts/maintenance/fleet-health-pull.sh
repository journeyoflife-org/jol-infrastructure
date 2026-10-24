#!/usr/bin/env bash
# =============================================================================
# fleet-health-pull.sh — operator-workstation alert PULL (layer 3 of 3)
#
# WHY: the fleet's push transport is PROVEN DEAD — PVE's only notification target
# (`mail-to-root`) bounces at Gmail with `550-5.7.1 The IP … is not authorized`
# (measured 2026-10-23T19:43Z, evidence §21b), and pbs01 has no monitoring path at
# all (its node_exporter is unscrapeable). Until a push channel with credentials is
# configured (runbook §7.2 — Telegram is the recommended fix), this is the layer
# that needs NO secret and uses only the SSH keys already in ~/.ssh/config.
#
# WHAT IT DOES: runs each host's own watchdog over SSH and raises a desktop
# notification + local log line when any of them reports CRITICAL.
#
# FAILURE MODES DESIGNED FOR (the two ways silent monitoring dies):
#   1. A host that cannot be reached is an ALERT, never a silent pass — an
#      unreachable monitor is indistinguishable from a healthy one if you treat
#      missing data as good data (this is exactly the class that hid hv01's inert
#      vzdump job for 10 weeks and pbs01's dead chrony peer).
#   2. A watchdog that returns rc=0 WITHOUT having evaluated its gates is not
#      trusted: gate coverage is sanity-checked by requiring the "HEALTH CHECK
#      COMPLETE" line in stdout (the 2026-10-23 `/cluster/tasks` bug produced a
#      permanent false CRITICAL *and* a dead staleness branch at the same time —
#      both directions must be provable).
#
# NOTIFICATION POLICY (added same day, after the first live run): notify on CHANGE of
# the alert SET, not on every run — a sticky critical stays in the log every 15 min but
# only pops once, because 96 identical dialogs a day train the operator to ignore the
# one that matters. Recovery is announced too, so "fixed" is distinguishable from
# "the monitor stopped". Digits are masked in the signature (bounce count 81 -> 82 is
# the same failure).
#
# Read-only on the remote hosts apart from their own watchdog log files.
# Exit: 0 = all hosts healthy, 1 = at least one alert or unreachable host.
# =============================================================================
set -uo pipefail

SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=12 -o ServerAliveInterval=5}"
LOG_DIR="${LOG_DIR:-$HOME/.local/share/jol-fleet-health}"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/pull.log"
STATE="$LOG_DIR/state"           # last known-GREEN run per host -> age shown on every alert
SIG_FILE="$LOG_DIR/last-alert-signature"
NOTIFY="${NOTIFY:-1}"
ONLY="${ONLY:-}"                 # optional: run one host alias only (proof/triage)

# host alias (from ~/.ssh/config) : remote command
TARGETS=(
    "pve|sudo /usr/local/bin/jol-health-check.sh"
    "pbs01|/usr/local/bin/jol-pbs01-health-check.sh"
)

FAILURES=0
NOTES=""
FAIL_SIGS=""

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }

# Desktop notification, decoupled from its own transport: a missing/broken notify-send
# is recorded, never swallowed — otherwise this script would fail silently, the exact
# defect it exists to detect.
push_note() {
    [[ "$NOTIFY" == "1" ]] || return 0
    command -v notify-send >/dev/null 2>&1 || { log "notify-send absent — desktop transport unavailable"; return 0; }
    notify-send -u "$1" -t 0 "$2" "$3" 2>/dev/null || log "notify-send failed — desktop transport also dead"
}

# How long has this host been NOT green? An alert that cannot be triaged by age is
# usually ignored. `never` is honest: it means this host has never passed a pull.
last_ok_age() {
    local f="$STATE.$1" ts age
    [[ -r "$f" ]] || { printf 'never'; return; }
    ts="$(date -u -d "$(cat "$f")" +%s 2>/dev/null || echo '')"
    [[ -n "$ts" ]] || { printf 'unreadable'; return; }
    age=$(( ($(date -u +%s) - ts) / 3600 ))
    printf '%s h ago' "$age"
}

for target in "${TARGETS[@]}"; do
    host="${target%%|*}"
    cmd="${target#*|}"
    [[ -z "$ONLY" || "$host" == "$ONLY" ]] || continue
    # Word-split the options deliberately and safely — no eval (an eval-built ssh
    # command line is an injection habit, and the remote command must stay ONE arg).
    read -r -a ssh_args <<< "$SSH_OPTS"
    # SC2029: the client-side expansion here is intentional and inert — every $cmd is a
    # fixed literal defined in TARGETS ("sudo /usr/local/bin/jol-…-check.sh"), containing
    # no client variables. It must arrive at the far side as one unparsed string so the
    # REMOTE shell resolves it (and its `sudo`). Do not "fix" this by quoting it further:
    # ssh takes everything after the hostname as the remote command, verbatim.
    # shellcheck disable=SC2029
    out="$(ssh "${ssh_args[@]}" "$host" "$cmd" 2>&1)"
    rc=$?
    if [[ $rc -eq 255 ]]; then
        # ssh's own failure code: transport/auth/DNS — NOT a healthy host.
        log "ALERT ${host}: unreachable or SSH failed (rc=255) — monitoring blind, not green (last OK: $(last_ok_age "$host"))"
        NOTES="${NOTES}${host}: unreachable (SSH rc=255), last OK $(last_ok_age "$host")\n"
        FAIL_SIGS="${FAIL_SIGS}${host}|transport-dead;"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    if ! printf '%s' "$out" | grep -q "HEALTH CHECK COMPLETE"; then
        log "ALERT ${host}: watchdog produced no completion marker (rc=$rc) — gate coverage UNVERIFIED (last OK: $(last_ok_age "$host"))"
        NOTES="${NOTES}${host}: watchdog completion marker missing\n"
        FAIL_SIGS="${FAIL_SIGS}${host}|no-completion-marker;"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    if [[ $rc -ne 0 ]]; then
        criticals="$(printf '%s' "$out" | grep -E 'CRITICAL' | sed 's/^\[[^]]*\] *//' | head -4)"
        n="$(printf '%s' "$out" | grep -cE 'CRITICAL')"
        log "ALERT ${host}: ${n} CRITICAL(s) (last OK: $(last_ok_age "$host"))"
        printf '%s\n' "$criticals" | tee -a "$LOG"
        NOTES="${NOTES}${host}: ${n} CRITICAL, last OK $(last_ok_age "$host") — $(printf '%s' "$criticals" | head -1 | cut -c1-90)\n"
        # Signature = gate identity, NOT the full text: digits are masked so a bounce
        # count ticking 81 -> 82 is the SAME problem, not a new one to notify about.
        FAIL_SIGS="${FAIL_SIGS}${host}|$(printf '%s' "$criticals" | sed -E 's/[0-9]+/N/g' | tr '\n;' '  ')"
        FAIL_SIGS="${FAIL_SIGS};"
        FAILURES=$((FAILURES + 1))
    else
        log "OK   ${host}: all gates pass"
        printf '%s\n' "$(date -u +%FT%TZ)" >"$STATE.$host"
    fi
done

if (( FAILURES > 0 )); then
    log "=== fleet health: ${FAILURES} host(s) need attention ==="
    # Notify on CHANGE only. A sticky critical must be impossible to forget but also
    # impossible to tune out: 96 identical pop-ups a day train the operator to ignore
    # the one that matters. Every run is still logged (evidence, CC7.2).
    if [[ "$FAIL_SIGS" != "$(cat "$SIG_FILE" 2>/dev/null || echo '')" ]]; then
        printf '%s\n' "$FAIL_SIGS" >"$SIG_FILE"
        push_note critical "JOL fleet health — ${FAILURES} alert(s)" "$(printf '%b' "$NOTES")"
    else
        log "same alert set as already notified — desktop notification suppressed (log still records this run)"
    fi
    exit 1
fi
if [[ -n "$ONLY" ]]; then
    # A subset run must never claim a fleet-wide result (280544fa-class honesty).
    log "=== fleet health: ${ONLY} OK — SUBSET ONLY, not a fleet-wide green (ONLY=$ONLY) ==="
    exit 0
fi
log "=== fleet health: all hosts OK ==="
# Recovery must be as loud as failure: without it the operator cannot tell "fixed"
# from "the monitor stopped".
if [[ -s "$SIG_FILE" ]]; then
    log "RECOVERED — alert set $(cat "$SIG_FILE") cleared"
    rm -f "$SIG_FILE"
    push_note normal "JOL fleet health — recovered" "All watchdog gates green (previous alert set cleared)."
fi
exit 0
