#!/usr/bin/env bash
# =============================================================================
# Tier-1 Baseline Remediation (items 1, 2, 4 of audit 2026-08-14)
#
# Scope (read-only baseline audit: /home/jol/jol-audit-20260814-172550):
#   R1  Vaultwarden secrets store hardening      GDPR Art. 32, ISO 27001 A.8.24
#   R2  Plaintext prod DB dump: encrypt+relocate GDPR Art. 9/32, ISO 27001 A.8.24
#   R3  backup/ log-residue quarantine + rename  ISO 27001 A.5.9 (asset inventory)
#   R4  World-writable object sweep              ISO 27001 A.8.2, SOC 2 CC6.1
#   Change log itself                            SOC 2 CC8.1
#
# Usage:
#   sudo DRY_RUN=1 ./remediate-tier1-baseline.sh     # preview, no changes
#   sudo ./remediate-tier1-baseline.sh               # apply (prompts for age passphrase)
#
# Properties: idempotent (every section no-ops when already remediated),
#             non-destructive (encrypt-verify-then-remove, archive-not-delete),
#             change-logged to /var/log/jol-remediation/ (root-only).
#
# OUT OF SCOPE — requires separate planned maintenance windows:
#   - LUKS encryption-at-rest partitions + encrypted swap (GDPR Art. 32 project)
#   - nosuid,nodev remount options; sudoers review (/etc/sudoers.d/90-jol-nopass)
#   - Credential rotation for C1 exposure (manual, via Vaultwarden)
#   - Pruning: qoder/, Project-Level-Configuration/, .Trash-1000, certs oddity
#   - Normalizing HTTPS git remotes to SSH
# =============================================================================
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/jol-remediation"
LOG="$LOG_DIR/remediation-$STAMP.log"

# ---------------------------------------------------------------- guards ----
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (sudo $0)" >&2
  exit 1
fi
command -v age >/dev/null || { echo "ERROR: 'age' not installed" >&2; exit 1; }
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

# Apply a mode/owner change only when needed; records before/after. Idempotent.
apply_stat() {
  # $1=path  $2=octal mode  $3=owner(user:group)  $4=why
  local path="$1" mode="$2" owner="$3" why="$4"
  [ -e "$path" ] || { log "SKIP   $path (absent)"; return 0; }
  local before after
  before="$(stat -c '%a %U:%G' "$path")"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRYRUN $path: $before -> $mode $owner ($why)"
    return 0
  fi
  chmod "$mode" "$path"
  chown "$owner" "$path"
  after="$(stat -c '%a %U:%G' "$path")"
  log "CHANGED $path: $before -> $after ($why)"
}

log "===================================================================="
log "Tier-1 baseline remediation start (DRY_RUN=$DRY_RUN) host=$(hostname) user=$(id -un)"
log "Baseline evidence: /home/jol/jol-audit-20260814-172550/"
log "===================================================================="

