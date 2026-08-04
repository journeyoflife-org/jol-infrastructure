#!/usr/bin/env bash
# generate-mtls-certs.sh — internal CA + leaf/client cert management.
# Normative docs: deploy/caddy/tls/README.md
#
# Usage:
#   generate-mtls-certs.sh --init-ca
#   generate-mtls-certs.sh --leaf <name> [--san "DNS:...,IP:..."]
#   generate-mtls-certs.sh --client <team-id>
#   generate-mtls-certs.sh --revoke <cert-file>
set -Eeuo pipefail

CA_DIR="${CA_DIR:-/opt/jol/ca}"
DAYS_CA=1825
DAYS_LEAF=365

log() { printf '[mtls] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v openssl >/dev/null || die "openssl required"

init_ca_dirs() {
  install -d -m 0700 "${CA_DIR}"/{private,certs,newcerts}
  touch "${CA_DIR}/index.txt"
  [[ -f "${CA_DIR}/serial" ]] || echo 1000 > "${CA_DIR}/serial"
  [[ -f "${CA_DIR}/openssl.cnf" ]] || cat > "${CA_DIR}/openssl.cnf" <<'CNF'
[ ca ]
default_ca = JOL_CA
[ JOL_CA ]
dir               = /opt/jol/ca
certificate       = $dir/certs/ca.crt
private_key       = $dir/private/ca.key
new_certs_dir     = $dir/newcerts
database          = $dir/index.txt
serial            = $dir/serial
default_md        = sha256
default_days      = 365
policy            = pol_any
email_in_dn       = no
copy_extensions   = copy
[ pol_any ]
commonName        = supplied
organizationName  = optional
countryName       = optional
[ req ]
distinguished_name = dn
prompt             = no
[ dn ]
CN = placeholder
CNF
}

audit() { echo "$(date -u +%FT%TZ) mtls action=$*" >> /var/log/jol-audit/bridge.log 2>/dev/null || true; }

case "${1:-}" in
  --init-ca)
    init_ca_dirs
    [[ -f "${CA_DIR}/private/ca.key" ]] && die "CA already exists — refusing to overwrite"
    openssl genrsa -out "${CA_DIR}/private/ca.key" 4096
    chmod 0400 "${CA_DIR}/private/ca.key"
    openssl req -x509 -new -key "${CA_DIR}/private/ca.key" -sha256 -days ${DAYS_CA} \
      -subj "/CN=JOL Internal CA/O=JOL" -out "${CA_DIR}/certs/ca.crt"
    audit init-ca
    log "CA created: ${CA_DIR}/certs/ca.crt (keep ca.key offline!)"
    ;;
  --leaf)
    name="${2:?leaf name required}"
    san="DNS:${name}.jol.internal,IP:10.40.10.21"
    [[ "${3:-}" == "--san" ]] && san="${4:?}"
    init_ca_dirs
    openssl genrsa -out "${CA_DIR}/private/${name}.key" 2048
    openssl req -new -key "${CA_DIR}/private/${name}.key" \
      -subj "/CN=${name}/O=JOL" -out "${CA_DIR}/certs/${name}.csr"
    openssl x509 -req -in "${CA_DIR}/certs/${name}.csr" \
      -CA "${CA_DIR}/certs/ca.crt" -CAkey "${CA_DIR}/private/ca.key" \
      -CAcreateserial -days ${DAYS_LEAF} -sha256 \
      -extfile <(printf "subjectAltName=%s" "${san}") \
      -out "${CA_DIR}/certs/${name}.crt"
    audit leaf "${name}"
    log "leaf issued: ${CA_DIR}/certs/${name}.{crt,key}"
    ;;
  --client)
    team="${2:?team id required}"
    init_ca_dirs
    openssl genrsa -out "${CA_DIR}/private/client-${team}.key" 2048
    openssl req -new -key "${CA_DIR}/private/client-${team}.key" \
      -subj "/CN=${team}/O=JOL" -out "${CA_DIR}/certs/client-${team}.csr"
    openssl x509 -req -in "${CA_DIR}/certs/client-${team}.csr" \
      -CA "${CA_DIR}/certs/ca.crt" -CAkey "${CA_DIR}/private/ca.key" \
      -CAcreateserial -days ${DAYS_LEAF} -sha256 \
      -extfile <(printf "extendedKeyUsage=clientAuth") \
      -out "${CA_DIR}/certs/client-${team}.crt"
    audit client "${team}"
    log "client cert issued for team ${team}"
    ;;
  --revoke)
    cert="${2:?cert file required}"
    init_ca_dirs
    openssl ca -revoke "${cert}" -config "${CA_DIR}/openssl.cnf"
    openssl ca -gencrl -config "${CA_DIR}/openssl.cnf" -out "${CA_DIR}/certs/ca.crl"
    audit revoke "${cert}"
    log "revoked; CRL regenerated → deploy to /etc/caddy/tls/ca.crl + reload caddy"
    ;;
  *)
    grep '^#' "$0" | head -10
    exit 1
    ;;
esac
