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

# Check if already public
if grep -q "^${APP}:" "$PUBLIC_APPS_FILE" 2>/dev/null; then
    echo "App '$APP' is already public"
    exit 0
fi

# Add to public apps
echo "${APP}:${HOSTNAME}" >> "$PUBLIC_APPS_FILE"

# Regenerate tunnel config
"$SCRIPT_DIR/tunnel-regenerate-config.sh"

# Add DNS record via Cloudflare (cloudflared handles this automatically when domain is on Cloudflare)
echo "Adding DNS record for $HOSTNAME..."

if cloudflared tunnel route dns homelab "$HOSTNAME" 2>&1; then
    echo "✓ DNS record created via Cloudflare"
else
    echo "⚠ Could not create DNS record automatically."
    echo ""
    echo "  If your domain is on Cloudflare DNS, check that:"
    echo "  1. The domain is 'Active' in Cloudflare dashboard"
    echo "  2. You're authenticated: cloudflared tunnel login"
    echo ""
    echo "  If your domain is NOT on Cloudflare, add manually:"
    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep homelab | awk '{print $1}')
    echo "  Type: CNAME"
    echo "  Host: ${HOSTNAME%%.*}"
    echo "  Target: ${TUNNEL_ID}.cfargotunnel.com"
fi

echo ""
echo "App '$APP' is now public at https://$HOSTNAME"
echo "Restart the tunnel to apply changes: homelab tunnel:restart"
