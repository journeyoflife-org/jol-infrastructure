#!/usr/bin/env bash
# =============================================================================
# hv01-health-check.sh — pve-prod-hv01 daily watchdog (06:00 UTC)
# Managed copy of /usr/local/bin/jol-health-check.sh (which existed only on the
# host — audit gap, same class as the MCP systemd units). Install:
#   sudo install -m 750 root:root hv01-health-check.sh /usr/local/bin/jol-health-check.sh
#
# Changes vs the host-only predecessor (2026-10-21):
#   A. ALERTS are written to /var/log/jol-hv01/ALERTS.log ALWAYS and mirrored to
#      /mnt/hdd-archive/health only when that mount is real. Before this, the
#      watchdog wrote its own evidence to the very disk it was supposed to be
#      monitoring: when the HDD was absent, alerts (including "SMART FAILURE")
#      landed silently on the NVMe root filesystem and were invisible.
#      Self-referential blindness fixed (GDPR Art. 5(2) accountability, CC7.2).
#   B. New gate 0: mount reality — /mnt/hdd-iso and /mnt/hdd-archive must be
#      mounted from sda1/sda2 AND on a different device than /. Detects the
#      exact failure seen on 2026-10-21 (PVE reported a missing HDD as
#      "active, 93 GB free" because the path had become a directory on /).
#   C. New gates 9-11 (backup reality — previously this script did not look at
#      backups at all, so "Backup Enabled: yes" could rot for 10 weeks unnoticed):
#       9  backup job registered in the scheduler (jobs.cfg section count must
#          equal /cluster/backup entry count — a rejected section never runs)
#       10 last vzdump task status (cluster task log, no credentials needed)
#       11 weekly /etc/pve config tarball freshness (> 8 days = alert)
#   D. VM auto-restart removed. The predecessor called `qm start`, but under cron
#      it NEVER worked: /etc/cron.d/jol-health sets no PATH, cron's default PATH is
#      `/usr/bin:/bin`, and `qm`/`smartctl`/`lvs` live in /usr/sbin. Evidence
#      (/mnt/hdd-archive/health/ALERTS.log, 415 lines from 2026-07-31 to 2026-10-21):
#      249 × "VM 1xx is  - attempting restart" and 166 × "SMART FAILURE on /dev/…"
#      — every one of them a false positive caused by an empty command lookup, and
#      every daily run looked catastrophic while proving nothing. An empty probe is
#      now reported as UNAVAILABLE, never as a failure. Restart is opt-in via
#      HV01_AUTO_START_VM=1, off by default: an unattended watchdog that starts VMs
#      conflicts with §0.3 change control.
#   E. Explicit PATH (root cause of D) + probe availability gate, so a missing
#      binary is a loud, distinct condition.
#
# Exit code: 0 = all gates pass, 1 = at least one alert (cron mail is meaningful).
# No credentials in this script. Read-only apart from its own log files.
# =============================================================================
set -uo pipefail

# cron does not export sbin dirs; without this every /usr/sbin probe returns empty
# and the watchdog screams false CRITICALs (see header note D).
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

LOG_DIR="/var/log/jol-hv01"
ARCHIVE_HEALTH="/mnt/hdd-archive/health"
# Device identity of / — resolved HERE, before alert() can ever run, because the alert mirror
# guard needs it (the script is `set -u`, so a late reference would abort a run mid-alert).
# Gate 0 below reuses the same value for the mount-reality check.
ROOT_DEV="$(stat -c '%d' /)"
DATE_TAG="$(date +%Y-%m-%d)"
LOG="${LOG_DIR}/${DATE_TAG}-health.log"
ALERT="${LOG_DIR}/ALERTS.log"
VM_IDS="${VM_IDS:-100 101 102}"
HV01_AUTO_START_VM="${HV01_AUTO_START_VM:-0}"
THIN_ALERT_PCT="${THIN_ALERT_PCT:-80}"
ROOT_ALERT_PCT="${ROOT_ALERT_PCT:-90}"
NVME_SPARE_MIN="${NVME_SPARE_MIN:-10}"
CONFIG_TAR_MAX_AGE_DAYS="${CONFIG_TAR_MAX_AGE_DAYS:-8}"
VZDUMP_MAX_AGE_HOURS="${VZDUMP_MAX_AGE_HOURS:-26}"
# Gate 13: positive proof of an OUTWARD delivery, written only by jol-verify-alert-transport.
PROOF_FILE="${PROOF_FILE:-/var/lib/jol-hv01/alert-transport-proof}"
TRANSPORT_PROOF_MAX_AGE_DAYS="${TRANSPORT_PROOF_MAX_AGE_DAYS:-7}"
ALERTS=0

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true

