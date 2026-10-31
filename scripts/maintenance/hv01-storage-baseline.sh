#!/usr/bin/env bash
# =============================================================================
# hv01-storage-baseline.sh
# Storage-role + boot-resilience baseline for pve-prod-hv01 (AI hypervisor).
#
# WHAT IT FIXES (all verified live 2026-10-21, see
# docs/runbooks/hv01-storage-backup-reconfiguration.md §1):
#   1. /etc/fstab mounts /mnt/hdd-iso and /mnt/hdd-archive WITHOUT nofail →
#      a dead or absent 1 TB HDD stalls boot into emergency target and takes
#      VMIDs 100/101/102 (RAG/MCP/Hermes) offline with it.
#   2. PVE dir storage `hdd-iso` offers `backup` content on a single-copy
#      5400 rpm consumer drive inside the host's own failure domain. Observed
#      silently falling back to the NVMe root filesystem when the mount was
#      absent (PVE reported "active, 93 GB free" and auto-created dump/+template/
#      on /). VM backups belong on pbs01, not here.
#   3. ext4 automatic fsck disabled on both partitions (max mount count -1,
#      check interval 0, last checked 2026-04-22) after a live-removal event
#      that produced "JBD2: I/O error when updating journal superblock".
#   4. Evidence directories for the config/health/access archives are not
#      guaranteed to exist (a missing dir + "2>/dev/null" = silent backup loss).
#   5. Reports (does not mutate) the two remaining findings that need a change
#      window of their own: the malformed vzdump job in jobs.cfg and the absent
#      PBS datastore registration.
#
# CONTRACT: idempotent (state checked before every mutation), change-logged
# (/var/log/jol-hv01 700, log file 600), DRY_RUN by default, non-destructive
# (no rm/mv; timestamped .bak before any file edit).
# No credentials in this script.
#
# Usage:   sudo DRY_RUN=1 ./hv01-storage-baseline.sh     # preview (default)
#          sudo DRY_RUN=0 ./hv01-storage-baseline.sh     # apply
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
EXPECTED_HOST="${EXPECTED_HOST:-pve-prod-hv01}"
ISO_MNT="${ISO_MNT:-/mnt/hdd-iso}"
ARC_MNT="${ARC_MNT:-/mnt/hdd-archive}"
ISO_DEV="${ISO_DEV:-/dev/sda1}"
ARC_DEV="${ARC_DEV:-/dev/sda2}"
ISO_STORAGE="${ISO_STORAGE:-hdd-iso}"
ISO_CONTENT="${ISO_CONTENT:-iso,vztmpl}"
PBS_STORAGE="${PBS_STORAGE:-pbs01}"
FSCK_MAX_MOUNT_COUNT="${FSCK_MAX_MOUNT_COUNT:-30}"
FSCK_MAX_INTERVAL="${FSCK_MAX_INTERVAL:-180d}"

LOG_DIR="/var/log/jol-hv01"
TS="$(date +%Y%m%d-%H%M%S)"
# Literal name: the script is normally piped into 'bash -s' over SSH, where $0
# would report "bash".
SCRIPT_NAME="hv01-storage-baseline.sh"

mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/baseline-$TS.log"
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

FAILURES=0

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARN : $*"; }
fail() { log "FAIL : $*"; FAILURES=$((FAILURES + 1)); }
run() {
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        log "DRY  : $*"
    fi
}

# --- 0. Preflight -----------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { echo "must run as root"; exit 1; }
HOSTNAME_NOW="$(hostname)"
[[ "$HOSTNAME_NOW" == "$EXPECTED_HOST" ]] || \
    { echo "refusing to run on $HOSTNAME_NOW (expected $EXPECTED_HOST)"; exit 1; }
command -v pvesm >/dev/null || { echo "pvesm not found — this is not a PVE host"; exit 1; }

log "=== $SCRIPT_NAME start (DRY_RUN=$DRY_RUN) on $HOSTNAME_NOW ==="

# Both HDD partitions must be mounted from the expected devices, otherwise
# every step below would mutate the NVMe root filesystem by accident.
for pair in "$ISO_MNT:$ISO_DEV" "$ARC_MNT:$ARC_DEV"; do
    mnt="${pair%%:*}"; dev="${pair##*:}"
    src="$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || true)"
    if [[ "$src" != "$dev" ]]; then
        fail "$mnt is not mounted from $dev (found: '${src:-nothing}') — aborting, mount the HDD first"
    fi
