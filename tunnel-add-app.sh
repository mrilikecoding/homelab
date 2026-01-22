#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"
TUNNEL_DIR="$HOME/.cloudflared"
CONFIG_FILE="$TUNNEL_DIR/config.yml"
CREDENTIALS_DIR="$HOME/.homelab/credentials"

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

# Regenerate config
"$SCRIPT_DIR/tunnel-regenerate-config.sh"

# Get tunnel ID
TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep homelab | awk '{print $1}')
if [[ -z "$TUNNEL_ID" ]]; then
    echo "Error: Could not find tunnel ID"
    exit 1
fi

# Extract subdomain and domain from hostname
# e.g., "hello-world.nate.green" -> subdomain="hello-world", domain="nate.green"
SUBDOMAIN="${HOSTNAME%%.*}"
DOMAIN="${HOSTNAME#*.}"

# Try to add DNS record via Porkbun API
echo "Adding DNS record for $HOSTNAME..."

if [[ -f "$CREDENTIALS_DIR/porkbun.ini" ]]; then
    # Read Porkbun credentials
    API_KEY=$(grep "dns_porkbun_key" "$CREDENTIALS_DIR/porkbun.ini" | cut -d'=' -f2 | tr -d ' ')
    API_SECRET=$(grep "dns_porkbun_secret" "$CREDENTIALS_DIR/porkbun.ini" | cut -d'=' -f2 | tr -d ' ')

    if [[ -n "$API_KEY" && -n "$API_SECRET" ]]; then
        # Create CNAME record via Porkbun API
        RESPONSE=$(curl -s -X POST "https://api.porkbun.com/api/json/v3/dns/create/$DOMAIN" \
            -H "Content-Type: application/json" \
            -d "{
                \"apikey\": \"$API_KEY\",
                \"secretapikey\": \"$API_SECRET\",
                \"name\": \"$SUBDOMAIN\",
                \"type\": \"CNAME\",
                \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
                \"ttl\": 600
            }")

        if echo "$RESPONSE" | grep -q '"status":"SUCCESS"'; then
            echo "✓ DNS record created: $HOSTNAME -> ${TUNNEL_ID}.cfargotunnel.com"
        elif echo "$RESPONSE" | grep -q "already exists"; then
            echo "✓ DNS record already exists for $HOSTNAME"
        else
            echo "⚠ Could not create DNS record automatically."
            echo "  API response: $RESPONSE"
            echo ""
            echo "  Please add manually in Porkbun:"
            echo "  Type: CNAME"
            echo "  Host: $SUBDOMAIN"
            echo "  Answer: ${TUNNEL_ID}.cfargotunnel.com"
        fi
    else
        echo "⚠ Porkbun credentials incomplete. Add DNS record manually:"
        echo "  Type: CNAME"
        echo "  Host: $SUBDOMAIN"
        echo "  Answer: ${TUNNEL_ID}.cfargotunnel.com"
    fi
else
    echo "⚠ No Porkbun credentials found. Add DNS record manually:"
    echo "  Type: CNAME"
    echo "  Host: $SUBDOMAIN"
    echo "  Answer: ${TUNNEL_ID}.cfargotunnel.com"
fi

echo ""
echo "App '$APP' is now public at https://$HOSTNAME"
echo "Restart the tunnel to apply changes: homelab tunnel:restart"
