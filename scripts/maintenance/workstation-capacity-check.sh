#!/usr/bin/env bash
# =============================================================================
# workstation-capacity-check.sh — custodian workstation (admin01) capacity watchdog
#
# WHY THIS EXISTS (measured 2026-11-04): /home (/dev/nvme0n1p7) reached 100 % with
# 1.3 MB free while PyCharm, Qoder and this agent were running on it. The only thing
# that told anybody was the GNOME desktop popup, whose condition is "less than 50 MiB
# left" — i.e. it fires at 0.05 % of a 92 GiB partition, after every process on the
# box is already one write away from failing. There was NO capacity watchdog: no
# user-cron alert and nothing in /etc/cron.d (checked: anacron, certbot, e2scrub_all,
# php, sysstat). The same condition had already been recorded once before, together
# with a mitigation decision and a prepared repartition runbook dated 2026-08-22 that
# was never executed. A recurring failure with an unexecuted fix is a monitoring
# defect, not a capacity defect, so this script is the monitoring half.
#
# WHAT IT DOES (read-only apart from its own state/log files):
#   gate 1  filesystem capacity  — percent used, absolute free, AND inode free
#   gate 2  mount reality        — every fstab block device is actually mounted AT
#                                  its own path, not silently absorbed by its parent
#   gate 3  self-liveness        — the timer that runs this script is enabled, and
#                                  the previous run is not stale (monitor the monitor)
#   gate 4  fill trend           — free space dropped faster than TREND_DROP_PCT since
#                                  the last run (warns BEFORE a threshold is crossed)
#
# DESIGN RULES BORROWED FROM THE FLEET WATCHDOGS (do not "simplify" these out):
#   A. PATH is set explicitly. cron/systemd do not export sbin dirs, and an empty
#      command lookup read as "check failed" produced 415 lines of 100 %-false
#      CRITICALs on hv01 (2026-07-31..10-21). A missing binary is UNAVAILABLE, never
#      a verdict. (See hv01-health-check.sh header note D.)
#   B. The completion marker goes to STDOUT. `info()` writes to the log file only,
#      which made hv01/pbs01 permanently UNVERIFIED to the remote pull — a caller
#      must be able to tell "every gate ran, nothing to report" from "died halfway".
#   C. Absence of failure is not presence of success: gate 3 requires a fresh run
#      stamp, so a dead timer is an alert rather than a quiet green.
#   D. Nothing here prints a secret. Only device names, mount points and numbers.
#      /home/jol/secrets is Tier-1 forbidden material and is never opened, listed or
#      measured — capacity is read from the filesystem, not from its contents.
#   E. The log is NOT the only copy. /home is the filesystem being monitored, so when
#      it is 100 % full the log append fails — exactly when the alert matters most.
#      Every line therefore goes to stdout first (journald captures the service, and
#      the journal is not on /home); file failure is reported, never swallowed.
#
# Exit: 0 = all gates pass, 1 = at least one CRITICAL, 2 = guard (wrong host / cannot
#       proceed). rc=2 is reserved for a refusal to run, never for a finding.
# Usage: ~/.local/bin/jol-workstation-capacity-check.sh [--notify=0]
# Install: see install-workstation-capacity-timer.sh (systemd user timer, 15 min)
# =============================================================================
set -uo pipefail