alert() {
    ALERTS=$((ALERTS + 1))
    printf '[%s] CRITICAL: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" |
        tee -a "$ALERT" "$LOG"
    # Mirror to the HDD only if it is genuinely mounted (never create dirs on /).
    # ⚠ FIXED 2026-10-31 (issue #124, finding F-2). The guard was
    #   `findmnt -n -o SOURCE "$ARCHIVE_HEALTH"`: findmnt resolves MOUNT POINTS, and
    #   ARCHIVE_HEALTH is a SUBDIRECTORY of the /mnt/hdd-archive mount, so the test returned
    #   empty on every run and the mirror never wrote — measured: the HDD copy was frozen at
    #   2026-10-21 (420 lines) while /var/log/jol-hv01/ALERTS.log kept recording (714 lines).
    #   `findmnt -T` is deliberately NOT used: it resolves any path to its containing mount
    #   INCLUDING /, so with the disk unmounted the guard would pass and alerts would be
    #   written onto the root filesystem — the exact 2026-10-21 failure class. Device identity
    #   is the sound test: unmounted or drifted to root ⇒ same device as / ⇒ refuse.
    #   Measured 2026-10-31: / = 64513, /mnt/hdd-archive = /mnt/hdd-archive/health = 2050.
    #   No alert() call here: alert() must never recurse into itself. Suppression is logged.
    if [[ ! -d "$ARCHIVE_HEALTH" ]]; then
        info "alert mirror SUPPRESSED: $ARCHIVE_HEALTH absent"
    elif [[ "$(stat -c '%d' "$ARCHIVE_HEALTH" 2>/dev/null)" == "$ROOT_DEV" ]]; then
        info "alert mirror SUPPRESSED: $ARCHIVE_HEALTH shares the root device ($ROOT_DEV) — evidence disk not mounted, refusing to write alerts onto /"
    else
        printf '[%s] CRITICAL: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$ARCHIVE_HEALTH/ALERTS.log"
    fi
}
info() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >>"$LOG"; }
# A missing binary is NOT a failed check — report it as unavailable instead.
have() { command -v "$1" >/dev/null 2>&1; }
probe_missing() { alert "probe unavailable: $1 not found (PATH=$PATH) — gate $2 not evaluated"; }

info "=== JOL HEALTH CHECK START ==="

# --- 0. Mount reality (the 2026-10-21 failure class) ------------------------
# ROOT_DEV is resolved in the config block above (the alert mirror guard needs it too).
for pair in "/mnt/hdd-iso:/dev/sda1" "/mnt/hdd-archive:/dev/sda2"; do
    mnt="${pair%%:*}"; want="${pair##*:}"
    src="$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || true)"
    dev="$(stat -c '%d' "$mnt" 2>/dev/null || echo unknown)"
    if [[ -z "$src" ]]; then
        alert "$mnt is NOT mounted — backup/evidence jobs would write onto the root fs"
    elif [[ "$src" != "$want" ]]; then
        alert "$mnt mounted from $src (expected $want)"
    elif [[ "$dev" == "$ROOT_DEV" ]]; then
        alert "$mnt resolves to the root filesystem device — mount is not real"
    else
        info "mount OK: $mnt <- $src"
    fi
done

# --- 1. LVM thin pool -------------------------------------------------------
if have lvs; then
    THIN_DATA="$(lvs --noheadings -o data_percent pve/data 2>/dev/null | tr -d ' ')"
    THIN_META="$(lvs --noheadings -o metadata_percent pve/data 2>/dev/null | tr -d ' ')"
    info "Thin pool: data=${THIN_DATA:-?}% meta=${THIN_META:-?}%"
    [[ -n "$THIN_DATA" ]] && (( ${THIN_DATA%.*} > THIN_ALERT_PCT )) && \
        alert "Thin pool DATA at ${THIN_DATA}% - VMs will freeze at 100%"
    [[ -n "$THIN_META" ]] && (( ${THIN_META%.*} > THIN_ALERT_PCT )) && \
        alert "Thin pool METADATA at ${THIN_META}% - pool corruption risk"
