#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "Error: config.sh not found. Copy config.example.sh to config.sh and edit it."
    exit 1
fi
source "$SCRIPT_DIR/config.sh"

echo "=============================================="
echo "  Home Server Setup for macOS + Tailscale"
echo "  Pi-hole + Dokku (git push to deploy)"
echo "=============================================="
echo ""

# =============================================================================
# Install dependencies
# =============================================================================
echo "==> Installing dependencies..."
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew is required. Install from https://brew.sh"
    exit 1
fi

brew install colima docker docker-compose socat

# =============================================================================
# Start Colima
# =============================================================================
echo "==> Starting Colima..."
colima start --cpu "$COLIMA_CPUS" --memory "$COLIMA_MEMORY" --network-address

echo "==> Disabling Colima's built-in dnsmasq..."
colima ssh -- sudo pkill dnsmasq || true
colima ssh -- sudo rm -f /etc/init.d/dnsmasq
colima ssh -- sudo rm -f /etc/runlevels/default/dnsmasq 2>/dev/null || true

# =============================================================================
# Get network addresses
# =============================================================================
echo "==> Getting network addresses..."
COLIMA_IP=$(colima list -j | grep -o '"address":"[^"]*"' | cut -d'"' -f4)
if [[ -z "$COLIMA_IP" ]]; then
    echo "Error: Could not determine Colima VM IP"
    exit 1
fi

if ! command -v tailscale &> /dev/null; then
    echo "Error: Tailscale is required. Install from https://tailscale.com/download"
    exit 1
fi

if [[ -z "$TAILSCALE_IP" ]]; then
    TAILSCALE_IP=$(tailscale ip -4)
fi
if [[ -z "$TAILSCALE_IP" ]]; then
    echo "Error: Could not determine Tailscale IP. Is Tailscale running?"
    exit 1
fi

echo "    Colima VM IP: $COLIMA_IP"
echo "    Tailscale IP: $TAILSCALE_IP"

# Save IPs for other scripts
cat > "$SCRIPT_DIR/.env" << ENVFILE
COLIMA_IP=$COLIMA_IP
TAILSCALE_IP=$TAILSCALE_IP
ENVFILE

# =============================================================================
# Set up Pi-hole
# =============================================================================
echo "==> Creating Pi-hole config directory..."
mkdir -p ~/pihole/etc-pihole ~/pihole/etc-dnsmasq.d

echo "==> Starting Pi-hole container..."
docker rm -f pihole 2>/dev/null || true
docker run -d \
  --name pihole \
  --network=host \
  -e TZ="$PIHOLE_TIMEZONE" \
  -e WEBPASSWORD="$PIHOLE_PASSWORD" \
  -e PIHOLE_DNS_="$PIHOLE_UPSTREAM_DNS" \
  --dns=1.1.1.1 \
  -v ~/pihole/etc-pihole:/etc/pihole \
  -v ~/pihole/etc-dnsmasq.d:/etc/dnsmasq.d \
  --restart=unless-stopped \
  pihole/pihole:latest

echo "==> Waiting for Pi-hole to start..."
sleep 15

# Configure Pi-hole to use non-standard ports (so Dokku can have 80/443)
echo "==> Configuring Pi-hole web ports..."
if [[ -f ~/pihole/etc-pihole/pihole.toml ]]; then
    # Update web server port to 8081 (HTTP) and 8443 (HTTPS)
    sed -i.bak 's/port = "80o,443os,\[::\]:80o,\[::\]:443os"/port = "8081o,8443os,[::]:8081o,[::]:8443os"/' ~/pihole/etc-pihole/pihole.toml
    docker restart pihole
    sleep 10
fi

# =============================================================================
# Set up Dokku
# =============================================================================
echo "==> Setting up Dokku..."
mkdir -p "$SCRIPT_DIR/dokku"

