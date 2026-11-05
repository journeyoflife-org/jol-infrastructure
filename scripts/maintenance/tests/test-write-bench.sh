#!/usr/bin/env bash
# =============================================================================
# test-write-bench.sh — fixtures for the sustained-write benchmark (t9).
#
# plateau_summary is the entire judgement: which number gets reported as "the
# speed that sizes the Phase 2 window". It is tested here rather than trusted,
# because the wrong choice (a whole-run mean, or a peak) does not error — it just
# books a window that is too short, at 03:00, with /home unmounted.
#
# Convention: functions are EXTRACTED from the script under test and sourced, and
# an empty extraction aborts with rc=2 so the file cannot pass by testing nothing.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/../benchmark-jolhome-writes.sh"

PASS=0; FAILED=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }

[[ -r "$TARGET" ]] || { echo "cannot read $TARGET"; exit 2; }

PS="$(awk '/^plateau_summary\(\) \{/,/^\}/' "$TARGET")"
TV="$(awk '/^target_verdict\(\) \{/,/^\}/' "$TARGET")"
OH="$(awk '/^operator_home\(\) \{/,/^\}/' "$TARGET")"
HV="$(awk '/^handover_verdict\(\) \{/,/^\}/' "$TARGET")"
if [[ -z "$PS" ]] || ! grep -q 'TOO_FEW_SAMPLES' <<<"$PS"; then
    echo "extraction failed: plateau_summary not found in $TARGET"; exit 2
fi
if [[ -z "$TV" ]] || ! grep -q 'TARGET_NOT_EMPTY' <<<"$TV"; then
    echo "extraction failed: target_verdict not found in $TARGET"; exit 2
fi
if [[ -z "$OH" ]] || ! grep -q 'sudo_home' <<<"$OH"; then
    echo "extraction failed: operator_home not found in $TARGET"; exit 2
fi
if [[ -z "$HV" ]] || ! grep -q 'FILE_ONLY_WARN' <<<"$HV"; then
    echo "extraction failed: handover_verdict not found in $TARGET"; exit 2
fi
eval "$PS"; eval "$TV"; eval "$OH"; eval "$HV"

run_p() { printf '%s\n' "$1" | plateau_summary "${2:-76}"; }
field() { printf '%s' "$1" | cut -f"$2"; }

echo "=== group 1: a cache collapse is found and reported, not averaged away ==="
# 1 GiB/s for 4 samples then a fall to 200 MiB/s for 8: the classic DRAM-less shape.
SERIAL='10 1024
20 1024
30 1024
40 1024
50 200
60 200
70 200
80 200
90 200
100 200
110 200
120 200'
S="$(run_p "$SERIAL")"
check "peak reported as the fast phase"      "1024" "$(field "$S" 1)"
check "sustained reported as the slow phase" "200"  "$(field "$S" 2)"
check "collapse is timed at the fall"        "50"   "$(field "$S" 3)"
# 76 GiB = 77824 MiB at 200 MiB/s = 389 s = 6.48 min, rounded UP to 7. The first draft
# of this fixture asserted 389, having divided by the rate and then by 60 in the wrong
# place — the code was right and my expectation was the bug.
check "copy window uses the SUSTAINED rate, rounded up" "7" "$(field "$S" 4)"
# Rounding must never inflate an exact whole minute. 240 GiB at 512 MiB/s is 491520/512
# = 480 s = 8 min exactly, so the ceiling must leave it at 8. The payload argument is
# chosen to land on a whole minute; 76 GiB never does at any integer MiB/s rate.
EXACT="$(printf '10 512\n20 512\n30 512\n40 512\n50 512\n60 512')"
check "an exact 8-minute window is not rounded to 9" "8" "$(field "$(run_p "$EXACT" 240)" 4)"
check "…while a 6.48-minute window does round up to 7" "7" "$(field "$(run_p "$SERIAL" 76)" 4)"

echo "--- and prove it is NOT the naive whole-run average (382 MiB/s -> 203 min) ---"
NAIVE="$(printf '%s\n' "$SERIAL" | awk '{s+=$2;n++} END{printf "%d", (76*1024)/(s/n)/60}')"
check "the whole-run mean would give a shorter, wrong window" "0" \
    "$([ "$NAIVE" != "$(field "$S" 4)" ] && echo 0 || echo 1)"

