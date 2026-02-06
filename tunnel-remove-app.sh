#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"

APP="$1"
HOSTNAME="$2"

if [[ -z "$APP" ]]; then
    echo "Usage: $0 <app-name> [hostname]"
    echo "  Without hostname: removes ALL public hostnames for the app"
    echo "  With hostname: removes only that specific hostname"
    exit 1
fi

if ! grep -q "^${APP}:" "$PUBLIC_APPS_FILE" 2>/dev/null; then
    echo "App '$APP' is not public"
    exit 0
fi

if [[ -n "$HOSTNAME" ]]; then
    # Remove a specific hostname
    if ! grep -q "^${APP}:${HOSTNAME}$" "$PUBLIC_APPS_FILE" 2>/dev/null; then
        echo "App '$APP' is not public at $HOSTNAME"
        exit 0
    fi

    grep -v "^${APP}:${HOSTNAME}$" "$PUBLIC_APPS_FILE" > "${PUBLIC_APPS_FILE}.tmp"
    mv "${PUBLIC_APPS_FILE}.tmp" "$PUBLIC_APPS_FILE"

    echo "Removing $HOSTNAME from Dokku app..."
    docker exec dokku dokku domains:remove "$APP" "$HOSTNAME" 2>/dev/null || true

    # Regenerate config
    "$SCRIPT_DIR/tunnel-regenerate-config.sh"

    echo "Removed $HOSTNAME from app '$APP'"
    echo "Restart the tunnel to apply changes: homelab tunnel:restart"
    echo "Note: DNS record still exists in Cloudflare - remove manually if needed"
else
    # Remove ALL hostnames for this app
    HOSTNAMES=$(grep "^${APP}:" "$PUBLIC_APPS_FILE" | cut -d: -f2)

    grep -v "^${APP}:" "$PUBLIC_APPS_FILE" > "${PUBLIC_APPS_FILE}.tmp"
    mv "${PUBLIC_APPS_FILE}.tmp" "$PUBLIC_APPS_FILE"

    # Remove all public hostnames from Dokku
    while IFS= read -r h; do
        if [[ -n "$h" ]]; then
            echo "Removing $h from Dokku app..."
            docker exec dokku dokku domains:remove "$APP" "$h" 2>/dev/null || true
        fi
    done <<< "$HOSTNAMES"

    # Regenerate config
    "$SCRIPT_DIR/tunnel-regenerate-config.sh"

    echo "App '$APP' is now private (all hostnames removed)"
    echo "Restart the tunnel to apply changes: homelab tunnel:restart"
    echo "Note: DNS records still exist in Cloudflare - remove manually if needed"
fi
