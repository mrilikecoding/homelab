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

CERT_DIR="$HOME/.homelab/certs"
CREDENTIALS_DIR="$HOME/.homelab/credentials"
DOMAIN="homelab.${APP_DOMAIN}"

echo -e "${CYAN}=============================================="
echo -e "  Homelab HTTPS Setup (Let's Encrypt)"
echo -e "==============================================${NC}"
echo ""

# =============================================================================
# Check prerequisites
# =============================================================================
echo -e "${CYAN}==> Checking prerequisites...${NC}"

# certbot will be installed via pipx in install_dns_plugin if needed

# =============================================================================
# DNS Provider Configuration
# =============================================================================
echo ""
echo -e "${CYAN}==> DNS Provider Setup${NC}"
echo ""
echo "Let's Encrypt needs to verify domain ownership via DNS."
echo "This requires a DNS provider plugin for certbot."
echo ""

# Check for existing credentials
mkdir -p "$CREDENTIALS_DIR"
chmod 700 "$CREDENTIALS_DIR"

# Determine DNS provider
if [[ -n "$CERTBOT_DNS_PLUGIN" ]]; then
    DNS_PLUGIN="$CERTBOT_DNS_PLUGIN"
    echo -e "Using configured DNS plugin: ${GREEN}$DNS_PLUGIN${NC}"
elif [[ -f "$CREDENTIALS_DIR/dns-provider" ]]; then
    DNS_PLUGIN=$(cat "$CREDENTIALS_DIR/dns-provider")
    echo -e "Using saved DNS plugin: ${GREEN}$DNS_PLUGIN${NC}"
else
    echo "Supported DNS providers:"
    echo "  1) porkbun     - Porkbun"
    echo "  2) cloudflare  - Cloudflare"
    echo "  3) route53     - Amazon Route 53"
    echo "  4) google      - Google Cloud DNS"
    echo "  5) digitalocean - DigitalOcean"
    echo "  6) namecheap   - Namecheap"
    echo "  7) manual      - Manual DNS (no automation)"
    echo ""
    read -p "Select your DNS provider [1-7]: " DNS_CHOICE

    case "$DNS_CHOICE" in
        1|porkbun) DNS_PLUGIN="porkbun" ;;
        2|cloudflare) DNS_PLUGIN="cloudflare" ;;
        3|route53) DNS_PLUGIN="route53" ;;
        4|google) DNS_PLUGIN="google" ;;
        5|digitalocean) DNS_PLUGIN="digitalocean" ;;
        6|namecheap) DNS_PLUGIN="namecheap" ;;
        7|manual) DNS_PLUGIN="manual" ;;
        *) echo -e "${RED}Invalid choice: '$DNS_CHOICE'. Enter 1-7 or provider name.${NC}"; exit 1 ;;
    esac

    echo "$DNS_PLUGIN" > "$CREDENTIALS_DIR/dns-provider"
fi

# =============================================================================
# Install DNS plugin and configure credentials
# =============================================================================
CREDENTIALS_FILE="$CREDENTIALS_DIR/${DNS_PLUGIN}.ini"

install_dns_plugin() {
    local plugin=$1
    echo -e "${YELLOW}Installing certbot-dns-${plugin}...${NC}"

    # Use pipx for installing Python CLI applications (modern macOS requirement)
    if ! command -v pipx &> /dev/null; then
        echo "Installing pipx..."
        brew install pipx
        pipx ensurepath
    fi

    # Install certbot via pipx if not already installed
    if ! pipx list | grep -q certbot; then
        echo "Installing certbot via pipx..."
        pipx install certbot
    fi

    # Inject the DNS plugin into the certbot environment
    case "$plugin" in
        porkbun)
            pipx inject certbot certbot-dns-porkbun
            ;;
        cloudflare)
            pipx inject certbot certbot-dns-cloudflare
            ;;
        route53)
            pipx inject certbot certbot-dns-route53
            ;;
        google)
            pipx inject certbot certbot-dns-google
            ;;
        digitalocean)
            pipx inject certbot certbot-dns-digitalocean
            ;;
        namecheap)
            pipx inject certbot certbot-dns-namecheap
            ;;
    esac
}

