#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"
TUNNEL_DIR="$HOME/.cloudflared"
CONFIG_FILE="$TUNNEL_DIR/config.yml"
TUNNEL_ID="b737c8e7-b80d-4150-ba5a-59c990b9995c"
CREDENTIALS_FILE="/Users/nathanielgreen/.cloudflared/b737c8e7-b80d-4150-ba5a-59c990b9995c.json"

cat > "$CONFIG_FILE" << CONFIGHEADER
# Cloudflare Tunnel configuration for homelab
# Managed by: homelab public/private commands
# Do not edit manually - changes will be overwritten

tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS_FILE

ingress:
CONFIGHEADER

# Add entries for each public app
if [[ -s "$PUBLIC_APPS_FILE" ]]; then
    while IFS=: read -r app hostname; do
        if [[ -n "$app" && -n "$hostname" ]]; then
            cat >> "$CONFIG_FILE" << APPENTRY
  - hostname: $hostname
    service: https://localhost:443
    originRequest:
      noTLSVerify: true
APPENTRY
        fi
    done < "$PUBLIC_APPS_FILE"
fi

# Catch-all rule (required)
cat >> "$CONFIG_FILE" << CATCHALL
  # Catch-all: reject unknown hostnames
  - service: http_status:404
CATCHALL

echo "Tunnel config regenerated: $CONFIG_FILE"
