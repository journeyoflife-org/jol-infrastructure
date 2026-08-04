#!/usr/bin/env bash
# rotate-api-keys.sh — batch management of bridge API keys.
# Keys are salted-hashed in the bridge key store; plaintext printed ONCE.
#
# Usage:
#   rotate-api-keys.sh --new <client-id>       issue first key
#   rotate-api-keys.sh --rotate <client-id>    new key, 72h dual-key window
#   rotate-api-keys.sh --revoke <client-id>    revoke all keys now
#   rotate-api-keys.sh --list                  audit view (no secrets)
set -Eeuo pipefail

KEYSTORE="/etc/jol/bridge/keys.db"
SALT_FILE="/etc/jol/bridge/salt"
AUDIT_LOG="/var/log/jol-audit/bridge.log"

log() { printf '[keys] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v sqlite3 >/dev/null || die "sqlite3 required"

init_db() {
  install -d -m 0700 "$(dirname "${KEYSTORE}")"
  [[ -f ${SALT_FILE} ]] || openssl rand -hex 16 > "${SALT_FILE}"
  chmod 0600 "${SALT_FILE}"
  sqlite3 "${KEYSTORE}" "CREATE TABLE IF NOT EXISTS keys (
    client_id TEXT NOT NULL,
    key_hash  TEXT NOT NULL,
    prefix    TEXT NOT NULL,
    status    TEXT NOT NULL DEFAULT 'active',
    issued    TEXT NOT NULL,
    expires   TEXT NOT NULL,
    PRIMARY KEY (client_id, key_hash));"
  chown bridge-svc:bridge-svc "${KEYSTORE}" "${SALT_FILE}" 2>/dev/null || true
  chmod 0600 "${KEYSTORE}"
}

hash_key() { echo -n "${1}$(cat "${SALT_FILE}")" | sha256sum | awk '{print $1}'; }

audit() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) key-mgmt client=$1 action=$2 actor=$(logname 2>/dev/null || echo root)" >> "${AUDIT_LOG}" 2>/dev/null || true; }

gen_key() { echo "jol_${1}_$(openssl rand -hex 32)"; }

case "${1:-}" in
  --new)
    client="${2:?client-id required}"
    init_db
    exists=$(sqlite3 "${KEYSTORE}" "SELECT count(*) FROM keys WHERE client_id='${client}' AND status='active';")
    (( exists == 0 )) || die "client ${client} already has an active key (use --rotate)"
    key="$(gen_key "${client}")"
    key_hash=$(hash_key "${key}")
    issued=$(date -u +%F)
    expires=$(date -u -d '+90 days' +%F)
    sqlite3 "${KEYSTORE}" "INSERT INTO keys VALUES ('${client}','${key_hash}','${key:0:12}','active','${issued}','${expires}');"
    audit "${client}" "issue"
    log "key issued for ${client} — store it now, it is shown only once:"
    echo "${key}"
    ;;
  --rotate)
    client="${2:?client-id required}"
    init_db
    key="$(gen_key "${client}")"
    key_hash=$(hash_key "${key}")
    new_expiry=$(date -u -d '+72 hours' +%FT%H:%M:%SZ)
    issued=$(date -u +%F)
    expires=$(date -u -d '+90 days' +%F)
    sqlite3 "${KEYSTORE}" "UPDATE keys SET expires='${new_expiry}' WHERE client_id='${client}' AND status='active';"
    sqlite3 "${KEYSTORE}" "INSERT INTO keys VALUES ('${client}','${key_hash}','${key:0:12}','active','${issued}','${expires}');"
    audit "${client}" "rotate(72h-dual-window)"
    log "new key issued; previous key expires in 72h:"
    echo "${key}"
    ;;
  --revoke)
    client="${2:?client-id required}"
    init_db
    sqlite3 "${KEYSTORE}" "UPDATE keys SET status='revoked' WHERE client_id='${client}';"
    audit "${client}" "revoke"
    log "all keys revoked for ${client}"
    ;;
  --list)
    init_db
    sqlite3 -header -column "${KEYSTORE}" \
      "SELECT client_id, prefix, status, issued, expires FROM keys ORDER BY client_id, issued;"
    ;;
  *)
    grep '^#' "$0" | head -12
    exit 1
    ;;
esac
