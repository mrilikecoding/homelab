# Homelab

A lightweight, extensible platform for running a combined homelab and development server on macOS. Deploy containerized apps with `git push`, access everything securely via Tailscale, and optionally expose services to the public internet.

## What You Get

- **Git push to deploy** - Push code, get a running app (like Heroku, but yours)
- **Network-wide ad blocking** - Pi-hole for all devices on your network
- **Private by default** - Everything accessible only via Tailscale VPN
- **Custom domains** - Use your own domain for internal services
- **Public when needed** - Expose specific apps to the internet via Tailscale Funnel or Cloudflare Tunnel
- **Auto-start on boot** - Services recover automatically after restarts

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Your Mac                                                        │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ Colima (Docker VM)                                      │   │
│   │                                                         │   │
│   │   ┌─────────────┐     ┌─────────────────────────────┐   │   │
│   │   │   Pi-hole   │     │         Dokku               │   │   │
│   │   │  DNS + Web  │     │   ┌─────┐ ┌─────┐ ┌─────┐   │   │   │
│   │   │             │     │   │ app │ │ app │ │ app │   │   │   │
│   │   └─────────────┘     │   └─────┘ └─────┘ └─────┘   │   │   │
│   │                       │             ▲               │   │   │
│   └───────────────────────┴─────────────│───────────────┘   │   │
│                                         │                       │
│                               ┌─────────┴───────┐               │
│                               │  Dokku Router   │               │
│                               │   :80 / :443    │               │
│                               └─────────────────┘               │
│                                         ▲                       │
└─────────────────────────────────────────│───────────────────────┘
                                          │
                    ┌─────────────────────┴─────────────────────┐
                    │              Tailscale VPN                │
                    │                                           │
          ┌─────────┴─────────┐                   ┌─────────────┴───┐
          │   Your devices    │                   │  Dev machine    │
          │   (any network)   │                   │  git push →     │
          └───────────────────┘                   └─────────────────┘
```

## Requirements

- macOS (Intel or Apple Silicon)
- [Homebrew](https://brew.sh)
- [Tailscale](https://tailscale.com/download)

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/homelab.git
cd homelab

cp config.example.sh config.sh
# Edit config.sh with your settings

./install.sh
```

## Configuration

Copy `config.example.sh` to `config.sh` and customize:

```bash
# Pi-hole
PIHOLE_PASSWORD="your-password"
PIHOLE_TIMEZONE="America/Los_Angeles"

# Dokku
DOKKU_HOSTNAME="your-machine.tailnet-name.ts.net"
DOKKU_SSH_PORT=3022

# Your domain (for internal DNS resolution)
APP_DOMAIN="yourdomain.com"
```

## Post-Install Setup

### Enable Tailscale DNS

