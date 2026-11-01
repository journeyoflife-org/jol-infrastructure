#!/usr/bin/env bash
# =============================================================================
# test-hv01-gate13.sh — negative-control fixtures for hv01-health-check.sh gate 13
#
# WHY THIS FILE EXISTS: gate 13 was three times found to be wrong in ways its own
# verdict could not show. (1) It counted the alert VERIFIER'S OWN bounce, so one probe
# mail inflated "N message(s)" by one. (2) Its "cannot read the journal" branch was
# DEAD CODE — `grep -c` always prints a number, so a failed journalctl read as
# "transport fine". (3) It counted DELIVERY RECORDS, so one message retried for hours
# read as a dozen failing alerts (measured 2026-10-25: 14 records = 3 messages).
# All three are the silent-pass class this repo keeps hitting (gate 10's dead
# branch), and none is visible by running the watchdog: only a fixture that MUST
# fail proves the branch. CI lints every scripts/**.sh with shellcheck, so this file
# is part of the gate's evidence, not a scratch pad.
#
# The gate text is EXTRACTED FROM THE SCRIPT UNDER TEST and sourced — never copied.
# A harness holding a copy drifts into proving nothing.
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the gate could not be extracted.
# Read-only; writes only into its own mktemp workdir. No credentials, no host access.
# =============================================================================
set -uo pipefail

# Path resolved from THIS file, not a hard-coded workstation path: `make test-gates` runs the
# fixtures in CI, where /opt/jol/repos/... does not exist (measured on PR #141: the job died
# with `FATAL: /opt/jol/repos/jol-infrastructure/scripts/maintenance/hv01-config-backup.sh not found`).
MAINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$MAINT_DIR/hv01-health-check.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^# --- 13\. Alert transport liveness/,/^info "=== HEALTH CHECK COMPLETE/' "$SRC" |
    sed '$d' >"$WORK/gate13.sh"
if [[ ! -s "$WORK/gate13.sh" ]]; then
    echo "FATAL: could not extract gate 13 from $SRC — the fixture is testing nothing" >&2
    exit 2
fi
echo "extracted $(grep -c '' "$WORK/gate13.sh") lines of gate 13 from $SRC"

# Fixtures: the exact journal shapes measured on pve-prod-hv01, 2026-10-24.
printf '%s\n' 'Oct 24 15:38:08 pve postfix/local[3117340]: 7E5F3321572: to=<jolproof1@pve.prod.lt9>, relay=local, delay=0.01, dsn=5.1.1, status=bounced (unknown user: "jolproof1")' >"$WORK/f_probe_only"
: >"$WORK/f_empty"
printf '%s\n' 'Oct 24 15:38:12 pve postfix/smtp[3117341]: 8E54B321566: to=<a@gmail.com>, relay=gmail-smtp-in.l.google.com[172.253.148.26]:25, delay=1.1, dsn=5.7.1, status=bounced (host said: 550-5.7.1 not authorized)' >"$WORK/f_outward"
printf '%s\n' 'Oct 24 15:38:12 pve postfix/smtp[3117341]: 9A11B223344: to=<a@gmail.com>, relay=none, delay=32, dsn=4.4.1, status=deferred (connect to alt2.gmail-smtp-in.l.google.com[142.251.10.27]:25: Connection timed out)' >"$WORK/f_deferred"
cat "$WORK/f_probe_only" "$WORK/f_outward" "$WORK/f_deferred" >"$WORK/f_mixed"
# f_churn: the shape measured on pve-prod-hv01 on 2026-10-25 — ONE deferred message
# (queue 70268321566) writing one delivery record per retry attempt, 12 of them.
: >"$WORK/f_churn"
for i in $(seq 1 12); do
    printf '%s\n' "Oct 25 0${i}:05:47 pve postfix/smtp[339258${i}]: 70268321566: to=<a@gmail.com>, relay=none, delay=$((60 * i)), dsn=4.4.1, status=deferred (connect to alt2.gmail-smtp-in.l.google.com[142.251.10.27]:25: Connection timed out)" >>"$WORK/f_churn"
done
# f_noparse: a status= record whose queue id the gate's pattern cannot read. If the
# collapse silently dropped it, the gate would under-report its own failure signal.
printf '%s\n' 'Oct 25 06:01:06 pve postfix/smtp[3392583]: unusual format with no queue id, to=<a@gmail.com>, relay=gmail-smtp-in.l.google.com[142.251.10.27]:25, dsn=5.7.26, status=bounced (sender unauthenticated)' >"$WORK/f_noparse"