# Rule A — cron/systemd minimal PATH would turn missing probes into false CRITICALs.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# --- configuration (every threshold is an env override, for testing and triage) ---
# Used-percent bar. 90 % of /home = ~9 GiB free: enough room for an IDE index, a
# container build and a Toolbox update to finish without the partition going green->red
# inside one timer interval.
CAP_ALERT_PCT="${CAP_ALERT_PCT:-90}"
# Absolute floor, independent of percent. This is the half the GNOME popup lacked: on a
# 9.1 GiB partition 90 % used leaves 910 MiB, which is NOT comfortable, while on a
# 92 GiB partition 90 % leaves 9.2 GiB, which is. Both conditions are checked and the
# WORSE of the two decides the verdict.
CAP_MIN_FREE_MIB="${CAP_MIN_FREE_MIB:-4096}"
# The floor is CAPPED at this percentage of each filesystem's own size, because a flat
# 4 GiB floor flags /boot/efi (1.1 GiB total) and /boot (1.9 GiB) as emergencies while
# they are perfectly healthy — both did on the first live run, 2026-11-04. A watchdog
# that screams at healthy mounts is worse than none: hv01's 415-line false-positive log
# is the proof. The floor still bites where it matters — on a 92 GiB /home the cap is
# 18 GiB, so the 4 GiB floor governs.
CAP_FLOOR_SIZE_PCT="${CAP_FLOOR_SIZE_PCT:-20}"
# A full inode table fails every write on a filesystem that looks 40 % empty in `df -h`.
INODE_ALERT_PCT="${INODE_ALERT_PCT:-90}"
# Fill-rate early warning: alert if free space dropped more than this many percentage
# points since the previous run, even if the absolute level is still comfortable.
TREND_DROP_PCT="${TREND_DROP_PCT:-10}"
# Percentage POINTS are coarse: one point on a 93 GiB partition is ~930 MiB, so a slow
# fill is invisible to the rule above for hours. These two govern the MiB-resolution rate
# added below, which is what actually answers "how long until this is full".
TREND_HOURS_TO_FULL="${TREND_HOURS_TO_FULL:-72}"
# A shift smaller than this is measurement noise between two runs, not a trend.
TREND_DROP_MIB="${TREND_DROP_MIB:-512}"
# Time-to-full projection is a WARN-only judgement by default: it extrapolates one
# interval onto a filesystem whose usage is bursty by nature (an IDE index, a browser
# cache refill, a git gc). Alerting CRITICAL on a projection would be crying wolf with
# a number that looks more precise than it is, which is how hv01's 415 false alerts were
# produced. Set to 1 to promote it to CRITICAL once the rate has been observed long
# enough to trust.
TREND_PROJECT_ALERTS="${TREND_PROJECT_ALERTS:-0}"
# Gate 5 — off-device backup ARTIFACT freshness. Gate 2 proves the mount is real; this
# proves something was actually WRITTEN there recently. On 2026-11-04 both were needed:
# the mount was absent AND the newest Terraform state snapshot was 4 days old, and only
# the second is the actual loss. A mounted-but-unused backup disk reads "healthy" to
# every mount-based and capacity-based check in this script.
# Format: "<path-glob>|<max_age_hours>" entries separated by ';'. 26 h mirrors
# VZDUMP_MAX_AGE_HOURS in hv01-health-check.sh — one missed daily run is already a finding.
BACKUP_ARTIFACTS="${BACKUP_ARTIFACTS:-/mnt/jol-backup/jol-control/*terraform.tfstate*.age|26;/mnt/jol-backup/jol-state-backup/*.age|26}"
# Gate 6 — is the /home backup still happening? Phase 0 was executed manually on
# 2026-11-05. A backup taken once is not a backup policy, and the proof artifact that
# unblocks provision-jolhome-disk.sh expires after 7 days, so a forgotten schedule
# degrades into "the migration is blocked" with nothing naming the cause.
HOME_BACKUP_DIR="${HOME_BACKUP_DIR:-/mnt/jol-backup/jol-home-backup}"
HOME_BACKUP_MAX_AGE_H="${HOME_BACKUP_MAX_AGE_H:-30}"
# Gate 3: the timer fires every 15 min; 30 h without a stamp means the timer is dead
# (a laptop that hibernates for a weekend must not read as a healthy fleet).
STALE_MAX_HOURS="${STALE_MAX_HOURS:-30}"
UNIT_NAME="${UNIT_NAME:-jol-workstation-capacity.timer}"
# Host guard. This measures the partition table of the MACHINE IT RUNS ON, so the
# dangerous case is not "unknown laptop" — it is running it on a FLEET HOST, where it
# would happily report hv01's or pbs01's geometry as if it were the custodian's and
# produce a green about a machine whose watchdog it never consulted. So the guard is a
# DENY list of known fleet identities, not an allow list of hostnames.
# (Measured 2026-11-04: this workstation's hostname is `ubuntu`, while the fleet docs
# call it `admin01`. An allow-list default of `admin01` would have aborted the watchdog
# on its own machine — a documentation-vs-ground-truth trap of the class this repo has
# been bitten by before. Do not convert this back to an allow list.)
FLEET_HOSTS="${FLEET_HOSTS:-pve-prod-hv01 pbs01 llm-prod-lt01 rag-prod-lt01 mcp-prod-lt01 her-prod-lt01 prox01}"
HOST_ID="$(hostname -s 2>/dev/null || echo unknown)"
FQDN_ID="$(hostname 2>/dev/null || echo unknown)"
for h in $FLEET_HOSTS; do
    if [[ "$HOST_ID" == "$h" || "$FQDN_ID" == "$h" || "$FQDN_ID" == "$h."* ]]; then
        printf 'ABORT: %s is a fleet host with its own watchdog (jol-health-check / pbs01-health-check).\nThis capacity script measures the custodian workstation partition table and would report a false green here.\n' "$h" >&2
        exit 2
    fi