else
    probe_missing lvs 1
fi

# --- 2. SMART ---------------------------------------------------------------
if have smartctl; then
    for DISK in /dev/nvme0n1 /dev/sda; do
        HEALTH="$(smartctl -H "$DISK" 2>/dev/null | grep -i 'overall' | awk '{print $NF}')"
        info "SMART $DISK: ${HEALTH:-no response}"
        # 'PASSED' → OK. Blank (drive not answering / not SMART-capable) is UNKNOWN
        # and is NOT reported as a failure — that conflation is what made the
        # predecessor's ALERTS.log unreadable.
        case "$HEALTH" in
            PASSED) ;;
            FAILED) alert "SMART $DISK verdict: FAILED - replace immediately" ;;
            *)      alert "SMART $DISK returned no verdict (device missing or smartctl unable to read it)" ;;
        esac
    done

    # --- 3. NVMe wear -------------------------------------------------------
    SPARE="$(smartctl -A /dev/nvme0n1 2>/dev/null | grep -i 'spare' | awk '{print $NF}' | head -1 | tr -d '%')"
    info "NVMe available spare: ${SPARE:-N/A}%"
    [[ -n "$SPARE" ]] && (( SPARE < NVME_SPARE_MIN )) && \
        alert "NVMe spare blocks at ${SPARE}% - drive wearing out"
else
    probe_missing smartctl 2
fi

# --- 4. RAS: memory vs block-device errors ----------------------------------
# Counting the word "error" in `ras-mc-ctl --errors` is wrong: the tool prints a
# "No <type> errors." heading per type, so the predecessor's MCE gate was pure
# noise. Parse the record blocks instead.
if have ras-mc-ctl; then
    RAS_OUT="$(ras-mc-ctl --errors 2>/dev/null || true)"
    TODAY="$(date +%Y-%m-%d)"
    MEM_ERRS="$(printf '%s\n' "$RAS_OUT" | awk '/^Memory errors:/{f=1;next} /^[A-Za-z].*errors:/{f=0} f' | grep -cE '^[0-9]+ ' || true)"
    DISK_ERRS_ALL="$(printf '%s\n' "$RAS_OUT" | awk '/^Disk errors:/{f=1;next} /^[A-Za-z].*errors:/{f=0} f' | grep -cE '^[0-9]+ ' || true)"
    DISK_ERRS_RECENT="$(printf '%s\n' "$RAS_OUT" | awk '/^Disk errors:/{f=1;next} /^[A-Za-z].*errors:/{f=0} f' | grep -c "$TODAY" || true)"
    info "RAS: memory=${MEM_ERRS:-0} block(all)=${DISK_ERRS_ALL:-0} block(today)=${DISK_ERRS_RECENT:-0}"
    (( ${MEM_ERRS:-0} > 0 )) && \
        alert "${MEM_ERRS} memory error record(s) in rasdaemon - non-ECC bit-flip possible, run memtest"
    (( ${DISK_ERRS_RECENT:-0} > 0 )) && \
        alert "${DISK_ERRS_RECENT} block-device I/O error record(s) today (rasdaemon 'Disk errors') - check dmesg and the HDD"
else
    probe_missing ras-mc-ctl 4
fi

# --- 5. VM state ------------------------------------------------------------
if have qm; then
    for VMID in $VM_IDS; do
        STATUS="$(qm status "$VMID" 2>/dev/null | awk '{print $2}')"
        info "VM $VMID: ${STATUS:-unknown}"
        if [[ -z "$STATUS" ]]; then
            alert "VM $VMID status unreadable (qm returned nothing) - not assuming stopped"
        elif [[ "$STATUS" != "running" ]]; then
            alert "VM $VMID is $STATUS"
            if [[ "$HV01_AUTO_START_VM" == "1" ]]; then
                qm start "$VMID" 2>>"$LOG" || true
            fi
        fi
    done
else
    probe_missing qm 5
fi

# --- 6. Filesystem space ----------------------------------------------------
ROOT_PCT="$(df / | tail -1 | awk '{print $5}' | tr -d '%')"
info "Root FS usage: ${ROOT_PCT}%"
(( ${ROOT_PCT:-0} > ROOT_ALERT_PCT )) && \
    alert "Root filesystem at ${ROOT_PCT}% - log rotation needed"
