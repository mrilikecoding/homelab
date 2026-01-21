#!/bin/bash
# Certificate renewal script for homelab

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$HOME/.homelab/certs"
DOKKU_CERT_DIR="$SCRIPT_DIR/dokku/certs"

# Renew certificates
certbot renew \
    --config-dir "$CERT_DIR" \
    --work-dir "$CERT_DIR/work" \
    --logs-dir "$CERT_DIR/logs"

# Find the domain from saved config
source "$SCRIPT_DIR/config.sh"
DOMAIN="homelab.${APP_DOMAIN}"
CERT_PATH="$CERT_DIR/live/${DOMAIN}"

# Copy renewed certs to Dokku
if [[ -f "$CERT_PATH/fullchain.pem" ]]; then
    cp "$CERT_PATH/fullchain.pem" "$DOKKU_CERT_DIR/server.crt"
    cp "$CERT_PATH/privkey.pem" "$DOKKU_CERT_DIR/server.key"

    # Reload nginx in Dokku
    docker exec dokku bash -c 'cp /certs/server.crt /mnt/dokku/home/dokku/.ssl/server.crt'
    docker exec dokku bash -c 'cp /certs/server.key /mnt/dokku/home/dokku/.ssl/server.key'
    docker exec dokku nginx:reload-config 2>/dev/null || true
fi