configure_credentials() {
    local plugin=$1

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        echo -e "${GREEN}Credentials file exists: $CREDENTIALS_FILE${NC}"
        read -p "Reconfigure credentials? [y/N]: " RECONFIG
        [[ "$RECONFIG" != "y" && "$RECONFIG" != "Y" ]] && return 0
    fi

    echo ""
    echo -e "${CYAN}Configure $plugin credentials:${NC}"

    case "$plugin" in
        porkbun)
            echo "Get your API keys from: https://porkbun.com/account/api"
            echo ""
            read -p "API Key: " API_KEY
            read -p "API Secret: " API_SECRET
            cat > "$CREDENTIALS_FILE" << EOF
dns_porkbun_key = $API_KEY
dns_porkbun_secret = $API_SECRET
EOF
            ;;
        cloudflare)
            echo "Get your API token from: https://dash.cloudflare.com/profile/api-tokens"
            echo "Create a token with Zone:DNS:Edit permissions"
            echo ""
            read -p "API Token: " API_TOKEN
            cat > "$CREDENTIALS_FILE" << EOF
dns_cloudflare_api_token = $API_TOKEN
EOF
            ;;
        route53)
            echo "Configure AWS credentials in ~/.aws/credentials"
            echo "Required IAM permissions: route53:GetChange, route53:ChangeResourceRecordSets, route53:ListHostedZones"
            echo ""
            # route53 uses AWS credentials, no separate file needed
            touch "$CREDENTIALS_FILE"
            ;;
        google)
            echo "Create a service account with DNS Admin role"
            echo "Download the JSON key file"
            echo ""
            read -p "Path to service account JSON: " JSON_PATH
            cp "$JSON_PATH" "$CREDENTIALS_FILE"
            ;;
        digitalocean)
            echo "Get your API token from: https://cloud.digitalocean.com/account/api/tokens"
            echo ""
            read -p "API Token: " API_TOKEN
            cat > "$CREDENTIALS_FILE" << EOF
dns_digitalocean_token = $API_TOKEN
EOF
            ;;
        namecheap)
            echo "Enable API access at: https://ap.www.namecheap.com/settings/tools/apiaccess/"
            echo ""
            read -p "API User: " API_USER
            read -p "API Key: " API_KEY
            cat > "$CREDENTIALS_FILE" << EOF
dns_namecheap_username = $API_USER
dns_namecheap_api_key = $API_KEY
EOF
            ;;
    esac

    chmod 600 "$CREDENTIALS_FILE"
    echo -e "${GREEN}Credentials saved to $CREDENTIALS_FILE${NC}"
}

# Install plugin and configure (skip for manual)
if [[ "$DNS_PLUGIN" != "manual" ]]; then
    install_dns_plugin "$DNS_PLUGIN"
    configure_credentials "$DNS_PLUGIN"
fi

# =============================================================================
# Request certificate
# =============================================================================
echo ""
echo -e "${CYAN}==> Requesting wildcard certificate for *.${DOMAIN}${NC}"

mkdir -p "$CERT_DIR"

# Email for Let's Encrypt notifications
if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
    read -p "Email for Let's Encrypt notifications: " LETSENCRYPT_EMAIL
fi

# Build certbot command
CERTBOT_CMD="certbot certonly"
CERTBOT_CMD+=" --config-dir $CERT_DIR"
CERTBOT_CMD+=" --work-dir $CERT_DIR/work"
CERTBOT_CMD+=" --logs-dir $CERT_DIR/logs"
CERTBOT_CMD+=" -d '*.${DOMAIN}'"
CERTBOT_CMD+=" -d '${DOMAIN}'"
CERTBOT_CMD+=" --email $LETSENCRYPT_EMAIL"
CERTBOT_CMD+=" --agree-tos"
CERTBOT_CMD+=" --non-interactive"

case "$DNS_PLUGIN" in
    porkbun)
        CERTBOT_CMD+=" --authenticator dns-porkbun"
        CERTBOT_CMD+=" --dns-porkbun-credentials $CREDENTIALS_FILE"
        CERTBOT_CMD+=" --dns-porkbun-propagation-seconds 60"
        ;;
    cloudflare)
        CERTBOT_CMD+=" --dns-cloudflare"
        CERTBOT_CMD+=" --dns-cloudflare-credentials $CREDENTIALS_FILE"
        ;;
    route53)
        CERTBOT_CMD+=" --dns-route53"
        ;;
    google)
        CERTBOT_CMD+=" --dns-google"
        CERTBOT_CMD+=" --dns-google-credentials $CREDENTIALS_FILE"
        ;;
    digitalocean)
        CERTBOT_CMD+=" --dns-digitalocean"
        CERTBOT_CMD+=" --dns-digitalocean-credentials $CREDENTIALS_FILE"
        ;;
    namecheap)
        CERTBOT_CMD+=" --dns-namecheap"
        CERTBOT_CMD+=" --dns-namecheap-credentials $CREDENTIALS_FILE"
        ;;
    manual)
        CERTBOT_CMD+=" --manual"
        CERTBOT_CMD+=" --preferred-challenges dns"
        # Remove non-interactive for manual
        CERTBOT_CMD="${CERTBOT_CMD//--non-interactive/}"
        echo ""
        echo -e "${YELLOW}Manual mode: You'll need to add DNS TXT records when prompted${NC}"
        ;;