1. Open [Tailscale Admin → DNS](https://login.tailscale.com/admin/dns)
2. Add your server's Tailscale IP as a custom nameserver
3. Enable "Override local DNS"

Now all devices on your Tailnet use Pi-hole for DNS and can resolve your custom domains.

---

## Deploying Apps

Deploy any containerized application from your local machine with git push.

### Create an App

```bash
# On your server (or via SSH)
docker exec dokku dokku apps:create myapp
docker exec dokku dokku domains:set myapp myapp.yourdomain.com
```

### Add DNS Entry

Edit `~/pihole/etc-pihole/pihole.toml` on your server and add to the `hosts` array:

```toml
hosts = [
  "100.x.x.x myapp.yourdomain.com"
]
```

Restart Pi-hole: `docker restart pihole`

### Deploy from Your Dev Machine

Your app needs a `Dockerfile` (or be buildpack-compatible).

```bash
cd your-app

# Add the remote (once)
git remote add dokku ssh://dokku@YOUR_SERVER_TAILSCALE_IP:3022/myapp

# Deploy
git push dokku main
```

That's it. Your app is live at `http://myapp.yourdomain.com` from any device on your Tailnet.

### Example: Deploy a Node.js App

```bash
mkdir hello-world && cd hello-world
git init

cat > server.js << 'EOF'
const http = require('http');
const port = process.env.PORT || 5000;
http.createServer((req, res) => {
  res.end('Hello from Dokku!\n');
}).listen(port, () => console.log(`Listening on ${port}`));
EOF

cat > Dockerfile << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY server.js .
ENV PORT=5000
EXPOSE 5000
CMD ["node", "server.js"]
EOF

git add . && git commit -m "Initial commit"
git remote add dokku ssh://dokku@YOUR_SERVER:3022/hello
git push dokku main
```

### Managing Apps

```bash
# List apps
docker exec dokku dokku apps:list

# View logs
docker exec dokku dokku logs myapp -t

# Restart
docker exec dokku dokku ps:restart myapp

# Stop
docker exec dokku dokku ps:stop myapp

# Delete
docker exec dokku dokku apps:destroy myapp --force
```

### Environment Variables

```bash
# Set variables
docker exec dokku dokku config:set myapp DATABASE_URL=postgres://...

# View variables
docker exec dokku dokku config:show myapp
```

### Persistent Storage

```bash
# Create and mount storage
docker exec dokku dokku storage:ensure-directory myapp-data
docker exec dokku dokku storage:mount myapp /var/lib/dokku/data/storage/myapp-data:/app/data
docker exec dokku dokku ps:restart myapp
```

---

## Exposing Apps Publicly

By default, apps are only accessible via Tailscale. To make an app publicly accessible:

### Option 1: Tailscale Funnel (Easiest)

Tailscale Funnel exposes your service through Tailscale's infrastructure with automatic HTTPS.

```bash
# On your server
tailscale funnel --bg 443
```

Then add a CNAME record for your public domain pointing to your Tailscale hostname:
```
public.yourdomain.com → your-machine.tailnet-name.ts.net
```

### Option 2: Cloudflare Tunnel (More Control)

For custom domains without exposing your IP:

1. Install cloudflared: `brew install cloudflared`
2. Authenticate: `cloudflared tunnel login`
3. Create tunnel: `cloudflared tunnel create homelab`
4. Configure routing in `~/.cloudflared/config.yml`:
   ```yaml
   tunnel: YOUR_TUNNEL_ID
   credentials-file: /path/to/credentials.json

   ingress:
     - hostname: app.yourdomain.com
       service: http://localhost:80
     - service: http_status:404
   ```
5. Add CNAME in Cloudflare DNS: `app.yourdomain.com → YOUR_TUNNEL_ID.cfargotunnel.com`
6. Run: `cloudflared tunnel run homelab`

### Option 3: Traditional Port Forwarding

Forward ports 80/443 on your router to your server. Consider:
- Setting a static IP or DHCP reservation
- Using a dynamic DNS service if you don't have a static public IP
- Adding SSL via Let's Encrypt: `docker exec dokku dokku letsencrypt:enable myapp`

---

## Extending Your Setup

### Adding New Services

The pattern for adding services:

1. Create a directory with a `Dockerfile` or `docker-compose.yml`
2. Deploy to Dokku or run standalone
3. Add DNS entry in Pi-hole
4. Access via your custom domain

### Database Services

```bash
# PostgreSQL plugin
docker exec dokku dokku plugin:install https://github.com/dokku/dokku-postgres.git

# Create database
docker exec dokku dokku postgres:create mydb

# Link to app
docker exec dokku dokku postgres:link mydb myapp
```

Similar plugins exist for Redis, MySQL, MongoDB, and more. See [Dokku Plugins](https://dokku.com/docs/community/plugins/).

### Monitoring (Example)

Deploy Uptime Kuma for monitoring your services:

```bash
docker exec dokku dokku apps:create uptime
docker exec dokku dokku domains:set uptime status.yourdomain.com
docker exec dokku dokku storage:ensure-directory uptime-data
docker exec dokku dokku storage:mount uptime /var/lib/dokku/data/storage/uptime-data:/app/data

# Clone and push
git clone https://github.com/louislam/uptime-kuma.git
cd uptime-kuma
git remote add dokku ssh://dokku@YOUR_SERVER:3022/uptime
git push dokku master
```

---

## Maintenance

### Updating Dokku

```bash
cd ~/homelab/dokku
docker compose pull
docker compose up -d
```

### Updating Pi-hole

```bash
docker pull pihole/pihole:latest
docker restart pihole
```

### Backup

Key data locations:
- `~/pihole/` - Pi-hole configuration and databases
- Dokku volume - App data (use `docker volume inspect dokku_data` to find path)

### Logs

```bash
# Startup log
cat /tmp/homelab-startup.log

# Pi-hole
docker logs pihole

# Dokku
docker logs dokku

# Specific app
docker exec dokku dokku logs myapp
```

---

## Troubleshooting

### DNS not resolving custom domains

1. Verify Pi-hole is running: `docker ps | grep pihole`
2. Check your device is using Tailscale DNS: `dig myapp.yourdomain.com`
3. Verify the hosts entry in `~/pihole/etc-pihole/pihole.toml`
4. Restart Pi-hole: `docker restart pihole`

### Can't push to Dokku

1. Verify your SSH key is registered:
   ```bash
   docker exec dokku dokku ssh-keys:list
   ```
2. Check your git remote uses the correct port:
   ```bash
   git remote -v
   # Should show: ssh://dokku@host:3022/appname
   ```
3. Test SSH connection:
   ```bash
   ssh -p 3022 dokku@YOUR_SERVER
   ```

### Services not starting after reboot

```bash
# Check startup log
cat /tmp/homelab-startup.log

# Manually start
colima start --network-address
docker restart pihole dokku
```

### Port conflicts

```bash
lsof -i :80
lsof -i :443
```

---

## Uninstall

```bash
./uninstall.sh
```

This removes containers and startup services but preserves your data. See script output for optional cleanup commands.

## File Locations

| Path | Purpose |
|------|---------|
| `~/pihole/` | Pi-hole configuration and data |
| `~/homelab/dokku/` | Dokku compose file (generated) |
| `/Library/LaunchDaemons/com.homelab.*` | Startup services |
| `/usr/local/bin/homelab-startup.sh` | Boot script |

## License

MIT
