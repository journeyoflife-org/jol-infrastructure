#!/usr/bin/env bash
# =============================================================================
# pbs01-health-check.sh — watchdog for the fleet's backup custodian
#
# WHY THIS EXISTS: pbs01 holds every off-host copy of VMIDs 100/101/102 and the
# llm model store, and had NO monitoring of its own — `monitoring_enabled` is
# false in inventory (node_exporter runs but is unreachable: no 9100 accept rule
# and the fleet Prometheus was the retired admin01). A silent failure here means
# backups stop landing while every consumer still reports "Backup Enabled".
#
# HOST GUARD (280544fa-class defect: commands pasted into the wrong shell mimic
# real failures): this script aborts loudly unless it is running on pbs01.
#
# GATES (all read-only; no credentials anywhere):
#   0  host identity + PATH                                   — precondition
#   1  time source: chrony leap status, offset, ≥3 sources    — CC7.2 / A.8.16
#   2  datastore pool usage > POOL_ALERT_PCT                 — A.8.13 availability
#   3  garbage collection: scheduled? pending-bytes over cap — orphan growth
#   4  prune + verify jobs exist                              — retention / integrity
#   5  freshness per group: newest snapshot name vs now (UTC)  — RPO
#   6  ACL row for the hv01 namespace still present            — drift detection
#   7  auditd active + plugin count (off-host shipping known gap, WARN only)
#   8  fail2ban: anything currently banned on sshd              — admin lockout
#   9  services: proxmox-backup + nftables + chrony active
#
# TIME TRAP (evidence §19b): `proxmox-backup-manager task list` prints LOCAL
# (EEST) time while `date -u` and the snapshot directory NAMES are UTC. Gate 5
# therefore parses directory NAMES (UTC ISO-8601) and never the task table.
#
# Evidence is written to the root filesystem ONLY — never into /backup-pool,
# because writing a watchdog's proof onto the very datastore it monitors is the
# self-referential blindness already fixed on hv01 (GDPR Art. 5(2), CC7.2).
#
# Exit: 0 = all gates pass, 1 = at least one CRITICAL.
# Install (from the operator workstation, over the ADR-008 SSH path):
#   ssh pbs01 'install -m 750 -o root -g root /dev/stdin /usr/local/bin/jol-pbs01-health-check.sh' \
#     < scripts/maintenance/pbs01-health-check.sh
#   ssh pbs01 'printf "PATH=/usr/sbin:/usr/bin:/sbin:/bin\n15 6 * * * root /usr/local/bin/jol-pbs01-health-check.sh >/dev/null 2>&1\n" > /etc/cron.d/jol-pbs01-health'
# =============================================================================
set -uo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

EXPECTED_HOST="${EXPECTED_HOST:-pbs01}"
DATASTORE="${DATASTORE:-pbs-store}"
BACKUP_ROOT="${BACKUP_ROOT:-/backup-pool/${DATASTORE}}"
FRESH_GROUPS="${FRESH_GROUPS:-ns/jol-hv01/vm/100 ns/jol-hv01/vm/101 ns/jol-hv01/vm/102 ns/jol-hv01/host/pve-prod-hv01 ns/jol-llm/host/llm-prod-lt01}"
RPO_MAX_HOURS="${RPO_MAX_HOURS:-26}"
POOL_ALERT_PCT="${POOL_ALERT_PCT:-70}"
GC_PENDING_ALERT_G="${GC_PENDING_ALERT_G:-50}"
CHRONY_MAX_SOURCES_OFFLINE="${CHRONY_MAX_SOURCES_OFFLINE:-0}"
CHRONY_MAX_OFFSET_S="${CHRONY_MAX_OFFSET_S:-1}"
LOG_DIR="/var/log/jol-pbs01"
ALERTS=0

# --- 0. Host guard ----------------------------------------------------------
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"
if [[ "$HOSTNAME_SHORT" != "$EXPECTED_HOST" ]]; then
    printf 'ABORT: this script must run on %s (this host is %s). PBS verbs and /backup-pool do not exist elsewhere.\n' \
        "$EXPECTED_HOST" "$HOSTNAME_SHORT" >&2
    exit 2