if findmnt -n -o TARGET /dev/sda2 >/dev/null 2>&1; then
    ARC_PCT="$(df /mnt/hdd-archive | tail -1 | awk '{print $5}' | tr -d '%')"
    info "HDD archive usage: ${ARC_PCT}%"
    (( ${ARC_PCT:-0} > ROOT_ALERT_PCT )) && alert "HDD archive at ${ARC_PCT}%"
fi

# --- 7. Uptime / load -------------------------------------------------------
info "Uptime: $(uptime -p) | Load: $(awk '{print $1, $2, $3}' /proc/loadavg)"

# --- 8. NTP -----------------------------------------------------------------
NTP_SYNC="$(chronyc tracking 2>/dev/null | grep 'Leap status' | awk '{print $NF}')"
info "NTP sync: ${NTP_SYNC:-unknown}"
[[ "$NTP_SYNC" == "Normal" ]] || alert "NTP not synced - log timestamps unreliable (SOC2 CC7.2)"

# --- 9. Backup job registered (a rejected section never runs) --------------
if have pvesh; then
    CFG_SECTIONS="$(grep -c '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null || true)"
    CFG_SECTIONS="${CFG_SECTIONS:-0}"
    API_JOBS="$(pvesh get /cluster/backup --output-format json 2>/dev/null || true)"
    API_COUNT=0
    if [[ -n "$API_JOBS" && "$API_JOBS" != "[]" ]]; then
        API_COUNT="$(printf '%s' "$API_JOBS" | grep -o '"schedule"' | wc -l | tr -d ' ')"
    fi
    info "Backup jobs: jobs.cfg sections=${CFG_SECTIONS} scheduler entries=${API_COUNT}"
    if [[ "$CFG_SECTIONS" != "$API_COUNT" ]]; then
        alert "Backup job drift: ${CFG_SECTIONS} section(s) in jobs.cfg but ${API_COUNT} registered in the scheduler — the difference NEVER RUNS (editing jobs.cfg by hand can produce a silently rejected section; use pvesh)"
    fi

    # --- 10. Last vzdump outcome --------------------------------------------
    # ⚠ FIXED 2026-10-23 — this gate was DEAD CODE, in a way that hid in plain sight. The cluster
    #   endpoint accepts NONE of the options used: `pvesh get /cluster/tasks --typefilter vzdump
    #   --limit 5` returns "Unknown option: typefilter / Unknown option: limit / 400 unable to parse
    #   option" (verified; `--type` is rejected too). Because stderr was swallowed by 2>/dev/null, the
    #   variable was ALWAYS empty, so the gate (a) raised a FALSE "no backup has run" CRITICAL on a
    #   healthy host and (b) never executed the staleness branch below — i.e. it could not detect a
    #   stopped nightly backup, the single failure class it exists for. The node-scoped endpoint DOES
    #   work: /nodes/<node>/tasks --typefilter vzdump --limit 5 returns the real tasks.
    #   Rule kept: a query that FAILS is reported as UNVERIFIED, never as a backup finding.
    NODE_NAME="$(hostname)"
    if LAST_VZDUMP="$(pvesh get "/nodes/${NODE_NAME}/tasks" --typefilter vzdump --limit 10 --output-format json 2>/dev/null)"; then
        if [[ -z "$LAST_VZDUMP" || "$LAST_VZDUMP" == "[]" ]]; then
            alert "No vzdump task in ${NODE_NAME}'s task log — no backup has run on this host"
        else
            # Pair starttime+status PER TASK (objects split on `{`), newest by VALUE — the
            # API's sort order is not a contract. Proven 2026-10-24 against the live log,
            # which holds OK and "job errors" INTERLEAVED inside one 5-task window.
            # ⚠ `|| [[ -n "$obj" ]]` is load-bearing: `read` returns false on a final
            #   line with no trailing newline, so WITHOUT it the LAST element of the JSON
            #   array is silently dropped (measured 2026-10-24 in .staging/g10-test.sh —
            #   T1 lost the newest task entirely). A partially-read list is worse than an
            #   empty one because it looks complete.
            TASK_TABLE="$(printf '%s' "$LAST_VZDUMP" | sed 's/},{/}\n{/g' |
                while read -r obj || [[ -n "$obj" ]]; do
                    ts="$(printf '%s' "$obj" | grep -o '"starttime":[0-9]*' | cut -d: -f2)"
                    st="$(printf '%s' "$obj" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
                    [[ -n "$ts" ]] && printf '%s %s\n' "$ts" "${st:-unknown}"
                done | sort -n)"
            info "Recent vzdump tasks (ts status): $(printf '%s\n' "$TASK_TABLE" | tr '\n' ' ')"
            NEWEST_LINE="$(printf '%s\n' "$TASK_TABLE" | tail -1)"
            # Statuses can contain a space ("job errors") — split on the FIRST field only,
            # `${LINE##* }` would truncate it to "errors" (caught by .staging/g10-test.sh).
            NEWEST_TS="$(printf '%s' "$NEWEST_LINE" | awk '{print $1}')"
            NEWEST_ST="$(printf '%s' "$NEWEST_LINE" | sed 's/^[0-9]* //')"
            NOW="$(date +%s)"
            # ⚠ FIXED 2026-10-24 — the old test was `grep -q '"status":"OK"'` over the whole
            #   window: ONE old success masked a NEWER failure, so a failed backup read as
            #   green. Judge the NEWEST task itself.
            if [[ "$NEWEST_ST" != "OK" ]]; then
                alert "Newest vzdump task ($(date -u -d "@$NEWEST_TS" +%FT%TZ)) ended '${NEWEST_ST}' — the LATEST backup did not complete, check the task log"
            fi
            FAILS_IN_WINDOW="$(printf '%s\n' "$TASK_TABLE" | awk -v now="$NOW" -v w="$((VZDUMP_MAX_AGE_HOURS * 3600))" '$2 != "OK" && now - $1 <= w' | grep -c . || true)"
            if [[ "${FAILS_IN_WINDOW:-0}" -gt 0 ]]; then
                alert "${FAILS_IN_WINDOW} vzdump task(s) FAILED within the last ${VZDUMP_MAX_AGE_HOURS} h (even though a later one may have succeeded) — partial backup loss, check which VMID"
            fi
            if [[ -n "$NEWEST_TS" ]] && (( NOW - NEWEST_TS > VZDUMP_MAX_AGE_HOURS * 3600 )); then
                alert "Newest vzdump task is $(( (NOW - NEWEST_TS) / 3600 )) h old (> ${VZDUMP_MAX_AGE_HOURS} h) — nightly backup is not running"
            fi
        fi
    else
        alert "Cannot read ${NODE_NAME}'s vzdump task log — backup freshness is UNVERIFIED (query failed; this is NOT evidence that backups did or did not run)"
    fi