done
if [[ "$FAILURES" -gt 0 ]]; then
    log "=== ABORTED: HDD not correctly mounted. Nothing changed. ==="
    exit 1
fi
log "preflight OK: $ISO_MNT <- $ISO_DEV, $ARC_MNT <- $ARC_DEV"

# --- 1. Pre-change capture --------------------------------------------------
PRE_DIR="$ARC_MNT/system/prechange-$TS"
run install -d -m 700 "$PRE_DIR"
if [[ "$DRY_RUN" == "0" ]]; then
    cp -p /etc/fstab "$PRE_DIR/fstab"
    cp -p /etc/pve/storage.cfg "$PRE_DIR/storage.cfg" 2>/dev/null || true
    cp -p /etc/pve/jobs.cfg "$PRE_DIR/jobs.cfg" 2>/dev/null || true
    cp -p /etc/cron.d/jol-config-backup "$PRE_DIR/" 2>/dev/null || true
    log "pre-change copies captured in $PRE_DIR (rollback source)"
fi

# --- 2. fstab: HDD mounts must never block boot ----------------------------
FSTAB_NEEDS_FIX=0
if grep -qE '^[^[:space:]]+[[:space:]]+/mnt/hdd-(iso|archive)[[:space:]]' /etc/fstab; then
    awk '/^[^ ]+[[:space:]]+\/mnt\/hdd-(iso|archive)/ { if ($4 !~ /nofail/) exit 1 }' /etc/fstab \
        || FSTAB_NEEDS_FIX=1
fi

if [[ "$FSTAB_NEEDS_FIX" == "1" ]]; then
    cp -p /etc/fstab "/etc/fstab.bak.$TS"
    log "editing /etc/fstab (backup: /etc/fstab.bak.$TS)"
    TMP_FSTAB="$(mktemp)"
    awk '/^[^ ]+[[:space:]]+\/mnt\/hdd-(iso|archive)/ && $4 !~ /nofail/ {
             $4 = $4 ",nofail,x-systemd.mount-timeout=10s,x-systemd.device-timeout=10s"
         }
         { print }' /etc/fstab > "$TMP_FSTAB"
    if [[ "$DRY_RUN" == "0" ]]; then
        cat "$TMP_FSTAB" > /etc/fstab
        rm -f "$TMP_FSTAB"
        systemctl daemon-reload
        if mount -a; then log "mount -a OK after fstab change"; else fail "mount -a failed after fstab change"; fi
        findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | grep hdd- | tee -a "$LOG_FILE"
    else
        log "DRY  : would append nofail + systemd mount/device timeouts to the two /mnt/hdd-* lines"
    fi
else
    log "fstab already carries nofail on both HDD mounts — no change"
fi

# --- 3. PVE storage role: hdd-iso stops being a backup target --------------
CURRENT_CONTENT="$(awk -v s="$ISO_STORAGE" '
    /^[a-zA-Z]+:[[:space:]]/ { inblk = ($2 == s) }
    inblk && /^[[:space:]]*content[[:space:]]/ { print $2; exit }
' /etc/pve/storage.cfg 2>/dev/null || true)"
log "storage '$ISO_STORAGE' current content: '${CURRENT_CONTENT:-not found}'"
if [[ -z "$CURRENT_CONTENT" ]]; then
    warn "storage $ISO_STORAGE missing from storage.cfg — skipping (was it removed?)"
elif [[ "$CURRENT_CONTENT" == "$ISO_CONTENT" ]]; then
    log "content already '$ISO_CONTENT' — no change"
else
    run pvesm set "$ISO_STORAGE" --content "$ISO_CONTENT"
fi

# --- 4. Evidence directories must exist ------------------------------------
for d in config-backup health access system mcp; do
    if [[ -d "$ARC_MNT/$d" ]]; then
        log "evidence dir present: $ARC_MNT/$d"
    else
        run install -d -m 700 "$ARC_MNT/$d"
    fi
done

