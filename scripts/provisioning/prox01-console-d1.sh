#!/usr/bin/env bash
# =============================================================================
# prox01-console-d1.sh — Console-session executor for prox01 D1 unblock
# =============================================================================
# Compliance: SOC 2 CC8.1 change control | GDPR Art. 5(1)(f) integrity |
#             ISO 27001 A.8.9 (configuration management)
# Change ref: docs/compliance/evidence/execution/p0/
#             prox01-hw-inventory-attempt-20260830-0223.txt (flag F-D1)
# Backup:     this script backs up every file it touches as <file>.bak.<TS>
# Rollback:   restore the .bak.<TS> files listed in the summary output
#
# RUN LOCATION: ON prox01 (10.60.60.10), as root, via physical console or
#               iDRAC virtual console. It does NOT require network access.
#
# Actions (per console-session plan):
#   (a) authorize fleet workstation keys for root and jol-admin (idempotent)
#   (b) verify/remediate PasswordAuthentication no (flag F-D1)
#   (c) capture D1 command outputs to an evidence file
#
# Design contract: idempotent (re-running changes nothing), DRY_RUN default,
# change-logged, non-destructive (no user creation, no deletion).
#
# Usage:
#   ./prox01-console-d1.sh            # DRY-RUN: report only, zero mutations
#   ./prox01-console-d1.sh --apply    # execute mutations + capture evidence
# =============================================================================
set -euo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1
TS="$(date +%Y%m%d-%H%M)"
EVIDENCE="/root/prox01-d1-capture-${TS}.txt"
MUTATIONS=()

# --- Fleet public keys (PUBLIC material only; fingerprints from workstation) ---
KEY_WORKSTATION='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICiufwj+dcKaSLu6Ere0YZX4PwIc88VXwflsVYyrZ8nu ubuntu24-jol-server-auth'
FP_WORKSTATION='SHA256:5wSsJlMIANmTTvucmimQqYlVGsyVmq8daj7nOZkWlws'
KEY_PLATFORM='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICp7USDADpl/7EA9uIa7gHVtevQ3qFmzDonUGyjOJB5u journeyoflife-platform'
FP_PLATFORM='SHA256:EnOjKXinbTf5WfSqpIsmn4Ye8Y27UCLx72oz7579778'

log()  { echo "[$(date +%H:%M:%S)] $*"; }
note() { echo "    -> $*"; }

if [[ $APPLY -eq 1 ]]; then log "MODE: APPLY (mutations enabled)"; else log "MODE: DRY-RUN (report only; pass --apply to execute)"; fi

# -----------------------------------------------------------------------------
# (a) Authorize fleet keys for root and jol-admin — idempotent append
# -----------------------------------------------------------------------------
authorize_user() {
  local user="$1"
  local home keyfile
  if ! id "$user" >/dev/null 2>&1; then
    log "(a) user '$user': MISSING — no user is created by this script (out of scope)."
    note "If jol-admin is expected here, create it change-controlled FIRST, then re-run."
    return
  fi
  home="$(getent passwd "$user" | cut -d: -f6)"
  keyfile="${home}/.ssh/authorized_keys"
  log "(a) user '$user' (${home})"
  if [[ $APPLY -eq 1 ]]; then
    mkdir -p "${home}/.ssh"
    chmod 700 "${home}/.ssh"
    chown "$user":"$(id -gn "$user")" "${home}/.ssh"
    touch "$keyfile"
  else
    if [[ -d "${home}/.ssh" ]]; then
      note ".ssh dir exists ($(stat -c '%a %U:%G' "${home}/.ssh"))"
    else
      note "WOULD create ${home}/.ssh (0700)"
    fi
    if [[ -f "$keyfile" ]]; then
      note "authorized_keys exists ($(stat -c '%a %U:%G' "$keyfile"))"
    else
      note "WOULD create $keyfile (0600)"
    fi
  fi
  for key in "$KEY_WORKSTATION" "$KEY_PLATFORM"; do
    if grep -qF "$key" "$keyfile" 2>/dev/null; then
      note "key already authorized (no change): ${key##* }"
    else
      if [[ $APPLY -eq 1 ]]; then
        [[ -s "$keyfile" ]] && cp -p "$keyfile" "${keyfile}.bak.${TS}" \
          && MUTATIONS+=("backup: ${keyfile}.bak.${TS}")
        echo "$key" >> "$keyfile"
        MUTATIONS+=("append key '${key##* }' to ${keyfile}")
        note "APPENDED key: ${key##* }"
      else
        note "WOULD append key: ${key##* }"
      fi
    fi
  done
  if [[ $APPLY -eq 1 ]]; then
    chmod 600 "$keyfile"
    chown "$user":"$(id -gn "$user")" "$keyfile"
  fi
  # Verify by fingerprint if ssh-keygen is present
  if command -v ssh-keygen >/dev/null 2>&1; then
    while read -r _bits fp comment; do
      [[ "$fp" == "$FP_WORKSTATION" || "$fp" == "$FP_PLATFORM" ]] \
        && note "fingerprint verified present: $fp ($comment)"
    done < <(ssh-keygen -lf "$keyfile" 2>/dev/null || true)
  fi
}

