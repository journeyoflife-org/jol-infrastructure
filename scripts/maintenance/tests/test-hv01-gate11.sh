#!/usr/bin/env bash
# =============================================================================
# test-hv01-gate11.sh — negative-control fixtures for hv01-health-check.sh gate 11
#
# WHY THIS FILE EXISTS (finding F-18, issue #128 follow-up): gate 11 checked a config archive for
# key material with a NAME pattern (`etc/pve/priv|\.key$|\.pem$`). F-3 is not a name — `cipassword:`
# is a FIELD inside a conf body — so the 2026-10-25 archive passed this gate while carrying 9
# credential hashes and travelling off-host. The publishing script now refuses to build such an
# archive, but a control must not be trusted only by its own author: if `hv01-config-backup.sh`
# drifts (F-4 was exactly that — the host copy 42 lines behind the repo) the watchdog is the only
# independent observer. Gate 11 therefore reads the CONTENT, and proves its own reach: an archive
# exposing no conf is reported UNVERIFIED, never clean (the pbs01 gate-3 "absence of measurement
# rendered as a number" class).
#
# The gate text is EXTRACTED FROM THE SCRIPT UNDER TEST and sourced — never copied. Run it against
# the pre-fix file to see the red:
#   git show main:scripts/maintenance/hv01-health-check.sh > /tmp/prefix.sh
#   ./test-hv01-gate11.sh /tmp/prefix.sh   # MUST fail: the value case and the no-conf case both
#                                          # report alerts=0 when nothing is being read
#   ./test-hv01-gate11.sh                  # passes against the fixed script
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the gate could not be extracted.
# Read-only on any real system: it writes only inside its own mktemp workdir, creates no /etc/pve
# content and needs no host access. Run from anywhere: `make test-gates`.
# =============================================================================
set -uo pipefail

SRC="${1:-/opt/jol/repos/jol-infrastructure/scripts/maintenance/hv01-health-check.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^# --- 11\. Config evidence/,/^# --- 12\./' "$SRC" | sed '$d' >"$WORK/gate11.sh"
if [[ ! -s "$WORK/gate11.sh" ]]; then
    echo "FATAL: could not extract gate 11 from $SRC — the fixture is testing nothing" >&2
    exit 2
fi
echo "extracted $(grep -c '' "$WORK/gate11.sh") lines of gate 11 from $SRC"

# --- build synthetic archives in the pmxcfs ARCHIVED layout (nodes/<node>/qemu-server/) --------
# Values below are fabricated and obviously fake; the gate must never see a real credential.
mkstage() { # $1=dir to build under $2=cipassword body line ("" = no cipassword field at all)
    mkdir -p "$1/etc/pve/nodes/pve-prod-hv01/qemu-server"
    {
        echo 'agent: enabled=1'
        echo 'cores: 4'
        [[ -n "$2" ]] && echo "$2"
    } >"$1/etc/pve/nodes/pve-prod-hv01/qemu-server/100.conf"
}

build() { # $1=name; prints the archive path
    local d="$WORK/stage-$1"
    # SC2016: `$5$…` is the literal sha256crypt prefix, not a shell variable; single quotes keep
    # the fabricated value inert.
    # shellcheck disable=SC2016
    case "$1" in
        clean)      mkstage "$d" 'cipassword: <STRIPPED by hv01-config-backup.sh 20261101 — issue #128>' ;;
        unsanitised) mkstage "$d" 'cipassword: $5$rounds=5000$fakesalt$FAKEVALUEneverreal' ;;
        noconf)     mkdir -p "$d/etc/pve"; echo 'x' >"$d/etc/pve/cluster.cfg" ;;
        keys)       mkstage "$d" 'cipassword: <STRIPPED by hv01-config-backup.sh>'
                    mkdir -p "$d/etc/pve/priv"
                    # NAME pattern is what the gate tests; no PEM header in a fixture, or the repo's
                    # own detect-private-key hook would trip on fabricated content.
                    printf 'FABRICATED-PLACEHOLDER-NOT-A-KEY\n' >"$d/etc/pve/priv/authkey.key" ;;
    esac
    tar -czf "$WORK/$1.tar.gz" -C "$d" etc
    chmod 600 "$WORK/$1.tar.gz"          # gate 11 also alerts on a mode other than 600
    echo "$WORK/$1.tar.gz"
}
A_CLEAN="$(build clean)"
A_VALUE="$(build unsanitised)"
A_NOCONF="$(build noconf)"
A_KEYS="$(build keys)"

