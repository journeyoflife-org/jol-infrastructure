#!/usr/bin/env bash
# =============================================================================
# hv01-config-backup.sh — weekly PVE config backup for pve-prod-hv01, WITHOUT keys
#
# Installed at /usr/local/bin/hv01-config-backup.sh, invoked by
# /etc/cron.d/jol-config-backup (Sun 03:00).
#
# WHY THIS EXISTS (2026-10-21 finding, docs/runbooks/hv01-storage-backup-
# reconfiguration.md §1c): the previous cron line tarred all of /etc/pve, which
# includes /etc/pve/priv — root CA key, cluster authkey.key, pve-www.key, the node
# SSL key and authorized_keys — into an archive with mode 644 on the 1 TB HDD.
# Anyone able to read that file could mint certificates trusted by the PVE cluster
# and authenticate against pmxcfs. The plan to replicate /mnt/hdd-archive to pbs01
# nightly would have propagated that exposure off-host. Fixed before replication
# went live: key material is excluded, the archive is 600, and the script refuses
# to publish if any key entry survives.
#
# Key material is NOT backed up here by design. It is escrowed in Vaultwarden
# (AGENTS.md §0.1, docs/architecture/secret-flow.md). A backup target is not a key
# store; losing the keys is recovered by re-issuing, not by reading a tarball.
#
# Idempotent, non-destructive apart from its own retention sweep, change-logged.
# Usage: sudo hv01-config-backup.sh        (cron-friendly, non-interactive)
# =============================================================================
set -euo pipefail

DEST_DIR="${DEST_DIR:-/mnt/hdd-archive/config-backup}"
KEEP_DAYS="${KEEP_DAYS:-30}"
STAMP="$(date +%Y%m%d)"
TARGET="$DEST_DIR/pve-config-$STAMP.tar.gz"

# Paths whose *configuration* is compliance evidence (SOC 2 CC8.1, ISO A.8.13/A.5.31):
PATHS=(
    /etc/pve
    /etc/network/interfaces
    /etc/fstab
    /etc/lvm/lvm.conf
    /etc/smartd.conf
    /etc/sysctl.d/
    /etc/ufw/
    /etc/chrony/
    /etc/fail2ban/
)

# Anything that looks like private key material is excluded, and the result is
# verified before the archive is published.
EXCLUDES=(
    --exclude='etc/pve/priv'
    --exclude='etc/pve/priv/*'
    --exclude='*.key'
    --exclude='*.srl'
    --exclude='*.pem'
)

umask 077
install -d -m 700 "$DEST_DIR"

# --one-file-system keeps /etc/pve/priv (a separate pmxcfs mount) out by accident
# of luck only — the explicit excludes above are the real control; this flag just
# stops the archive from wandering into mounted storage.
tar --one-file-system "${EXCLUDES[@]}" -czf "$TARGET.new" "${PATHS[@]}" \
    2>/dev/null || {
        echo "$(date '+%F %T') ERROR: tar failed" >&2
        rm -f "$TARGET.new"
        exit 1
    }

if tar tzf "$TARGET.new" | grep -qE 'etc/pve/priv|\.key$|\.pem$|\.srl$'; then
    echo "$(date '+%F %T') ERROR: private key material still present — refusing to publish" >&2
    rm -f "$TARGET.new"
    exit 1
fi

mv "$TARGET.new" "$TARGET"
chmod 600 "$TARGET"
tar tzf "$TARGET" >/dev/null
echo "$(date '+%F %T') OK: $TARGET mode=$(stat -c %a "$TARGET") size=$(du -h "$TARGET" | cut -f1) entries=$(tar tzf "$TARGET" | wc -l)"

# Retention: sweep only this script's own naming pattern, inside its own directory.
find "$DEST_DIR" -maxdepth 1 -name 'pve-config-*.tar.gz' -mtime "+$KEEP_DAYS" -delete