# Evidence snapshot of the critical paths, pre-change
{
  echo "--- pre-state $STAMP"
  stat -c '%A %a %U:%G %n' /opt/jol /opt/jol/secrets /opt/jol/certs \
    /opt/jol/backup /opt/jol/backups \
    /home/jol/secrets /home/jol/secrets/vaultwarden \
    /home/jol/secrets/vaultwarden/* 2>/dev/null
} >> "$LOG"

# ================================================================ R1 =======
log "===== R1: Vaultwarden secrets store hardening (GDPR Art. 32, ISO 27001 A.8.24)"
apply_stat /home/jol/secrets                  700 root:root "C1: secrets root dir was 775 jol:jol"
apply_stat /home/jol/secrets/vaultwarden      700 root:root "C1: vaultwarden data dir was 775 jol:jol"
for f in /home/jol/secrets/vaultwarden/db.sqlite3 \
         /home/jol/secrets/vaultwarden/db.sqlite3-shm \
         /home/jol/secrets/vaultwarden/db.sqlite3-wal \
         /home/jol/secrets/vaultwarden/rsa_key.pem; do
  apply_stat "$f" 600 root:root "C1: vaultwarden secret file was world-readable"
done
log "NOTE: jol-vaultwarden container must run as root for the above ownership to"
log "      remain usable (db.sqlite3 is root-owned). Verify after: docker restart jol-vaultwarden"
log "      then confirm health. Manual follow-up: rotate any credential that cannot"
log "      be proven unread during the 644/775 exposure window (SOC 2 CC7.2)."

# ================================================================ R2 =======
log "===== R2: encrypt plaintext prod dump (GDPR Art. 9/32, ISO 27001 A.8.24)"
DUMP_DIR="/opt/jol/backups"
DUMP="$DUMP_DIR/jol_lt_platform_prod_backup_2026_07_18.dump"
ENC_DIR="$DUMP_DIR/encrypted"
if [ ! -f "$DUMP" ]; then
  log "SKIP   $DUMP absent (already remediated or relocated)"
else
  ENC="$ENC_DIR/$(basename "$DUMP").$STAMP.age"
  apply_stat "$DUMP" 600 jol:jol "interim: stop world-read before encryption"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRYRUN age-encrypt $DUMP -> $ENC, verify round-trip, then remove plaintext"
  else
    mkdir -p "$ENC_DIR"
    chmod 700 "$ENC_DIR"
    chown root:root "$ENC_DIR"
    # Passphrase via direct read (no echo, no history); min 16 chars.
    printf 'age passphrase for dump encryption (min 16 chars, input hidden): ' >/dev/tty
    read -rs PASS </dev/tty; printf '\n' >/dev/tty
    if [ "${#PASS}" -lt 16 ]; then
      log "ABORT  passphrase shorter than 16 chars — plaintext left in place"
      exit 1
    fi
    echo -n "$PASS" | age -p -o "$ENC" "$DUMP"
    chmod 600 "$ENC"; chown root:root "$ENC"
    # Round-trip verification BEFORE plaintext removal (data integrity)
    if echo -n "$PASS" | age -d "$ENC" | cmp -s - "$DUMP"; then
      rm -f "$DUMP"
      log "CHANGED $DUMP -> $ENC (verified round-trip, plaintext removed)"
    else
      log "ABORT  round-trip verification FAILED — plaintext retained at $DUMP"
      exit 1
    fi
    unset PASS
  fi
fi
apply_stat "$ENC_DIR" 700 root:root "encrypted backup store"
log "NOTE: store the passphrase in Vaultwarden (org secrets vault) NOW — losing it"
log "      loses the only backup of the platform production database."
log "NOTE: offsite replication to pbs01 (fleet standard, 3-2-1) is a separate task."

# ================================================================ R3 =======
log "===== R3: quarantine /opt/jol/backup log residue (ISO 27001 A.5.9)"
RESIDUE_ARCHIVE="/opt/jol/backup/log-residue-20260221"
if [ -d "$RESIDUE_ARCHIVE" ]; then
  log "SKIP   $RESIDUE_ARCHIVE already exists (idempotent)"
else
  if [ "$DRY_RUN" = "1" ]; then
    log "DRYRUN move old /var/log residue under $RESIDUE_ARCHIVE (700 root:root) + README"
  else
    mkdir -p "$RESIDUE_ARCHIVE"
    find /opt/jol/backup -mindepth 1 -maxdepth 1 ! -name "$(basename "$RESIDUE_ARCHIVE")" \
      -exec mv -t "$RESIDUE_ARCHIVE" {} +
    chmod 700 "$RESIDUE_ARCHIVE"; chown root:root "$RESIDUE_ARCHIVE"
    cat > "$RESIDUE_ARCHIVE/README.txt" <<'EOF'
Old /var/log residue from the reclaimed nvme0n1p6 partition (install era,
<= 2026-02-21). Quarantined by remediate-tier1-baseline.sh on remediation date.
NOT a backup. No restore dependency known.
Decision (asset owner): wipe after review — see change log in /var/log/jol-remediation/.
EOF
    chmod 600 "$RESIDUE_ARCHIVE/README.txt"
    log "CHANGED /opt/jol/backup: residue moved to $RESIDUE_ARCHIVE; mount root now clean"
  fi
fi
log "NOTE: decision to WIPE the residue (destructive) is intentionally left manual."

# ================================================================ R4 =======
log "===== R4: world-writable sweep (ISO 27001 A.8.2, SOC 2 CC6.1)"
WW_LIST="$LOG_DIR/world-writable-$STAMP.txt"
# -xdev per mount; /opt/jol/tmp excluded as the designated scratch area
find /opt/jol          -xdev -perm -0002 ! -type l ! -path '/opt/jol/tmp*' \
  > "$WW_LIST" 2>/dev/null || true
find /opt/jol/data     -xdev -perm -0002 ! -type l >> "$WW_LIST" 2>/dev/null || true
find /opt/jol/backup   -xdev -perm -0002 ! -type l >> "$WW_LIST" 2>/dev/null || true
COUNT=$(wc -l < "$WW_LIST")
log "Found $COUNT world-writable objects (inventory: $WW_LIST)"
if [ "$DRY_RUN" = "1" ]; then
  log "DRYRUN chmod o-w on all $COUNT objects"
elif [ "$COUNT" -gt 0 ]; then
  xargs -0 -r chmod o-w < <(tr '\n' '\0' < "$WW_LIST")
  log "CHANGED removed o+w on $COUNT objects"
fi
# Group-write on top-level structure only (repo internals left for git-config policy)
for d in /opt/jol/git /opt/jol/.pnpm-store /opt/jol/.idea \
         /opt/jol/Project-Level-Configuration /opt/jol/backups /opt/jol/backups/backup; do
  apply_stat "$d" 755 jol:jol "top-level group-write normalized to 755"
done

# ============================================================== summary =====
{
  echo "--- post-state $STAMP"
  stat -c '%A %a %U:%G %n' /opt/jol /opt/jol/secrets /opt/jol/certs \
    /opt/jol/backup /opt/jol/backups "$ENC_DIR" \
    /home/jol/secrets /home/jol/secrets/vaultwarden \
    /home/jol/secrets/vaultwarden/* 2>/dev/null
} >> "$LOG"
chmod 600 "$LOG"
log "===================================================================="
log "Remediation complete (DRY_RUN=$DRY_RUN). Change log: $LOG"
log "Re-run /home/jol/jol_baseline_audit.sh to capture post-remediation baseline."
