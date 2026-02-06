#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"
TUNNEL_DIR="$HOME/.cloudflared"
CONFIG_FILE="$TUNNEL_DIR/config.yml"

APP="$1"
HOSTNAME="${2:-$APP.$APP_DOMAIN}"

if [[ -z "$APP" ]]; then
    echo "Usage: $0 <app-name> [public-hostname]"
    echo "Example: $0 myapp myapp.nate.green"
    exit 1
fi

# Check if app exists in Dokku
if ! docker exec dokku dokku apps:exists "$APP" 2>/dev/null; then
    echo "Error: App '$APP' does not exist in Dokku"
    exit 1
fi

# Check if this exact app:hostname pair already exists
if grep -q "^${APP}:${HOSTNAME}$" "$PUBLIC_APPS_FILE" 2>/dev/null; then
    echo "App '$APP' is already public at $HOSTNAME"
    exit 0
fi

# Add to public apps
echo "${APP}:${HOSTNAME}" >> "$PUBLIC_APPS_FILE"

# Add public hostname to Dokku so it accepts requests for this domain
echo "Adding $HOSTNAME to Dokku app..."
docker exec dokku dokku domains:add "$APP" "$HOSTNAME" 2>/dev/null || true

# Regenerate tunnel config
"$SCRIPT_DIR/tunnel-regenerate-config.sh"

# Add DNS record via Cloudflare
TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep homelab | awk '{print $1}')

if [[ "$HOSTNAME" == *".${APP_DOMAIN}" || "$HOSTNAME" == "$APP_DOMAIN" ]]; then
    # Hostname is under the cloudflared-authorized zone — auto-create DNS
    echo "Adding DNS record for $HOSTNAME..."
    if cloudflared tunnel route dns homelab "$HOSTNAME" 2>&1; then
        echo "✓ DNS record created via Cloudflare"
    else
        echo "⚠ Could not create DNS record automatically."
        echo ""
        echo "  Add manually in Cloudflare DNS for $APP_DOMAIN:"
        echo "  Type: CNAME"
        echo "  Name: ${HOSTNAME%%.$APP_DOMAIN}"
        echo "  Target: ${TUNNEL_ID}.cfargotunnel.com"
        echo "  Proxy: Enabled (orange cloud)"
    fi
else
    # Hostname is on a different zone — cloudflared cert.pem can't manage it
    echo ""
    echo "⚠ $HOSTNAME is not under $APP_DOMAIN — add DNS record manually:"
    echo "  Zone: $HOSTNAME"
    echo "  Type: CNAME"
    if [[ "$HOSTNAME" == *.* && "$(echo "$HOSTNAME" | tr '.' '\n' | wc -l)" -gt 2 ]]; then
        # Subdomain (e.g., trellis.nrgforge.com) — name is the subdomain part
        ZONE="${HOSTNAME#*.}"
        echo "  Name: ${HOSTNAME%%.$ZONE}"
    else
        # Apex domain (e.g., nrgforge.com) — name is @
        echo "  Name: @ (root)"
    fi
    echo "  Target: ${TUNNEL_ID}.cfargotunnel.com"
    echo "  Proxy: Enabled (orange cloud)"
fi

echo ""
echo "App '$APP' is now public at https://$HOSTNAME"
echo "Restart the tunnel to apply changes: homelab tunnel:restart"