else
    probe_missing pvesh 9
fi

# --- 11. Config evidence freshness + key hygiene ---------------------------
NEWEST_TAR="$(find /mnt/hdd-archive/config-backup -name 'pve-config-*.tar.gz' -mtime "-${CONFIG_TAR_MAX_AGE_DAYS}" 2>/dev/null | head -1)"
if [[ -z "$NEWEST_TAR" ]]; then
    alert "No /etc/pve config backup within ${CONFIG_TAR_MAX_AGE_DAYS} days (hv01-config-backup.sh or its mount is broken)"
else
    info "Config backup fresh: $(basename "$NEWEST_TAR")"
    # A config backup must never carry key material — the pre-2026-10-21 job did
    # (root CA key + cluster authkey in a 644 archive). Fail loudly if it returns.
    if tar tzf "$NEWEST_TAR" 2>/dev/null | grep -qE 'etc/pve/priv|\.key$|\.pem$'; then
        alert "$(basename "$NEWEST_TAR") contains PRIVATE KEY material — fix hv01-config-backup.sh excludes and rotate the exposed keys"
    fi
    # ⚠ ADDED 2026-11-01 (finding F-18, issue #128 follow-up). The gate above is a NAME pattern,
    #   and F-3 is not a name: `cipassword:` is a FIELD inside a conf body, so an archive could
    #   (and did, 2026-10-25) pass this gate while carrying 9 credential hashes. Detection of an
    #   F-3 regression must not rest solely on the publishing script's own gate — if that script
    #   drifts (F-4 class: the host copy is 42 lines behind the repo) the watchdog is the only
    #   independent observer. Content check, and its reach is proven: 0 confs inspected is an
    #   alert, not a pass (same "absence of measurement wearing a number" class as pbs01 gate 3).
    CONF_REACH="$(tar tzf "$NEWEST_TAR" 2>/dev/null | grep -cE '/qemu-server/[^/]+\.conf$' || true)"
    if (( CONF_REACH == 0 )); then
        alert "$(basename "$NEWEST_TAR") exposes no qemu-server conf to inspect (unreadable archive or wrong layout) — F-3 credential check UNVERIFIED, not clean"
    elif tar xzOf "$NEWEST_TAR" --wildcards '*/qemu-server/*.conf' 2>/dev/null |
            grep -qE '^[[:space:]]*cipassword: [^<]'; then
        alert "$(basename "$NEWEST_TAR") contains an UNSANITISED cipassword value — hv01-config-backup.sh strip/gate is broken; do NOT replicate this archive off-host (issue #128)"
    fi
    if [[ "$(stat -c '%a' "$NEWEST_TAR")" != "600" ]]; then
        alert "$(basename "$NEWEST_TAR") mode $(stat -c '%a' "$NEWEST_TAR") — config backups must be 600"
    fi
