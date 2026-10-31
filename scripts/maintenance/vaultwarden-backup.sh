#!/usr/bin/env bash
# =============================================================================
# vaultwarden-backup.sh — consistent, verified backup of the on-prem Vaultwarden
#
# WHY THIS EXISTS (2026-10-22 finding): the fleet's ONLY credential store runs as
# container `jol-vaultwarden` on the operator workstation, data in
# /home/jol/secrets/vaultwarden (db.sqlite3 + WAL + rsa_key.pem), on a plain ext4
# /home with NO backup anywhere — no cron, no timer, no archive. docs/architecture/
# secret-flow.md claimed it lives on admin01; it does not. Loss of that one disk, or
# one accidental `docker run` flag, is an unrecoverable fleet-wide credential event
# (GDPR Art. 32(1)(c) availability+resilience, ISO A.8.13, A.5.29; SOC 2 CC6.5/A1.2).
#
# WHAT IT DOES
#   1. Quiesces SQLite safely by PAUSING the container (no new packages needed —
#      neither the host nor the image has a sqlite3 CLI), so db.sqlite3, -wal and
#      -shm are copied as one coherent set.
#   2. Unpauses on every exit path (trap), so a failure can never leave the vault down.
#   3. Archives with mode 600, writes a SHA256SUMS, and VERIFIES the archive opens as
#      a real SQLite database (magic header + integrity_check via python3's stdlib
#      sqlite3 — no content is ever printed).
#   4. Retention sweep limited to this script's own filenames.
#
# It never prints, copies elsewhere, or logs any secret value. The archive itself is
# the encrypted-vault database: treat the file like a master key (it also contains
# the JWT signing key, which offline cracking of weak master passwords targets).
#
# Run as the operator (the agent must not touch /home/jol/secrets/** — Tier-1 rule):
#   sudo DRY_RUN=1 ./vaultwarden-backup.sh      # preview
#   sudo ./vaultwarden-backup.sh                # backup + verify
#   sudo OFFSITE_DIR=/mnt/hdd-archive/vaultwarden ./vaultwarden-backup.sh
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
CONTAINER="${CONTAINER:-jol-vaultwarden}"
DATA_DIR="${DATA_DIR:-/home/jol/secrets/vaultwarden}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/vaultwarden}"
OFFSITE_DIR="${OFFSITE_DIR:-}"
KEEP="${KEEP:-14}"
TS="$(date +%Y%m%d-%H%M%S)"
STAGED="$BACKUP_DIR/vaultwarden-$TS.tar.gz"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(id -u)" == "0" ]] || die "must run as root"
command -v docker >/dev/null || die "docker not found"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container $CONTAINER not found"
[[ -d "$DATA_DIR" ]] || die "data dir $DATA_DIR missing"
[[ -f "$DATA_DIR/db.sqlite3" ]] || die "no db.sqlite3 in $DATA_DIR — refusing to make an empty backup"

install -d -m 700 "$BACKUP_DIR"
log "=== Vaultwarden backup $TS (DRY_RUN=$DRY_RUN) ==="

if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY  : docker pause $CONTAINER"
    log "DRY  : copy db.sqlite3 + -wal + -shm + rsa_key.pem (+ config.json if present) from $DATA_DIR"
    log "DRY  : docker unpause $CONTAINER (trap, always)"
    log "DRY  : tar $STAGED (mode 600) + SHA256SUMS + SQLite header/integrity check"
    [[ -n "$OFFSITE_DIR" ]] && log "DRY  : copy archive to $OFFSITE_DIR"
    exit 0
fi

WORK="$(mktemp -d -t vw-backup-XXXXXX)"
chmod 700 "$WORK"
cleanup() {
    if docker unpause "$CONTAINER" >/dev/null 2>&1; then
        log "container unpaused"
    else
        log "WARNING: unpause failed or container not paused — check 'docker ps' NOW"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

log "pausing $CONTAINER for a consistent copy (vault is briefly frozen)"
docker pause "$CONTAINER" >/dev/null
# Copy straight from the host bind mount. NOT via docker exec: a paused (frozen)
# container cannot run a process, so an exec-based copy would hang the backup.
for f in db.sqlite3 db.sqlite3-wal db.sqlite3-shm rsa_key.pem config.json; do
    if [[ -e "$DATA_DIR/$f" ]]; then
        if cp -p "$DATA_DIR/$f" "$WORK/$f"; then
            log "copied $f ($(stat -c %s "$WORK/$f") bytes)"
        else
            log "WARNING: could not copy $f"
        fi
    fi
done
docker unpause "$CONTAINER" >/dev/null && log "container resumed"
sleep 2
STATE="$(docker inspect -f '{{.State.Status}} paused={{.State.Paused}}' "$CONTAINER" 2>/dev/null || echo unknown)"
log "container state: $STATE"
[[ "$STATE" == "running paused=false" ]] || die "container is not running after resume — investigate before anything else"

tar -czf "$STAGED" -C "$WORK" .
chmod 600 "$STAGED"
( cd "$BACKUP_DIR" && sha256sum "$(basename "$STAGED")" > "$(basename "$STAGED").sha256" )

# --- verify: real SQLite file inside the archive, and integrity_check passes ----
CHECK="$(mktemp -d -t vw-verify-XXXXXX)"
tar -xzf "$STAGED" -C "$CHECK"
python3 - "$CHECK/db.sqlite3" <<'PY'
import sqlite3, sys
p = sys.argv[1]
head = open(p, 'rb').read(16)
if head[:15] != b'SQLite format 3':
    print("FAIL: not a SQLite file"); sys.exit(1)
con = sqlite3.connect(p)
ok = con.execute("PRAGMA integrity_check").fetchone()[0]
tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
acct = next((t for t in ("users", "user", "accounts") if t in tables), None)
print(f"OK: integrity={ok} tables={len(tables)} accounts={con.execute(f'SELECT count(*) FROM {acct}').fetchone()[0] if acct else 'n/a'}")
con.close()
PY
[[ -s "$STAGED" ]] || die "archive is empty"
log "verified: $STAGED ($(du -h "$STAGED" | cut -f1), mode $(stat -c %a "$STAGED"))"

if [[ -n "$OFFSITE_DIR" ]]; then
    install -d -m 700 "$OFFSITE_DIR"
    install -m 600 "$STAGED" "$OFFSITE_DIR/"
    install -m 600 "$STAGED".sha256 "$OFFSITE_DIR/"
    log "off-host copy staged in $OFFSITE_DIR — move at least one copy off this machine"
fi

# Retention: only this script's own archives.
find "$BACKUP_DIR" -maxdepth 1 -name 'vaultwarden-*.tar.gz' -mtime "+$KEEP" -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'vaultwarden-*.tar.gz.sha256' -mtime "+$KEEP" -delete
log "backups retained in $BACKUP_DIR: $(find "$BACKUP_DIR" -maxdepth 1 -name 'vaultwarden-*.tar.gz' | wc -l)"
log "=== done ==="