echo "=== group 2: refusals, never a fabricated number ==="
check "no samples at all -> NO_SAMPLES"        "NO_SAMPLES"       "$(run_p '')"
check "one sample cannot bound a plateau"      "TOO_FEW_SAMPLES"  "$(run_p '10 500')"
check "two samples still refuse"               "TOO_FEW_SAMPLES"  "$(run_p "$(printf '10 500\n20 100')")"
check "three samples is enough to answer"      "PASS" \
    "$([[ "$(run_p "$(printf '10 500\n20 100\n30 100')")" == *$'\t'* ]] && echo PASS || echo FAIL)"
check "garbage-only input -> NO_SAMPLES"       "NO_SAMPLES"       "$(run_p 'a b
c d')"
# All-zero rows are filtered out entirely, so nothing usable remains: NO_SAMPLES is the
# truthful token, not TOO_FEW_SAMPLES. Asserted to pin that a dead probe is reported as
# "no data" rather than as "almost enough data".
check "zero-rate rows are dropped, leaving no samples" "NO_SAMPLES" \
    "$(run_p "$(printf '10 0\n20 0\n30 0')")"

echo "=== group 3: no-collapse case must be honest, not invent a collapse ==="
FLAT="$(printf '10 300\n20 300\n30 300\n40 300\n50 300\n60 300')"
F="$(run_p "$FLAT")"
check "flat drive reports no collapse"  "0"   "$(field "$F" 3)"
check "flat drive sustained is the rate" "300" "$(field "$F" 2)"

echo "--- a warming drive (slow then fast) must NOT be reported as a cache collapse ---"
# This is the case that caught the real defect: the first implementation scanned for any
# sample below half the eventual maximum, so a drive accelerating 100 -> 1000 MiB/s
# produced a fabricated collapse at 20s.
WARM="$(printf '10 100\n20 150\n30 200\n40 900\n50 950\n60 1000')"
W="$(run_p "$WARM")"
check "no half-peak fall AFTER the peak means no collapse" "0"   "$(field "$W" 3)"
# n=6, so the last third starts at index 5: (950 + 1000) / 2 = 975.
check "sustained is the mean of the tail third"            "975" "$(field "$W" 2)"
check "a mid-run dip that recovers is still not a collapse" "0" \
    "$(field "$(run_p "$(printf '10 100\n20 50\n30 900\n40 950\n50 980\n60 1000')")" 3)"

echo "=== group 4: payload actually drives the projection ==="
A76="$(field "$(run_p "$SERIAL" 76)" 4)"
A152="$(field "$(run_p "$SERIAL" 152)" 4)"
check "a bigger payload needs a longer window" "1" "$([ "$A152" -gt "$A76" ] && echo 1 || echo 0)"
# Doubling the payload doubles the true time; the ceiling can shave at most one minute
# off the doubled result, so the pair is bounded rather than asserted equal.
check "and it scales proportionally within rounding" "1" \
    "$([ "$A152" -ge $((A76 * 2 - 1)) ] && [ "$A152" -le $((A76 * 2)) ] && echo 1 || echo 0)"

echo "=== group 5: target guards — each refusal is distinct and ordered ==="
# Bound for the sourced guard function, its only consumer; across the `.` the linter
# cannot see the use, so it reads as unused.
# shellcheck disable=SC2034
MAPPER="jolhome_crypt"
check "not mounted wins over everything"      "NOT_MOUNTED"      "$(target_verdict no no /dev/mapper/jolhome_crypt 0)"
# A mount point that resolves to / is the /mnt/jol-backup failure reproduced: the path
# exists, df reports real numbers, and none of them describe the device you think you
# are measuring. It must be reported as that, not as a passing empty target.
check "resolving to / is refused before source" "RESOLVES_TO_ROOT" "$(target_verdict yes yes /dev/mapper/jolhome_crypt 0)"
check "wrong backing device is named"          "WRONG_SOURCE"     "$(target_verdict yes no /dev/sda1 0)"
check "resolving to / with a wrong source still says ROOT" "RESOLVES_TO_ROOT" "$(target_verdict yes yes /dev/sda1 0)"
check "a populated target is refused"          "TARGET_NOT_EMPTY" "$(target_verdict yes no /dev/mapper/jolhome_crypt 3)"
check "the good case is OK"                    "OK"               "$(target_verdict yes no /dev/mapper/jolhome_crypt 0)"
check "emptiness is a count, not a string"     "TARGET_NOT_EMPTY" "$(target_verdict yes no /dev/mapper/jolhome_crypt '0 stray')"