fi

# --- 12. Every declared storage must actually be usable --------------------
# A defined-but-inactive storage is the failure class that hid for 10 weeks: the
# config looked configured while nothing worked. pbs01 inactive = no off-host backup.
while read -r sname sstatus || [[ -n "$sname" ]]; do
    case "$sstatus" in
        active|N/A) ;;
        *) alert "storage $sname is declared but status=$sstatus — backups targeting it will fail" ;;
    esac
done < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1, $3}')

# --- 13. Alert transport liveness (monitor the monitor) --------------------
# ⚠ FIXED 2026-10-24 — the first version of this gate counted bounced/deferred mail
#   only. That decays to zero when nothing fails (no failing job ⇒ no mail ⇒ no
#   bounce), so a quiet fleet would have read "transport OK" WITHOUT ANY TEST —
#   absence of failure is not presence of success. The gate now needs BOTH:
#   (a) no bounce/defer in the window (a failure record), AND
#   (b) a positive delivery PROOF RECORD newer than TRANSPORT_PROOF_MAX_AGE_DAYS,
#       written only by `jol-verify-alert-transport` after an outward `status=sent`.
# Measured transport reality (48 h journal, 2026-10-24): TWO independent defects —
#   ~104 `status=deferred` (connect to …gmail-smtp-in…:25 `Connection timed out` /
#   IPv6 `Network is unreachable`) AND successful connections that then `status=bounced`
#   with `550-5.7.1 [62.212.207.81] … not authorized` and `550-5.7.26 sender
#   unauthenticated … SPF [pve.prod.lt9] did not pass`. So :25 is PARTIALLY blocked
#   after all (the 2026-10-23 "falsified" note was over-inference from one sample) and
#   the sender is also unauthorised/unauthenticated. Fix needs an authenticated relay,
#   which is exactly what a proof record verifies end to end.
# ⚠ FIXED again 2026-10-24, by reading this gate's own output — two defects in the gate
#   itself, both proved against the live journal, neither visible in the verdict:
#   1. The count was contaminated by the VERIFIER'S OWN bounce. `jol-verify-alert-transport`
#      injects with envelope sender `<nonce>@pve.prod.lt9`, and `myhostname` is in
#      `mydestination`, so a Gmail rejection generates a DSN back to that sender and
#      `postfix/local` answers `status=bounced (unknown user: "jolproof…")`. One probe
#      therefore wrote TWO records and the gate reported "6 message(s)" for 5 real
#      failures. A metric contaminated by its own diagnostic is not a metric, so (a)
#      now counts OUTWARD attempts only — the same `relay=local` refusal that (b)
#      already applies to a `relay=local` `status=sent`. Trade-off stated: a broken
#      LOCAL mailbox on the `mail-to-root` hop is no longer counted here, because that
#      hop is not an off-host alert; `relay=none` defers (a real :25 timeout — 70
#      records in the 48 h window) are deliberately still counted as failures.
#   2. The "cannot read the journal" branch was DEAD CODE: `grep -c` always prints a
#      number, so a failed `journalctl` (errors swallowed by 2>/dev/null) yielded "0"
#      and the gate read an unreadable journal as "transport fine" — gate 10's dead
#      branch in a new costume, the exact silent-pass class this gate exists to stop.
#      Readability is now decided by journalctl's EXIT STATUS, proved to discriminate:
#      rc=1 on a real failure, rc=0 on a unit that is merely quiet — so a day with no
#      mail at all still reads as zero failures, and (b) keeps the bar.
#   3. Counted DELIVERY RECORDS, not messages (measured 2026-10-25). One deferred
#      message writes one record per retry attempt, so a single stuck mail produced
#      12 of the 14 records in the window: 14 "messages" reported for 3 real ones.
#      The number is the triage signal — an inflating one reads as a spreading
#      failure instead of one mail that cannot leave the host. Now collapses to
#      distinct queue ids and names the record count beside it.
if have journalctl; then
    if ! POSTFIX_JOURNAL="$(journalctl -u postfix --since "-24 hours" --no-pager 2>&1)"; then
        alert "cannot read the postfix journal — alert transport is UNVERIFIED (not assumed working)"
    else
        TRANSPORT_FAILURES="$(printf '%s\n' "$POSTFIX_JOURNAL" |
            grep -vE 'relay=local' | grep -E 'status=(bounced|deferred)' || true)"
        TRANSPORT_RECORDS=0
        TRANSPORT_MESSAGES=0
        if [[ -n "$TRANSPORT_FAILURES" ]]; then
            TRANSPORT_RECORDS="$(printf '%s\n' "$TRANSPORT_FAILURES" | wc -l)"
            TRANSPORT_MESSAGES="$(printf '%s\n' "$TRANSPORT_FAILURES" |
                sed -nE 's#.* postfix/[a-z]+\[[0-9]+\]: ([0-9A-F]+): .*#\1#p' | sort -u | wc -l)"
            # A status= line whose queue id this pattern cannot read must NOT vanish:
            # fall back to the record count, so an unexpected log format can only ever
            # over-count, never silently under-count.
            (( TRANSPORT_MESSAGES > 0 )) || TRANSPORT_MESSAGES="$TRANSPORT_RECORDS"
        fi
        if (( TRANSPORT_RECORDS > TRANSPORT_MESSAGES )); then
            alert "ALERT TRANSPORT BROKEN: ${TRANSPORT_MESSAGES} outward message(s) bounced/deferred in the last 24 h (${TRANSPORT_RECORDS} delivery records, retries collapsed) — failure notifications are NOT reaching anybody (runbook §7.2)"
        elif (( TRANSPORT_MESSAGES > 0 )); then
            alert "ALERT TRANSPORT BROKEN: ${TRANSPORT_MESSAGES} outward message(s) bounced/deferred in the last 24 h — failure notifications are NOT reaching anybody (runbook §7.2)"
        fi
    fi
    PROOF_RECORD="$(cat "$PROOF_FILE" 2>/dev/null || true)"
    if [[ -z "$PROOF_RECORD" ]]; then
        alert "alert transport NEVER VERIFIED end-to-end — no proof record at ${PROOF_FILE}; run 'sudo jol-verify-alert-transport' (runbook §7.2)"
    elif [[ "$(find "$PROOF_FILE" -mtime "-${TRANSPORT_PROOF_MAX_AGE_DAYS}" 2>/dev/null)" != "$PROOF_FILE" ]]; then
        alert "alert transport proof is STALE (> ${TRANSPORT_PROOF_MAX_AGE_DAYS} d): ${PROOF_RECORD} — re-run 'sudo jol-verify-alert-transport'"
    else
        info "Alert transport proof: ${PROOF_RECORD}"
    fi
else
    probe_missing journalctl 13
fi

info "=== HEALTH CHECK COMPLETE (alerts=${ALERTS}) ==="
# STDOUT completion marker — required by the workstation pull (runbook §7.2, layer 3).
# `info` writes to the log file ONLY, so a remote caller could not tell "every gate
# ran, nothing to report" from "the script died halfway" — the same blind-spot class
# as gate 10's dead branch, so both directions must stay provable.
printf '[%s] === HEALTH CHECK COMPLETE (alerts=%s) ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ALERTS"

# Rotate: keep 90 days of logs on-host and (when mounted) on the HDD
find "$LOG_DIR" -name '*-health.log' -mtime +90 -delete 2>/dev/null || true
if findmnt -n -o TARGET /dev/sda2 >/dev/null 2>&1; then
    find "$ARCHIVE_HEALTH" -name '*-health.log' -mtime +90 -delete 2>/dev/null || true
fi

[[ "$ALERTS" -eq 0 ]] || exit 1
exit 0