done
LOG_DIR="${LOG_DIR:-$HOME/.local/share/jol-fleet-health}"
LOG="$LOG_DIR/capacity.log"
STATE="$LOG_DIR/capacity-state"          # last reading per mount -> trend + liveness
# When STATE was written. The MiB reading in STATE is meaningless as a RATE without the
# interval it was measured across, and the state line's own format carries no timestamp.
STATE_TS="$LOG_DIR/capacity-state-ts"
# MiB-resolution history, one row per mount per run. This file is the actual point of the
# change: `capacity.log` prints GiB because that is what a human scanning a log wants, and
# 8 GiB vs 8 GiB tells you nothing about a fill rate. Asserting a rate from it earlier in
# this thread produced a number ('~3.4 GiB/day') that the stored data could not support.
# To MEASURE that number instead of remembering it:
#   awk -F'\t' -v m=/home '
#     $2==m { n++; if (!f) { f=$1; hi=$3 }; lo=$3; last=$1 }
#     END {
#       if (n < 2)  { printf "%s: need >= 2 samples to bound a rate\n", m; exit 1 }
#       h = (last - f) / 3600
#       if (h < 1)  { printf "%s: only %.3f h of history, too short to extrapolate\n", m, h; exit 1 }
#       d = (hi - lo) / 1024
#       if (d <= 0) { printf "%s: %.2f GiB GAINED over %.1f h, not filling\n", m, -d, h; exit 0 }
#       printf "%s: %.2f GiB/day over %.1f h\n", m, d/(h/24), h
#     }' "$SAMPLES"
# Every refusal EXITS NON-ZERO on purpose. Two mistakes were made in the first draft of
# this snippet and both were caught only by RUNNING it against the real file: it divided
# by a zero-length window and printed "-nan GiB/day" with rc=0, and it wrapped one printf
# across two lines, which is not valid awk inside a single-line { ...; } block and made
# every branch die with a parse error. A number computed from nothing must be impossible
# to read as a result — and a helper embedded in documentation has to be executed, not
# assumed to parse.
SAMPLES="$LOG_DIR/capacity-samples.tsv"
SAMPLE_KEEP="${SAMPLE_KEEP:-20000}"
STAMP="$LOG_DIR/capacity-last-run"       # last run time -> gate 3
SIG_FILE="$LOG_DIR/capacity-last-alert"  # alert set already notified
NOTIFY="${NOTIFY:-1}"
[[ "${1:-}" == "--notify=0" ]] && NOTIFY=0

ALERTS=0
LOG_FILE_OK=1

mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true

# Rule E — stdout is the primary channel (journald holds the copy that survives a full
# /home); the file is the convenience copy. A failed append is announced, not hidden,
# and never re-enters alert() (no recursion).
emit() {
    printf '%s\n' "$1"
    if ! printf '%s\n' "$1" >>"$LOG" 2>/dev/null; then
        if [[ "$LOG_FILE_OK" == "1" ]]; then
            LOG_FILE_OK=0
            printf '[%s] NOTE: %s is unwritable (the monitored filesystem is full) — relying on the journal copy only\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG"
        fi
    fi
}
# Alert texts are also kept IN MEMORY, not only in the log. When /home is the full
# filesystem the log append fails, and a notification built by grepping that log would
# then be built from NOTHING — the alert would arrive empty at the exact moment it
# matters. The array is the authoritative copy for the verdict block.
ALERT_TEXTS=()
alert() {
    ALERTS=$((ALERTS + 1))
    ALERT_TEXTS+=("$1")
    emit "[$(date '+%Y-%m-%d %H:%M:%S')] CRITICAL: $1"
}
warn() { emit "[$(date '+%Y-%m-%d %H:%M:%S')] WATCH: $1"; }
info() { emit "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
probe_missing() { alert "probe unavailable: $1 not found (PATH=$PATH) — gate $2 not evaluated"; }

# Desktop notification, decoupled from its own transport: a missing/broken notify-send
# is recorded, never swallowed — otherwise this watchdog would fail silently, the exact
# defect it exists to detect.
push_note() {
    [[ "$NOTIFY" == "1" ]] || return 0
    command -v notify-send >/dev/null 2>&1 || { info "notify-send absent — desktop transport unavailable"; return 0; }
    notify-send -u "$1" -t 0 "$2" "$3" 2>/dev/null || info "notify-send failed — desktop transport also dead"
}

emit "[$(date '+%Y-%m-%d %H:%M:%S')] === JOL WORKSTATION CAPACITY CHECK START (host=$HOST_ID) ==="

# --- gate 3a: self-liveness, read BEFORE this run overwrites the stamp --------
# Checked first so that a watchdog that has been dead for days still reports the gap
# it is currently closing.
PREV_STAMP="$(cat "$STAMP" 2>/dev/null || true)"
if [[ -z "$PREV_STAMP" ]]; then
    info "gate 3: no previous run stamp — first run, freshness not yet established"
else
    PREV_EPOCH="$(date -u -d "$PREV_STAMP" +%s 2>/dev/null || echo '')"
    if [[ -z "$PREV_EPOCH" ]]; then
        alert "gate 3: run stamp '$PREV_STAMP' is unreadable — watchdog liveness UNVERIFIED, not assumed"
    else
        GAP_H=$(( ( $(date -u +%s) - PREV_EPOCH ) / 3600 ))
        if (( GAP_H > STALE_MAX_HOURS )); then
            alert "gate 3: this watchdog last ran ${GAP_H} h ago (> ${STALE_MAX_HOURS} h) — the timer is NOT firing, capacity is unmonitored"
        else
            info "gate 3: previous run ${GAP_H} h ago (fresh)"
        fi
    fi
fi

# gate 3b: the unit that schedules it. Absent unit file = not installed (dev/CI run),
# which is reported and does NOT alert; present but disabled IS an alert, because a
# disabled timer means every future green comes from a manual run nobody will repeat.
if have systemctl; then
    if [[ -f "$HOME/.config/systemd/user/$UNIT_NAME" ]]; then
        UNIT_STATE="$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)"
        case "$UNIT_STATE" in
            enabled) info "gate 3: $UNIT_NAME enabled" ;;
            static|masked|disabled|created|generated|bad|"")
                alert "gate 3: $UNIT_NAME is present but '$UNIT_STATE' — capacity alerts will stop when this session ends" ;;
            *) info "gate 3: $UNIT_NAME state: $UNIT_STATE" ;;
        esac
        NEXT_RUN="$(systemctl --user list-timers "$UNIT_NAME" --no-pager 2>/dev/null | sed -n '2p')"
        [[ -n "$NEXT_RUN" ]] && info "gate 3: next scheduled run: ${NEXT_RUN%% *}* "
    else
        info "gate 3: $UNIT_NAME not installed — running standalone (install via install-workstation-capacity-timer.sh)"
    fi
