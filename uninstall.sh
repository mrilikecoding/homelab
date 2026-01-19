#!/bin/bash
set -e

echo "=============================================="
echo "  Homelab Uninstaller"
echo "=============================================="
echo ""

echo "==> Stopping and removing Dokku container..."
docker rm -f dokku 2>/dev/null || true

echo "==> Stopping and removing Pi-hole container..."
docker rm -f pihole 2>/dev/null || true

echo "==> Unloading LaunchDaemons..."
sudo launchctl unload /Library/LaunchDaemons/com.homelab.startup.plist 2>/dev/null || true
sudo launchctl unload /Library/LaunchDaemons/com.homelab.dns.plist 2>/dev/null || true

echo "==> Removing LaunchDaemons and startup scripts..."
sudo rm -f /Library/LaunchDaemons/com.homelab.startup.plist
sudo rm -f /Library/LaunchDaemons/com.homelab.dns.plist
sudo rm -f /usr/local/bin/homelab-startup.sh

echo "==> Stopping Colima..."
colima stop 2>/dev/null || true

echo ""
echo "=============================================="
echo "  Uninstall complete!"
echo "=============================================="
echo ""
echo "Optional cleanup (run manually if desired):"
echo ""
echo "  # Remove data directories"
echo "  rm -rf ~/pihole"
echo ""
echo "  # Remove Docker volumes"
echo "  docker volume rm dokku_data"
echo ""
echo "  # Remove Colima VM entirely"
echo "  colima delete"
echo ""
echo "  # Uninstall packages"
echo "  brew uninstall socat colima docker docker-compose"
echo ""
echo "Don't forget to remove the DNS entry from Tailscale admin:"
echo "  https://login.tailscale.com/admin/dns"
echo ""
