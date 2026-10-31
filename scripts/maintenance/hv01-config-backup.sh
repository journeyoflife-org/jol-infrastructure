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
# ⚠ EXTENDED 2026-10-31 (issue #128, finding F-3): the exclusion list above is a NAME
# pattern, and a name pattern cannot see a secret that is a FIELD INSIDE a config body.
# `/etc/pve/qemu-server/<vmid>.conf` carries `cipassword:` — the cloud-init user password
# as a salted sha256crypt (`$5$`) hash. Measured 2026-10-31: `tar tzf` of the archive dated
# 2026-10-25 held 6 qemu-server entries containing **9 `cipassword:` lines**, i.e. the
# pre-fix gate passed ("no key entries") while credential material travelled — and
# `/mnt/hdd-archive` is pushed to pbs01 nightly since 2026-10-25, so it travelled off-host.
# (PVE itself masks the field to `**********` on the API — see
# /usr/share/perl5/PVE/API2/Qemu.pm — so pmxcfs reads and archives, not the Web UI, are the
# surface.) The archive is therefore now built through a staging copy in which `cipassword:`
# is replaced by a marker, and publishing is REFUSED if any un-stripped value survives.
# The VM configs stay in the archive (they are recovery evidence); only the credential field
# is neutralised, and the live /etc/pve is never touched.
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

# Staging tree: the archive is built from a COPY so that credential fields can be
# neutralised without ever touching the live /etc/pve (pmxcfs) content.
STAGE="$(mktemp -d -p "$DEST_DIR" .stage-XXXXXX)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# --one-file-system keeps /etc/pve/priv (a separate pmxcfs mount) out by accident
# of luck only — the explicit excludes above are the real control; this flag just
# stops the archive from wandering into mounted storage.
# Guarded explicitly: with `pipefail` a tar warning on a live pmxcfs read must fail LOUDLY
# here rather than leave a half-staged tree that the next gate would happily sign off.
if ! tar --one-file-system "${EXCLUDES[@]}" -cf - "${PATHS[@]}" 2>/dev/null |
        tar -xf - -C "$STAGE" 2>/dev/null; then
    echo "$(date '+%F %T') ERROR: staging copy of the config paths failed — nothing published" >&2
    exit 1
fi

STRIPPED=0
# pmxcfs archives VM configs under etc/pve/nodes/<node>/qemu-server/<vmid>.conf — NOT under
# etc/pve/qemu-server (measured 2026-10-31: the archive holds etc/pve/qemu-server as an entry
# with no files beneath it). A pattern anchored to the *presented* path would match nothing and
# the strip would "succeed" at doing nothing — a control that cannot fail. Match any depth.
while IFS= read -r conf; do
    [[ -e "$conf" ]] || continue
    # Anchored to the line start on purpose: `cipassword` appears as a value elsewhere
    # (e.g. in comments), and over-stripping would corrupt the recovery evidence.
    n=$(grep -c '^cipassword:' "$conf" || true)
    if [[ "$n" -gt 0 ]]; then
        sed -i -E 's|^cipassword:.*|cipassword: <STRIPPED by hv01-config-backup.sh '"$STAMP"' — issue #128: the value lives in Vaultwarden, not in an archive>|' "$conf"
        STRIPPED=$((STRIPPED + n))
    fi
done < <(find "$STAGE/etc/pve" -path '*/qemu-server/*.conf' -type f 2>/dev/null)

tar -czf "$TARGET.new" -C "$STAGE" etc \
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

# F-3 gate: a `cipassword:` line that still carries a value (i.e. was not replaced by the
# marker) means the strip did not happen — fail closed rather than replicate a credential.
# Same lesson as above: the member pattern must match the archived (node-scoped) path, and the
# gate proves its own reach by counting how many confs it inspected — 0 inspected is a FAILURE.
CONF_MEMBERS="$(tar tzf "$TARGET.new" | grep -E '/qemu-server/[^/]+\.conf$' || true)"
CONF_N=$(printf '%s\n' "$CONF_MEMBERS" | grep -c . || true)
if (( CONF_N == 0 )); then
    echo "$(date '+%F %T') ERROR: no qemu-server confs found in the archive — the F-3 gate cannot prove anything, refusing to publish" >&2
    rm -f "$TARGET.new"
    exit 1
fi
if tar xzOf "$TARGET.new" --wildcards '*/qemu-server/*.conf' 2>/dev/null |
        grep -qE '^cipassword: [^<]'; then
    echo "$(date '+%F %T') ERROR: cipassword value survived staging — refusing to publish (issue #128)" >&2
    rm -f "$TARGET.new"
    exit 1
fi

mv "$TARGET.new" "$TARGET"
chmod 600 "$TARGET"
tar tzf "$TARGET" >/dev/null
echo "$(date '+%F %T') OK: $TARGET mode=$(stat -c %a "$TARGET") size=$(du -h "$TARGET" | cut -f1) entries=$(tar tzf "$TARGET" | wc -l) qemu_confs=$CONF_N cipassword_lines_stripped=$STRIPPED"

# Retention: sweep only this script's own naming pattern, inside its own directory.
find "$DEST_DIR" -maxdepth 1 -name 'pve-config-*.tar.gz' -mtime "+$KEEP_DAYS" -delete
