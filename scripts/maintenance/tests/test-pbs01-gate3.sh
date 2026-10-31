#!/usr/bin/env bash
# =============================================================================
# test-pbs01-gate3.sh — negative-control fixtures for pbs01-health-check.sh gate 3
#
# WHY THIS FILE EXISTS (finding F-5, issue #129): gate 3 read `pending-bytes` from
# `garbage-collection status` and alerted only above 50 GiB. That field is the tally OF THE
# LAST GC RUN, so on a datastore where GC has never completed it is structurally 0 even after
# prunes deleted groups (measured on pbs01 2026-10-31: prunes had already trimmed each VMID to
# 7 groups, and the payload still said pending-bytes 0 / removed-bytes 0 / upid null). The gate
# therefore printed "GC pending-bytes: 0 GiB" and the whole watchdog read GREEN — an absence of
# measurement rendered as a number. Same class as gate 10's dead branch and gate 13's
# decay-to-zero count, both of which were found the same way: by running a control that must fail.
#
# The gate text is EXTRACTED FROM THE SCRIPT UNDER TEST and sourced — never copied. A harness
# holding a copy drifts into proving nothing. Run it against the pre-fix file to see the red:
#   git show main:scripts/maintenance/pbs01-health-check.sh > /tmp/prefix.sh
#   ./test-pbs01-gate3.sh /tmp/prefix.sh      # MUST fail — every case has at least one
#                                            # assertion the pre-fix gate cannot satisfy
#   ./test-pbs01-gate3.sh                     # passes against the fixed script
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the gate could not be extracted.
# Read-only; writes only into its own mktemp workdir. No credentials, no host access.
# =============================================================================
set -uo pipefail

SRC="${1:-/opt/jol/repos/jol-infrastructure/scripts/maintenance/pbs01-health-check.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^# --- 3\. Garbage collection/,/^# --- 4\. Retention/' "$SRC" | sed '$d' >"$WORK/gate3.sh"
if [[ ! -s "$WORK/gate3.sh" ]]; then
    echo "FATAL: could not extract gate 3 from $SRC — the fixture is testing nothing" >&2
    exit 2
fi
echo "extracted $(grep -c '' "$WORK/gate3.sh") lines of gate 3 from $SRC"

# Fixtures: the exact JSON shapes measured on pbs01 (2026-10-31) plus the post-GC shapes
# that must be distinguishable from them.
cat >"$WORK/list_never" <<'J'
[{"duration":null,"last-run-endtime":null,"next-run":1794018600,"pending-bytes":0,
  "schedule":"sat 04:30","store":"pbs-store"}]
J
cat >"$WORK/list_never_nosched" <<'J'
[{"duration":null,"last-run-endtime":null,"next-run":null,"pending-bytes":0,
  "store":"pbs-store"}]
J
cat >"$WORK/list_ok_zero" <<'J'
[{"duration":12,"last-run-endtime":1793900000,"last-run-state":"OK","next-run":1794018600,
  "pending-bytes":0,"removed-bytes":7516192768,"schedule":"sat 04:30","store":"pbs-store"}]
J
cat >"$WORK/list_ok_big" <<'J'
[{"duration":40,"last-run-endtime":1793900000,"last-run-state":"OK","next-run":1794018600,
  "pending-bytes":64424509440,"removed-bytes":1073741824,"schedule":"sat 04:30","store":"pbs-store"}]
J
cat >"$WORK/status_zero" <<'J'
{"disk-bytes":0,"disk-chunks":0,"pending-bytes":0,"pending-chunks":0,"removed-bytes":0,
 "schedule":"sat 04:30","store":"pbs-store","upid":null}
J
cat >"$WORK/status_big" <<'J'
{"disk-bytes":100,"pending-bytes":64424509440,"pending-chunks":900,"removed-bytes":0,
 "schedule":"sat 04:30","store":"pbs-store","upid":null}
J

