#!/usr/bin/env bash
# =============================================================================
# test-workstation-capacity.sh — negative-control fixtures for the capacity watchdog
#
# WHY: a watchdog that has never been seen to fail is indistinguishable from a dead
# one. hv01's ALERTS.log ran 2026-07-31..10-21 at a 100 % FALSE-POSITIVE rate (415
# lines) while the one control that was genuinely broken produced no alert at all. So
# every gate here is asserted in BOTH directions: the real 2026-11-04 condition must
# fire, and a healthy disk must stay silent.
#
# The gate text is EXTRACTED FROM THE SCRIPT UNDER TEST and sourced — never copied.
# `df` is stubbed as a shell FUNCTION, which takes precedence over PATH lookup inside
# the sourced block, so the fixture decides what the filesystem census contains without
# touching a real disk. Run it against an unfixed file to see the red:
#   ./test-workstation-capacity.sh /tmp/prefix.sh
#
# Exit: 0 all cases behaved, 1 a case failed, 2 the gate could not be extracted.
# Read-only on any real system: writes only inside its own mktemp workdir.
# =============================================================================
set -uo pipefail

MAINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$MAINT_DIR/workstation-capacity-check.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/^# --- gate 1 \+ gate 4/,/^# Publish state atomically/' "$SRC" | sed '$d' >"$WORK/gate1.sh"
if [[ ! -s "$WORK/gate1.sh" ]]; then
    echo "FATAL: could not extract gate 1 from $SRC — the fixture is testing nothing" >&2
    exit 2
fi
# Gate 5's range ENDS at the gate 6 header, not at the verdict. When gate 6 was added
# between them, a range still ending at `# --- verdict` silently swallowed the new gate
# into every gate-5 fixture — nine cases then failed for a reason unrelated to what they
# test. Extraction ranges must be bounded by the NEXT section, not by the end of file.
awk '/^# --- gate 5/,/^# --- gate 6/' "$SRC" | sed '$d' >"$WORK/gate5.sh"
if [[ ! -s "$WORK/gate5.sh" ]]; then
    echo "FATAL: could not extract gate 5 from $SRC - the fixture is testing nothing" >&2
    exit 2
fi
awk '/^# --- gate 6/,/^# --- verdict/' "$SRC" | sed '$d' >"$WORK/gate6.sh"
if [[ ! -s "$WORK/gate6.sh" ]]; then
    echo "FATAL: could not extract gate 6 from $SRC - the fixture is testing nothing" >&2
    exit 2
fi
echo "extracted gate 1, gate 5 and gate 6 from $SRC"

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
expect_counts() { # $1=label $2=expected "alerts=N" $3=output
    local got
    got="$(grep -oE 'alerts=[0-9]+' <<<"$3" | tail -1)"
    if [[ "$got" == "$2" ]]; then report_ok "$1 ($got)"; else report_bad "$1" "$2" "${got:-none}"; fi
}

# --- df fixtures -------------------------------------------------------------
# Columns mirror `df -P`: Filesystem 1024-blocks Used Available Capacity Mounted-on.
# Values are fabricated; no real filesystem is described or touched.
HDR='Filesystem     1024-blocks      Used Available Capacity Mounted on'

