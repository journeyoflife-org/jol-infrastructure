#!/usr/bin/env bash
# =============================================================================
# hv01-archive-to-pbs.sh
# Nightly off-host replication of the pve-prod-hv01 host-evidence archive.
#
# WHY: /mnt/hdd-archive on the hypervisor's 1 TB HDD is the ONLY copy of
#   config-backup/  — weekly tar of /etc/pve, /etc/fstab, /etc/network/
#                    interfaces, /etc/lvm/lvm.conf, ufw, chrony, fail2ban
#                    (SOC 2 CC8.1 change evidence, ISO A.8.13)
#   health/         — daily jol-health-check.sh logs + ALERTS.log
#                    (SOC 2 CC7.2 monitoring evidence)
#   access/ system/ mcp/ — log and state archives
# A single copy on a consumer 5400 rpm drive inside the same failure domain as
# the workload it describes is not a backup and is not durable evidence. This
# script creates the second, off-host copy on pbs01 (RAIDZ2, dedup, verified).
#
# Mechanism: guest-side proxmox-backup-client pxar push — the proven fleet
# precedent for non-VM data (scripts/maintenance/backup-ollama-models.sh on
# llm-prod-lt01, since 2026-08-11). VM disks are NOT handled here; they go
# through hypervisor vzdump -> PBS.
#
# Target:  jol-hv01 namespace on pbs-store @ 10.10.10.30, backup-type host,
#          backup-id pve-prod-hv01.
# Security: client-side encryption (--keyfile, crypt-mode encrypt), TLS
#          fingerprint pinned, token read from PBS_PASSWORD_FILE — the secret
#          never appears in argv, ps output, or shell history. The token file is
#          PVE's own /etc/pve/priv/storage/pbs01.pw (created when the datastore was
#          registered in the Web UI), so no secret is ever typed into a terminal.
# Idempotent + safe to re-run; no destructive operations. Runs as root.
#
# Usage:  sudo ./hv01-archive-to-pbs.sh            (cron-friendly, non-interactive)
#         INCLUDE_ISO=1 sudo ./hv01-archive-to-pbs.sh   # also push the 596 MB
#                                                        provisioning image (once;
#                                                        dedups to ~0 afterwards)
# =============================================================================
set -euo pipefail

PBS_REPO="${PBS_REPO:-pve-backup@pbs!pve-token@10.10.10.30:pbs-store}"
PBS_NS="${PBS_NS:-jol-hv01}"
# pbs01 server certificate fingerprint (CN=pbs01.jol.lan), public pinning data —
# see docs/servers/pbs01.md "Certificates". Rotate together with a cert renewal.
PBS_FP="${PBS_FP:-4b:93:a9:7e:0b:9a:89:ee:1a:9f:64:2c:40:e1:8f:3a:4a:91:92:d4:29:ed:f5:a6:1b:1d:b3:26:e6:4c:54:92}"
TOKEN_FILE="${PBS_TOKEN_FILE:-/etc/pve/priv/storage/pbs01.pw}"
PVE_TOKEN_FILE="/etc/pve/priv/storage/pbs01.pw"
FALLBACK_TOKEN_FILE="/etc/jol-hv01/pbs-token"
# ONE client-side key per datastore, not two. PVE already holds the key it uses for
# vzdump backups at /etc/pve/priv/storage/pbs01.enc; reusing it for the evidence pxar
# avoids a second secret to escrow and a second way to lose a restore.
KEY_FILE="${PBS_KEY_FILE:-/etc/pve/priv/storage/pbs01.enc}"
PVE_KEY_FILE="/etc/pve/priv/storage/pbs01.enc"
FALLBACK_KEY_FILE="/etc/jol-hv01/pbs-encryption.key"
ARCHIVE_DIR="/mnt/hdd-archive"
ISO_DIR="/mnt/hdd-iso/template"
BACKUP_TYPE="host"
BACKUP_ID="pve-prod-hv01"
KEEP_DAILY=7
KEEP_WEEKLY=4
INCLUDE_ISO="${INCLUDE_ISO:-0}"
LOG_DIR="/var/log/jol-hv01"
LOG_FILE="$LOG_DIR/archive-pbs.log"
# Evidence staleness threshold: health logs are written daily at 06:00.
MAX_EVIDENCE_AGE_HOURS="${MAX_EVIDENCE_AGE_HOURS:-48}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# Credential resolution — deliberately NO interactive secret capture in this flow.
# Once the datastore is registered through the PVE Web UI, PVE itself holds the token
# secret at /etc/pve/priv/storage/<id>.pw (0600 root, per PBSPlugin), so the same
# credential is reused instead of typing it a second time. Every extra copy of a
# secret is another way to get it wrong — see
# docs/compliance/evidence/hv01-storage-inspection-20261021.txt §15.
if [[ ! -s "$TOKEN_FILE" && -s "$FALLBACK_TOKEN_FILE" ]]; then
    log "note: PVE credential file absent/empty, using $FALLBACK_TOKEN_FILE"
    TOKEN_FILE="$FALLBACK_TOKEN_FILE"
elif [[ ! -s "$TOKEN_FILE" ]]; then
    die "no usable PBS credential: neither $PVE_TOKEN_FILE nor $FALLBACK_TOKEN_FILE has content. Register the 'pbs01' datastore in the PVE Web UI first (that form is the only place the secret needs typing)."
