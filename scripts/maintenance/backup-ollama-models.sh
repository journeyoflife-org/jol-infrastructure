#!/usr/bin/env bash
# =============================================================================
# backup-ollama-models.sh
# Nightly model-store backup for llm-prod-lt01 (jol-llm inference host).
#
# Runs ON llm-prod-lt01 (root cron): pushes the Ollama model store to the
# fleet backup platform pbs01 (Proxmox Backup Server) using the official
# proxmox-backup-client — the same push model pve-prod-hv01 uses for VM
# backups. Ollama is stopped for the snapshot window (consistency), then
# restarted on every exit path.
#
# Target:  jol-llm-backup@pbs!llm-token@10.10.10.30:pbs-store
#          namespace jol-llm (auto-created on first backup; DatastoreBackup
#          ACL only — least privilege).
# Security: client-side encryption (--keyfile), TLS fingerprint pinned,
#          token secret in /etc/jol-ollama/pbs-token (600 root),
#          encryption key in /etc/jol-ollama/pbs-encryption.key (600 root).
# Scope:   FULL store (~23 GB) — pbs01 backup-pool is 3.27 TB RAIDZ2, so the
#          pre-2026-08-11 selective-scope workaround (admin01 /home) is gone.
#          Includes irreplaceable mistral:7b-instruct weights and qwen3:30b.
# Retention: keep-daily=7, keep-weekly=4 (server-side prune/verify jobs
#          handle garbage collection and monthly verification).
#
# Supersedes the admin01 tar.gz design (2026-08-09..2026-08-11).
# Restore procedure: docs/runbooks/llm-prod-lt01-deployment.md (Phase 5).
#
# SOC 2 Type II / GDPR / ISO 27001 A.8.13 — change recorded in
# docs/servers/llm-prod-lt01.md and docs/servers/pbs01.md.
# No credentials in this script.
#
# Usage: backup-ollama-models.sh   (non-interactive; cron-friendly, as root)
# =============================================================================
set -euo pipefail

PBS_REPO="jol-llm-backup@pbs!llm-token@10.10.10.30:pbs-store"
PBS_NS="jol-llm"
# pbs01 server certificate fingerprint (CN=pbs01.jol.lan) — pins TLS, see
# docs/servers/pbs01.md. Rotate together with a pbs01 cert renewal.
PBS_FP="4b:93:a9:7e:0b:9a:89:ee:1a:9f:64:2c:40:e1:8f:3a:4a:91:92:d4:29:ed:f5:a6:1b:1d:b3:26:e6:4c:54:92"
TOKEN_FILE="/etc/jol-ollama/pbs-token"
KEY_FILE="/etc/jol-ollama/pbs-encryption.key"
MODEL_STORE="/var/lib/jol-ollama/models"
BACKUP_TYPE="host"
BACKUP_ID="llm-prod-lt01"
KEEP_DAILY=7
KEEP_WEEKLY=4
LOG_FILE="/var/log/jol-ollama-backup.log"

STOPPED=0

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

snapshot_count() {
    # `list` shows one row per group; with default field splitting the
    # borders are tokens of their own: $2 = group, $6 = backup-count.
    pbs list 2>/dev/null | awk -v g="${BACKUP_TYPE}/${BACKUP_ID}" '$2 == g {print $6}' || true
}

pbs() {
    # Token secret and TLS pin via env (never on the command line / in ps).
    # Empty PBS_ENCRYPTION_PASSWORD: the key file carries a passphrase-less key
    # (--kdf none) so cron runs unattended; the key itself is the secret.
    PBS_PASSWORD_FILE="$TOKEN_FILE" PBS_FINGERPRINT="$PBS_FP" \
    PBS_ENCRYPTION_PASSWORD="" proxmox-backup-client "$@" \
        --repository "$PBS_REPO" --ns "$PBS_NS"
}

# --- 0. Preflight --------------------------------------------------------
[[ "$(id -u)" == "0" ]] || die "must run as root (cron: root)"
command -v proxmox-backup-client >/dev/null || die "proxmox-backup-client not installed"
[[ -s "$TOKEN_FILE" ]] || die "missing $TOKEN_FILE"
[[ -s "$KEY_FILE" ]] || die "missing $KEY_FILE"
[[ -d "$MODEL_STORE" ]] || die "missing $MODEL_STORE"
[[ -d "$MODEL_STORE/blobs" && -d "$MODEL_STORE/manifests" ]] || \
    die "model store looks empty (no blobs/manifests) — refusing to back up"

log "=== jol-ollama model-store backup to pbs01 started ==="

# Restart ollama on any exit path once it has been stopped.
restore_service() {
    if [[ "$STOPPED" -eq 1 ]]; then
        log "restarting ollama"
        if ! systemctl start ollama; then
            log "ERROR: failed to restart ollama — MANUAL INTERVENTION REQUIRED"
        fi
        sleep 5
        if [[ "$(systemctl is-active ollama 2>/dev/null || true)" != "active" ]]; then
            log "ERROR: ollama not active after restart — MANUAL INTERVENTION REQUIRED"
        fi
    fi
}
trap restore_service EXIT

# --- 1. Stop ollama for a consistent snapshot -----------------------------
if [[ "$(systemctl is-active ollama)" == "active" ]]; then
    log "stopping ollama for consistent snapshot"
    systemctl stop ollama
    STOPPED=1
fi

# --- 2. Push full store to pbs01 (client-side encrypted) -------------------
count_before="$(snapshot_count)"
store_size="$(du -sb "$MODEL_STORE" | cut -f1)"
log "pushing $(numfmt --to=iec "$store_size") model store to ${PBS_REPO} (ns: ${PBS_NS})"
pbs backup "jol-models.pxar:${MODEL_STORE}" \
    --backup-type "$BACKUP_TYPE" --backup-id "$BACKUP_ID" \
    --keyfile "$KEY_FILE" --crypt-mode encrypt \
    || die "PBS backup run failed"

# --- 3. Verify: the backup group must hold one more snapshot ----------------
count_after="$(snapshot_count)"
if [[ "$count_after" -le "$count_before" ]]; then
    die "snapshot count unchanged after backup (${count_before} -> ${count_after})"
fi
log "snapshot verified on pbs01 (${count_before} -> ${count_after})"

# --- 4. Retention (server-side GC reclaims freed chunks later) --------------
pbs prune "${BACKUP_TYPE}/${BACKUP_ID}" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
    || log "WARNING: retention prune failed (backup itself succeeded)"

log "=== backup to pbs01 completed OK ==="