mk_census() { # pairs of "device size avail pct mount"
    printf '%s\n' "$HDR"
    while [[ $# -ge 5 ]]; do
        printf '%s %s %s %s %s%% %s\n' "$1" "$2" "$3" "$4" "$5" "$6"
        shift 6
    done
}

# SC2317: df()/mktemp() below are invoked only by the gate text sourced in run_gate,
# which shellcheck cannot see across the `.` — they are reachable.
# shellcheck disable=SC2317
run_gate() { # $1=census text  $2=inode pct for the last mount  $3=optional STATE baseline
             # $4=optional epoch for STATE_TS (the fill-rate interval)
    (
        ALERTS=0
        ALERT_TEXTS=()
        # Bound for the sourced gate text (state/log paths), which is its only consumer.
        # The linter cannot see across the `.`, so it reads as unused. Bind it, do not
        # delete it. Note the directive below must sit on its OWN line: a continuation
        # comment that merely starts with the same hash-plus-"shellcheck" token is parsed
        # as a directive too, which is the trap test-hv01-gate11.sh documents.
        # shellcheck disable=SC2034
        LOG_DIR="$WORK"
        STATE="$WORK/state"
        # Assigned by the script's config block, which is OUTSIDE the extracted range, so
        # the fixture must bind them or `set -u` aborts the whole sourced block — which
        # presents as every fixture failing at once, not as one missing binding.
        STATE_TS="$WORK/state-ts"
        if [[ -n "${4:-}" ]]; then printf '%s\n' "$4" >"$STATE_TS"; else rm -f "$STATE_TS"; fi
        SAMPLES="$WORK/samples.tsv"
        rm -f "$SAMPLES"
        # Consumed only by the sourced gate text, across the `.` — the same binding rule
        # as LOG_DIR above. Directive must be its own line, not a continuation comment.
        # shellcheck disable=SC2034
        SAMPLE_KEEP=20000
        if [[ -n "${3:-}" ]]; then printf '%s\n' "$3" >"$STATE"; else rm -f "$STATE"; fi
        CAP_ALERT_PCT="${CAP_ALERT_PCT:-90}"
        CAP_MIN_FREE_MIB="${CAP_MIN_FREE_MIB:-4096}"
        # Must be bound here too: the gate reads it, and under `set -u` an unbound
        # threshold aborts the whole sourced block — which presents as EVERY fixture
        # failing at once, not as one missing binding. When the gate grows a new
        # threshold, this list grows with it.
        CAP_FLOOR_SIZE_PCT="${CAP_FLOOR_SIZE_PCT:-20}"
        INODE_ALERT_PCT="${INODE_ALERT_PCT:-90}"
        TREND_DROP_PCT="${TREND_DROP_PCT:-10}"
        TREND_HOURS_TO_FULL="${TREND_HOURS_TO_FULL:-72}"
        TREND_DROP_MIB="${TREND_DROP_MIB:-512}"
        TREND_PROJECT_ALERTS="${TREND_PROJECT_ALERTS:-0}"
        FIX_CENSUS="$1"
        FIX_INODE="$2"
        df() {
            case "${1:-}" in
                -P)  printf '%s\n' "$FIX_CENSUS" ;;
                -iP) printf '%s\n' "$HDR"
                     # IUse% is column 5; the gate reads only the last line.
                     # '-' is what real `df -iP` emits for vfat/ntfs (no inode table).
                     if [[ "$FIX_INODE" == "-" ]]; then
                         printf '/dev/fake - - - -%% /home\n'
                     else
                         printf '/dev/fake 6111232 1148541 4962691 %s%% /home\n' "$FIX_INODE"
                     fi ;;
            esac
        }
        alert() { ALERTS=$((ALERTS + 1)); ALERT_TEXTS+=("$1"); printf 'CRITICAL: %s\n' "$1"; }
        warn()  { printf 'WATCH: %s\n' "$1"; }
        info()  { printf 'INFO: %s\n' "$1"; }
        # shellcheck disable=SC1090,SC1091
        . "$WORK/gate1.sh"
        echo "alerts=$ALERTS"
    )
}

echo "--- 1 (THE 2026-11-04 CONTROL): /home at 100 % with 1.3 MiB free MUST fire"
# Measured that day: 92 GiB partition, 1.3 MB available, 100 % used, inodes only 19 %.
F1="$(mk_census /dev/nvme0n1p7 195317760 195315136 1344 100 /home)"
O1="$(run_gate "$F1" 19)"
expect_text 'full /home -> named as capacity CRITICAL' 'CRITICAL: capacity: /home' "$O1"
expect_text 'full /home -> says it holds the IDE/agent working copies' '/home holds the IDE' "$O1"
expect_counts 'full /home -> exactly one CRITICAL' 'alerts=1' "$O1"

echo "--- 1b (DEVICE-AGNOSTIC CONTROL): the /home annotation must key on the mount point"
# Measured 2026-11-05: physically swapping one NVMe renumbered every other one, moving the OS
# disk from nvme0n1 to nvme1n1. A version of this gate matched the literal device node
# `nvme0n1p7`, so the annotation would have quietly stopped firing after a disk swap — the
# remembered-letter failure class that also produced the /mnt/jol-backup outage.
F1b="$(mk_census /dev/nvme9n1p7 195317760 195315136 1344 100 /home)"
O1b="$(run_gate "$F1b" 19)"
expect_text 'home on an unexpected device name -> still annotated' '/home holds the IDE' "$O1b"
# And the converse: the old device name mounted at a NON-home path must not borrow the note.
F1c="$(mk_census /dev/nvme0n1p7 195317760 195315136 1344 100 /var/lib/thing)"
O1c="$(run_gate "$F1c" 19)"
expect_absent 'old device name at another mount -> must NOT claim it is /home' 'holds the IDE' "$O1c"
expect_counts 'non-home mount at 100 % -> still one CRITICAL' 'alerts=1' "$O1c"