log "=== ACTION (a): fleet key authorization ==="
authorize_user root
authorize_user jol-admin

# -----------------------------------------------------------------------------
# (b) PasswordAuthentication no — flag F-D1 remediation
# -----------------------------------------------------------------------------
log "=== ACTION (b): PasswordAuthentication policy (flag F-D1) ==="
DROPIN='/etc/ssh/sshd_config.d/00-jol-keyonly.conf'
# Report every existing PasswordAuthentication directive (first match wins in sshd)
mapfile -t existing < <(grep -rn '^[[:space:]]*PasswordAuthentication' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || true)
if ((${#existing[@]})); then
  for line in "${existing[@]}"; do note "existing directive: $line"; done
else
  note "no explicit PasswordAuthentication directive found (sshd default: yes)"
fi
if [[ -f "$DROPIN" ]]; then
  note "drop-in $DROPIN already present — idempotent skip"
else
  if [[ $APPLY -eq 1 ]]; then
    cat > "$DROPIN" <<'EOF'
# JOL fleet SSH policy — key-only access (docs/servers/prox01.md §SSH Policy)
# Name sorts FIRST so sshd's first-match precedence wins over later drop-ins.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    MUTATIONS+=("create $DROPIN")
    note "CREATED $DROPIN"
  else
    note "WOULD create $DROPIN (PasswordAuthentication no)"
  fi
fi
# Effective value as sshd sees it
EFFECTIVE="$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' || echo 'unknown')"
note "effective sshd value now: $EFFECTIVE"
if [[ $APPLY -eq 1 ]]; then
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
    MUTATIONS+=("reload/restart ssh.service (config validated with sshd -t first)")
    note "sshd reloaded after sshd -t validation"
    note "effective after reload: $(sshd -T 2>/dev/null | grep -i '^passwordauthentication')"
  else
    log "ERROR: sshd -t FAILED — sshd NOT reloaded; investigate before retry"
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# (c) D1 evidence capture
# -----------------------------------------------------------------------------
log "=== ACTION (c): D1 evidence capture ==="
capture() {
  {
    echo "# prox01 D1 capture $(date -u +%Y-%m-%dT%H:%M:%SZ) (console session, flag F-D1)"
    echo "## hostname"; hostname
    echo "## pveversion -v"; pveversion -v 2>/dev/null || pveversion
    echo "## lscpu"; lscpu
    echo "## free -h"; free -h
    echo "## qm list (VMs)"; qm list
    echo "## pct list (LXCs)"; pct list 2>/dev/null || true
    echo "## zpool list"; zpool list -o name,size,alloc,free,health
    echo "## zpool status"; zpool status
    echo "## ip -br addr"; ip -br addr
    echo "## sshd effective auth"; sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin)'
  } 2>&1 | tee "$1"
}
if [[ $APPLY -eq 1 ]]; then
  capture "$EVIDENCE"
  MUTATIONS+=("evidence capture written to $EVIDENCE")
else
  note "WOULD capture D1 outputs to $EVIDENCE"
  log "DRY-RUN preview of a subset:"
  hostname; free -h | head -3; qm list || true
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log "=== SUMMARY ==="
if ((${#MUTATIONS[@]})); then
  printf '  MUTATION: %s\n' "${MUTATIONS[@]}"
else
  log "no mutations performed (dry-run or fully idempotent)"
fi
cat <<EOF

NEXT STEPS (operator):
1. Transfer $EVIDENCE to the repo:
   docs/compliance/evidence/execution/p0/prox01-d1-capture-${TS}.txt
2. Record CPU/RAM in docs/servers/prox01.md Hardware table (CPU + RAM rows)
   and the VM inventory outcome; re-compute docs/servers/prox01-capacity-baseline.md.
3. From the fleet workstation verify remote access now works:
   ssh -o BatchMode=yes root@10.60.60.10 hostname
4. Add the CHANGELOG.md + prox01.md Provisioning Log rows (repo-side change record).
EOF