# Run the real gate text with a stubbed environment.
# $1=list fixture path (or "" to simulate an unreadable query)  $2=status fixture path
# SC2317: the stubs below are invoked only by the gate text sourced at the end of this
# function, which shellcheck cannot see across the `.` — they are reachable.
# shellcheck disable=SC2317
run_gate() {
    (
        ALERTS=0
        WARNS=0
        # DATASTORE and GC_PENDING_ALERT_G look unused for the same reason: the sourced gate
        # text is their only consumer. Bind them, do not delete them.
        # shellcheck disable=SC2034
        DATASTORE="pbs-store"
        # shellcheck disable=SC2034
        GC_PENDING_ALERT_G=50
        alert() { ALERTS=$((ALERTS + 1)); printf 'CRITICAL: %s\n' "$1"; }
        warn()  { WARNS=$((WARNS + 1));  printf 'WARN: %s\n' "$1"; }
        info()  { printf 'INFO: %s\n' "$1"; }
        have()  { [ "$1" = "proxmox-backup-manager" ]; }
        probe_missing() { alert "probe unavailable: $1"; }
        proxmox-backup-manager() {
            case "$*" in
                *"collection list"*)   [ -n "$LIST_FIXTURE" ] && cat "$LIST_FIXTURE" ;;
                *"collection status"*) cat "$STATUS_FIXTURE" ;;
            esac
        }
        export LIST_FIXTURE="$1" STATUS_FIXTURE="$2"
        # SC1091: the gate text is generated in a mktemp dir at runtime, so no path
        # resolvable at lint time exists. (A continuation comment must never begin
        # with the literal `# shellcheck` — it is parsed as a directive.)
        # shellcheck disable=SC1090,SC1091
        . "$WORK/gate3.sh"
        echo "alerts=$ALERTS warns=$WARNS"
    )
}

pass=0
fail=0
report_ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"
}

expect_text() { # $1=label $2=required substring $3=output
    if grep -qF -- "$2" <<<"$3"; then report_ok "$1"; else report_bad "$1" "$2" "$3"; fi
}
expect_absent() { # $1=label $2=forbidden substring $3=output
    if grep -qF -- "$2" <<<"$3"; then report_bad "$1" "no '$2'" "found '$2'"; else report_ok "$1"; fi
}
expect_counts() { # $1=label $2="alerts=N warns=M" $3=output
    local got
    got="$(grep -oE 'alerts=[0-9]+ warns=[0-9]+' <<<"$3" | tail -1)"
    if [[ "$got" == "$2" ]]; then report_ok "$1 ($got)"; else report_bad "$1" "$2" "${got:-none}"; fi
}

echo "--- 1 (THE F-5 CONTROL): never-run GC must NOT be reported as '0 GiB' health"
OUT1="$(run_gate "$WORK/list_never" "$WORK/status_zero")"
expect_text 'never ran -> says no GC has EVER run' 'has EVER run' "$OUT1"
expect_absent 'never ran -> does not present pending-bytes as a measurement' 'pending-bytes: 0 GiB' "$OUT1"
expect_counts 'never ran -> WARN only, no CRITICAL' 'alerts=0 warns=1' "$OUT1"

echo "--- 2 (NEGATIVE CONTROL): an unreadable list must be CRITICAL, not 'NOT scheduled'"
OUT2="$(run_gate "" "$WORK/status_zero")"
expect_text 'unreadable list -> UNVERIFIED' 'cannot read garbage-collection list' "$OUT2"
expect_absent 'unreadable list -> never claims an unscheduled datastore' 'is NOT scheduled' "$OUT2"
expect_counts 'unreadable list -> CRITICAL' 'alerts=1 warns=0' "$OUT2"

echo "--- 3: a REAL GC run with nothing pending stays green and says so"
OUT3="$(run_gate "$WORK/list_ok_zero" "$WORK/status_zero")"
expect_text 'ran OK -> reports the state beside the number' 'last-run-state=OK; pending-bytes: 0 GiB' "$OUT3"
expect_absent 'ran OK -> no bogus "never ran" warning' 'has EVER run' "$OUT3"
expect_counts 'ran OK -> clean' 'alerts=0 warns=0' "$OUT3"

echo "--- 4: orphan growth above the cap still fires, now naming the last run"
OUT4="$(run_gate "$WORK/list_ok_big" "$WORK/status_big")"
expect_text '60 GiB pending -> CRITICAL' '60 GiB of orphaned chunks pending GC' "$OUT4"
expect_text 'and it cites the last run' 'last run: OK' "$OUT4"
expect_counts '60 GiB pending -> CRITICAL' 'alerts=1 warns=0' "$OUT4"

echo "--- 5: unscheduled AND never-run are two separate statements, both shown"
OUT5="$(run_gate "$WORK/list_never_nosched" "$WORK/status_zero")"
expect_text 'no schedule -> NOT scheduled warn' 'garbage collection is NOT scheduled' "$OUT5"
expect_text 'and still says no GC has EVER run' 'has EVER run' "$OUT5"
expect_counts 'two warnings, zero criticals' 'alerts=0 warns=2' "$OUT5"

echo
echo "gate-3 fixtures: $pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