fi

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
LOG="${LOG_DIR}/$(date +%Y-%m-%d)-health.log"
ALERT_LOG="${LOG_DIR}/ALERTS.log"

alert() {
    ALERTS=$((ALERTS + 1))
    printf '[%s] CRITICAL: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" | tee -a "$ALERT_LOG" "$LOG"
}
warn() { printf '[%s] WARN: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" | tee -a "$LOG"; }
info() { printf '[%s] %s\n' "$(date -u '+%H:%M:%SZ')" "$1" >>"$LOG"; }
have() { command -v "$1" >/dev/null 2>&1; }
probe_missing() { alert "probe unavailable: $1 not found (PATH=$PATH) — gate $2 not evaluated"; }

info "=== PBS01 HEALTH CHECK START ==="

# --- 1. Time source --------------------------------------------------------
# Audit timestamps on the custodian are only as good as this; it was found
# +65.657 s fast with a single dead peer on 2026-10-22.
if have chronyc; then
    LEAP="$(chronyc tracking 2>/dev/null | awk -F: '/Leap status/{gsub(/ /,"",$2);print $2}')"
    OFFSET="$(chronyc tracking 2>/dev/null | awk -F: '/System time/{print $2}' | grep -oE '[0-9.]+' | head -1)"
    [[ -n "$LEAP" ]] || LEAP="unknown"
    info "chrony: leap=${LEAP} offset=${OFFSET:-?}s"
    [[ "$LEAP" == "Normal" ]] || alert "chrony leap status is '${LEAP}' — clock not synced, audit timestamps unreliable (CC7.2/A.8.16)"
    if [[ -n "$OFFSET" ]]; then
        awk -v o="$OFFSET" -v m="$CHRONY_MAX_OFFSET_S" 'BEGIN{ if (o+0 > m+0) exit 1 }' || \
            alert "chrony offset ${OFFSET}s exceeds ${CHRONY_MAX_OFFSET_S}s — prune/verify boundaries and snapshot ordering drift"
    fi
    ACTIVITY="$(chronyc activity 2>/dev/null | tail -1)"
    OFF_N="$(printf '%s' "$ACTIVITY" | grep -oE '^[0-9]+' || echo '')"
    ON_N="$(chronyc activity 2>/dev/null | grep -oE '^[0-9]+ sources online' | grep -oE '^[0-9]+' || echo 0)"
    info "chrony sources: online=${ON_N:-0} offline=${OFF_N:-?}"
    # Fewer than 3 sources cannot reject a falseticker (RFC 5905 §10).
    (( ${ON_N:-0} >= 3 )) || alert "only ${ON_N:-0} chrony source(s) online — <3 cannot outvote a falseticker (RFC 5905 §10)"
else
    probe_missing chronyc 1
fi

# --- 2. Pool usage ---------------------------------------------------------
if have df; then
    PCT="$(df "$BACKUP_ROOT" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')"
    info "Datastore pool usage: ${PCT:-?}%"
    [[ -n "$PCT" ]] || alert "cannot read df for ${BACKUP_ROOT} — pool usage UNVERIFIED"
    [[ -n "$PCT" ]] && (( PCT > POOL_ALERT_PCT )) && \
        alert "backup pool at ${PCT}% (>${POOL_ALERT_PCT}%) — a full pool stops every backup AND every restore read"
else
    probe_missing df 2
fi

# --- 3. Garbage collection -------------------------------------------------
# PBS 4.2 has NO `garbage-collection create` verb: GC is a datastore property
# (`datastore update <store> --gc-schedule <calendar>`). Verified on-host 2026-10-23.
# There is also no --max-used-percent on a datastore in 4.2, which is why gate 2
# must exist here instead.
# ⚠ FIXED 2026-10-31 (issue #129, finding F-5): this gate used to read `pending-bytes`
#   from `garbage-collection status` alone and alert only above the threshold. That field
#   is the tally OF THE LAST GC RUN: on a datastore where GC has never completed the whole
#   payload is zeros (measured on pbs01 after prunes had already deleted groups — each VMID
#   holds exactly 7 under keep-daily=7), so the gate printed "GC pending-bytes: 0 GiB" and the
#   run read GREEN. An absence of measurement rendered as a number — gate 10's dead branch and
#   gate 13's decay-to-zero in a third costume. `status` carries NO timestamp at all, so it
#   cannot answer "did GC ever run"; `list` does (last-run-state / last-run-endtime / duration),
#   so the question is asked of the endpoint that can answer it. "never ran" is WARN (the
#   schedule exists, first run pending) and "ran, nothing pending" stays a plain 0 GiB info —
#   the two states must not be conflated in either direction.
if have proxmox-backup-manager; then
    GC_LIST_JSON="$(proxmox-backup-manager garbage-collection list --output-format json 2>/dev/null || true)"
    if [[ -z "$GC_LIST_JSON" ]]; then
        alert "cannot read garbage-collection list for ${DATASTORE} — GC state UNVERIFIED (not assumed scheduled)"
    else
        GC_SCHED="$(printf '%s' "$GC_LIST_JSON" | grep -o "\"schedule\":\"[^\"]*\"" | head -1)"
        if [[ -z "$GC_SCHED" ]]; then
            warn "garbage collection is NOT scheduled on ${DATASTORE} — orphaned chunks from prunes are never reclaimed (see runbook §7.1 to schedule)"
        else
            info "GC schedule: ${GC_SCHED}"
        fi
        LAST_STATE="$(printf '%s' "$GC_LIST_JSON" | grep -o "\"last-run-state\":\"[^\"]*\"" | head -1 | cut -d'"' -f4)"
        PENDING="$(proxmox-backup-manager garbage-collection status "$DATASTORE" --output-format json 2>/dev/null | grep -o "\"pending-bytes\":[0-9]*" | grep -oE '[0-9]+$' || echo '')"
        if [[ -z "$LAST_STATE" ]]; then
            # No GC has ever completed here, so there is no measurement to report.
            warn "no garbage collection has EVER run on ${DATASTORE} — pending-bytes is not a measurement yet (orphan growth UNVERIFIED until the first scheduled run reports a state)"
        elif [[ -z "$PENDING" ]]; then
            alert "cannot read GC pending-bytes for ${DATASTORE} — orphan growth UNVERIFIED"
        else
            PENDING_G=$(( PENDING / 1073741824 ))
            info "GC last-run-state=${LAST_STATE}; pending-bytes: ${PENDING_G} GiB"
            (( PENDING_G > GC_PENDING_ALERT_G )) && \
                alert "${PENDING_G} GiB of orphaned chunks pending GC (> ${GC_PENDING_ALERT_G} GiB) — run garbage collection now (last run: ${LAST_STATE})"
        fi
    fi
