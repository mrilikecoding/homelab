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

    # Update certs for all apps
    cd "$DOKKU_CERT_DIR"
    APPS=$(docker exec dokku dokku apps:list 2>/dev/null | tail -n +2)
    for app in $APPS; do
        if [[ -n "$app" ]]; then
            echo "Updating cert for $app..."
            tar cf - server.crt server.key | docker exec -i dokku dokku certs:update "$app" 2>&1 || true
        fi
    done
fi
