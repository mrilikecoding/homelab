#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load config
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo -e "${RED}Error: config.sh not found${NC}"
    exit 1
fi
source "$SCRIPT_DIR/config.sh"

TUNNEL_DIR="$HOME/.cloudflared"
TUNNEL_NAME="homelab"
CONFIG_FILE="$TUNNEL_DIR/config.yml"
PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"

echo -e "${CYAN}=============================================="
echo -e "  Cloudflare Tunnel Setup"
echo -e "  (Selective Public Access)"
echo -e "==============================================${NC}"
echo ""

# =============================================================================
# Install cloudflared
# =============================================================================
echo -e "${CYAN}==> Checking cloudflared...${NC}"

if ! command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}Installing cloudflared...${NC}"
    brew install cloudflared
fi

echo -e "${GREEN}cloudflared is installed${NC}"

# =============================================================================
# Login to Cloudflare (if needed)
# =============================================================================
if [[ ! -f "$TUNNEL_DIR/cert.pem" ]]; then
    echo ""
    echo -e "${CYAN}==> Logging in to Cloudflare...${NC}"
    echo ""
    echo "This will open a browser to authenticate with Cloudflare."
    echo "Make sure ${APP_DOMAIN} is added to your Cloudflare account."
    echo ""
    read -p "Press Enter to continue..."

    cloudflared tunnel login

    echo -e "${GREEN}Logged in successfully!${NC}"
fi

# =============================================================================
# Create tunnel (if needed)
# =============================================================================
echo ""
echo -e "${CYAN}==> Setting up tunnel...${NC}"

# Check if tunnel exists
if cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
    echo -e "${GREEN}Tunnel '$TUNNEL_NAME' already exists${NC}"
    TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
else
    echo "Creating tunnel '$TUNNEL_NAME'..."
    cloudflared tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    echo -e "${GREEN}Tunnel created: $TUNNEL_ID${NC}"
fi

# Find credentials file
CREDENTIALS_FILE="$TUNNEL_DIR/${TUNNEL_ID}.json"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo -e "${RED}Credentials file not found: $CREDENTIALS_FILE${NC}"
    exit 1
fi

# =============================================================================
# Create initial config
# =============================================================================
echo ""
echo -e "${CYAN}==> Creating tunnel configuration...${NC}"

# Initialize public apps file if it doesn't exist
touch "$PUBLIC_APPS_FILE"

# Generate config from public apps list
generate_tunnel_config() {
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
    service: http://localhost:80
    originRequest:
      httpHostHeader: ${app}.homelab.${APP_DOMAIN}
APPENTRY
            fi
        done < "$PUBLIC_APPS_FILE"
    fi

    # Catch-all rule (required)
    cat >> "$CONFIG_FILE" << CATCHALL
  # Catch-all: reject unknown hostnames
  - service: http_status:404
CATCHALL
}

generate_tunnel_config

echo -e "${GREEN}Configuration created: $CONFIG_FILE${NC}"

# =============================================================================
# Create management scripts
# =============================================================================
echo ""
echo -e "${CYAN}==> Creating management scripts...${NC}"

# Script to add a public app
cat > "$SCRIPT_DIR/tunnel-add-app.sh" << 'ADDSCRIPT'
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

# Regenerate config
"$SCRIPT_DIR/tunnel-regenerate-config.sh"

# Add DNS record
echo "Adding DNS record for $HOSTNAME..."
cloudflared tunnel route dns homelab "$HOSTNAME" 2>/dev/null || {
    echo "Note: DNS record may already exist or needs manual setup"
}

echo "App '$APP' is now public at https://$HOSTNAME"
echo "Restart the tunnel to apply changes: homelab tunnel:restart"
ADDSCRIPT
chmod +x "$SCRIPT_DIR/tunnel-add-app.sh"

# Script to remove a public app
cat > "$SCRIPT_DIR/tunnel-remove-app.sh" << 'REMOVESCRIPT'
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
REMOVESCRIPT
chmod +x "$SCRIPT_DIR/tunnel-remove-app.sh"

