#!/usr/bin/env bash
# =============================================================================
# hv01-backup-onboard.sh — pve-prod-hv01 backup onboarding, phase 4c-7
#
# RUN THIS AFTER the two operator-only steps have been completed:
#   (a) on pbs01: namespace /backup-pool/pbs-store/ns/jol-hv01 + DatastorePowerUser
#       ACLs for 'pve-backup@pbs' and 'pve-backup@pbs!pve-token'
#   (b) in the PVE Web UI: Add Storage -> Proxmox Backup Server, ID 'pbs01',
#       datastore pbs-store, namespace jol-hv01, TLS fingerprint pinned
#       (verified live 2026-10-21 from hv01: sha256
#        4B:93:A9:7E:0B:9A:89:EE:1A:9F:64:2C:40:E1:8F:3A:4A:91:92:D4:29:ED:F5:A6:1B:1D:B3:26:E6:4C:54:92,
#        CN=pbs01.jol.lan, notBefore 2026-07-04, notAfter 3025-11-04)
# Those two cannot be automated from here: pbs01 SSH (10.10.10.30:22) is not
# reachable from the workstation and hv01 holds no key on pbs01, and the token
# secret must never transit a command line (AGENTS.md §0.1).
#
# WHAT THIS SCRIPT DOES (verify -> mutate -> verify, idempotent, DRY_RUN default):
#   1. gate: pbs01 datastore registered and usable (skips with instructions if not)
#   2. creates the vzdump job for VMIDs 100/101/102 through the API — the API is the
#      only safe writer: the previous hand-written jobs.cfg section was inert because
#      its option lines lacked the mandatory leading TAB. Parameter names below were
#      read out of the live PVE 9 schema (/usr/share/perl5/PVE/API2/Backup.pm +
#      VZDump/Common.pm), not guessed: the create endpoint takes 'id' (NOT 'sid'),
#      'comment' (NOT 'notes'), and 'schedule' in the pve-calendar-event subset — a
#      systemd-style spec, e.g. "02:00" or "*-*-* 02:00:00"; legacy 5-field cron is not
#      what PVE writes. 'starttime'/'dow' are deprecated shorthands that PVE converts
#      into exactly "HH:MM", which is why "02:00" is the safest form here.
#   3. proves the job is in the scheduler registry AND jobs.cfg (counts must agree),
#      and that it appears in /cluster/next-run
#   4. runs one real vzdump of the smallest VM (102) into pbs01 as the pipe test,
#      then asserts a fresh OK vzdump task
#   5. prepares phase 7 (host-evidence pxar push): checks the client binary (already
#      present on hv01), the secret files, installs the archive script + cron
#   6. prints the gate table with anything left to the operator marked UNVERIFIED
#
# Usage:  sudo DRY_RUN=1 ./hv01-backup-onboard.sh     # preview (default)
#         sudo DRY_RUN=0 ./hv01-backup-onboard.sh     # apply
# No credentials in this script, and none on any command line it builds.
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
NODE="$(hostname)"
EXPECTED_HOST="${EXPECTED_HOST:-pve-prod-hv01}"
PBS_STORAGE="${PBS_STORAGE:-pbs01}"
PBS_NS="${PBS_NS:-jol-hv01}"
VM_IDS="${VM_IDS:-100 101 102}"
TEST_VMID="${TEST_VMID:-102}"
TEST_VZDUMP="${TEST_VZDUMP:-0}"
JOB_ID="${JOB_ID:-hv01-nightly-pbs}"
SCHEDULE="${SCHEDULE:-02:00}"
PRUNE="${PRUNE:-keep-daily=7,keep-weekly=4,keep-monthly=6}"
ARCHIVE_SCRIPT="/usr/local/bin/hv01-archive-to-pbs.sh"
HEALTH_SCRIPT="${HEALTH_SCRIPT:-/usr/local/bin/jol-health-check.sh}"
# The token secret is already on this host once the datastore is registered in the
# Web UI — PVE stores it at /etc/pve/priv/storage/<id>.pw (0600 root). Reusing it
# avoids ever typing a secret into a terminal (see evidence §15).
PVE_CRED_FILE="/etc/pve/priv/storage/${PBS_STORAGE}.pw"
KEY_FILE="/etc/jol-hv01/pbs-encryption.key"
LOG_DIR="/var/log/jol-hv01"
TS="$(date +%Y%m%d-%H%M%S)"
SCRIPT_NAME="hv01-backup-onboard.sh"

mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/onboard-$TS.log"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"

FAILURES=0
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARN : $*"; }
fail() { log "FAIL : $*"; FAILURES=$((FAILURES + 1)); }
run() {
    # Under `set -e` a failing pipeline must not abort the run: the verification
    # gates below are what decide success, and they need to be reached.
    if [[ "$DRY_RUN" == "0" ]]; then
        if "$@" 2>&1 | tee -a "$LOG_FILE"; then
            return 0
        fi
        fail "command failed: $*"
        return 0
    fi
    log "DRY  : $*"
}

[[ "$(id -u)" == "0" ]] || { echo "must run as root"; exit 1; }
[[ "$NODE" == "$EXPECTED_HOST" ]] || { echo "refusing to run on $NODE"; exit 1; }
log "=== $SCRIPT_NAME start (DRY_RUN=$DRY_RUN) on $NODE ==="

# --- 1. Gate: the operator steps landed -------------------------------------
if ! pvesm status 2>/dev/null | awk -v s="$PBS_STORAGE" '$1 == s {found=1} END {exit !found}'; then
    fail "datastore '$PBS_STORAGE' is not registered on this host — finish step (b) in the PVE Web UI first (server 10.10.10.30, datastore pbs-store, username pve-backup@pbs, token pve-token, namespace $PBS_NS, fingerprint pinned). Nothing else in this script can succeed without it."
    log "=== $SCRIPT_NAME aborted at gate 1 — no changes made ==="
    exit 1
fi
log "storage '$PBS_STORAGE' present: $(pvesm status 2>/dev/null | awk -v s="$PBS_STORAGE" '$1==s {print $2, $3, $4}')"
# Prove it is actually usable, not merely declared (a wrong token/ACL shows up here).
if [[ "$DRY_RUN" == "0" ]]; then
    if pvesh get "/nodes/$NODE/storage/$PBS_STORAGE/status" --output-format json >>"$LOG_FILE" 2>&1; then
        V_ACTIVE="yes (status query accepted by pbs01)"
        log "storage status query OK (credentials + TLS pin accepted by pbs01)"
    else
        fail "'pvesh get /nodes/$NODE/storage/$PBS_STORAGE/status' failed — wrong token, missing ACL on the namespace (step a), or fingerprint mismatch. Output above."
        log "=== $SCRIPT_NAME aborted at gate 1b — no job created ==="
        exit 1
    fi
else
    V_ACTIVE="not probed (DRY_RUN does not touch pbs01)"
    log "DRY  : pvesh get /nodes/$NODE/storage/$PBS_STORAGE/status"
fi

# --- 2 + 3. Backup job, created through the API ------------------------------
VM_ARGS=()
for v in $VM_IDS; do VM_ARGS+=(--vmid "$v"); done

if pvesh get "/cluster/backup/$JOB_ID" >/dev/null 2>&1; then
    log "job '$JOB_ID' already registered — not creating a duplicate"
    pvesh get "/cluster/backup/$JOB_ID" --output-format yaml | tee -a "$LOG_FILE"
