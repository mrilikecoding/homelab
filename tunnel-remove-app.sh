#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"

APP="$1"

if [[ -z "$APP" ]]; then
    echo "Usage: $0 <app-name>"
    exit 1
fi

# Remove from public apps
if grep -q "^${APP}:" "$PUBLIC_APPS_FILE" 2>/dev/null; then
    # Get the hostname before removing
    HOSTNAME=$(grep "^${APP}:" "$PUBLIC_APPS_FILE" | cut -d: -f2)

    # Remove from list
    grep -v "^${APP}:" "$PUBLIC_APPS_FILE" > "${PUBLIC_APPS_FILE}.tmp"
    mv "${PUBLIC_APPS_FILE}.tmp" "$PUBLIC_APPS_FILE"

    # Remove public hostname from Dokku
    if [[ -n "$HOSTNAME" ]]; then
        echo "Removing $HOSTNAME from Dokku app..."
        docker exec dokku dokku domains:remove "$APP" "$HOSTNAME" 2>/dev/null || true
    fi

    # Regenerate config
    "$SCRIPT_DIR/tunnel-regenerate-config.sh"

    echo "App '$APP' is now private"
    echo "Restart the tunnel to apply changes: homelab tunnel:restart"
    echo "Note: DNS record still exists in Cloudflare - remove manually if needed"
else
    echo "App '$APP' is not public"
fi