# Script to regenerate config
cat > "$SCRIPT_DIR/tunnel-regenerate-config.sh" << REGENSCRIPT
#!/bin/bash
set -e

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "\$SCRIPT_DIR/config.sh"

PUBLIC_APPS_FILE="\$SCRIPT_DIR/.public-apps"
TUNNEL_DIR="\$HOME/.cloudflared"
CONFIG_FILE="\$TUNNEL_DIR/config.yml"
TUNNEL_ID="$TUNNEL_ID"
CREDENTIALS_FILE="$CREDENTIALS_FILE"

cat > "\$CONFIG_FILE" << CONFIGHEADER
# Cloudflare Tunnel configuration for homelab
# Managed by: homelab public/private commands
# Do not edit manually - changes will be overwritten

tunnel: \$TUNNEL_ID
credentials-file: \$CREDENTIALS_FILE

ingress:
CONFIGHEADER

# Add entries for each public app
if [[ -s "\$PUBLIC_APPS_FILE" ]]; then
    while IFS=: read -r app hostname; do
        if [[ -n "\$app" && -n "\$hostname" ]]; then
            cat >> "\$CONFIG_FILE" << APPENTRY
  - hostname: \$hostname
    service: http://localhost:80
    originRequest:
      httpHostHeader: \${app}.homelab.\${APP_DOMAIN}
APPENTRY
        fi
    done < "\$PUBLIC_APPS_FILE"
fi

# Catch-all rule (required)
cat >> "\$CONFIG_FILE" << CATCHALL
  # Catch-all: reject unknown hostnames
  - service: http_status:404
CATCHALL

echo "Tunnel config regenerated: \$CONFIG_FILE"
REGENSCRIPT
chmod +x "$SCRIPT_DIR/tunnel-regenerate-config.sh"

# Script to list public apps
cat > "$SCRIPT_DIR/tunnel-list-apps.sh" << 'LISTSCRIPT'
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
LISTSCRIPT
chmod +x "$SCRIPT_DIR/tunnel-list-apps.sh"

# =============================================================================
# Create LaunchDaemon for tunnel
# =============================================================================
echo ""
echo -e "${CYAN}==> Setting up tunnel service...${NC}"

CLOUDFLARED_PATH=$(which cloudflared)

sudo tee /Library/LaunchDaemons/com.homelab.tunnel.plist > /dev/null << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CLOUDFLARED_PATH}</string>
        <string>tunnel</string>
        <string>--config</string>
        <string>${CONFIG_FILE}</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/homelab-tunnel.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/homelab-tunnel.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
</dict>
</plist>
PLIST

# Don't start the tunnel yet if no apps are public
if [[ -s "$PUBLIC_APPS_FILE" ]]; then
    echo "Starting tunnel service..."
    sudo launchctl unload /Library/LaunchDaemons/com.homelab.tunnel.plist 2>/dev/null || true
    sudo launchctl load /Library/LaunchDaemons/com.homelab.tunnel.plist
    echo -e "${GREEN}Tunnel is running${NC}"
else
    echo -e "${YELLOW}Tunnel service configured but not started (no public apps yet)${NC}"
    echo "The tunnel will start when you make your first app public"
fi

# =============================================================================
# Done!
# =============================================================================
echo ""
echo -e "${GREEN}=============================================="
echo -e "  Cloudflare Tunnel Setup Complete!"
echo -e "==============================================${NC}"
echo ""
echo "To make an app public:"
echo "  homelab public <app-name> [custom-hostname]"
echo ""
echo "To make an app private again:"
echo "  homelab private <app-name>"
echo ""
echo "To list public apps:"
echo "  homelab public:list"
echo ""
echo "Examples:"
echo "  homelab public myapp                    # -> myapp.${APP_DOMAIN}"
echo "  homelab public myapp custom.${APP_DOMAIN}  # -> custom.${APP_DOMAIN}"
echo ""
