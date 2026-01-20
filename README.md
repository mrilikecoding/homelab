# Homelab

A lightweight, extensible platform for running a combined homelab and development server on macOS. Deploy containerized apps with `git push`, access everything securely via Tailscale, and optionally expose services to the public internet.

## What You Get

- **Git push to deploy** - Push code, get a running app (like Heroku, but yours)
- **Network-wide ad blocking** - Pi-hole for all devices on your network
- **Private by default** - Everything accessible only via Tailscale VPN
- **Custom domains** - Wildcard DNS for automatic subdomain routing
- **Zero config deploys** - Deploy from any machine with one command
- **Self-documenting API** - Query the server for setup instructions

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Your Mac (Homelab Server)                                       │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ Colima (Docker VM)                                      │   │
│   │                                                         │   │
│   │   ┌─────────────┐     ┌─────────────────────────────┐   │   │
│   │   │   Pi-hole   │     │         Dokku               │   │   │
│   │   │  DNS + Web  │     │   ┌─────┐ ┌─────┐ ┌─────┐   │   │   │
│   │   │             │     │   │ app │ │ app │ │ api │   │   │   │
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

## Quick Start (Server Setup)

```bash
git clone https://github.com/mrilikecoding/homelab.git
cd homelab

cp config.example.sh config.sh
# Edit config.sh with your settings

./install.sh
```

After installation, configure Tailscale DNS:

1. Go to https://login.tailscale.com/admin/dns
2. Add **Split DNS**: `homelab.YOURDOMAIN` → `YOUR_TAILSCALE_IP`
3. (Optional) Add your Tailscale IP as a **Global Nameserver** for network-wide ad blocking

Your apps will be available at `*.homelab.YOURDOMAIN` (e.g., `myapp.homelab.nate.green`).

## Remote Machine Setup

### Option 1: Automated (with Claude)

If you have Claude on your dev machine, ask it:

> "Set up my machine to deploy to my homelab. The setup API is at http://api.homelab.YOURDOMAIN"

Claude will fetch the configuration and guide you through setup.

### Option 2: Manual Setup

On any machine connected to your Tailnet:

```bash
# 1. Get your server's Tailscale IP
HOMELAB_IP="your-tailscale-ip"

# 2. Add SSH config
cat >> ~/.ssh/config << EOF

Host dokku
  HostName $HOMELAB_IP
  Port 3022
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF

# 3. Add your SSH key to Dokku
cat ~/.ssh/id_ed25519.pub | ssh user@$HOMELAB_IP "docker exec -i dokku dokku ssh-keys:add $(whoami)"

# 4. Set your domain
echo 'export DOKKU_DOMAIN=yourdomain.com' >> ~/.zshrc
source ~/.zshrc

# 5. Install deploy script
sudo curl -o /usr/local/bin/deploy https://raw.githubusercontent.com/mrilikecoding/homelab/main/deploy
sudo chmod +x /usr/local/bin/deploy
```

---

## Deploying Apps

### First Deploy (New App)

```bash
cd my-app
deploy myapp --create
```

This:
1. Creates the app in Dokku
2. Sets domain to `myapp.homelab.YOURDOMAIN`
3. Pushes and builds your code

### Subsequent Deploys

```bash
deploy myapp
```

### What You Need

Your app needs one of:
- `Dockerfile` - Dokku builds and runs it
- Buildpack-compatible code (Node.js package.json, Python requirements.txt, etc.)

### Example: Deploy a Node.js App

```bash
mkdir hello && cd hello
git init

cat > server.js << 'EOF'
const http = require('http');
const port = process.env.PORT || 5000;
http.createServer((req, res) => {
  res.end('Hello from Dokku!\n');
}).listen(port);
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
deploy hello --create
```

Visit `http://hello.homelab.YOURDOMAIN`

---

## Setup API

The homelab includes a self-documenting API at `http://api.homelab.YOURDOMAIN` that provides:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Overview and available endpoints |
| `GET /setup` | Complete setup instructions for remote machines |
| `GET /ssh-config` | SSH config snippet ready to append |
| `GET /deploy-script` | The deploy script content |
| `GET /status` | Current Dokku apps and their status |
| `GET /config` | Server configuration (domain, IPs, ports) |

### Using with Claude

On a new dev machine, tell Claude:

```
Fetch http://api.homelab.YOURDOMAIN/setup and configure this machine to deploy apps to my homelab.
```

Claude will:
1. Fetch the setup instructions
2. Create the SSH config
3. Guide you through adding your SSH key
4. Install the deploy script
5. Set the required environment variables

---

## Managing Apps

```bash
# Via SSH (from any machine)
ssh dokku apps:list
ssh dokku logs myapp -t
ssh dokku ps:restart myapp
ssh dokku config:set myapp KEY=value
ssh dokku apps:destroy myapp --force
```

---

## Exposing Apps Publicly

By default, apps are only accessible via Tailscale.

### Tailscale Funnel (Easiest)

```bash
# On your server
tailscale funnel --bg 443
```

Add a CNAME: `public.yourdomain.com → your-machine.tailnet-name.ts.net`

### Cloudflare Tunnel

```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create homelab
# Configure ~/.cloudflared/config.yml
cloudflared tunnel run homelab
```

---

## Configuration

### config.example.sh

```bash
# Pi-hole
PIHOLE_PASSWORD="your-password"
PIHOLE_TIMEZONE="America/Los_Angeles"

# Dokku
DOKKU_HOSTNAME="your-machine.tailnet-name.ts.net"
DOKKU_SSH_PORT=3022

# Your domain for apps
APP_DOMAIN="yourdomain.com"
```

### Environment Variables (Dev Machine)

| Variable | Description | Example |
|----------|-------------|---------|
| `DOKKU_DOMAIN` | Your app domain (required) | `nate.green` |
| `DOKKU_HOST` | SSH host alias (optional) | `dokku` |

---

## File Locations

### Server

| Path | Purpose |
|------|---------|
| `~/homelab/` | This repo |
| `~/pihole/` | Pi-hole config and data |
| `/Library/LaunchDaemons/com.homelab.*` | Startup services |

### Dev Machine

| Path | Purpose |
|------|---------|
| `~/.ssh/config` | SSH config with dokku host |
| `/usr/local/bin/deploy` | Deploy script |
| `DOKKU_DOMAIN` env var | Your domain |

---

## Maintenance

### Update Dokku

```bash
cd ~/homelab/dokku
docker compose pull
docker compose up -d
```

### View Logs

```bash
# Startup log
cat /tmp/homelab-startup.log

# App logs
ssh dokku logs myapp
```

### Backup

Key data:
- `~/pihole/` - Pi-hole config
- Dokku volume - `docker volume inspect dokku_data`

---

## Troubleshooting

### Can't connect to dokku host

```bash
# Test SSH
ssh -v dokku version

# Check Tailscale
tailscale status
```

### DNS not resolving

```bash
# Check Pi-hole
dig myapp.homelab.yourdomain.com @YOUR_TAILSCALE_IP

# Restart Pi-hole
docker restart pihole
```

Ensure Tailscale Split DNS is configured:
1. Go to https://login.tailscale.com/admin/dns
2. Add Split DNS: `homelab.YOURDOMAIN` → `YOUR_TAILSCALE_IP`

### Deploy fails

```bash
# Check app exists
ssh dokku apps:list

# Check logs
ssh dokku logs myapp
```

---

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
