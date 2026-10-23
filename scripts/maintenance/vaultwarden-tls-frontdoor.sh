#!/usr/bin/env bash
# =============================================================================
# vaultwarden-tls-frontdoor.sh — give the loopback Vaultwarden an HTTPS endpoint
#
# WHY (2026-10-22, measured, not assumed): the web vault at
# http://127.0.0.1:8090 refuses to authenticate at all and shows
#     "An error has occurred. Insecure URL not allowed. All URLs must use HTTPS."
# Vaultwarden's own README: "The web-vault requires the use of HTTPS and a secure
# context for the Web Crypto API." Confirmed on this host:
#   DOMAIN=http://127.0.0.1:8090 · no TLS listener · no reverse proxy installed ·
#   `docker logs --since 30m jol-vaultwarden` EMPTY → the login request never
#   reached the server. So "wrong master password" is NOT yet a known fact; the
#   password cannot be tested at all until an HTTPS endpoint exists.
#
# DESIGN CHOICES
#   1. Add a TLS front door; do NOT recreate the Vaultwarden container. Recreating
#      it would change DOMAIN and restart the fleet's only credential server
#      mid-session. This is additive and reversible in one command.
#   2. Use the nginx image already present locally (nginx:1.27-alpine) — no network
#      pull, no new software installed on the host.
#   3. Loopback only: nginx binds 127.0.0.1:8443, never 0.0.0.0. Self-signed cert
#      generated locally with openssl; nothing is exposed on any network segment.
#   4. This script never reads, writes or prints vault content or secrets.
#
# Usage:
#   ./vaultwarden-tls-frontdoor.sh            # create/refresh the front door
#   ./vaultwarden-tls-frontdoor.sh --status   # what is listening / reachable
#   ./vaultwarden-tls-frontdoor.sh --remove   # tear it down
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-jol-vaultwarden}"
PROXY="${PROXY:-vw-tls}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
UPSTREAM="${UPSTREAM:-127.0.0.1:8090}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
STATE_DIR="${STATE_DIR:-$HOME/.config/vaultwarden-tls}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "vault container '$CONTAINER' not found"

case "${1:-}" in
    --status)
        docker ps -a --format '{{.Names}} | {{.Status}}' | grep -E "^($PROXY|$CONTAINER) \|" || true
        ss -tlnp 2>/dev/null | grep -E "$LISTEN_ADDR:$HTTPS_PORT" || echo "no listener on $LISTEN_ADDR:$HTTPS_PORT"
        curl -sk --max-time 5 -o /dev/null -w "https://$LISTEN_ADDR:$HTTPS_PORT/alive -> HTTP %{http_code}\n" \
            "https://$LISTEN_ADDR:$HTTPS_PORT/alive" || echo "https endpoint not answering"
        exit 0
        ;;
    --remove)
        docker rm -f "$PROXY" >/dev/null 2>&1 && echo "removed $PROXY" || echo "$PROXY not present"
        exit 0
        ;;
esac

docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1 || \
    die "image $NGINX_IMAGE not present locally (refusing to pull). Point NGINX_IMAGE at any local TLS-capable image."
command -v openssl >/dev/null || die "openssl not found"

install -d -m 700 "$STATE_DIR" "$STATE_DIR/tls"

# --- self-signed loopback certificate (regenerated only if missing) ----------
if [[ ! -s "$STATE_DIR/tls/tls.crt" || ! -s "$STATE_DIR/tls/tls.key" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
        -keyout "$STATE_DIR/tls/tls.key" -out "$STATE_DIR/tls/tls.crt" \
        -subj "/CN=127.0.0.1/O=vaultwarden-loopback" \
        -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \
        -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
    chmod 600 "$STATE_DIR/tls/tls.key"
    chmod 644 "$STATE_DIR/tls/tls.crt"
    echo "generated loopback certificate (self-signed; the browser will warn once)"
fi
echo "certificate SHA256 fingerprint (verify in the browser if you want to be strict):"
openssl x509 -in "$STATE_DIR/tls/tls.crt" -noout -fingerprint -sha256 | sed 's/^/  /'

# --- nginx config: TLS on loopback, proxy to the vault, WebSocket passthrough --
cat > "$STATE_DIR/default.conf" <<CFG
server {
    listen $LISTEN_ADDR:$HTTPS_PORT ssl;
    server_name 127.0.0.1 localhost;

    ssl_certificate     /etc/nginx/tls/tls.crt;
    ssl_certificate_key /etc/nginx/tls/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # Vaultwarden's SignalR notifications hub needs the upgrade headers.
    proxy_http_version 1.1;
    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host       \$host;
    proxy_set_header X-Real-IP  \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    client_max_body_size 64m;

    location / {
        proxy_pass http://$UPSTREAM;
    }
}
CFG
chmod 600 "$STATE_DIR/default.conf"

docker rm -f "$PROXY" >/dev/null 2>&1 || true
# --network host lets the proxy reach the vault's 127.0.0.1:8090 published binding;
# the listen directive above pins the proxy to loopback, so nothing is exposed.
docker run -d --name "$PROXY" --restart unless-stopped --network host \
    --volume "$STATE_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    --volume "$STATE_DIR/tls:/etc/nginx/tls:ro" \
    "$NGINX_IMAGE" >/dev/null

echo "started $PROXY: https://$LISTEN_ADDR:$HTTPS_PORT  →  http://$UPSTREAM"
sleep 3
if curl -sk --max-time 8 -o /dev/null -w '' "https://$LISTEN_ADDR:$HTTPS_PORT/alive"; then
    curl -sk --max-time 8 -o /dev/null -w "probe /alive -> HTTP %{http_code}\n" "https://$LISTEN_ADDR:$HTTPS_PORT/alive"
    echo "Now open https://$LISTEN_ADDR:$HTTPS_PORT in the browser, accept the"
    echo "certificate warning once, and try the master password there."
else
    echo "front door is not answering yet — inspect: docker logs $PROXY"
    exit 1
fi