else
    probe_missing systemctl 3
fi

# --- gate 2: mount reality ---------------------------------------------------
# The failure this guards is not low space but FALSE space: if a declared device is
# not mounted at its own path, its directory is just files on the parent filesystem,
# and a capacity check on that path reports the parent's headroom while the real
# device sits empty. hv01 saw exactly this on 2026-10-21 (a missing HDD shown as
# "active, 93 GB free"). `findmnt` on a SUBDIRECTORY silently returns nothing, so the
# sound test is `--target` (resolves to the containing mount) compared against the
# declared mount point for equality.
MOUNTS_CHECKED=0
if have findmnt && have df && [[ -r /etc/fstab ]]; then
    while read -r fs_spec fs_mount fs_type rest || [[ -n "$fs_spec" ]]; do
        case "$fs_spec" in ''|\#*) continue ;; esac           # blank / comment
        case "$fs_type" in swap|autofs|tmpfs|devtmpfs|squashfs|overlay|none) continue ;; esac
        case "$fs_spec" in /dev/*|UUID=*|PARTUUID=*|LABEL=*) ;; *) continue ;; esac
        resolved="$(findmnt -rno TARGET --target "$fs_mount" 2>/dev/null || true)"
        if [[ -z "$resolved" ]]; then
            alert "gate 2: $fs_mount has no mount at all — its path is ordinary files on a parent filesystem"
        elif [[ "$resolved" != "$fs_mount" ]]; then
            alert "gate 2: $fs_mount is NOT mounted (path resolves to '$resolved') — capacity measured there belongs to a different device"
        else
            MOUNTS_CHECKED=$((MOUNTS_CHECKED + 1))
        fi
    done < /etc/fstab
    info "gate 2: $MOUNTS_CHECKED fstab block mount(s) verified at their own path"
    if (( MOUNTS_CHECKED == 0 )); then
        alert "gate 2: no fstab block mount could be verified — mount reality UNVERIFIED, not clean"
    fi
else
    probe_missing "findmnt/df" 2
fi

# --- gate 1 + gate 4: capacity and fill trend --------------------------------
# `df -P` (POSIX) is used deliberately: plain `df -h` WRAPS long device names onto a
# second line, and a wrapped line parsed as a healthy row is a mount that silently
# drops out of the census. Pseudo-filesystems are excluded by fstype, not by name
# guessing.
declare -A PREV_PCT=()
declare -A PREV_AVAIL=()
NOW_EPOCH="$(date -u +%s)"
# The previous run's timestamp, not this one's: gate 3 has already read and will
# re-write $STAMP. Absent or unparseable means the interval is unknown, and an unknown
# interval means no rate may be computed at all — a division by a zero-length window is
# not a slow fill, it is a lie.
PREV_TS=""
if [[ -r "$STATE_TS" ]]; then
    PREV_TS="$(tr -cd '0-9' < "$STATE_TS" 2>/dev/null || true)"
fi
if [[ -r "$STATE" ]]; then
    while read -r _m _av pct || [[ -n "${_m:-}" ]]; do
        case "$_m" in ''|\#*) continue ;; esac
        PREV_PCT["$_m"]="$pct"
        # Column 2 was already being measured and DISCARDED here (read into `_av` and
        # never used). The MiB figure was in the state file all along; only the log line
        # had thrown the precision away.
        PREV_AVAIL["$_m"]="$_av"
    done < "$STATE"
fi

NEW_STATE="$LOG_DIR/capacity-state.new"
: >"$NEW_STATE" 2>/dev/null || NEW_STATE=""
# The df working rows live OUTSIDE the monitored filesystem: mktemp lands in /tmp (on /),
# so a 100 % full /home cannot make the census itself fail to materialise.
ROWS="$(mktemp 2>/dev/null || echo '')"
if [[ -z "$ROWS" ]]; then
    alert "gate 1: cannot create a temp file — filesystem census UNVERIFIED"
    ROWS="$LOG_DIR/.df.rows"
fi
DF_COUNTED=0

DF_OUT="$(df -P -x tmpfs -x devtmpfs -x squashfs -x efivarfs -x overlay -x fuse.gvfsd-fuse 2>/dev/null)"
if [[ -z "$DF_OUT" ]]; then
    alert "gate 1: df returned nothing — filesystem capacity is UNVERIFIED, not assumed free"
else
    # Deduplicate by mount point: a bind mount or a device listed twice must not be
    # counted (or alerted on) twice.
    printf '%s\n' "$DF_OUT" | tail -n +2 |
        awk '{ m=$6; for (i=7; i<=NF; i++) m=m" "$i; if (!(m in seen)) { seen[m]=1; print $1, $2, $4, $5, m } }' |
    while read -r fs _blocks avail pct mnt; do
        [[ -n "${fs:-}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$fs" "$_blocks" "$avail" "$pct" "$mnt"
    done >"$ROWS" 2>/dev/null || true

    while read -r fs blocks avail pct mnt; do
        [[ -n "${fs:-}" ]] || continue
        DF_COUNTED=$((DF_COUNTED + 1))
        used_pct="${pct%%%*}"
        total_mib=$(( blocks / 1024 ))
        avail_mib=$(( avail / 1024 ))
        avail_gib=$(( avail_mib / 1024 ))
        # A numeric Use% is the basis of every judgement below. A row that cannot be
        # read is reported, never skipped quietly — "filtered out" and "passed" look
        # identical in the output otherwise.
        case "$used_pct" in
            ''|*[!0-9]*)
                alert "gate 1: $mnt returned a non-numeric usage field ('$used_pct') — capacity UNVERIFIED for this mount, not assumed free"
                continue
                ;;
        esac
        eff_floor=$(( total_mib * CAP_FLOOR_SIZE_PCT / 100 ))
        (( eff_floor > CAP_MIN_FREE_MIB )) && eff_floor=$CAP_MIN_FREE_MIB
        (( eff_floor < 1 )) && eff_floor=1

        # Rule D: never descend into the filesystem's contents. Report the mount, not
        # what is on it, so no user file (and no Tier-1 forbidden path) is ever opened.
        info "gate 1: $mnt ($fs) ${used_pct}% used, ${avail_gib} GiB free"

        # Both conditions are evaluated INDEPENDENTLY. A filesystem can be over the
        # percent bar AND under the absolute floor, and an operator triaging from a single
        # alert line needs both reasons; an `elif` here hid the second one (caught by
        # fixture 2). The floor is the half the GNOME popup lacked — percent alone cannot
        # see a small partition that is only 60 % full but has nowhere to write.
        reasons=()
        (( used_pct >= CAP_ALERT_PCT )) && reasons+=("at ${used_pct}% (>= ${CAP_ALERT_PCT}%)")
        (( avail_mib < eff_floor )) && reasons+=("only ${avail_mib} MiB free (< ${eff_floor} MiB floor = ${CAP_MIN_FREE_MIB} MiB capped at ${CAP_FLOOR_SIZE_PCT}% of ${total_mib} MiB)")

        # gate 4: filling fast is worth knowing before the level becomes critical.
        # SIGN: used% RISING means space is being LOST, so drop = now - previous.
        # The first version of this gate had the sign inverted — it alerted when space was
        # FREED and stayed silent through a fast fill, i.e. it was worse than no gate
        # because it looked like a working early warning. Fixture 4 exists for this.
        if [[ -n "${PREV_PCT[$mnt]:-}" ]]; then
            drop=$(( used_pct - ${PREV_PCT[$mnt]} ))
            if (( drop < 0 )); then
                freed=$(( -drop ))
                (( freed >= TREND_DROP_PCT )) && info "gate 4: $mnt recovered ${freed} points since last run"
            elif (( drop >= TREND_DROP_PCT )); then
                reasons+=("losing space fast — ${drop} points in one interval (${PREV_PCT[$mnt]}% -> ${used_pct}%)")
            fi
        fi

        # gate 4b: the MiB-resolution rate, and the time-to-full it implies.
        # Everything here is gated on an interval being KNOWN. With no readable
        # $STATE_TS there is no rate — and every pre-existing fixture supplies a STATE
        # baseline without one, so this block must stay inert for them rather than
        # invent a division. Note the reason that matters: the state file's MiB column is
        # only a rate once you know how long the delta was observed over.
        rate_lost='' ; rate_day='' ; rate_hours='' ; rate_span=0
        # One [[ ]] compound, not two joined with a leading && on the next line: bash
        # parses `if [[ a ]]<newline>&& [[ b ]]; then` as a complete (and invalid) if,
        # which is a syntax error that takes the whole script down, not a soft miss.
        if [[ -n "$PREV_TS" && "$PREV_TS" != '0' && -n "${PREV_AVAIL[$mnt]:-}" \
              && "${PREV_AVAIL[$mnt]}" != *[!0-9]* ]]; then
            rate_span=$(( (NOW_EPOCH - PREV_TS) / 60 ))
            if (( rate_span >= 1 )); then
                rate_lost=$(( PREV_AVAIL[$mnt] - avail_mib ))
                if (( rate_lost > 0 )); then
                    rate_day=$(( rate_lost * 1440 / rate_span ))
                    if (( avail_mib <= 0 )); then
                        rate_hours=0
                    else
                        rate_hours=$(( avail_mib * rate_span / rate_lost / 60 ))
                    fi
                fi
            fi
        fi
        if [[ -n "$rate_day" && "$rate_day" != '0' && -n "$rate_lost" && "$rate_lost" != '0' ]]; then
            rate_msg="gate 4: $mnt filling at ${rate_day} MiB/day — ${rate_lost} MiB over ${rate_span} min, ${avail_mib} MiB left, ≈${rate_hours} h to full at this rate"
            if (( rate_hours < TREND_HOURS_TO_FULL )); then
                # Deliberately a WATCH, not a CRITICAL, unless explicitly promoted: a
                # projection from a single interval over bursty usage is the least
                # trustworthy number this script emits, and a confident wrong number is
                # worse than no number.
                if [[ "$TREND_PROJECT_ALERTS" == "1" ]]; then
                    reasons+=("projected full in ${rate_hours} h (< ${TREND_HOURS_TO_FULL} h) at ${rate_day} MiB/day")
                else
                    warn "$rate_msg"
                fi
            else
                info "$rate_msg"
            fi
        elif [[ -n "$rate_lost" ]] && (( rate_lost < 0 )); then
            rate_gain=$(( -rate_lost ))
            if (( rate_gain >= TREND_DROP_MIB )); then
                info "gate 4: $mnt gained ${rate_gain} MiB over ${rate_span} min"
            fi
        fi

        if (( ${#reasons[@]} > 0 )); then
            verdict="$(printf '%s; ' "${reasons[@]}")"
            verdict="${verdict%; }"
            # Match the MOUNT POINT, never the device node. A physical disk swap renumbers
            # nvmeXn1: measured 2026-11-05, when removing one drive shifted the OS disk from
            # nvme0n1 to nvme1n1 and the Intel from nvme1n1 to nvme0n1. An earlier draft of
            # this line matched `nvme0n1p7`, which would have gone silently stale — the same
            # remembered-letter trap that broke /mnt/jol-backup.
            if [[ "$mnt" == "/home" || "$mnt" == "/home/"* ]]; then
                verdict="$verdict — /home holds the IDE, this agent and the repo working copies"
            fi
            alert "capacity: $mnt $verdict"
        elif (( used_pct >= CAP_ALERT_PCT - 10 )); then
            warn "capacity: $mnt at ${used_pct}% — inside 10 points of the ${CAP_ALERT_PCT}% bar"
        fi

        # inodes: a full inode table denies writes on a filesystem that looks empty.
        iused_pct="$(df -iP "$mnt" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')"
        # vfat/ntfs/exfat have NO inode table, so `df -iP` emits '-' for IUse%. That is
        # neither a failure nor a pass: it is inapplicable. Passing '-' into (( )) raises
        # "syntax error: operand expected", which under `set -u` (no -e) does NOT stop the
        # script — it silently skips the inode check for every FAT mount. Measured on the
        # first live run at /boot/efi and /media/jol/….
        case "$iused_pct" in
            ''|*[!0-9]*)
                info "gate 1: $mnt exposes no inode table (df -iP returned '${iused_pct:-nothing}') — inode check not applicable"
                ;;
            *)
                if (( iused_pct >= INODE_ALERT_PCT )); then
                    alert "gate 1: $mnt at ${iused_pct}% INODES (file-count exhaustion — ${avail_gib} GiB free does not mean writable)"
                fi
                ;;
        esac

        [[ -n "$NEW_STATE" ]] && printf '%s %s %s\n' "$mnt" "$avail_mib" "$used_pct" >>"$NEW_STATE"
        # The machine-readable history. GiB in a human log cannot express a fill rate;
        # this can, and it is the artifact that makes a claim like "~3.4 GiB/day" either
        # checkable or falsifiable instead of remembered.
        printf '%s\t%s\t%s\t%s\n' "$NOW_EPOCH" "$mnt" "$avail_mib" "$used_pct" \
            >>"$SAMPLES" 2>/dev/null || true
    done <"$ROWS"
    rm -f "$ROWS" 2>/dev/null || true

    if (( DF_COUNTED == 0 )); then
        alert "gate 1: df produced no rows to judge — capacity UNVERIFIED (a grep/filter that matches nothing is not a pass)"
    else
        info "gate 1: $DF_COUNTED real filesystem(s) censused"
    fi
fi

# Publish state atomically for the next run's trend + liveness comparison.
if [[ -n "$NEW_STATE" && -s "$NEW_STATE" ]]; then
    mv "$NEW_STATE" "$STATE" 2>/dev/null || info "could not publish $STATE (filesystem full?) — next run loses the trend baseline"
    # Published WITH the state, never after it. A timestamp newer or older than the
    # readings it describes turns every rate below into a fiction, and the two files can
    # only be made consistent by writing the pair together.
    printf '%s\n' "$NOW_EPOCH" >"$STATE_TS" 2>/dev/null \
        || info "could not publish $STATE_TS — the next run loses the fill-rate interval"
fi

# Bound the sample history. A 15-minute timer across ~12 mounts is ~35k rows a week; an
# unbounded append-only file is a slow-motion version of the exact failure this watchdog
# was built to catch.
if [[ -r "$SAMPLES" ]]; then
    _samples_now="$(grep -c '' "$SAMPLES" 2>/dev/null || echo 0)"
    if [[ "$_samples_now" != *[!0-9]* ]] && (( _samples_now > SAMPLE_KEEP )); then
        tail -n $(( SAMPLE_KEEP / 2 )) "$SAMPLES" >"$SAMPLES.trim" 2>/dev/null \
            && mv "$SAMPLES.trim" "$SAMPLES" 2>/dev/null || rm -f "$SAMPLES.trim" 2>/dev/null || true
        info "gate 1: trimmed $SAMPLES from ${_samples_now} to ~$(( SAMPLE_KEEP / 2 )) rows"
    fi
fi
printf '%s\n' "$(date -u +%FT%TZ)" >"$STAMP" 2>/dev/null || \
    alert "gate 3: cannot write run stamp to $STAMP — self-liveness will be UNVERIFIED on the next run"

# --- gate 5: off-device backup artifacts are actually being WRITTEN ----------
# The failure this closes is the one that ran for four days: a scheduled backup whose
# destination silently stopped existing. The job's own guard failed LOUDLY and correctly
# (`ERROR: backup destination does not exist`), but the cron wrapper ends in
# `>/dev/null 2>&1` and the systemd unit exhausted StartLimitBurst=10, so nobody was
# told. Checking the artifact timestamp is the only control that does not depend on the
# failing job reporting itself — a dead monitor cannot announce its own death.
IFS=';' read -r -a _BA_ENTRIES <<< "$BACKUP_ARTIFACTS"
for entry in "${_BA_ENTRIES[@]}"; do
    [[ -n "$entry" ]] || continue
    ba_glob="${entry%%|*}"
    ba_max_h="${entry##*|}"
    case "$ba_max_h" in
        ''|*[!0-9]*)
            alert "gate 5: entry '$entry' has a non-numeric max age — cannot judge freshness, not assumed fresh"
            continue
            ;;
    esac
    ba_dir="${ba_glob%/*}"
    if [[ ! -d "$ba_dir" ]]; then
        alert "gate 5: backup directory $ba_dir is ABSENT — the off-device volume is not mounted (see gate 2); nothing has been written there"
        continue
    fi
    # nullglob so a non-matching pattern yields an EMPTY array rather than the literal
    # glob string, which would then be glob-matched against nothing and reported as a
    # confusing "unreadable mtime" instead of the truth: nothing matched.
    shopt -s nullglob
    # SC2206: unquoted on purpose — this IS the glob expansion the gate exists to perform.
    # shellcheck disable=SC2206
    matches=( $ba_glob )
    shopt -u nullglob
    if (( ${#matches[@]} == 0 )); then
        alert "gate 5: no backup artifact matched $ba_glob in an existing directory — freshness UNVERIFIED, never read as clean"
        continue
    fi
    NEWEST_TS=0
    for f in "${matches[@]}"; do
        # -L is load-bearing, not decoration: GNU `stat` uses lstat() by default, so
        # WITHOUT -L a DANGLING symlink scores its own recent mtime and the gate reports
        # "fresh" over a backup target that does not exist. Measured in the gate-5
        # fixtures on 2026-11-04 — this branch graded a broken link as healthy until the
        # fixture caught it. An artifact's age is the age of the BYTES it points at.
        m="$(stat -L -c '%Y' "$f" 2>/dev/null || echo 0)"
        (( m > NEWEST_TS )) && NEWEST_TS="$m"
    done
    if (( NEWEST_TS == 0 )); then
        alert "gate 5: ${#matches[@]} file(s) matched $ba_glob but none had a readable mtime — freshness UNVERIFIED"
        continue
    fi
    AGE_H=$(( ( $(date +%s) - NEWEST_TS ) / 3600 ))
    # A FUTURE mtime makes AGE_H negative, and a negative age is `< 26` — so a naive
    # comparison grades a clock fault or a copied-in artifact as perfectly fresh.
    # state_backup_guard.sh hit exactly this and printed "newest snapshot is
    # -632713h old (< 24h)" while exiting 0; a negative age is a REFUSAL here.
    if (( AGE_H < 0 )); then
        alert "gate 5: newest artifact matching $ba_glob has a FUTURE mtime ($(( -AGE_H )) h ahead of this host) — refusing to treat it as fresh"
    elif (( AGE_H > ba_max_h )); then
        alert "gate 5: newest backup artifact matching $ba_glob is ${AGE_H} h old (> ${ba_max_h} h) across ${#matches[@]} file(s) — the off-device backup is NOT running"
    else
        info "gate 5: $ba_glob fresh — newest ${AGE_H} h old, ${#matches[@]} artifact(s) inspected"
    fi
done

# --- gate 6: the /home backup is still running -------------------------------
# The failure this prevents is the one this whole thread began with: a control that
# ran once, looked configured, and then silently stopped being run. Three states are
# distinguished deliberately — absent directory, unreadable directory, and present-but-
# stale — because collapsing "cannot look" into "nothing there" produced a false
# finding on the 2026-11-05 run, when the snapshot tree was mode 700 root:root and
# therefore invisible to this user-level watchdog.
if [[ ! -e "$HOME_BACKUP_DIR" ]]; then
    alert "gate 6: $HOME_BACKUP_DIR does not exist — /home has no backup on the off-device disk (finding D-1 is still open)"
elif [[ ! -r "$HOME_BACKUP_DIR" ]]; then
    alert "gate 6: $HOME_BACKUP_DIR is not readable by $(id -un) — /home backup freshness UNVERIFIED, not assumed recent (needs mode 750 root:$(id -un) or a root-level check)"
else
    # ⚠ THE SNAPSHOT'S AGE MUST BE READ FROM ITS DIRECTORY NAME, NOT ITS mtime.
    # rsync -a preserves the mtime of the directory it copies, so the snapshot dir
    # `home-20261105T131022Z` carries the mtime of /home itself — which is Aug 19, the
    # last time an entry was added at that level. Measured 2026-11-05: a backup taken
    # 36 minutes ago was reported as "1875 h old — the /home backup is NOT running".
    # That is a permanent false CRITICAL on a correctly working control, the precise
    # 415-line hv01 failure mode. The directory name is generated at run time from
    # `date -u`, so it IS the backup timestamp; lexicographic sort on it is also the
    # correct newest-first order, unlike mtime.
    HB_NEWEST_NAME="$(find "$HOME_BACKUP_DIR" -maxdepth 1 -type d -name 'home-*' 2>/dev/null | sort | tail -1)"
    HB_COUNT="$(find "$HOME_BACKUP_DIR" -maxdepth 1 -type d -name 'home-*' 2>/dev/null | grep -c . || true)"
    if [[ -z "$HB_NEWEST_NAME" ]]; then
        alert "gate 6: $HOME_BACKUP_DIR exists but holds ${HB_COUNT:-0} snapshots — /home is not being backed up"
    else
        HB_STAMP="$(basename "$HB_NEWEST_NAME")"
        HB_EPOCH=""
        case "$HB_STAMP" in
            home-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
                HB_ISO="${HB_STAMP#home-}"
                HB_EPOCH="$(date -u -d "${HB_ISO:0:4}-${HB_ISO:4:2}-${HB_ISO:6:2}T${HB_ISO:9:2}:${HB_ISO:11:2}:${HB_ISO:13:2}Z" +%s 2>/dev/null || echo '')"
                ;;
        esac
        if [[ -z "$HB_EPOCH" ]]; then
            # Fall back to mtime, but SAY so — otherwise a directory named outside the
            # convention is judged by a clock the reader cannot see, and the number it
            # produces is exactly the misleading kind measured above.
            HB_EPOCH="$(stat -c '%Y' "$HB_NEWEST_NAME" 2>/dev/null || echo '')"
            [[ -n "$HB_EPOCH" ]] && info "gate 6: '$HB_STAMP' does not match home-YYYYMMDDTHHMMSSZ — falling back to its mtime"
        fi
        if [[ -z "$HB_EPOCH" ]]; then
            alert "gate 6: newest snapshot '$HB_STAMP' has no usable timestamp — /home backup freshness UNVERIFIED, not assumed recent"
        else
            HB_AGE_H=$(( ( $(date +%s) - HB_EPOCH ) / 3600 ))
            if (( HB_AGE_H < 0 )); then
                alert "gate 6: newest /home snapshot is dated $(( -HB_AGE_H )) h in the FUTURE — refusing to treat it as fresh"
            elif (( HB_AGE_H > HOME_BACKUP_MAX_AGE_H )); then
                alert "gate 6: newest /home snapshot ($HB_STAMP) is ${HB_AGE_H} h old (> ${HOME_BACKUP_MAX_AGE_H} h) across ${HB_COUNT} snapshot(s) — the /home backup is NOT running"
            else
                info "gate 6: /home backup fresh — $HB_STAMP is ${HB_AGE_H} h old, ${HB_COUNT} snapshot(s) inspected"
            fi
        fi
    fi
fi

# --- verdict -----------------------------------------------------------------
info "=== HEALTH CHECK COMPLETE (alerts=$ALERTS) ==="
# Rule B — STDOUT marker, not log-file only. A caller must be able to distinguish
# "all gates ran and passed" from "the script died halfway".
printf '[%s] === HEALTH CHECK COMPLETE (alerts=%s) ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ALERTS"

if (( ALERTS > 0 )); then
    # Notify on CHANGE of the alert SET, with digits masked. 96 identical pop-ups a day
    # train the operator to ignore the one that matters; but every run stays in the log
    # as evidence. Masking means 12 GiB -> 11 GiB free is the SAME problem, not a new one.
    SIG="$(printf '%s\n' "${ALERT_TEXTS[@]}" | sed -E 's/[0-9]+/N/g' | tr '\n;' '  ')"
    BODY="$(printf '%s\n' "${ALERT_TEXTS[@]}" | head -4 | tr '\n' '|')"
    if [[ "$SIG" != "$(cat "$SIG_FILE" 2>/dev/null || echo '')" ]]; then
        printf '%s\n' "$SIG" >"$SIG_FILE" 2>/dev/null || true
        push_note critical "JOL workstation capacity — $ALERTS alert(s)" "$BODY"
    else
        info "same alert set as already notified — desktop notification suppressed (log still records this run)"
    fi
    exit 1
fi

# Recovery must be as loud as failure: without it the operator cannot tell "fixed" from
# "the monitor stopped".
if [[ -s "$SIG_FILE" ]]; then
    info "RECOVERED — alert set $(cat "$SIG_FILE") cleared"
    rm -f "$SIG_FILE" 2>/dev/null || true
    push_note normal "JOL workstation capacity — recovered" "All capacity gates green (previous alert set cleared)."
fi
exit 0
