#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"

if [[ ! -s "$PUBLIC_APPS_FILE" ]]; then
    echo "No apps are currently public"
    exit 0
fi

echo "Public apps:"
while IFS=: read -r app hostname; do
    if [[ -n "$app" && -n "$hostname" ]]; then
        echo "  $app -> https://$hostname"
    fi
done < "$PUBLIC_APPS_FILE"