# --- 5. ext4 integrity policy ------------------------------------------------
for dev in "$ISO_DEV" "$ARC_DEV"; do
    mmc="$(tune2fs -l "$dev" 2>/dev/null | sed -n 's/^Maximum mount count:[[:space:]]*//p')"
    ci="$(tune2fs -l "$dev" 2>/dev/null | sed -n 's/^Check interval:[[:space:]]*//p')"
    last="$(tune2fs -l "$dev" 2>/dev/null | sed -n 's/^Last checked:[[:space:]]*//p')"
    log "$dev: max-mount-count=${mmc:-?} check-interval=${ci:-?} last-checked='${last:-?}'"
    if [[ "$mmc" != "$FSCK_MAX_MOUNT_COUNT" || "$ci" != "$FSCK_MAX_INTERVAL" ]]; then
        # tune2fs refuses some options on a mounted rw filesystem; if it does,
        # this is retried inside the §3.2 offline fsck window.
        if [[ "$DRY_RUN" == "0" ]]; then
            if tune2fs -c "$FSCK_MAX_MOUNT_COUNT" -i "$FSCK_MAX_INTERVAL" "$dev" 2>&1 | tee -a "$LOG_FILE"; then
                log "$dev: fsck policy set to -c $FSCK_MAX_MOUNT_COUNT -i $FSCK_MAX_INTERVAL"
            else
                warn "$dev: tune2fs refused while mounted — apply during the offline fsck window"
            fi
        else
            log "DRY  : tune2fs -c $FSCK_MAX_MOUNT_COUNT -i $FSCK_MAX_INTERVAL $dev"
        fi
    fi
done

# --- 6. Report: backup job registry (mutation needs its own approval) ------
JOBCFG_SECTIONS="$(grep -c '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null || true)"
API_JOBS="$(pvesh get /cluster/backup --output-format json 2>/dev/null || true)"
log "jobs.cfg vzdump sections: ${JOBCFG_SECTIONS:-0} | /cluster/backup API: ${API_JOBS:-<empty>}"
if [[ "${JOBCFG_SECTIONS:-0}" != "0" && ( -z "$API_JOBS" || "$API_JOBS" == "[]" ) ]]; then
    fail "hand-written vzdump job(s) in jobs.cfg are NOT registered — no backup job is scheduled. Cause is serialisation: option lines must begin with a TAB (verify with 'cat -A /etc/pve/jobs.cfg'). Fix with 'pvesh delete /cluster/backup/<id>' + 'pvesh create /cluster/backup ...' (runbook §3.6), never by editing the file."
elif [[ "$API_JOBS" != "[]" && -n "$API_JOBS" ]]; then
    log "backup job registry OK: $(printf '%s' "$API_JOBS" | grep -o '"schedule":"[^"]*"' | tr '\n' ' ')"
fi

# --- 7. Report: PBS datastore registration ----------------------------------
if pvesm status 2>/dev/null | awk -v s="$PBS_STORAGE" '$1 == s {found=1} END {exit !found}'; then
    log "PBS datastore '$PBS_STORAGE' registered — VM backups can target it"
    pvesm status 2>/dev/null | tee -a "$LOG_FILE"
else
    warn "no PBS datastore '$PBS_STORAGE' on this host — register it in the PVE Web UI (Add Storage > Proxmox Backup Server, namespace 'jol-hv01', TLS fingerprint pinned). CLI is NOT used because 'pvesm add pbs --password <secret>' would expose the token in argv and shell history (AGENTS.md 0.1)."
fi

# --- 8. Verification pass ---------------------------------------------------
log "--- verify ---"
findmnt -o TARGET,SOURCE,OPTIONS | grep -E 'hdd-' | tee -a "$LOG_FILE" || true
grep -E '/mnt/hdd-' /etc/fstab | tee -a "$LOG_FILE" || true
awk '/^dir: hdd-iso$/{f=1;next} f&&/^[a-z]+:/{f=0} f' /etc/pve/storage.cfg 2>/dev/null | tee -a "$LOG_FILE" || true

if [[ "$FAILURES" -gt 0 ]]; then
    log "=== $SCRIPT_NAME finished with $FAILURES finding(s) — see $LOG_FILE ==="
    exit 1
fi
log "=== $SCRIPT_NAME finished OK (DRY_RUN=$DRY_RUN) — log: $LOG_FILE ==="