else
    probe_missing proxmox-backup-manager 3
fi

# --- 4. Retention + integrity jobs exist -----------------------------------
if have proxmox-backup-manager; then
    PRUNE_N="$(proxmox-backup-manager prune-job list --output-format json 2>/dev/null | grep -o "\"id\"" | wc -l | tr -d ' ')"
    VERIFY_N="$(proxmox-backup-manager verify-job list --output-format json 2>/dev/null | grep -o "\"id\"" | wc -l | tr -d ' ')"
    info "jobs: prune=${PRUNE_N:-0} verify=${VERIFY_N:-0}"
    (( ${PRUNE_N:-0} > 0 )) || alert "no prune job on ${DATASTORE} — snapshots accumulate until the pool fills (retention undefined)"
    (( ${VERIFY_N:-0} > 0 )) || alert "no verify job on ${DATASTORE} — backup readability is never proven, only assumed (A.8.13)"
fi

# --- 5. Freshness per group (UTC from directory names) ---------------------
NOW_EPOCH="$(date -u +%s)"
for grp in $FRESH_GROUPS; do
    dir="${BACKUP_ROOT}/${grp}"
    if [[ ! -d "$dir" ]]; then
        alert "backup group ${grp} is absent — that entity has NO off-host copy"
        continue
    fi
    newest_name="$(find "$dir" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' 2>/dev/null | sort | tail -1)"
    if [[ -z "$newest_name" ]]; then
        alert "backup group ${grp} has no snapshots — nothing to restore"
        continue
    fi
    # Names are UTC ISO-8601 (YYYY-MM-DDTHH:MM:SSZ) — parse explicitly, never `date -d`
    # on a locale-dependent format.
    e="$(date -u -d "${newest_name/T/ }" +%s 2>/dev/null || echo '')"
    if [[ -z "$e" ]]; then
        alert "cannot parse snapshot name '${newest_name}' in ${grp} — freshness UNVERIFIED"
        continue
    fi
    age_h=$(( (NOW_EPOCH - e) / 3600 ))
    info "fresh ${grp}: newest=${newest_name} age=${age_h}h"
    (( age_h > RPO_MAX_HOURS )) && \
        alert "STALE: newest snapshot in ${grp} is ${age_h} h old (> ${RPO_MAX_HOURS} h) — the nightly backup is not landing here"
