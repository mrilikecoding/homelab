# Homelab

Your own Heroku, running on a Mac. A lightweight platform for deploying containerized apps with a familiar CLI experience — `homelab deploy` and you're live.

```bash
homelab deploy myapp --create   # First deploy: creates app + deploys
homelab logs -t                 # Tail logs (auto-detects app from git remote)
homelab config:set KEY=value    # Set environment variables
```

Built on [Dokku](https://dokku.com), secured with [Tailscale](https://tailscale.com), with optional network-wide ad blocking via Pi-hole.

## What You Get

- **Heroku-like CLI** - `homelab deploy`, `homelab logs`, `homelab config` — muscle memory transfers
- **Git push to deploy** - Push code, get a running app at `myapp.homelab.yourdomain.com`
- **Auto-detection** - CLI detects app name from git remote, no need to specify it every time
- **Private by default** - Everything accessible only via Tailscale VPN
- **Custom domains** - Wildcard DNS for automatic subdomain routing
- **AI-friendly setup** - Self-documenting API that Claude (or any agent) can follow
- **Network-wide ad blocking** - Pi-hole for all devices on your network

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
# 1. Set your server's Tailscale IP
HOMELAB_IP="your-tailscale-ip"

# 2. Trust the host key
ssh-keyscan -p 3022 $HOMELAB_IP >> ~/.ssh/known_hosts

# 3. Add SSH config (idempotent)
grep -q "Host dokku" ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config << EOF

Host dokku
  HostName $HOMELAB_IP
  Port 3022
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF

# 4. Add your SSH key to Dokku (replace YOUR_USER and KEYNAME)
cat ~/.ssh/id_ed25519.pub | ssh YOUR_USER@$HOMELAB_IP "/usr/local/bin/docker exec -i dokku dokku ssh-keys:add KEYNAME"

# 5. Set your domain and PATH
echo 'export DOKKU_DOMAIN=yourdomain.com' >> ~/.zshrc
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 6. Install homelab CLI (no sudo needed)
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/homelab https://raw.githubusercontent.com/mrilikecoding/homelab/main/homelab
chmod +x ~/.local/bin/homelab
```

---

## Deploying Apps

### First Deploy (New App)

```bash
cd my-app
homelab deploy myapp --create
```

This:
1. Creates the app in Dokku
2. Sets domain to `myapp.homelab.YOURDOMAIN`
3. Adds a `dokku` git remote to your repo
4. Pushes and builds your code

### Subsequent Deploys

```bash
homelab deploy
```

The CLI auto-detects the app name from your git remote, so you don't need to specify it after the first deploy.

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
homelab deploy hello --create
```

Visit `http://hello.homelab.YOURDOMAIN`

---

## Setup API

The homelab includes a self-documenting API at `http://api.homelab.YOURDOMAIN` that provides:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Overview and available endpoints |
| `GET /setup` | Human-readable setup instructions (markdown) |
| `GET /setup/agent` | Machine-readable setup for AI assistants (JSON) |
| `GET /ssh-config` | SSH config snippet ready to append |
| `GET /deploy-script` | The homelab CLI script |
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
4. Install the homelab CLI
5. Set the required environment variables

---

## Homelab CLI Reference

The `homelab` CLI provides a Heroku-like interface for Dokku:

```
Usage: homelab <command> [options]

App Management:
  apps                    List all apps
  create <name>           Create a new app (adds git remote)
  destroy <name>          Permanently delete an app

Deployment:
  deploy [name] [--create]  Deploy app (auto-detects from git remote)
  deploy [name] -b <branch> Deploy specific branch

Runtime:
  logs [name] [-t]        View logs (-t to tail/follow)
  ps [name]               Show running processes
  run <name> <cmd>        Run one-off command
  restart [name]          Restart app
  stop [name]             Stop app
  start [name]            Start app

Configuration:
  config [name]           Show config vars
  config:set <name> K=V   Set config vars
  config:unset <name> K   Unset config vars
  domains [name]          Show domains

Utilities:
  url [name]              Show app URL
  ssh                     Interactive dokku shell
  dokku <cmd>             Pass-through to dokku
```

**Auto-detection:** When run from a git repo with a `dokku` remote, commands like `deploy`, `logs`, `ps`, `config`, and `url` automatically detect the app name.

---

## Managing Apps

The `homelab` CLI provides Heroku-like commands for managing your apps:

```bash
homelab apps                    # List all apps
homelab logs myapp              # View logs
homelab logs myapp -t           # Tail/follow logs
homelab ps myapp                # Show process status
homelab restart myapp           # Restart app
homelab config myapp            # Show config vars
homelab config:set myapp KEY=val  # Set config var
homelab run myapp bash          # Run one-off command
homelab destroy myapp           # Delete app (with confirmation)
```

When you're inside a repo with a `dokku` git remote, you can omit the app name:

```bash
cd my-app
homelab logs                    # Auto-detects app from git remote
homelab restart
homelab config
```

### Direct Dokku Access

For commands not wrapped by the CLI, use pass-through:

```bash
homelab dokku nginx:show-config myapp
homelab ssh                     # Interactive dokku shell
```

---

## HTTPS Setup

By default, apps use HTTP. To enable HTTPS with valid Let's Encrypt certificates:

```bash
homelab https:setup
```

This interactive wizard will:
1. Install certbot and your DNS provider's plugin
2. Request a wildcard certificate for `*.homelab.YOURDOMAIN`
3. Configure Dokku to use the certificate
4. Set up automatic weekly renewal

### Supported DNS Providers

The certificate setup uses DNS-01 validation, which works without exposing your homelab publicly. Supported providers:

| Provider | Plugin | API Key Location |
|----------|--------|------------------|
| Porkbun | `certbot-dns-porkbun` | https://porkbun.com/account/api |
| Cloudflare | `certbot-dns-cloudflare` | https://dash.cloudflare.com/profile/api-tokens |
| Route 53 | `certbot-dns-route53` | AWS IAM credentials |
| Google Cloud | `certbot-dns-google` | Service account JSON |
| DigitalOcean | `certbot-dns-digitalocean` | https://cloud.digitalocean.com/account/api/tokens |
| Namecheap | `certbot-dns-namecheap` | https://ap.www.namecheap.com/settings/tools/apiaccess/ |
| Manual | N/A | You add TXT records manually |

### HTTPS Commands

```bash
homelab https:setup    # Initial setup (interactive)
homelab https:status   # Show certificate info
homelab https:renew    # Manually renew certificates
```

### Configuration

Add to `config.sh` to skip prompts:

```bash
LETSENCRYPT_EMAIL="you@example.com"
CERTBOT_DNS_PLUGIN="porkbun"  # or cloudflare, route53, etc.
```

---

## Exposing Apps Publicly

By default, apps are only accessible via Tailscale. To make specific apps publicly accessible while keeping everything else private, use Cloudflare Tunnel.

### Quick Start

```bash
# One-time setup (requires Cloudflare account with your domain)
homelab tunnel:setup

# Make an app public
homelab public myapp                    # → https://myapp.yourdomain.com
homelab public myapp api.yourdomain.com # → custom hostname

# Make it private again
homelab private myapp

# List public apps
homelab public:list
```

### How It Works

```
Internet                              Your Tailnet (Private)
────────                              ──────────────────────
myapp.nate.green ──► Cloudflare ──► Tunnel ──► Dokku ──► myapp
                         │
                         ✗ Cannot reach *.homelab.nate.green
```

- Only apps you explicitly make public are accessible
- `*.homelab.YOURDOMAIN` stays completely private (Tailnet-only)
- Cloudflare handles HTTPS for the public hostname
- You can use any hostname on your domain

### Tunnel Commands

```bash
homelab tunnel:setup    # Initial Cloudflare Tunnel setup
homelab tunnel:status   # Show tunnel status and public apps
homelab tunnel:restart  # Restart the tunnel
homelab tunnel:logs     # View tunnel logs
homelab tunnel:logs -f  # Follow tunnel logs
```

### Alternative: Tailscale Funnel

For quick, temporary sharing without Cloudflare:

```bash
# On your server
tailscale funnel --bg 443
```

This exposes your entire port 443 via `your-machine.tailnet-name.ts.net`. Less control, but simpler for one-off sharing.

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
| `~/homelab/dokku/certs/` | SSL certificates for Dokku |
| `~/pihole/` | Pi-hole config and data |
| `~/.homelab/certs/` | Let's Encrypt certificate storage |
| `~/.homelab/credentials/` | DNS provider API credentials |
| `~/.cloudflared/` | Cloudflare Tunnel config |
| `/Library/LaunchDaemons/com.homelab.*` | Startup services |

### Dev Machine

| Path | Purpose |
|------|---------|
| `~/.ssh/config` | SSH config with dokku host |
| `~/.local/bin/homelab` | Homelab CLI |
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