echo "--- 2 (THE ABSOLUTE-FLOOR CONTROL): a small fs at 60 % is NOT comfortable"
# This is the half the GNOME popup lacked: percent alone would read 60 % as healthy,
# while 3.8 GiB free is not enough for an IDE index to finish.
F2="$(mk_census /dev/nvme0n1p6 9728000 3891200 5836800 40 /opt/jol/backup \
               /dev/nvme0n1p7 96468992 57881344 33717248 64 /home)"
O2="$(run_gate "$F2" 19)"
expect_text '5.5 GiB free at 40 % -> passes the floor (no alert)' 'alerts=0' "$O2"
# 1425 MiB free at 85 % used on a 9.5 GiB filesystem: the capped floor is 1900 MiB and
# the percent bar (90 %) is NOT crossed, so this proves the floor is an INDEPENDENT
# trigger rather than a decoration on the percent test.
F2b="$(mk_census /dev/nvme0n1p6 9728000 8268800 1459200 85 /opt/jol/backup)"
O2b="$(run_gate "$F2b" 19)"
expect_text '1425 MiB free at 85 % -> capped floor fires alone' 'MiB free' "$O2b"
expect_absent '1425 MiB free at 85 % -> percent bar correctly NOT blamed' '>= 90%' "$O2b"
expect_counts 'small fs under the floor -> CRITICAL' 'alerts=1' "$O2b"
# Both reasons must appear when both hold — the first draft used `elif` and hid the floor.
F2c="$(mk_census /dev/nvme0n1p6 9728000 8800000 512000 91 /opt/jol/backup)"
O2c="$(run_gate "$F2c" 19)"
expect_text '91 % used AND 500 MiB free -> percent reason present' 'at 91%' "$O2c"
expect_text '91 % used AND 500 MiB free -> floor reason ALSO present' 'MiB free' "$O2c"

echo "--- 2b (FALSE-POSITIVE CONTROL): a small HEALTHY partition must not be flagged"
# This is the case the first live run produced for real: /boot/efi is 1.1 GiB total with
# 1 GiB free and 6 % used, and a FLAT 4 GiB floor called it an emergency. A watchdog that
# cries wolf at healthy mounts is how hv01's operator learned to ignore 415 alerts.
F8b="$(mk_census /dev/nvme0n1p1 1150976 60976 1090000 6 /boot/efi \
                /dev/nvme0n1p7 96468992 65536000 30932992 68 /home)"
O8b="$(run_gate "$F8b" 19)"
expect_absent '1 GiB free on a 1.1 GiB ESP -> no floor alert' 'MiB free' "$O8b"
expect_counts 'small healthy partitions -> clean' 'alerts=0' "$O8b"

echo "--- 2c (NOT-APPLICABLE CONTROL): vfat has no inode table; '-' is neither pass nor fail"
# Real `df -iP` emits '-' for IUse% on vfat/ntfs. Feeding '-' to (( )) raises "syntax
# error: operand expected", which under `set -u` WITHOUT -e does not abort — it silently
# skips the check. Measured on the first live run at /boot/efi and /media/jol/….
F8c="$(mk_census /dev/nvme0n1p1 1150976 60976 1090000 6 /boot/efi)"
O8c="$(run_gate "$F8c" -)"
expect_text 'vfat inode field -> says not applicable' 'not applicable' "$O8c"
expect_absent 'vfat inode field -> no arithmetic error leaked into the report' 'syntax error' "$O8c"
expect_counts 'vfat inode field -> clean, not silently skipped' 'alerts=0' "$O8c"

echo "--- 2d (UNREADABLE ROW CONTROL): a non-numeric Use% is UNVERIFIED, never a pass"
F8d="$(mk_census /dev/nvme0n1p7 96468992 65536000 30932992 'N/A' /home)"
O8d="$(run_gate "$F8d" 19)"
expect_text 'non-numeric Use% -> named UNVERIFIED' 'UNVERIFIED for this mount' "$O8d"
expect_counts 'non-numeric Use% -> CRITICAL, not green' 'alerts=1' "$O8d"

echo "--- 3 (INODE CONTROL): inode exhaustion with plenty of free bytes MUST fire"
# A filesystem can be 87 % FREE and still refuse every write. `df -h` shows nothing wrong.
F3="$(mk_census /dev/nvme0n1p7 96468992 12058624 84410368 13 /home)"
O3="$(run_gate "$F3" 100)"
expect_text 'inodes exhausted -> named as INODES, not bytes' '% INODES' "$O3"
expect_text 'inodes exhausted -> says free space does not mean writable' 'does not mean writable' "$O3"
expect_counts 'inode-only exhaustion -> CRITICAL' 'alerts=1' "$O3"