else
    CFG_SECTIONS="$(grep -c '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null || true)"
    CFG_SECTIONS="${CFG_SECTIONS:-0}"
    JOBS_JSON="$(pvesh get /cluster/backup --output-format json 2>/dev/null || true)"
    if [[ "${CFG_SECTIONS:-0}" != "0" && ( -z "$JOBS_JSON" || "$JOBS_JSON" == "[]" ) ]]; then
        warn "jobs.cfg has $CFG_SECTIONS inert section(s) the parser dropped (option lines missing the mandatory leading TAB). ⚠ Such a section is NOT harmless and NOT survivable as evidence (learned 2026-10-22): PVE 9's job registry aborts on every write while it is present ('unknown section type' at PVE::Job::Registry.pm:73), and 'pvesh delete /cluster/backup/<id>' cannot remove it because the parser cannot see it. Remove it by direct file edit AFTER backing the file up: cp -a /etc/pve/jobs.cfg /root/prechange-\$(date +%Y%m%d-%H%M)/jobs.cfg.bak, then ': > /etc/pve/jobs.cfg' (or excise just that section), then verify 'pvesh get /cluster/backup' returns cleanly with NO warnings before creating the job."
    fi
    run pvesh create /cluster/backup \
        --id "$JOB_ID" --schedule "$SCHEDULE" --storage "$PBS_STORAGE" \
        --mode snapshot --compress zstd --enabled 1 --repeat-missed 1 \
        --mailnotification failure --prune-backups "$PRUNE" \
        --comment "hv01 AI estate nightly (VMIDs $VM_IDS) -> $PBS_STORAGE ns $PBS_NS" \
        "${VM_ARGS[@]}"
fi

AFTER="$(pvesh get /cluster/backup --output-format json 2>/dev/null || true)"
COUNT="$(printf '%s' "$AFTER" | grep -o '"schedule"' | wc -l | tr -d ' ' || true)"
CFG_AFTER="$(grep -c '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null || true)"
log "registry: jobs.cfg vzdump sections=${CFG_AFTER:-0} scheduler entries=${COUNT}"
if [[ "$DRY_RUN" == "0" && "${CFG_AFTER:-0}" != "$COUNT" ]]; then
    fail "jobs.cfg vs scheduler disagree — a section is still inert (that is how the 2026 job hid for 10 weeks)"
elif [[ "$DRY_RUN" == "0" ]]; then
    log "registration consistent"
fi
if [[ "$DRY_RUN" == "0" ]]; then
    pvesh get /cluster/next-run --output-format yaml 2>/dev/null | grep -A3 -i vzdump | tee -a "$LOG_FILE" || true
fi

# --- 4. First real off-host backup (pipe test on the smallest VM) -----------
V_LANDED="no"
if [[ "$TEST_VZDUMP" == "1" ]]; then
    log "running vzdump of VMID $TEST_VMID into $PBS_STORAGE (pipe test)"
    run vzdump "$TEST_VMID" --storage "$PBS_STORAGE" --mode snapshot --compress zstd --mailnotification failure
    NEWEST_OK="$(pvesh get /cluster/tasks --typefilter vzdump --limit 3 --output-format json 2>/dev/null | grep -c '"status":"OK"' || true)"
    if [[ "${NEWEST_OK:-0}" == "0" ]]; then
        fail "no OK vzdump task after the run — backup did not land on $PBS_STORAGE"
    else
        # Prove it is visible through PVE's own PBS query — no pbs01 admin needed.
        CONTENT="$(pvesh get "/nodes/$NODE/storage/$PBS_STORAGE/content" --content backup --output-format json 2>/dev/null || true)"
        if printf '%s' "$CONTENT" | grep -q "vm/$TEST_VMID"; then
            V_LANDED="yes"
            log "vzdump OK and the snapshot group is listed through PVE: vm/$TEST_VMID present in ns $PBS_NS"
        else
            V_LANDED="task-OK-not-listed"
            warn "vzdump task said OK but the group is not listed via the storage content API — check the PBS datastore view manually"
        fi
    fi
else
    log "TEST_VZDUMP unset — skipping the pipe-test run (set TEST_VZDUMP=1 to execute it)"
fi

# --- 5. Phase 7: host-evidence replication ----------------------------------
if command -v proxmox-backup-client >/dev/null 2>&1; then
    log "proxmox-backup-client present"
else
    warn "proxmox-backup-client missing — install it before phase 7"
fi
if [[ -s "$PVE_CRED_FILE" ]]; then
    log "PBS credential present (written by the Web UI registration): $PVE_CRED_FILE ($(stat -c '%a %U:%G' "$PVE_CRED_FILE")) — no secret typing needed"
else
    warn "expected PVE credential file $PVE_CRED_FILE is missing — re-check that the 'pbs01' datastore was added through the Web UI"
fi
if [[ -s "$KEY_FILE" ]]; then
    log "client-side encryption key: $KEY_FILE ($(stat -c '%a %U:%G' "$KEY_FILE")) — escrow this off-host, key loss = unreadable backups"