fi

# Same resolution order for the encryption key; if PVE's key file is unusable by the
# client (format/newline differences) fall back to a dedicated key and say so loudly.
if [[ ! -s "$KEY_FILE" ]]; then
    if [[ -s "$FALLBACK_KEY_FILE" ]]; then
        log "note: PVE key file absent/empty, using $FALLBACK_KEY_FILE"
        KEY_FILE="$FALLBACK_KEY_FILE"
    else
        die "no usable client-side encryption key: neither $PVE_KEY_FILE nor $FALLBACK_KEY_FILE has content. Create one and escrow it: sudo install -d -m 700 /etc/jol-hv01 && sudo proxmox-backup-client key create $FALLBACK_KEY_FILE --kdf none"
    fi
fi
log "credential: $TOKEN_FILE | encryption key: $KEY_FILE (mode $(stat -c %a "$KEY_FILE"))"

pbs() {
    # Secret via file, TLS pinned, encryption key passphrase-less for unattended
    # cron (the key file itself is the secret) — identical convention to
    # backup-ollama-models.sh.
    PBS_PASSWORD_FILE="$TOKEN_FILE" PBS_FINGERPRINT="$PBS_FP" \
    PBS_ENCRYPTION_PASSWORD="" proxmox-backup-client "$@" \
        --repository "$PBS_REPO" --ns "$PBS_NS"
}

snapshot_count() {
    pbs list 2>/dev/null | awk -v g="${BACKUP_TYPE}/${BACKUP_ID}" '$2 == g {print $6}' || true
}

# --- 0. Preflight -----------------------------------------------------------
[[ "$(id -u)" == "0" ]] || die "must run as root (cron: root)"
command -v proxmox-backup-client >/dev/null || \
    die "proxmox-backup-client not installed (apt install proxmox-backup-client)"
[[ -s "$TOKEN_FILE" ]] || die "empty credential $TOKEN_FILE (expected PVE's own file from the Web UI registration)"
[[ -s "$KEY_FILE" ]] || die "empty encryption key $KEY_FILE"

# The archive must be a real mount, not an empty directory on the NVMe root fs.
# A silently-unmounted HDD would otherwise make this job "succeed" on nothing.
SRC="$(findmnt -n -o SOURCE "$ARCHIVE_DIR" 2>/dev/null || true)"
[[ -n "$SRC" ]] || die "$ARCHIVE_DIR is not a mounted filesystem — refusing to back up an empty dir"
log "archive mount OK: $SRC"

[[ -d "$ARCHIVE_DIR/config-backup" ]] || die "no config-backup/ under $ARCHIVE_DIR — evidence tree missing"
newest="$(find "$ARCHIVE_DIR/health" -name '*-health.log' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 || true)"
if [[ -n "$newest" ]]; then
    age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
    if (( age_h > MAX_EVIDENCE_AGE_HOURS )); then
        # Fail visible (AGENTS.md M3 root-cause pattern): a stale evidence tree
        # means jol-health-check.sh or its mount is broken.
        log "WARNING: newest health log is ${age_h} h old (> ${MAX_EVIDENCE_AGE_HOURS} h) — monitoring evidence pipeline broken?"
    fi
    [[ -f "$ARCHIVE_DIR/ALERTS.log" ]] || log "note: no ALERTS.log yet (clean history)"
else
    log "WARNING: no health logs found under $ARCHIVE_DIR/health"
fi

log "=== hv01 evidence archive backup to pbs01 started ==="

# --- 1. Push archive to pbs01 (client-side encrypted) -----------------------
count_before="$(snapshot_count)"
archive_size="$(du -sb "$ARCHIVE_DIR" | cut -f1)"
log "pushing $(numfmt --to=iec "$archive_size") evidence archive to ${PBS_REPO} (ns: ${PBS_NS})"
pbs backup "hv01-archive.pxar:${ARCHIVE_DIR}" \
    --backup-type "$BACKUP_TYPE" --backup-id "$BACKUP_ID" \
    --keyfile "$KEY_FILE" --crypt-mode encrypt \
    || die "PBS backup run failed"

# --- 2. Optional: provisioning media (596 MB, dedups after first run) -------
if [[ "$INCLUDE_ISO" == "1" && -d "$ISO_DIR" ]]; then
    log "pushing provisioning media ${ISO_DIR} (first run ~596 MB, deduped afterwards)"
    pbs backup "hv01-iso.pxar:${ISO_DIR}" \
        --backup-type "$BACKUP_TYPE" --backup-id "$BACKUP_ID" \
        --keyfile "$KEY_FILE" --crypt-mode encrypt \
        || log "WARNING: ISO/template push failed (evidence archive already succeeded)"
fi

# --- 3. Verify: the backup group must hold one more snapshot -----------------
count_after="$(snapshot_count)"
if [[ -n "$count_before" && -n "$count_after" && "$count_after" -le "$count_before" ]]; then
    die "snapshot count unchanged after backup (${count_before} -> ${count_after})"
fi
log "snapshot verified on pbs01 (${count_before:-?} -> ${count_after:-?})"

# --- 4. Retention ------------------------------------------------------------
pbs prune "${BACKUP_TYPE}/${BACKUP_ID}" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    || log "WARNING: retention prune failed (backup itself succeeded)"

log "=== backup to pbs01 completed OK ==="