done

# --- 6. ACL drift on the hv01 namespace ------------------------------------
if [[ -r /etc/proxmox-backup/acl.cfg ]]; then
    grep -q 'jol-hv01' /etc/proxmox-backup/acl.cfg || \
        alert "no ACL row mentions jol-hv01 in /etc/proxmox-backup/acl.cfg — the backup token has lost its grants (pushes will fail with \"Cannot find datastore\")"
    grep -q 'pve-backup@pbs!pve-token' /etc/proxmox-backup/acl.cfg || \
        alert "pve-backup@pbs!pve-token has no ACL row — NOTE: 'user delete-token' PRUNES a token's grants, so any rotation must be followed by a re-grant"
else
    alert "cannot read /etc/proxmox-backup/acl.cfg — permission drift UNVERIFIED"
fi

# --- 7. auditd (off-host shipping is a KNOWN open gap: WARN, not CRITICAL) --
if have systemctl; then
    [[ "$(systemctl is-active auditd 2>/dev/null)" == "active" ]] || \
        alert "auditd is not active — the custodian records nothing about itself"
    PLUGIN_ON="$(grep -c '^\s*active\s*=\s*yes' /etc/audit/auditd.conf 2>/dev/null || echo 0)"
    [[ "${PLUGIN_ON:-0}" == "0" ]] && \
        warn "no auditd plugin active: the audit trail is LOCAL-ONLY, so a compromised pbs01 can erase its own record (open since 2026-08-01)"
fi

# --- 8. fail2ban -----------------------------------------------------------
if have fail2ban-client; then
    BANNED="$(fail2ban-client status sshd 2>/dev/null | grep -oE 'Currently banned:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' || echo '')"
    info "fail2ban sshd currently banned: ${BANNED:-?}"
    [[ -n "$BANNED" ]] && (( BANNED > 0 )) && \
        alert "fail2ban has ${BANNED} active SSH ban(s) — check it is not the operator workstation (the ADR-008 /32 is deliberately bannable)"
fi

# --- 9. Services -----------------------------------------------------------
for svc in proxmox-backup nftables chrony; do
    if have systemctl; then
        [[ "$(systemctl is-active "$svc" 2>/dev/null)" == "active" ]] || \
            alert "service ${svc} is not active — backup service interrupted"
    fi
done

info "=== PBS01 HEALTH CHECK COMPLETE (alerts=${ALERTS}) ==="
# STDOUT completion marker — required by the workstation pull (runbook §7.2, layer 3).
# `info` writes to the log file ONLY; without an explicit marker a caller cannot
# distinguish "all gates ran, all green" from "the watchdog aborted midway".
printf '[%s] === PBS01 HEALTH CHECK COMPLETE (alerts=%s) ===\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$ALERTS"
if (( ALERTS > 0 )); then
    printf 'pbs01 watchdog: %s CRITICAL — see %s\n' "$ALERTS" "$ALERT_LOG" >&2
    exit 1
fi
exit 0