echo "--- 4 (TREND CONTROL): losing 11 points in one interval fires BEFORE the bar"
# 78 % -> 89 % is under the 90 % threshold, so a level-only gate stays silent while the
# partition is minutes from full. This is the early-warning half of the design, and it is
# also the control that caught an INVERTED SIGN in the first draft (drop was computed
# previous - now, so a fast fill read as 'recovered' and the gate never fired).
F4="$(mk_census /dev/nvme0n1p7 96468992 10605184 85863808 89 /home)"
O4="$(run_gate "$F4" 19 '/home 81634 78')"
expect_text 'fast fill -> says losing space fast' 'losing space fast' "$O4"
expect_absent 'fast fill -> must NOT be misread as recovery' 'recovered' "$O4"
expect_counts 'fast fill below the bar -> still CRITICAL' 'alerts=1' "$O4"
# And the opposite direction must stay quiet: space freed after a cleanup is not an alert.
# (10 points, because the recovery NOTE uses the same TREND_DROP_PCT threshold as the
# fill alert — symmetric by design, so a 7-point wobble is not reported in either case.)
O4b="$(run_gate "$(mk_census /dev/nvme0n1p7 96468992 78848000 17620992 82 /home)" 19 '/home 17620992 92')"
expect_text 'space recovered -> reported as recovered' 'recovered 10 points' "$O4b"
expect_counts 'space recovered -> no CRITICAL' 'alerts=0' "$O4b"
expect_absent 'space recovered -> must NOT be misread as a fast fill' 'losing space fast' "$O4b"

echo "--- 5 (GREEN CONTROL): a healthy fleet must stay silent — the gate is not a screamer"
F5="$(mk_census /dev/nvme0n1p3 62478336 39854592 19377152 68 / \
               /dev/nvme0n1p7 96468992 65536000 29006336 70 /home \
               /dev/nvme0n1p8 585957376 138240000 417378304 25 /opt/jol)"
O5="$(run_gate "$F5" 19)"
expect_absent 'healthy disks -> no CRITICAL at all' 'CRITICAL' "$O5"
expect_counts 'healthy disks -> clean' 'alerts=0' "$O5"

echo "--- 6 (DEDUPE CONTROL): the same mount listed twice must not alert twice"
F6="$(mk_census /dev/nvme0n1p7 195317760 195315136 1344 100 /home \
               /dev/nvme0n1p7 195317760 195315136 1344 100 /home)"
O6="$(run_gate "$F6" 19)"
expect_counts 'duplicate census row -> one CRITICAL, not two' 'alerts=1' "$O6"

echo "--- 7 (BLIND-GATE CONTROL): df returning nothing is UNVERIFIED, never a pass"
O7="$(run_gate "" 19)"
expect_text 'empty df -> says UNVERIFIED' 'UNVERIFIED' "$O7"
expect_counts 'empty df -> CRITICAL, not green' 'alerts=1' "$O7"

echo "--- 8 (BLIND-GATE CONTROL 2): a census that filters to zero rows is not a pass"
O8="$(run_gate "$HDR" 19)"
expect_text 'header-only census -> admits it judged nothing' 'no rows to judge' "$O8"
expect_counts 'header-only census -> CRITICAL' 'alerts=1' "$O8"

echo
echo "--- 8e (GATE 5): off-device backup ARTIFACT freshness ----------------------"
# Gate 5 does ordinary filesystem work, so these fixtures use REAL files with controlled
# mtimes rather than a stubbed probe. The property under test is a timestamp comparison,
# and faking the artifact would leave unexercised the exact thing that broke on
# 2026-11-04: four days with no new Terraform state snapshot on the backup disk.
mk_artifact() { # $1=dir $2=name $3=touch -d spec
    mkdir -p "$1"
    : >"$1/$2"
    touch -d "$3" "$1/$2"
}

# SC2317: alert()/info() below are invoked only by the gate text sourced at the end of
# run_gate5, which shellcheck cannot see across the `.` — they are reachable.
# shellcheck disable=SC2317
run_gate5() { # $1=BACKUP_ARTIFACTS value
    (
        ALERTS=0
        # Bound for the sourced gate text, its only consumer; the linter cannot see
        # across the `.` so it reads as unused.
        # shellcheck disable=SC2034
        BACKUP_ARTIFACTS="$1"
        alert() { ALERTS=$((ALERTS + 1)); printf 'CRITICAL: %s\n' "$1"; }
        info()  { printf 'INFO: %s\n' "$1"; }
        # shellcheck disable=SC1090,SC1091
        . "$WORK/gate5.sh"
        echo "alerts=$ALERTS"
    )
}