# Run the real gate text with a stubbed environment.
# $1=journal fixture  $2=journalctl exit status  $3=proof content ('' = absent)
# $4=days to backdate the proof record (empty = leave it at now)
# SC2317: every stub below is invoked only by the gate text sourced at the end of
# this function, which shellcheck cannot see across the `.` — they are reachable.
# shellcheck disable=SC2317
run_gate() {
    (
        ALERTS=0
        # LOG and TRANSPORT_PROOF_MAX_AGE_DAYS look unused for the same reason: the
        # sourced gate is their only consumer. Bind them, do not delete them.
        # shellcheck disable=SC2034
        LOG="$WORK/log"
        # One proof path PER CALL, seeded only by this call. Sharing a single path
        # across cases let an earlier case's fresh proof satisfy a later case that
        # asserted 'no proof record' — it passed for the wrong reason, and a control
        # that cannot fail is not a control.
        PROOF_FILE="$WORK/proof.$BASHPID"
        rm -f "$PROOF_FILE"
        # shellcheck disable=SC2034
        TRANSPORT_PROOF_MAX_AGE_DAYS=7
        alert() { ALERTS=$((ALERTS + 1)); printf 'CRITICAL: %s\n' "$1"; }
        info() { :; }
        have() { command -v "$1" >/dev/null 2>&1; }
        probe_missing() { alert "probe unavailable: $1"; }
        journalctl() { cat "$JOURNAL_FIXTURE"; return "$JOURNAL_RC"; }
        export JOURNAL_FIXTURE="$1" JOURNAL_RC="$2"
        if [[ -n "$3" ]]; then
            printf '%s\n' "$3" >"$PROOF_FILE"
            if [[ -n "${4:-}" ]]; then
                touch -d "-${4} days" "$PROOF_FILE"
            fi
        fi
        # SC1091: the gate text is generated in a mktemp dir at runtime, so no path
        # resolvable at lint time exists. (A continuation comment must never begin
        # with the literal `# shellcheck` — it is parsed as a directive.)
        # shellcheck disable=SC1090,SC1091
        . "$WORK/gate13.sh"
        echo "alerts=$ALERTS"
    )
}

pass=0
fail=0
report_ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"
}

# Assert on the COUNT, not the sentence. The fix also rewords the alert, and a
# before/after comparison that differs only in wording proves nothing about behaviour.
expect_count() { # $1=label $2=expected count ('none' = no transport alert) $3=output
    local got
    got="$(grep -oE 'BROKEN: [0-9]+' <<<"$3" | grep -oE '[0-9]+' || true)"
    if [[ "$2" == none ]]; then
        if [[ -z "$got" ]]; then report_ok "$1"; else report_bad "$1" 'no transport alert' "counted $got"; fi
    elif [[ "$got" == "$2" ]]; then
        report_ok "$1 (count=$got)"
    else
        report_bad "$1" "count $2" "count ${got:-none}"
    fi
}

expect_text() { # $1=label $2=required substring $3=output
    if grep -qF -- "$2" <<<"$3"; then report_ok "$1"; else report_bad "$1" "$2" "$3"; fi
}

FRESH="PASS utc=2026-10-24T00:00:00Z host=pve queue=ABC relay=gmail-smtp-in.l.google.com:25"

echo "--- 1: the verifier's own relay=local bounce is not a transport failure"
expect_count 'probe-only journal -> counted nothing' none "$(run_gate "$WORK/f_probe_only" 0 "$FRESH")"

echo "--- 2 (NEGATIVE CONTROL): a real outward bounce must still fire"
expect_count 'outward gmail bounce -> counted' 1 "$(run_gate "$WORK/f_outward" 0 '')"

echo "--- 3: the :25 timeout class (relay=none, deferred) still counts as a failure"
expect_count 'relay=none deferred -> counted' 1 "$(run_gate "$WORK/f_deferred" 0 '')"

echo "--- 4 (NEGATIVE CONTROL): an unreadable journal must NOT read as healthy"
expect_text 'journalctl rc=1 -> UNVERIFIED' 'cannot read the postfix journal' \
    "$(run_gate "$WORK/f_empty" 1 "$FRESH")"

echo "--- 5: a quiet-but-readable journal is zero failures, not 'unverifiable'"
expect_count 'rc=0 + empty journal -> counted nothing' none "$(run_gate "$WORK/f_empty" 0 "$FRESH")"

echo "--- 6: mixed journal counts outward records only (2, not 3)"
expect_count 'mixed probe+outward+deferred -> outward only' 2 "$(run_gate "$WORK/f_mixed" 0 "$FRESH")"

echo "--- 7 (NEGATIVE CONTROL): no proof record stays red even with zero bounces"
expect_text 'no proof -> NEVER VERIFIED' 'alert transport NEVER VERIFIED' \
    "$(run_gate "$WORK/f_empty" 0 '')"

echo "--- 8 (NEGATIVE CONTROL): a stale proof record is reported, not honoured"
expect_text 'stale proof -> STALE' 'proof is STALE' "$(run_gate "$WORK/f_empty" 0 "$FRESH" 30)"

echo "--- 9: retry churn is ONE stuck message, not twelve"
CHURN_OUT="$(run_gate "$WORK/f_churn" 0 '')"
expect_count '12 retries of one queue id -> 1 message' 1 "$CHURN_OUT"
expect_text 'and the collapsed count names the record total' '12 delivery records' "$CHURN_OUT"

echo "--- 10 (NEGATIVE CONTROL): a record with no readable queue id must still alert"
expect_count 'unparseable record -> falls back to the record count' 1 "$(run_gate "$WORK/f_noparse" 0 '')"

echo
echo "gate-13 fixtures: $pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