pass=0
fail=0
report_ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
report_bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"
}

# SC2317: alert()/info()/find() below are invoked only by the gate text sourced at the end of
# run_gate, which shellcheck cannot see across the `.` — they are reachable.
# shellcheck disable=SC2317
run_gate() { # $1=archive path the stubbed find should return ("" = no fresh backup at all)
    (
        ALERTS=0
        # Bound for the sourced gate text, which is its only consumer — shellcheck cannot see
        # across the `.`, so it reads as unused. Bind it, do not delete it.
        # shellcheck disable=SC2034
        CONFIG_TAR_MAX_AGE_DAYS=8
        alert() { ALERTS=$((ALERTS + 1)); printf 'CRITICAL: %s\n' "$1"; }
        info()  { printf 'INFO: %s\n' "$1"; }
        # Gate 11's only `find` call is the freshness lookup; stub it so the fixture decides what
        # is "fresh" without touching /mnt/hdd-archive.
        find()  { [[ -n "$FIX_ARCHIVE" ]] && printf '%s\n' "$FIX_ARCHIVE"; }
        export FIX_ARCHIVE="$1"
        # SC1091: the gate text is generated in a mktemp dir at runtime, so no path resolvable
        # at lint time exists. (A continuation comment must never begin with the literal
        # `# shellcheck` — it is parsed as a directive.)
        # shellcheck disable=SC1090,SC1091
        . "$WORK/gate11.sh"
        echo "alerts=$ALERTS"
    )
}

expect_text() { # $1=label $2=required substring $3=output
    if grep -qF -- "$2" <<<"$3"; then report_ok "$1"; else report_bad "$1" "$2" "$3"; fi
}
expect_absent() { # $1=label $2=forbidden substring $3=output
    if grep -qF -- "$2" <<<"$3"; then report_bad "$1" "no '$2'" "found '$2'"; else report_ok "$1"; fi
}
expect_counts() { # $1=label $2=expected "alerts=N" $3=output
    local got
    got="$(grep -oE 'alerts=[0-9]+' <<<"$3" | tail -1)"
    if [[ "$got" == "$2" ]]; then report_ok "$1 ($got)"; else report_bad "$1" "$2" "${got:-none}"; fi
}

echo "--- 1 (THE F-18 CONTROL): a surviving cipassword value inside a conf body MUST be seen"
O1="$(run_gate "$A_VALUE")"
expect_text 'value present -> named as unsanitised' 'UNSANITISED cipassword value' "$O1"
expect_counts 'value present -> exactly one CRITICAL' 'alerts=1' "$O1"

echo "--- 2 (REACH CONTROL): an archive exposing no qemu-server conf is UNVERIFIED, not clean"
O2="$(run_gate "$A_NOCONF")"
expect_text 'no conf reachable -> says UNVERIFIED' 'UNVERIFIED, not clean' "$O2"
expect_absent 'no conf reachable -> never claims the archive is sanitized' 'UNSANITISED' "$O2"
expect_counts 'no conf reachable -> CRITICAL' 'alerts=1' "$O2"

echo "--- 3: a properly stripped archive stays green (the gate must not be a screamer)"
O3="$(run_gate "$A_CLEAN")"
expect_absent 'stripped archive -> no credential alert' 'cipassword' "$O3"
expect_counts 'stripped archive -> clean' 'alerts=0' "$O3"

echo "--- 4: the pre-existing key-material branch still fires (the new check did not replace it)"
O4="$(run_gate "$A_KEYS")"
expect_text 'key entry -> PRIVATE KEY alert' 'PRIVATE KEY material' "$O4"
expect_counts 'key entry -> CRITICAL' 'alerts=1' "$O4"

echo "--- 5: no fresh archive at all stays an alert (freshness half of the gate)"
O5="$(run_gate "")"
expect_text 'absent archive -> freshness alert' 'No /etc/pve config backup' "$O5"
expect_counts 'absent archive -> CRITICAL' 'alerts=1' "$O5"

echo
echo "gate-11 fixtures: $pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
