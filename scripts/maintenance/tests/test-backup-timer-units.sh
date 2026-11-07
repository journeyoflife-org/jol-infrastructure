#!/usr/bin/env bash
# =============================================================================
# test-backup-timer-units.sh — fixtures for install-workstation-backup-timer.sh.
#
# WHY THIS EXISTS. The deployed jol-home-backup.service carried
#     IONiceClass=2
#     IONiceLevel=6
# and systemd logged, verbatim, twice per reload, measured on the host
# 2026-11-07T13:30:14Z:
#     /etc/systemd/system/jol-home-backup.service:22: Unknown key name
#     'IONiceClass' in section 'Service', ignoring.
# Those are rsync's option spellings, not systemd properties. The unit therefore
# ran the nightly 79 GiB backup with NO I/O throttling while its own comment
# claimed throttling was configured — a control that is inert and prints nothing.
# The valid properties are IOSchedulingClass= and IOSchedulingPriority=.
#
# Convention (same as test-installer-guard.sh): the unit bodies are EXTRACTED from
# the script under test, never copied, so a fixture cannot drift from what gets
# written; and an empty extraction aborts with rc=2 rather than passing on nothing.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/../install-workstation-backup-timer.sh"
[[ -f "$TARGET" ]] || { echo "FAIL: installer under test not found: $TARGET"; exit 2; }

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ # <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi
}

# -----------------------------------------------------------------------------
# extract_unit <service|timer> — the heredoc body the installer will write.
# -----------------------------------------------------------------------------
extract_unit() {
    # The delimiter is quoted for the service body (no expansion needed) and bare for
    # the timer body, because the schedule must expand. Matching only the bare form
    # silently extracted nothing — the rc=2 guard below is what turned that into a
    # finding instead of a vacuous pass. Deliberately index()-based: a literal
    # apostrophe inside a single-quoted awk program closes the program mid-line, and
    # bash then reports the syntax error dozens of lines later.
    awk -v u="jol-home-backup.$1" '
        index($0, u) && index($0, "<<") { f=1; next }
        f && /^[[:space:]]*UNIT[[:space:]]*$/ { exit }
        f { print }' "$TARGET"
}

SVC="$(extract_unit service)"
TMR="$(extract_unit timer)"
[[ -n "$SVC" ]] || { echo "FAIL: extracted an EMPTY service unit — the fixture would be testing nothing"; exit 2; }
[[ -n "$TMR" ]] || { echo "FAIL: extracted an EMPTY timer unit — the fixture would be testing nothing"; exit 2; }
# Both bodies must contain a section header, or the extraction grabbed prose.
for body in "$SVC" "$TMR"; do
    grep -qE '^\[[A-Za-z]+\]$' <<<"$body" || { echo "FAIL: extraction has no [Section] header"; exit 2; }
done
printf '\ngroup 1: extraction must be real, not a vacuous pass\n'
check "service unit body extracted" "yes" "$([[ ${#SVC} -gt 40 ]] && echo yes || echo no)"
check "timer unit body extracted"   "yes" "$([[ ${#TMR} -gt 40 ]] && echo yes || echo no)"

# -----------------------------------------------------------------------------
# group 2 — the defect, asserted in BOTH directions so a mutant cannot hide it.
# -----------------------------------------------------------------------------
printf '\ngroup 2: I/O throttling properties must be the systemd names\n'
check "IONiceClass absent"  "" "$(printf '%s\n' "$SVC" | grep -E '^[[:space:]]*IONiceClass=' || true)"
check "IONiceLevel absent"  "" "$(printf '%s\n' "$SVC" | grep -E '^[[:space:]]*IONiceLevel=' || true)"
check "IOSchedulingClass present" "2" \
    "$(printf '%s\n' "$SVC" | awk -F= '/^[[:space:]]*IOSchedulingClass=/{print $2; exit}')"
check "IOSchedulingPriority present" "6" \
    "$(printf '%s\n' "$SVC" | awk -F= '/^[[:space:]]*IOSchedulingPriority=/{print $2; exit}')"
check "CPU nice still applied" "15" \
    "$(printf '%s\n' "$SVC" | awk -F= '/^[[:space:]]*Nice=/{print $2; exit}')"

# -----------------------------------------------------------------------------
# group 3 — every emitted key must be a property systemd actually parses.
# A whitelist, because "Unknown key name … ignoring" is silent at run time and
# this is the second member of the class: a declared control that measures nothing.
# -----------------------------------------------------------------------------
printf '\ngroup 3: no unknown systemd keys in either unit\n'
KNOWN='Description|Documentation|After|Requires|Wants|BindsTo|Type|User|Group|ExecStart|Environment|EnvironmentFile|WorkingDirectory|Nice|IOSchedulingClass|IOSchedulingPriority|TimeoutStartSec|TimeoutStopSec|SuccessExitStatus|RemainAfterExit|StandardInput|StandardOutput|OnCalendar|OnUnitActiveSec|Persistent|AccuracySec|RandomizedDelaySec|WantedBy|Restart|RestartSec|ProtectSystem|PrivateTmp'
UNKNOWN_KEYS="$( { printf '%s\n' "$SVC"; printf '%s\n' "$TMR"; } \
    | grep -E '^[A-Za-z][A-Za-z0-9]*=' \
    | cut -d= -f1 \
    | grep -Ev "^($KNOWN)$" | sort -u | tr '\n' ' ' )"
check "all keys recognised by systemd" "" "$UNKNOWN_KEYS"

# -----------------------------------------------------------------------------
# group 4 — the properties that carry the job's failure semantics.
# -----------------------------------------------------------------------------
printf '\ngroup 4: failure reporting must stay loud\n'
check "rc=1 is NOT masked by SuccessExitStatus" "" \
    "$(printf '%s\n' "$SVC" | grep -E '^[[:space:]]*SuccessExitStatus=' || true)"
check "service runs the installed tool" "/usr/local/bin/jol-backup-home.sh" \
    "$(printf '%s\n' "$SVC" | awk -F= '/^[[:space:]]*ExecStart=/{print $2; exit}')"
# The VALUE of Environment= contains an '=' itself, so field-splitting on '=' returns
# "DRY_RUN" and the assertion passes/fails for the wrong reason. Strip the key only.
check "backup runs for real, not dry" "DRY_RUN=0" \
    "$(printf '%s\n' "$SVC" | sed -n 's/^[[:space:]]*Environment=//p' | head -1)"
check "destination mount is required, not optional" "mnt-jol\\x2dbackup.mount" \
    "$(printf '%s\n' "$SVC" | awk -F= '/^[[:space:]]*Requires=/{print $2; exit}')"
check "timer is a calendar event (Persistent can then mean something)" "yes" \
    "$(printf '%s\n' "$TMR" | grep -qE '^[[:space:]]*OnCalendar=' && echo yes || echo no)"
check "Persistent=true present" "true" \
    "$(printf '%s\n' "$TMR" | awk -F= '/^[[:space:]]*Persistent=/{print $2; exit}')"
check "RandomizedDelaySec is zero (booking predictability)" "0" \
    "$(printf '%s\n' "$TMR" | awk -F= '/^[[:space:]]*RandomizedDelaySec=/{print $2; exit}')"

printf '\nbackup-timer unit fixtures: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