else
    warn "no client-side encryption key found at $KEY_FILE — create and escrow one:
      sudo proxmox-backup-client key create /etc/jol-hv01/pbs-encryption.key --kdf none"
fi
if [[ ! -f "$ARCHIVE_SCRIPT" && -n "${ARCHIVE_SRC:-}" && -f "$ARCHIVE_SRC" ]]; then
    run install -m 750 -o root -g root "$ARCHIVE_SRC" "$ARCHIVE_SCRIPT"
fi
if [[ -f "$ARCHIVE_SCRIPT" ]]; then
    log "archive script installed: $(sha256sum "$ARCHIVE_SCRIPT")"
    if [[ -f /etc/cron.d/jol-hv01-archive ]]; then
        log "evidence cron installed: $(tr -d '\n' </etc/cron.d/jol-hv01-archive)"
    else
        CRON_LINE=$'PATH=/usr/sbin:/usr/bin:/sbin:/bin\n45 3 * * * root '"$ARCHIVE_SCRIPT"$' >> /var/log/jol-hv01/archive-pbs.log 2>&1\n'
        if [[ "$DRY_RUN" == "0" ]]; then
            printf '%s' "$CRON_LINE" > /etc/cron.d/jol-hv01-archive
            chmod 644 /etc/cron.d/jol-hv01-archive
            log "evidence cron installed (03:45 UTC, after the 03:00 prune and 03:15 llm push)"
        else
            log "DRY  : would write /etc/cron.d/jol-hv01-archive (03:45 UTC)"
        fi
    fi
else
    warn "archive script not installed — pipe scripts/maintenance/hv01-archive-to-pbs.sh to the host and re-run with ARCHIVE_SRC=/path/to/it"
fi
V_PUSH="skipped"
if [[ "${PUSH_EVIDENCE:-0}" == "1" && -x "$ARCHIVE_SCRIPT" && "$DRY_RUN" == "0" ]]; then
    log "pushing host evidence to pbs01 once (INCLUDE_ISO=${INCLUDE_ISO:-0})"
    if INCLUDE_ISO="${INCLUDE_ISO:-0}" "$ARCHIVE_SCRIPT"; then
        V_PUSH="ok"
        log "evidence archive pushed"
    else
        V_PUSH="failed"
        fail "evidence push failed — see /var/log/jol-hv01/archive-pbs.log (VM backups are unaffected by this)"
    fi
fi

# --- 6. Gate table ----------------------------------------------------------
log "--- gates ---"
log "1 PBS datastore $PBS_STORAGE registered and active   : $V_ACTIVE"
log "2 backup job registered (jobs.cfg=${CFG_AFTER:-0} scheduler=${COUNT}) : $( [[ "${CFG_AFTER:-0}" == "$COUNT" ]] && echo yes || echo NO )"
log "3 first vzdump of VMID $TEST_VMID landed and listed   : $V_LANDED"
log "4 evidence archive cron installed                     : $( [[ -f /etc/cron.d/jol-hv01-archive ]] && echo yes || echo NO )"
log "5 evidence pxar push                                  : $V_PUSH"
log "6 client-side key escrowed off-host                   : operator (key loss = unreadable backups)"
log "TODO operator: restore drill (qmrestore to scratch VMID 199, NIC detached) + negative encryption test"
log "TODO: never delete /var/lib/vz/dump/vzdump-qemu-100-2026_08_12-*.vma.zst before the pbs01 restore drill passes"

# --- 7. Re-run the watchdog so the new state is asserted, not assumed -------
if [[ "${RUN_WATCHDOG:-1}" == "1" && -x "$HEALTH_SCRIPT" && "$DRY_RUN" == "0" ]]; then
    log "--- watchdog after onboarding ---"
    "$HEALTH_SCRIPT" || log "watchdog exited non-zero: remaining alerts above are real, not noise"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    log "=== $SCRIPT_NAME finished with $FAILURES finding(s) — log: $LOG_FILE ==="
    exit 1
fi
log "=== $SCRIPT_NAME finished OK (DRY_RUN=$DRY_RUN) — log: $LOG_FILE ==="