echo ""
echo "=== group 6: under sudo the evidence must land in the OPERATOR's home, not /root ==="
# This is the defect that shipped in the first draft of the benchmark: WIN_DIR came from
# $HOME, and the mutating path requires uid 0, so a sudo run wrote samples under a 700
# /root while --report — deliberately reachable WITHOUT root — read the operator's own
# home and answered "no benchmark has been run yet" for a measurement that HAD run.
check "root + resolved sudo home -> operator home" \
      "/home/jol" "$(operator_home 0 /root /home/jol)"
check "plain user run keeps its own home"            \
      "/home/jol" "$(operator_home 1000 /home/jol '')"
# A genuine root shell (rescue.target, where §3.6 is meant to run) has no SUDO_USER and
# /root IS correct — resolving it away would be the opposite bug.
check "root with no sudo caller keeps /root"         \
      "/root" "$(operator_home 0 /root '')"
# getent can fail for an odd passwd entry, so sudo_home arrives empty and the fallback
# is $HOME; the "a home of /" case below is what proves an empty component can never
# reach the join as "/.local/share/…".
# The uid condition must be load-bearing: a non-root process that happens to carry a
# resolved home (sudo -u with HOME preserved) must NOT be redirected into it.
check "non-root ignores sudo_home, keeps its own HOME" \
      "/root" "$(operator_home 1000 /root /home/jol)"
check "trailing slash is normalised, no double slash" \
      "/home/jol" "$(operator_home 0 /root /home/jol/)"
# The same normalisation on the NON-root side: without a fixture here, deleting the
# home-normalisation line is invisible to the suite, and a mutant that survives is a
# decision nobody tested.
check "trailing slash normalised for a plain user too" \
      "/home/jol" "$(operator_home 1000 /home/jol/ '')"
check "a home of / does not become an empty string"   \
      "/" "$(operator_home 1000 / '')"
# The join the script actually performs, asserted end-to-end rather than in pieces.
check "the evidence dir under sudo is operator-readable" \
      "/home/jol/.local/share/jol-fleet-health" \
      "$(operator_home 0 /root /home/jol)/.local/share/jol-fleet-health"
check "and in rescue.target it is under /root" \
      "/root/.local/share/jol-fleet-health" \
      "$(operator_home 0 /root '')/.local/share/jol-fleet-health"

echo ""
echo "=== group 7: ownership handover must never re-own a directory it does not own ==="
# This is the control-defeat vector found in review. The first version ran
#   chown "$SUDO_USER:" "$WIN_DIR" "$OUT"
# on a caller-controlled WIN_DIR, so
#   WIN_DIR=/var/lib/jol-workstation sudo DRY_RUN=0 jol-write-bench.sh
# would have chowned the privileged artifact directory (700 root:root on this host) to
# uid 1000 — dismantling the very untraversability that makes the custody and backup-proof
# gates report UNVERIFIED rather than pretend to know. Silent, and no error anywhere.
check "privileged dir outside home is NOT re-owned" \
      "FILE_ONLY_WARN" "$(handover_verdict 0 jol /var/lib/jol-workstation /home/jol)"
check "the default location may be handed over" \
      "FILE_AND_DIR"   "$(handover_verdict 0 jol /home/jol/.local/share/jol-fleet-health /home/jol)"
# Prefix discipline: /home/jol is a prefix of /home/jolevil as a STRING, but must not count
# as "inside the home". A case pattern without the slash would hand over a sibling tree.
check "a sibling whose name starts with the home is not inside it" \
      "FILE_ONLY_WARN" "$(handover_verdict 0 jol /home/jolevil/.local /home/jol)"
check "the home itself, not a path under it, is not re-owned" \
      "FILE_ONLY_WARN" "$(handover_verdict 0 jol /home/jol /home/jol)"
check "a plain user run hands nothing over" \
      "NO_HANDOVER"    "$(handover_verdict 1000 jol /home/jol/.local /home/jol)"
# sudo -s / sudo bash can leave SUDO_USER=root; re-owning to root would be a no-op at best
# and a false sense of handover at worst.
check "root invoking as root hands nothing over" \
      "NO_HANDOVER"    "$(handover_verdict 0 root /root/.local /root)"
check "root with no SUDO_USER hands nothing over" \
      "NO_HANDOVER"    "$(handover_verdict 0 '' /root/.local /root)"
check "a missing home is treated as outside, not as a wildcard" \
      "FILE_ONLY_WARN" "$(handover_verdict 0 jol /var/lib/jol-workstation '')"

echo ""
echo "write-bench fixtures: $PASS passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