cat > "$SCRIPT_DIR/dokku/docker-compose.yml" << DOKKUCOMPOSE
services:
  dokku:
    image: dokku/dokku:0.35.15
    container_name: dokku
    restart: unless-stopped
    network_mode: bridge
    ports:
      - "${DOKKU_SSH_PORT}:22"
      - "80:80"
      - "443:443"
    volumes:
      - dokku_data:/mnt/dokku
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      DOKKU_HOSTNAME: ${DOKKU_HOSTNAME}
      DOKKU_HOST_ROOT: /mnt/dokku/home/dokku
      DOKKU_LIB_HOST_ROOT: /mnt/dokku/var/lib/dokku

volumes:
  dokku_data:
DOKKUCOMPOSE

echo "==> Starting Dokku..."
cd "$SCRIPT_DIR/dokku"
docker compose up -d

echo "==> Waiting for Dokku to be ready..."
sleep 30

# Add SSH key to Dokku
echo "==> Adding SSH key to Dokku..."
if [[ -f ~/.ssh/id_ed25519.pub ]]; then
    cat ~/.ssh/id_ed25519.pub | docker exec -i dokku dokku ssh-keys:add admin 2>/dev/null || true
elif [[ -f ~/.ssh/id_rsa.pub ]]; then
    cat ~/.ssh/id_rsa.pub | docker exec -i dokku dokku ssh-keys:add admin 2>/dev/null || true
else
    echo "Warning: No SSH key found. Add one manually:"
    echo "  cat ~/.ssh/YOUR_KEY.pub | docker exec -i dokku dokku ssh-keys:add admin"
fi

# =============================================================================
# Set up Pi-hole proxy app in Dokku
# =============================================================================
echo "==> Creating Pi-hole proxy app..."
mkdir -p "$SCRIPT_DIR/pihole-proxy"

cat > "$SCRIPT_DIR/pihole-proxy/Dockerfile" << 'DOCKERFILE'
FROM nginx:alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
DOCKERFILE

cat > "$SCRIPT_DIR/pihole-proxy/nginx.conf" << NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://${COLIMA_IP}:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

# Create and deploy the app
docker exec dokku dokku apps:create pihole 2>/dev/null || true
docker exec dokku dokku domains:set pihole pihole.${APP_DOMAIN}

cd "$SCRIPT_DIR/pihole-proxy"
rm -rf .git
git init -q
git add .
git commit -q -m "Pi-hole proxy app"
git remote add dokku ssh://dokku@127.0.0.1:${DOKKU_SSH_PORT}/pihole 2>/dev/null || true
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -p ${DOKKU_SSH_PORT}" git push -f dokku main 2>/dev/null || \
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -p ${DOKKU_SSH_PORT}" git push -f dokku master 2>/dev/null || true
rm -rf .git

# =============================================================================
# Configure DNS records in Pi-hole
# =============================================================================
echo "==> Configuring local DNS records..."
if [[ -f ~/pihole/etc-pihole/pihole.toml ]]; then
    # Add DNS record for pihole.${APP_DOMAIN}
    sed -i.bak "s/hosts = \[\]/hosts = [\"${TAILSCALE_IP} pihole.${APP_DOMAIN}\"]/" ~/pihole/etc-pihole/pihole.toml
    docker restart pihole
    sleep 5
fi

# =============================================================================
# Create DNS forwarder LaunchDaemon
# =============================================================================
echo "==> Creating DNS forwarder LaunchDaemon..."
sudo tee /Library/LaunchDaemons/com.homelab.dns.plist > /dev/null << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.dns</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/socat</string>
        <string>UDP-RECVFROM:53,bind=${TAILSCALE_IP},fork,reuseaddr</string>
        <string>UDP-SENDTO:${COLIMA_IP}:53</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

# =============================================================================
# Create startup script
# =============================================================================
echo "==> Creating startup script..."
sudo tee /usr/local/bin/homelab-startup.sh > /dev/null << 'STARTUP'
#!/bin/bash
# Startup script for homelab on macOS
# Manages: Colima, Pi-hole, Dokku

LOG="/tmp/homelab-startup.log"
exec > "$LOG" 2>&1

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "$(date): Starting homelab startup script"

