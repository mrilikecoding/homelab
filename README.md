# Homelab on macOS

Run a personal home server on a Mac with:
- **Pi-hole** - Network-wide ad blocking
- **Dokku** - Git push to deploy (like Heroku)
- **Tailscale** - Secure access from anywhere

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Mac (ng-mini)                                                   │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ Colima VM (192.168.64.x)                                │   │
│   │                                                         │   │
│   │   ┌─────────────┐     ┌─────────────────────────────┐   │   │
│   │   │   Pi-hole   │     │         Dokku               │   │   │
│   │   │  DNS + Web  │     │   ┌─────┐ ┌─────┐ ┌─────┐   │   │   │
│   │   │  :53, :8081 │     │   │app1 │ │app2 │ │app3 │   │   │   │
│   │   └─────────────┘     │   └─────┘ └─────┘ └─────┘   │   │   │
│   │         ▲             │             ▲               │   │   │
│   └─────────│─────────────┴─────────────│───────────────┘   │
│             │                           │                   │
│   ┌─────────┴───────┐         ┌─────────┴───────┐           │
│   │  socat (DNS)    │         │  Dokku nginx    │           │
│   │  Tailscale:53   │         │  :80, :443      │           │
│   └─────────────────┘         └─────────────────┘           │
│             ▲                           ▲                   │
└─────────────│───────────────────────────│───────────────────┘
              │                           │
              │      Tailscale VPN        │
              │                           │
    ┌─────────┴───────┐         ┌─────────┴───────┐
    │  DNS queries    │         │  HTTP requests  │
    │  from devices   │         │  pihole.domain  │
    └─────────────────┘         │  myapp.domain   │
                                └─────────────────┘
```

## Features

- **Ad blocking** for all devices on your Tailnet
- **Git push to deploy** any app with a Dockerfile
- **Custom domains** via Pi-hole local DNS (e.g., `myapp.nate.green`)
- **Auto-start** on reboot
- **Zero port forwarding** - everything runs over Tailscale

## Requirements

- macOS (Intel or Apple Silicon)
- [Homebrew](https://brew.sh)
- [Tailscale](https://tailscale.com/download) installed and connected

## Quick Start

```bash
# Clone this repo
git clone https://github.com/YOUR_USERNAME/homelab.git
cd homelab

# Configure
cp config.example.sh config.sh
nano config.sh  # Edit settings

# Install
./install.sh
```

## Configuration

Edit `config.sh` before running the installer:

```bash
# Pi-hole
PIHOLE_PASSWORD="your-secure-password"
PIHOLE_TIMEZONE="America/Los_Angeles"

# Dokku
DOKKU_HOSTNAME="your-machine.tail-name.ts.net"
DOKKU_SSH_PORT=3022

# Your domain for apps
APP_DOMAIN="yourdomain.com"
```

## After Installation

### 1. Configure Tailscale DNS

1. Go to [Tailscale Admin DNS](https://login.tailscale.com/admin/dns)
2. Click **Add nameserver** → **Custom**
3. Enter your Mac's Tailscale IP (shown at end of install)
4. Enable **Override DNS servers**

### 2. Access Pi-hole

Open `http://pihole.YOUR_DOMAIN/admin` from any device on your Tailnet.

### 3. Deploy Your First App

```bash
# On the server
docker exec dokku dokku apps:create myapp
docker exec dokku dokku domains:set myapp myapp.YOUR_DOMAIN

# Add DNS record
# Edit ~/pihole/etc-pihole/pihole.toml
# Add to hosts array: "YOUR_TAILSCALE_IP myapp.YOUR_DOMAIN"
docker restart pihole

# On your dev machine
cd your-app  # Must have a Dockerfile
git remote add dokku ssh://dokku@YOUR_SERVER:3022/myapp
git push dokku main
```

Your app is now live at `http://myapp.YOUR_DOMAIN`!

## Deploying Apps

### App Requirements

Your app needs one of:
- `Dockerfile` - Dokku builds and runs it
- `docker-compose.yml` - For multi-container apps
- Buildpack-compatible code (Node.js, Python, Ruby, etc.)

### Deploy Commands

```bash
# Create app
docker exec dokku dokku apps:create myapp

# Set domain
docker exec dokku dokku domains:set myapp myapp.YOUR_DOMAIN

# Deploy
git push dokku main

# View logs
docker exec dokku dokku logs myapp

# Restart
docker exec dokku dokku ps:restart myapp

# Delete
docker exec dokku dokku apps:destroy myapp
```

### Adding DNS for New Apps

Edit `~/pihole/etc-pihole/pihole.toml` and add to the `hosts` array:

```toml
hosts = [
  "100.x.x.x pihole.yourdomain.com",
  "100.x.x.x myapp.yourdomain.com",
  "100.x.x.x anotherapp.yourdomain.com"
]
```

Then restart Pi-hole: `docker restart pihole`

## Going Public (Optional)

To expose an app to the public internet:

### Option 1: Tailscale Funnel

```bash
tailscale funnel 443
```

Then CNAME `public.yourdomain.com` to your Tailscale hostname.

### Option 2: Cloudflare Tunnel

Install `cloudflared` and create a tunnel pointing to your local service.

## File Locations

| Path | Purpose |
|------|---------|
| `~/pihole/` | Pi-hole config and database |
| `~/homelab/dokku/` | Dokku docker-compose file (generated) |
| `~/homelab/pihole-proxy/` | Pi-hole proxy app for Dokku (generated) |
| `/Library/LaunchDaemons/com.homelab.startup.plist` | Boot startup |
| `/Library/LaunchDaemons/com.homelab.dns.plist` | DNS forwarder |
| `/usr/local/bin/homelab-startup.sh` | Startup script |
| `/tmp/homelab-startup.log` | Startup log |

## Troubleshooting

### Services not starting after reboot

Check the startup log:
```bash
cat /tmp/homelab-startup.log
```

Manually start services:
```bash
colima start --network-address
colima ssh -- sudo pkill dnsmasq
docker restart pihole
docker restart dokku
sudo launchctl kickstart -k system/com.homelab.dns
```

### DNS not resolving

1. Check Pi-hole is running: `docker ps | grep pihole`
2. Check DNS forwarder: `sudo launchctl list | grep homelab`
3. Test DNS directly: `dig @YOUR_TAILSCALE_IP google.com`

### Can't push to Dokku

1. Verify SSH key is added:
   ```bash
   docker exec dokku dokku ssh-keys:list
   ```

2. Check you're using the right port:
   ```bash
   git remote -v
   # Should show: ssh://dokku@hostname:3022/appname
   ```

### Port conflicts

Check what's using a port:
```bash
lsof -i :80
lsof -i :443
```

## Uninstallation

```bash
./uninstall.sh
```

This removes containers and LaunchDaemons but preserves data. See the script output for optional cleanup commands.

## How It Works

1. **Colima** runs a lightweight Linux VM on macOS with Docker
2. **Pi-hole** runs in Docker with host networking for DNS (port 53)
3. **Dokku** runs in Docker, managing deployed apps
4. **socat** forwards DNS from Tailscale IP → Colima VM
5. **LaunchDaemons** start everything on boot
6. **Pi-hole local DNS** resolves custom domains to Tailscale IP
7. **Dokku nginx** routes requests to the correct app

## License

MIT
