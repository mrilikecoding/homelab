#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"

APP="$1"

if [[ -z "$APP" ]]; then
    echo "Usage: $0 <app-name>"
    exit 1
fi

# Remove from public apps
if grep -q "^${APP}:" "$PUBLIC_APPS_FILE" 2>/dev/null; then
    grep -v "^${APP}:" "$PUBLIC_APPS_FILE" > "${PUBLIC_APPS_FILE}.tmp"
    mv "${PUBLIC_APPS_FILE}.tmp" "$PUBLIC_APPS_FILE"

    # Regenerate config
    "$SCRIPT_DIR/tunnel-regenerate-config.sh"

    echo "App '$APP' is now private"
    echo "Restart the tunnel to apply changes: homelab tunnel:restart"
    echo "Note: DNS record still exists - remove manually if needed"
else
    echo "App '$APP' is not public"
fi