# Wait for network
echo "$(date): Waiting for network..."
while ! ping -c 1 1.1.1.1 &>/dev/null; do
    sleep 5
done
echo "$(date): Network is up"

# Find the user who owns the colima config
CONSOLE_USER="$(stat -f %Su /Users/*/.colima 2>/dev/null | head -1)"

if [[ -z "$CONSOLE_USER" ]]; then
    echo "$(date): ERROR - Could not determine user"
    exit 1
fi

echo "$(date): Running as user: $CONSOLE_USER"

# Start Colima
echo "$(date): Starting Colima..."
sudo -u "$CONSOLE_USER" /usr/local/bin/colima start --network-address

# Wait for Colima to be ready
echo "$(date): Waiting for Colima..."
sleep 10

# Kill dnsmasq inside the VM
echo "$(date): Killing dnsmasq..."
sudo -u "$CONSOLE_USER" /usr/local/bin/colima ssh -- sudo pkill dnsmasq || true

# Start containers
echo "$(date): Starting Pi-hole..."
sudo -u "$CONSOLE_USER" /usr/local/bin/docker restart pihole || true

echo "$(date): Starting Dokku..."
sudo -u "$CONSOLE_USER" /usr/local/bin/docker restart dokku || true

sleep 5

# Restart DNS forwarder
echo "$(date): Restarting DNS forwarder..."
launchctl kickstart -k system/com.homelab.dns || true

echo "$(date): Startup complete"
STARTUP

sudo chmod +x /usr/local/bin/homelab-startup.sh

# =============================================================================
# Create boot LaunchDaemon
# =============================================================================
echo "==> Creating boot LaunchDaemon..."
sudo tee /Library/LaunchDaemons/com.homelab.startup.plist > /dev/null << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.startup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/homelab-startup.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/homelab-startup.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/homelab-startup.log</string>
</dict>
</plist>
PLIST

# Load LaunchDaemons
echo "==> Loading LaunchDaemons..."
sudo launchctl unload /Library/LaunchDaemons/com.homelab.dns.plist 2>/dev/null || true
sudo launchctl unload /Library/LaunchDaemons/com.homelab.startup.plist 2>/dev/null || true
sudo launchctl load /Library/LaunchDaemons/com.homelab.dns.plist
sudo launchctl load /Library/LaunchDaemons/com.homelab.startup.plist

# =============================================================================
# Configure power management
# =============================================================================
echo "==> Configuring power management for headless operation..."
sudo pmset -a sleep 0 disksleep 0 displaysleep 0 autorestart 1

# =============================================================================
# Done!
# =============================================================================
echo ""
echo "=============================================="
echo "  Installation complete!"
echo "=============================================="
echo ""
echo "Pi-hole:"
echo "  Dashboard: http://pihole.${APP_DOMAIN}/admin"
echo "  Password:  $PIHOLE_PASSWORD"
echo "  DNS IP:    $TAILSCALE_IP"
echo ""
echo "Dokku:"
echo "  SSH Port:  $DOKKU_SSH_PORT"
echo "  Deploy:    git remote add dokku ssh://dokku@${DOKKU_HOSTNAME}:${DOKKU_SSH_PORT}/APPNAME"
echo "             git push dokku main"
echo ""
echo "Next steps:"
echo "  1. Go to https://login.tailscale.com/admin/dns"
echo "  2. Add nameserver: $TAILSCALE_IP"
echo "  3. Enable 'Override DNS servers'"
echo ""
echo "To deploy a new app:"
echo "  1. Add DNS: Edit ~/pihole/etc-pihole/pihole.toml"
echo "     Add to hosts array: \"$TAILSCALE_IP myapp.${APP_DOMAIN}\""
echo "  2. Restart Pi-hole: docker restart pihole"
echo "  3. Create app: docker exec dokku dokku apps:create myapp"
echo "  4. Set domain: docker exec dokku dokku domains:set myapp myapp.${APP_DOMAIN}"
echo "  5. Push code: git push dokku main"
echo ""