esac

echo ""
echo "Running: $CERTBOT_CMD"
echo ""

eval $CERTBOT_CMD

# Find the cert path
CERT_PATH="$CERT_DIR/live/${DOMAIN}"
if [[ ! -d "$CERT_PATH" ]]; then
    # Try wildcard path format
    CERT_PATH="$CERT_DIR/live/*.${DOMAIN}"
    CERT_PATH=$(echo $CERT_PATH)  # Expand glob
fi

if [[ ! -f "$CERT_PATH/fullchain.pem" ]]; then
    echo -e "${RED}Certificate not found at expected path${NC}"
    echo "Check $CERT_DIR/live/ for the certificate directory"
    exit 1
fi

echo -e "${GREEN}Certificate obtained successfully!${NC}"
echo "  Certificate: $CERT_PATH/fullchain.pem"
echo "  Private key: $CERT_PATH/privkey.pem"

# =============================================================================
# Configure Dokku to use the certificate
# =============================================================================
echo ""
echo -e "${CYAN}==> Configuring Dokku to use wildcard certificate...${NC}"

# Copy certs to a location we can use
DOKKU_CERT_DIR="$SCRIPT_DIR/dokku/certs"
mkdir -p "$DOKKU_CERT_DIR"
cp "$CERT_PATH/fullchain.pem" "$DOKKU_CERT_DIR/server.crt"
cp "$CERT_PATH/privkey.pem" "$DOKKU_CERT_DIR/server.key"

echo -e "${GREEN}Certificates saved to $DOKKU_CERT_DIR${NC}"

# =============================================================================
# Set up auto-renewal
# =============================================================================
echo ""
echo -e "${CYAN}==> Setting up certificate auto-renewal...${NC}"

# Create renewal script
cat > "$SCRIPT_DIR/renew-certs.sh" << 'RENEWSCRIPT'
#!/bin/bash
# Certificate renewal script for homelab

# Resolve symlinks to find actual script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

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

# Copy renewed certs
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
RENEWSCRIPT
chmod +x "$SCRIPT_DIR/renew-certs.sh"

# Create launchd plist for auto-renewal (runs weekly)
sudo tee /Library/LaunchDaemons/com.homelab.certrenew.plist > /dev/null << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.certrenew</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_DIR}/renew-certs.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/homelab-certrenew.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/homelab-certrenew.log</string>
</dict>
</plist>
PLIST

sudo launchctl unload /Library/LaunchDaemons/com.homelab.certrenew.plist 2>/dev/null || true
sudo launchctl load /Library/LaunchDaemons/com.homelab.certrenew.plist

echo -e "${GREEN}Auto-renewal configured (runs weekly)${NC}"

# =============================================================================
# Enable HTTPS for existing apps
# =============================================================================
echo ""
echo -e "${CYAN}==> Enabling HTTPS for existing apps...${NC}"

# Get list of apps
APPS=$(docker exec dokku dokku apps:list 2>/dev/null | tail -n +2)

cd "$DOKKU_CERT_DIR"
for app in $APPS; do
    if [[ -n "$app" ]]; then
        echo "Enabling HTTPS for $app..."
        # Add cert to each app (Dokku requires per-app certs)
        tar cf - server.crt server.key | docker exec -i dokku dokku certs:add "$app" 2>&1 | grep -v "^a " || true
    fi
done

# =============================================================================
# Done!
# =============================================================================
echo ""
echo -e "${GREEN}=============================================="
echo -e "  HTTPS Setup Complete!"
echo -e "==============================================${NC}"
echo ""
echo "Your apps are now available via HTTPS:"
echo "  https://pihole.${DOMAIN}"
echo "  https://api.${DOMAIN}"
echo "  https://<app>.${DOMAIN}"
echo ""
echo "Certificate auto-renewal is configured to run weekly."
echo ""
echo "To manually renew certificates:"
echo "  $SCRIPT_DIR/renew-certs.sh"
echo ""
