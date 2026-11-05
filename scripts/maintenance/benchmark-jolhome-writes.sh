#!/usr/bin/env bash
# =============================================================================
# benchmark-jolhome-writes.sh — runbook §3.6 as an executable, guarded check.
#
# WHY (t9)
# The LEGEND 900 is DRAM-less and leans on a dynamic SLC write cache. A short burst
# benchmarks at the rated ~4.7 GB/s; a large sequential write runs PAST the cache and
# falls to native TLC speed. Phase 2 is a 76 GiB rsync, which is precisely the
# workload that crosses that boundary, so the number that sizes the rescue-window
# reservation is the plateau, not the peak. Measuring the wrong one does not fail
# loudly — it produces a window that is simply too short at 03:00 with /home unmounted.
#
# WHY A SCRIPT AND NOT THE PASTED dd FROM THE RUNBOOK
# The command is three steps (write, clean up, sync) where the middle one is the
# evidence and the last one is easy to skip. This version also refuses the two ways
# the test can be run meaninglessly or dangerously: against a target that is not the
# encrypted volume, and against a volume that already holds something.
#
# Design contract: DRY_RUN=1 default, root required to write, always cleans up,
# verifies the cleanup by post-state rather than by the command having run, and prints
# a copy window derived from the MEASURED plateau.
# =============================================================================
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

DRY_RUN="${DRY_RUN:-1}"
STAGING="${STAGING:-/mnt/jolhome-staging}"
MAPPER="${MAPPER:-jolhome_crypt}"
SIZE_GIB="${SIZE_GIB:-32}"          # per §3.6: 32 GiB defeats most dynamic SLC caches
PAYLOAD_GIB="${PAYLOAD_GIB:-76}"    # the real Phase 2 rsync volume, for the projection

# -----------------------------------------------------------------------------
# operator_home — WHICH home the evidence belongs to, as a PURE FUNCTION.
#
# The mutating path requires uid 0, so this script normally runs under sudo, where
# $HOME is /root. Resolving the evidence directory from $HOME therefore wrote the
# samples into /root/.local/share/jol-fleet-health (under a 700 /root, unreadable by
# the operator) while --report — which is deliberately reachable WITHOUT root — looked
# in the operator's own home and found nothing. A completed benchmark would then have
# answered "no benchmark has been run yet": the two paths never meet. That is the
# silent-failure class this thread keeps documenting, shipped in my own first draft.
#
#   $1 uid           $2 $HOME as seen by this process
#   $3 home of SUDO_USER, already resolved (empty when not applicable)
#
# When there is no SUDO_USER at all — a genuine root shell, e.g. the rescue.target
# window §3.6 is meant to run in — /root IS the operator's home and is the right answer.
# -----------------------------------------------------------------------------
operator_home() {
    local uid="${1:-1}" home="${2:-/none}" sudo_home="${3:-}"
    # Three separate decisions, on three separate lines, so each is independently testable:
    # a mutant that deletes two of them at once can make a fixture about the third unobservable
    # (that is exactly what a bundled needle did to the first version of this harness).
    home="${home%/}"
    [[ -n "$home" ]] || home="/"
    sudo_home="${sudo_home%/}"
    if [[ "$uid" == "0" && -n "$sudo_home" ]]; then printf '%s\n' "$sudo_home"; return 0; fi
    printf '%s\n' "$home"
}