G5DIR="$WORK/g5"
mk_artifact "$G5DIR" "ctl-terraform.tfstate.age" "2 hours ago"
O5a="$(run_gate5 "$G5DIR/*terraform.tfstate*.age|26")"
# Assert on the phrase that ONLY the success branch emits, not on 'gate 5:' — every
# branch prints that, so matching it would pass against a CRITICAL too.
expect_text 'gate5 fresh artifact -> success branch reached' 'artifact(s) inspected' "$O5a"
expect_absent 'gate5 fresh artifact -> no CRITICAL emitted' 'CRITICAL' "$O5a"
expect_counts 'gate5 fresh artifact -> clean' 'alerts=0' "$O5a"

mk_artifact "$G5DIR" "ctl-terraform.tfstate.age" "100 hours ago"
O5b="$(run_gate5 "$G5DIR/*terraform.tfstate*.age|26")"
expect_text 'gate5 100h-old artifact -> says backup NOT running' 'NOT running' "$O5b"
expect_counts 'gate5 stale artifact -> CRITICAL' 'alerts=1' "$O5b"

# The 2026-11-04 real case, replayed: snapshots stopped on Oct 31 while the disk itself
# looked perfectly healthy at 1% used. Capacity and mount checks both pass; only this
# gate sees it.
mk_artifact "$G5DIR" "ctl-terraform.tfstate.age" "96 hours ago"
O5c="$(run_gate5 "$G5DIR/*terraform.tfstate*.age|26")"
expect_text 'gate5 four-day gap -> named in hours' 'is 96 h old' "$O5c"

mk_artifact "$G5DIR" "ctl-terraform.tfstate.age" "+5 hours"
O5d="$(run_gate5 "$G5DIR/*terraform.tfstate*.age|26")"
expect_text 'gate5 FUTURE mtime -> refused, not graded fresh' 'FUTURE mtime' "$O5d"
expect_absent 'gate5 FUTURE mtime -> never claims it inspected fresh artifacts' 'artifact(s) inspected' "$O5d"
expect_counts 'gate5 FUTURE mtime -> CRITICAL' 'alerts=1' "$O5d"

O5e="$(run_gate5 "$WORK/never-mounted/*.age|26")"
expect_text 'gate5 absent directory -> says ABSENT' 'is ABSENT' "$O5e"
expect_counts 'gate5 absent directory -> CRITICAL' 'alerts=1' "$O5e"

mkdir -p "$WORK/g5-empty"
O5f="$(run_gate5 "$WORK/g5-empty/*.age|26")"
expect_text 'gate5 existing dir, zero matches -> UNVERIFIED' 'UNVERIFIED, never read as clean' "$O5f"
expect_counts 'gate5 zero matches -> CRITICAL, not green' 'alerts=1' "$O5f"

mkdir -p "$WORK/g5-broken"
ln -s /nonexistent-target "$WORK/g5-broken/x.age"
O5g="$(run_gate5 "$WORK/g5-broken/*.age|26")"
expect_text 'gate5 dangling symlink -> UNVERIFIED not fresh' 'readable mtime' "$O5g"
expect_absent 'gate5 dangling symlink -> never claims fresh' 'artifact(s) inspected' "$O5g"
expect_counts 'gate5 dangling symlink -> CRITICAL' 'alerts=1' "$O5g"

O5h="$(run_gate5 "$G5DIR/*terraform.tfstate*.age|abc")"
expect_text 'gate5 non-numeric max age -> refused loudly' 'non-numeric max age' "$O5h"
expect_counts 'gate5 bad config -> CRITICAL, not silent' 'alerts=1' "$O5h"

# Newest wins, regardless of listing order: a stale leftover in the same directory must
# not mask a fresh snapshot (and mirrors hv01 gate 10's "one old success masked a newer
# failure" lesson, judged on the NEWEST element).
# Own directory on purpose: G5DIR still holds the FUTURE-mtime file the O5d fixture left
# behind, and reusing it made this case fail for a reason unrelated to what it tests.
# Fixture state must not leak between cases.
G5MIX="$WORK/g5-mix"
mk_artifact "$G5MIX" "old-terraform.tfstate.age" "500 hours ago"
mk_artifact "$G5MIX" "new-terraform.tfstate.age" "1 hours ago"
mk_artifact "$G5MIX" "mid-terraform.tfstate.age" "90 hours ago"
O5i="$(run_gate5 "$G5MIX/*terraform.tfstate*.age|26")"
expect_counts 'gate5 newest-of-many wins -> clean' 'alerts=0' "$O5i"
expect_text 'gate5 reports how many artifacts it inspected' '3 artifact(s) inspected' "$O5i"
# And the inverse: newest is stale while an older file exists -> still an alert.
mk_artifact "$G5MIX" "new-terraform.tfstate.age" "80 hours ago"
O5j="$(run_gate5 "$G5MIX/*terraform.tfstate*.age|26")"
expect_text 'gate5 newest stale -> alerts on the newest age' 'is 80 h old' "$O5j"
expect_counts 'gate5 newest stale -> CRITICAL' 'alerts=1' "$O5j"


echo "--- 6e (GATE 6): is the /home backup still being taken? -------------------"
# Real directories with controlled mtimes: this gate is about a timestamp on disk, so
# stubbing the probe would leave the property under test unexercised.
# SC2317: alert()/info() below are invoked only by the gate text sourced in run_gate6,
# which the linter cannot see across the `.` — they are reachable.
# shellcheck disable=SC2317
run_gate6() { # $1=HOME_BACKUP_DIR  $2=HOME_BACKUP_MAX_AGE_H
    (
        ALERTS=0
        # Bound for the sourced gate text, its only consumer; across the `.` the linter
        # cannot see the use, so both read as unused. Bind them, do not delete them.
        # shellcheck disable=SC2034
        HOME_BACKUP_DIR="$1"
        # shellcheck disable=SC2034
        HOME_BACKUP_MAX_AGE_H="$2"
        alert() { ALERTS=$((ALERTS + 1)); printf 'CRITICAL: %s\n' "$1"; }
        info()  { printf 'INFO: %s\n' "$1"; }
        # shellcheck disable=SC1090,SC1091
        . "$WORK/gate6.sh"
        echo "alerts=$ALERTS"
    )
}

HB="$WORK/hb"
# These fixtures set the DIRECTORY NAME, not the mtime. That is the property under test:
# rsync -a propagates the source directory's mtime onto the snapshot, so an mtime-based
# age reported a backup taken 36 minutes ago as "1875 h old" on 2026-11-05. A fixture
# that only touched the mtime would have kept passing against that broken gate.
NOW_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FUTURE_STAMP="$(date -u -d '+10 hours' +%Y%m%dT%H%M%SZ)"
mkdir -p "$HB/home-$NOW_STAMP"
O6a="$(run_gate6 "$HB" 30)"
expect_text 'gate6 fresh snapshot -> success branch' 'snapshot(s) inspected' "$O6a"
expect_counts 'gate6 fresh snapshot -> clean' 'alerts=0' "$O6a"

rm -rf "$HB/home-$NOW_STAMP"
mkdir -p "$HB/home-20260101T000000Z"
O6b="$(run_gate6 "$HB" 30)"
expect_text 'gate6 snapshot named 2026-01-01 -> says NOT running' 'NOT running' "$O6b"
expect_counts 'gate6 stale snapshot -> CRITICAL' 'alerts=1' "$O6b"

O6c="$(run_gate6 "$WORK/hb-absent" 30)"
expect_text 'gate6 no directory at all -> names D-1 as still open' 'does not exist' "$O6c"
expect_counts 'gate6 absent directory -> CRITICAL' 'alerts=1' "$O6c"

mkdir -p "$WORK/hb-empty"
O6d="$(run_gate6 "$WORK/hb-empty" 30)"
expect_text 'gate6 directory present but empty -> not backed up' 'is not being backed up' "$O6d"
expect_counts 'gate6 empty directory -> CRITICAL, not green' 'alerts=1' "$O6d"

rm -rf "$HB/home-20260101T000000Z"
mkdir -p "$HB/home-$FUTURE_STAMP"
O6e="$(run_gate6 "$HB" 30)"
expect_text 'gate6 FUTURE-dated name -> refused, not graded fresh' 'FUTURE' "$O6e"
expect_absent 'gate6 FUTURE-dated name -> never claims inspected' 'snapshot(s) inspected' "$O6e"
expect_counts 'gate6 FUTURE-dated name -> CRITICAL' 'alerts=1' "$O6e"

# A directory NOT following the naming convention must fall back to mtime AND say so.
# Silence here would let a hand-made or renamed snapshot be judged by an invisible clock.
rm -rf "$HB/home-$FUTURE_STAMP"
mkdir -p "$HB/home-handy-label"
touch -d "2 hours ago" "$HB/home-handy-label"
O6g="$(run_gate6 "$HB" 30)"
expect_text 'gate6 non-conforming name -> announces the mtime fallback' 'falling back to its mtime' "$O6g"
expect_counts 'gate6 non-conforming name but recent mtime -> judged fresh' 'alerts=0' "$O6g"

# The state that actually occurred on 2026-11-05: the snapshot tree was mode 700
# root:root, so a user-level watchdog could not see it. Reporting that as "no backup
# exists" would be a false finding; it must be reported as UNVERIFIED.
mkdir -p "$WORK/hb-secret/home-$NOW_STAMP"
chmod 000 "$WORK/hb-secret"
O6f="$(run_gate6 "$WORK/hb-secret" 30)"
if [[ "$(id -u)" == "0" ]]; then
    # Root bypasses the permission check, so this case cannot be exercised here.
    # Saying so is required: an assertion that cannot fail must not be reported as passing.
    report_ok 'gate6 unreadable directory -> NOT EXERCISED (running as root, permissions do not apply)'
else
    expect_text 'gate6 unreadable directory -> UNVERIFIED not absent' 'UNVERIFIED' "$O6f"
    expect_absent 'gate6 unreadable directory -> must NOT claim no backup exists' 'does not exist' "$O6f"
    expect_counts 'gate6 unreadable directory -> CRITICAL' 'alerts=1' "$O6f"
fi
chmod 755 "$WORK/hb-secret"


echo
echo "--- 9 (RULE B, static): the completion marker must reach STDOUT, not only the log"
# hv01/pbs01 both shipped this defect: the marker went through info() (log-file only),
# so a remote caller could never match it and reported UNVERIFIED forever.
if grep -qE "^printf .*=== HEALTH CHECK COMPLETE" "$SRC"; then
    report_ok 'marker is printed at top level (stdout), not wrapped in info()'
else
    report_bad 'marker on stdout' '^printf ... "=== HEALTH CHECK COMPLETE' 'not found at top level'
fi

echo "--- 10 (RULE A, static): PATH must be set explicitly or cron/systemd false-alerts"
if grep -qE '^PATH="/usr/local/sbin:' "$SRC"; then
    report_ok 'PATH pinned including sbin (the 415-false-alert root cause)'
else
    report_bad 'PATH pinned' 'PATH=/usr/local/sbin:...' 'not found'
fi

echo "--- 11 (RULE D, static): no secret material may be read by the watchdog"
# Comments are excluded: this file's own header NAMES /home/jol/secrets to say it never
# opens it, and a rule check that greps prose would fail on documentation rather than code.
if grep -vE '^[[:space:]]*#' "$SRC" | grep -qE 'secrets|\.env|vault|token'; then
    report_bad 'no secret-path access' 'no secrets/.env/vault/token in executable lines' 'found one'
else
    report_ok 'gate reads filesystem statistics only — Tier-1 forbidden paths never opened'
fi

echo
echo "--- 12 (FILL RATE): MiB-resolution trend, which a GiB log cannot express -----------"
# Equality helper for exact numeric fields; expect_* match substrings, which would let
# '4' pass inside '14'.
check_eq() { if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_bad "$1" "$2" "$3"; fi; }
# The originating defect: `capacity.log` prints whole GiB, so six runs over 79 minutes all
# read "8 GiB free" and no fill rate could be substantiated from it — a rate of ~3.4 GiB/day
# had been asserted from memory and was not supportable. These fixtures pin the behaviour
# that makes it measurable instead.
NOW_S="$(date -u +%s)"
ONE_H_AGO=$(( NOW_S - 3600 ))
# avail 85,937 MiB now vs 90,000 MiB in state: 4,063 MiB lost over 60 min.
FR_CENSUS="$(mk_census /dev/nvme0n1p7 96468992 8400000 88000000 9 /home)"
FR_STATE='/home 90000 8'
O12a="$(run_gate "$FR_CENSUS" 19 "$FR_STATE" "$ONE_H_AGO")"
expect_text 'fill rate is reported in MiB/day' 'MiB/day' "$O12a"
expect_text 'fill rate reports the remaining time to full' 'h to full' "$O12a"
# Default posture: a projection is a WATCH. Promoting it to CRITICAL on one interval of
# bursty usage is how a watchdog earns to be ignored.
expect_counts 'projected fill -> WARN only, no CRITICAL by default' 'alerts=0' "$O12a"
O12b="$(TREND_PROJECT_ALERTS=1 run_gate "$FR_CENSUS" 19 "$FR_STATE" "$ONE_H_AGO")"
expect_text 'projection can be promoted to CRITICAL when asked' 'projected full in' "$O12b"
expect_counts 'promoted projection -> exactly one CRITICAL' 'alerts=1' "$O12b"

# No interval means no rate. This is what keeps every pre-existing fixture (which passes a
# STATE baseline but never a timestamp) from silently gaining a new alert.
O12c="$(run_gate "$FR_CENSUS" 19 "$FR_STATE")"
expect_absent 'no STATE_TS -> no rate invented' 'MiB/day' "$O12c"
expect_counts 'no STATE_TS -> verdict unchanged from before this gate' 'alerts=0' "$O12c"

# A zero-length interval must not divide, and must not print a confident number either.
O12d="$(run_gate "$FR_CENSUS" 19 "$FR_STATE" "$NOW_S")"
expect_absent 'zero-length interval -> no rate emitted' 'MiB/day' "$O12d"
# These two lines are what makes the span guard testable. Without them a mutant that
# deletes `rate_span >= 1` survives: the division by zero aborts the assignment BEFORE
# any MiB/day text is produced, so absence-of-output alone cannot tell a working guard
# from a missing one. The error must be caught, not merely suppressed.
expect_absent 'zero-length interval -> no division-by-zero leaked' 'division by 0' "$O12d"
expect_absent 'zero-length interval -> no arithmetic error leaked' 'syntax error' "$O12d"
expect_counts 'zero-length interval -> clean, not silently skipped' 'alerts=0' "$O12d"
O12e="$(run_gate "$FR_CENSUS" 19 "$FR_STATE" 'garbage-not-an-epoch')"
expect_absent 'unparseable interval -> inert, not a crash' 'MiB/day' "$O12e"
expect_absent 'unparseable interval -> no arithmetic error leaked' 'syntax error' "$O12e"
O12f="$(run_gate "$FR_CENSUS" 19 '/home notanumber 8' "$ONE_H_AGO")"
expect_absent 'non-numeric previous avail -> inert' 'MiB/day' "$O12f"
# Without the numeric guard, arithmetic on 'notanumber' silently evaluates as 0, so the
# delta becomes a huge GAIN and this gate would print "gained 85937 MiB" about a
# filesystem that is filling. Asserting only the absence of MiB/day would let that pass.
expect_absent 'non-numeric previous avail -> must not fabricate a gain' 'gained ' "$O12f"
expect_absent 'non-numeric previous avail -> no arithmetic error' 'syntax error' "$O12f"
expect_counts 'non-numeric previous avail -> no new CRITICAL either' 'alerts=0' "$O12f"

# Recovery in MiB, and the sub-noise case the floor exists for. Both are stated as
# gains: 88,000 MiB now vs 80,000 then is +8,000 (reported) and vs 87,800 then is +200
# (below TREND_DROP_MIB, so silent).
O12g="$(run_gate "$(mk_census /dev/nvme0n1p7 96468992 8400000 90112000 8 /home)" 19 '/home 80000 9' "$ONE_H_AGO")"
expect_text 'space regained is reported in MiB' 'gained 8000 MiB' "$O12g"
expect_counts 'recovery -> no CRITICAL' 'alerts=0' "$O12g"
O12h="$(run_gate "$(mk_census /dev/nvme0n1p7 96468992 8400000 90112000 8 /home)" 19 '/home 87800 9' "$ONE_H_AGO")"
expect_absent 'a 200 MiB gain is below the noise floor and stays silent' 'gained ' "$O12h"
expect_counts 'sub-noise wobble -> clean' 'alerts=0' "$O12h"

# The artifact itself: this is the thing that makes a rate computable at all.
run_gate "$FR_CENSUS" 19 "$FR_STATE" "$ONE_H_AGO" >/dev/null
if [[ -r "$WORK/samples.tsv" ]]; then
    report_ok 'the MiB sample history is written'
    cols="$(awk -F'\t' 'NR==1{print NF}' "$WORK/samples.tsv")"
    check_eq 'sample row has 4 tab-separated fields' "4" "$cols"
    check_eq 'sample row carries the MiB value, not GiB' "85937" "$(awk -F'\t' 'NR==1{print $3}' "$WORK/samples.tsv")"
else
    report_bad 'sample history written' 'a readable capacity-samples.tsv' 'missing'
fi
if [[ -r "$WORK/state-ts" ]]; then
    report_ok 'the state timestamp is published with the state (an interval exists to pair it)'
else
    report_bad 'STATE_TS published' 'a readable state-ts' 'missing'
fi

echo
echo "capacity fixtures: $pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