_SUDO_HOME=""
if [[ "$(id -u)" == "0" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    # getent, not "/home/$SUDO_USER": the operator's home is whatever passwd says it is.
    _SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
fi
_OP_HOME="$(operator_home "$(id -u)" "$HOME" "$_SUDO_HOME")"
WIN_DIR="${WIN_DIR:-$_OP_HOME/.local/share/jol-fleet-health}"
# HANDOVER is computed later, after handover_verdict() is defined. Calling a function
# before bash has seen its definition does not raise a visible error here: the command
# substitution captures the empty string and exits 127, so the case statement that acts
# on the verdict would match NO branch and the ownership warning would silently disappear
# — the warning vanishing exactly when an operator points WIN_DIR somewhere it should not.
PROBE="$STAGING/.wtest"

FAILURES=0
say()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
info() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
alert() { printf '[%s] ALERT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; FAILURES=$((FAILURES+1)); }
die()  { printf '[%s] ABORT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 2; }

# -----------------------------------------------------------------------------
# handover_verdict — may this run change OWNERSHIP, and of what?
#
# Why this exists as a separate decision: the first version of the handover ran
#   chown "$SUDO_USER:" "$WIN_DIR" "$OUT"
# on a WIN_DIR the caller controls entirely through the environment. That turns a
# convenience into a control-defeat primitive:
#
#   WIN_DIR=/var/lib/jol-workstation sudo DRY_RUN=0 jol-write-bench.sh
#
# would chown the privileged artifact directory — measured on this host `700 root:root` —
# over to uid 1000. That directory's untraversability is exactly what makes the custody
# gate and the Phase 0 backup-proof gate report "UNVERIFIED, not absent" instead of
# pretending to know; handing it to the operator would have quietly dismantled that, from
# a benchmark script, with no error anywhere.
#
# The rule, which is deliberately boring:
#   - a file this run created may always be handed over — it is ours;
#   - a DIRECTORY's ownership is changed only when it lies inside the operator's own home,
#     where the operator already owns the parent and nothing can be weakened;
#   - anywhere else, ownership is left alone and the operator is told to use sudo.
#
#   $1 uid  $2 sudo_user  $3 win_dir  $4 operator_home
# -----------------------------------------------------------------------------
handover_verdict() {
    local uid="${1:-1}" su="${2:-}" dir="${3:-}" home="${4:-}"
    if [[ "$uid" != "0" || -z "$su" || "$su" == "root" ]]; then printf 'NO_HANDOVER\n';  return 0; fi
    # An empty home would make the pattern below "/*", which matches EVERY absolute path and
    # would authorise re-owning any directory on the host. operator_home never returns empty,
    # but a decision this consequential must not rest on the caller's discipline — it is
    # measured, and it was wrong: this branch returned FILE_AND_DIR for /var/lib/* until a
    # fixture written to prove the guard safe caught it.
    [[ -n "$home" ]] || { printf 'FILE_ONLY_WARN\n'; return 0; }
    case "$dir" in
        "$home"/*) printf 'FILE_AND_DIR\n'; return 0 ;;
        *)         printf 'FILE_ONLY_WARN\n' ;;
    esac
}

# -----------------------------------------------------------------------------
# plateau_summary — the whole judgement, as a PURE FUNCTION so it can be tested
# without writing 32 GiB to a disk.
#
#   stdin : lines of "<elapsed_seconds> <MiB_per_second>", one per interval
#   $1    : payload in GiB to project the copy window onto
#
# Writes "<peak>\t<sustained>\t<collapse_s>\t<window_min>" or a refusal token.
#
# window_min is the ceiling of the computed time, never the floor.
#
# Sustained is the mean of the LAST THIRD of intervals, not of all of them. A mean
# over the whole run averages the fast SLC phase into the slow TLC phase and reports
# a number that describes neither — which is the mistake that makes a vendor peak
# look like a safe planning figure.
#
# The window is computed in whole minutes inside awk rather than by a downstream
# `bc`: the first draft piped through bc, which is not installed by default, and
# `bc ... || echo 0` would then have printed a copy window of 0 minutes — a confidently
# wrong number that would have shortened the very window this measurement exists to size.
# -----------------------------------------------------------------------------
plateau_summary() {
    local payload_gib="${1:-76}"
    awk -v payload="$payload_gib" '
        NF >= 2 && $1+0 >= 0 && $2+0 > 0 { n++; e[n] = $1+0; r[n] = $2+0 }
        END {
            if (n == 0)   { print "NO_SAMPLES"; exit }
            if (n < 3)    { print "TOO_FEW_SAMPLES"; exit }
            peak = r[1]; collapse = 0; lastpeak = 1
            for (i = 2; i <= n; i++) if (r[i] > peak) peak = r[i]
            for (i = 1; i <= n; i++) if (r[i] == peak) lastpeak = i
            # A collapse is a FALL FROM THE PEAK, so it can only occur after the last
            # peak sample. The first draft scanned for "any sample at or below half the
            # eventual maximum", which reported a collapse at 20s on a drive that was
            # simply warming up (100 -> 1000 MiB/s) — a fabricated cache cliff, in the
            # one direction that would have made the operator trust a false finding.
            half = peak / 2
            for (i = lastpeak + 1; i <= n; i++) if (r[i] <= half) { collapse = e[i]; break }
            tail_from = int(n * 2 / 3) + 1
            if (tail_from < 2) tail_from = 2
            s = 0; c = 0
            for (i = tail_from; i <= n; i++) { s += r[i]; c++ }
            sustained = (c > 0) ? s / c : 0
            if (sustained <= 0) { print "ZERO_SUSTAINED"; exit }
            # Round the window UP: truncating 6.48 min to 6 books a window shorter than
            # the measurement says it needs, and a short window is the failure mode this
            # whole benchmark exists to prevent.
            secs = (payload * 1024) / sustained
            wmin = int(secs / 60)
            if (wmin * 60 < secs) wmin++
            printf "%d\t%d\t%d\t%d\n", peak, sustained, collapse, wmin }
    '
}

# -----------------------------------------------------------------------------
# verdict for the guards, pure so the refusal branches are testable
# -----------------------------------------------------------------------------
target_verdict() { # $1=is_mount  $2=same_as_root  $3=source  $4=extra_entries
    if [[ "$1" != "yes" ]]; then printf 'NOT_MOUNTED\n';   return 0; fi
    if [[ "$2" == "yes" ]];   then printf 'RESOLVES_TO_ROOT\n'; return 0; fi
    if [[ "$3" != "/dev/mapper/$MAPPER" ]]; then printf 'WRONG_SOURCE\n'; return 0; fi
    if [[ "$4" != "0" ]];     then printf 'TARGET_NOT_EMPTY\n'; return 0; fi
    printf 'OK\n'
}

# --- preconditions -----------------------------------------------------------
if [[ "$DRY_RUN" != "1" && "$(id -u)" -ne 0 ]]; then
    die "needs root to write to $STAGING (it is root-owned). DRY_RUN=1 shows the plan unprivileged."
fi
if [[ "${1:-}" == "--report" ]]; then
    latest="$(find "$WIN_DIR" -maxdepth 1 -name 'write-bench-*.tsv' -printf '%T@ %p\n' 2>/dev/null \
              | sort -rn | head -1 | cut -d' ' -f2- || true)"
    if [[ -z "$latest" ]]; then echo "no benchmark has been run yet"; exit 1; fi
    echo "latest: $latest"; tail -20 "$latest"; exit 0
fi

say "=== jolhome sustained-write benchmark (DRY_RUN=$DRY_RUN, target $STAGING) ==="

IS_MOUNT=no; SAME_AS_ROOT=no; SRC=""
if findmnt -rn -o TARGET "$STAGING" >/dev/null 2>&1; then IS_MOUNT=yes; fi
if [[ "$IS_MOUNT" == "yes" ]]; then
    [[ "$(stat -c '%d' "$STAGING")" == "$(stat -c '%d' /)" ]] && SAME_AS_ROOT=yes
    SRC="$(findmnt -rno SOURCE "$STAGING" 2>/dev/null || true)"
fi
EXTRA="$(find "$STAGING" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name '.wtest' 2>/dev/null | wc -l)"
TVERDICT="$(target_verdict "$IS_MOUNT" "$SAME_AS_ROOT" "$SRC" "$EXTRA")"
HANDOVER="$(handover_verdict "$(id -u)" "${SUDO_USER:-}" "$WIN_DIR" "$_OP_HOME")"
info "  target: mount=$IS_MOUNT off-disk=$([ "$SAME_AS_ROOT" = no ] && echo yes || echo no) source='${SRC:-none}' extra_entries=$EXTRA"

if [[ "$DRY_RUN" == "1" ]]; then
    case "$TVERDICT" in
        OK)               info "  guards: PASS" ;;
        NOT_MOUNTED)      alert "  guards: $STAGING is not mounted — nothing to benchmark" ;;
        RESOLVES_TO_ROOT) alert "  guards: $STAGING resolves to / — writing here would fill the root filesystem, not the volume" ;;
        WRONG_SOURCE)     alert "  guards: backed by '${SRC}', expected /dev/mapper/$MAPPER — the benchmark would measure the wrong disk" ;;
        TARGET_NOT_EMPTY) alert "  guards: $EXTRA unexpected entries already present — refusing to write a benchmark onto a populated tree" ;;
    esac
    printf 'DRY  : would write %s GiB as %s sequential 1 GiB direct steps to %s\n' "$SIZE_GIB" "$SIZE_GIB" "$PROBE"
    printf 'DRY  : per-interval samples to %s\n' "$WIN_DIR/write-bench-<utc>.tsv"
    # The handover decision is printed in the PLAN, not only after the fact: an operator
    # pointing WIN_DIR at a privileged directory must see that ownership will NOT be
    # changed there before 32 GiB has been written, not after.
    printf 'DRY  : ownership handover: %s (WIN_DIR=%s, operator home=%s)\n' "$HANDOVER" "$WIN_DIR" "$_OP_HOME"
    # The path is printed as RESOLVED, not as an expression: under sudo an operator must be
    # able to see at a glance that the evidence will land in their own home, not in /root.
    printf 'DRY  : running as uid %s (%s)%s\n' "$(id -u)" "$(id -un)" \
        "${SUDO_USER:+, invoked by sudo from ${SUDO_USER}}"
    printf 'DRY  : %s sequential dd steps of 1 GiB, each at its own seek offset, oflag=direct conv=fdatasync\n' "$SIZE_GIB"
    printf 'DRY  : first step would be: dd if=/dev/zero of=%s bs=1M count=1024 seek=0 oflag=direct conv=fdatasync\n' "$PROBE"
    # Stated as a fact rather than a promise: this script always uses dd, so the line
    # cannot imply a different execution path than the one that will actually run.
    say "  fio available on this host: $(command -v fio >/dev/null && echo yes || echo no) — this script uses dd either way,"
    say "         so the result depends on nothing that might be absent on the rescue shell."
    if (( FAILURES > 0 )); then say "=== PLAN NOT SAFE, $FAILURES guard(s) failed ==="; exit 1; fi
    say "=== PLAN OK — re-run with DRY_RUN=0 under sudo to execute ==="; exit 0
fi

case "$TVERDICT" in
    OK) : ;;
    *) die "guard $TVERDICT on $STAGING — resolve it before writing $SIZE_GIB GiB of test data" ;;
esac

mkdir -p "$WIN_DIR" 2>/dev/null || die "cannot create $WIN_DIR"
OUT="$WIN_DIR/write-bench-$(date -u +%Y%m%dT%H%M%SZ).tsv"
printf '# elapsed_s\tinterval_rate_MiBps\tpart MiB\tof %s GiB\n' "$SIZE_GIB" > "$OUT" \
    || die "cannot write $OUT"

# Act on the handover verdict computed above. The file is always ours to hand over; the
# directory is only ours to re-own when it sits inside the operator's home.
case "$HANDOVER" in
    NO_HANDOVER)
        ;;
    FILE_AND_DIR)
        if chown "$SUDO_USER:" "$WIN_DIR" "$OUT" 2>/dev/null; then
            say "evidence handed to ${SUDO_USER}: $(stat -c '%U:%G %a' "$OUT") (dir too: $WIN_DIR)"
        else
            alert "could not chown $OUT to ${SUDO_USER} — read it with sudo, --report will not find it"
        fi
        ;;
    FILE_ONLY_WARN)
        chown "$SUDO_USER:" "$OUT" 2>/dev/null \
            || alert "could not chown $OUT to ${SUDO_USER}"
        alert "WIN_DIR $WIN_DIR is outside ${SUDO_USER}'s home — its ownership was NOT changed, deliberately: this script does not re-own directories it does not own the parent of. --report will not find the evidence there; read it with sudo, or leave WIN_DIR unset."
        ;;
esac

# Always remove the test file, even on interruption: leaving 32 GiB on a volume that
# Phase 2 must copy into would change the very capacity the cutover preflight checks.
cleanup() {
    [[ -e "$PROBE" ]] && rm -f "$PROBE" 2>/dev/null
    sync 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say "writing ${SIZE_GIB} GiB as ${SIZE_GIB} sequential 1 GiB direct steps"
START=$(date -u +%s)
for (( step=1; step<=SIZE_GIB; step++ )); do
    t0=$(date -u +%s)
    # seek, not a growing count: each step must measure ITS OWN interval. Writing 1 GiB,
    # then 2 GiB from offset zero, then 3 GiB yields a cumulative average that hides the
    # cache transition behind the fast samples that precede it — the opposite of what
    # this benchmark exists to find.
    if ! dd if=/dev/zero of="$PROBE" bs=1M count=1024 \
              seek=$(( (step - 1) * 1024 )) oflag=direct conv=fdatasync status=none; then
        die "dd failed at step ${step}/${SIZE_GIB} — see dmesg; the volume may be failing"
    fi
    t1=$(date -u +%s)
    el=$(( t1 - t0 )); (( el < 1 )) && el=1
    rate=$(( 1024 / el ))
    printf '%s\t%s\t%s\t%s\n' "$((t1 - START))" "$rate" "$((step * 1024))" "" >> "$OUT"
    printf '  step %2s/%s GiB (offset %5s MiB): %6s MiB/s in %ss\n' \
        "$step" "$SIZE_GIB" "$(( (step - 1) * 1024 ))" "$rate" "$el"
done

SUMMARY="$(awk -F'\t' 'NR>1 { print $1, $2 }' "$OUT" | plateau_summary "$PAYLOAD_GIB")"
if [[ "$SUMMARY" == *$'\t'* ]]; then
    IFS=$'\t' read -r PEAK SUSTAINED COLLAPSE WINDOW_MIN <<<"$SUMMARY"
    say "RESULT  peak ${PEAK} MiB/s | sustained ${SUSTAINED} MiB/s | collapse at ${COLLAPSE}s"
    say "        ${PAYLOAD_GIB} GiB at the SUSTAINED rate = ${WINDOW_MIN} min of copy time"
    if (( COLLAPSE > 0 )); then
        say "        the SLC cache held for ${COLLAPSE}s then fell over: plan the Phase 2 window"
        say "        from the sustained figure, never the peak."
    else
        say "        no clear collapse seen inside ${SIZE_GIB} GiB — either the cache is larger"
        say "        than the test or the drive is not caching; consider SIZE_GIB=64."
    fi
    printf 'PEAK_MiBps=%s SUSTAINED_MiBps=%s COLLAPSE_S=%s WINDOW_MIN_FOR_%sGIB=%s\n' \
        "$PEAK" "$SUSTAINED" "$COLLAPSE" "$PAYLOAD_GIB" "$WINDOW_MIN" >> "$OUT"
else
    alert "could not summarise samples: $SUMMARY"
fi

# Verify the cleanup by post-state, not by the command having run.
cleanup
if [[ -e "$PROBE" ]]; then
    alert "$PROBE still exists after cleanup — the ${SIZE_GIB} GiB test file was NOT removed"
else
    info "cleanup verified: $PROBE absent, target holds only $(find "$STAGING" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) entries"
fi

say "evidence: $OUT"
if (( FAILURES == 0 )); then say "=== BENCHMARK COMPLETE ==="; else say "=== BENCHMARK finished with $FAILURES problem(s) ==="; exit 1; fi
exit 0
