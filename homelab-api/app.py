#!/usr/bin/env python3
"""
Homelab Setup API

A self-documenting API that provides setup instructions and configuration
for remote machines to deploy to this homelab.

Designed to be queried by Claude or other AI assistants to automate setup.
"""

import os
import subprocess
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, JSONResponse

app = FastAPI(
    title="Homelab Setup API",
    description="Self-documenting API for configuring remote machines to deploy to this homelab"
)

# Configuration from environment
DOMAIN = os.environ.get('DOKKU_DOMAIN', 'example.com')
TAILSCALE_IP = os.environ.get('TAILSCALE_IP', '')
SSH_PORT = os.environ.get('DOKKU_SSH_PORT', '3022')
GITHUB_REPO = os.environ.get('GITHUB_REPO', 'https://github.com/mrilikecoding/homelab')


def get_tailscale_ip():
    """Get the Tailscale IP if not configured."""
    if TAILSCALE_IP:
        return TAILSCALE_IP
    try:
        result = subprocess.run(['tailscale', 'ip', '-4'], capture_output=True, text=True)
        return result.stdout.strip()
    except:
        return 'YOUR_TAILSCALE_IP'


@app.get("/")
async def index():
    """API overview and available endpoints."""
    ip = get_tailscale_ip()
    return {
        'name': 'Homelab Setup API',
        'description': 'Self-documenting API for configuring remote machines to deploy to this homelab',
        'domain': DOMAIN,
        'tailscale_ip': ip,
        'endpoints': {
            '/': 'This overview',
            '/setup': 'Complete setup instructions (start here)',
            '/setup/agent': 'Machine-readable setup for AI assistants',
            '/ssh-config': 'SSH config snippet to append to ~/.ssh/config',
            '/deploy-script': 'The deploy script content',
            '/status': 'Current Dokku apps and their status',
            '/config': 'Server configuration details'
        },
        'quick_start': 'Fetch /setup/agent for automated setup instructions'
    }


@app.get("/config")
async def config():
    """Server configuration details."""
    ip = get_tailscale_ip()
    return {
        'domain': DOMAIN,
        'tailscale_ip': ip,
        'ssh_port': SSH_PORT,
        'ssh_user': 'dokku',
        'github_repo': GITHUB_REPO,
        'deploy_script_url': f'{GITHUB_REPO}/raw/main/deploy'
    }


@app.get("/ssh-config", response_class=PlainTextResponse)
async def ssh_config():
    """SSH config snippet ready to append."""
    ip = get_tailscale_ip()
    return f"""Host dokku
  HostName {ip}
  Port {SSH_PORT}
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes"""


@app.get("/deploy-script", response_class=PlainTextResponse)
async def deploy_script():
    """The deploy script content."""
    return '''#!/bin/bash
set -e

APP_NAME="$1"
CREATE_FLAG="$2"

DOKKU_HOST="${DOKKU_HOST:-dokku}"
DOKKU_DOMAIN="${DOKKU_DOMAIN:-}"

if [ -z "$APP_NAME" ]; then
    echo "Usage: deploy <app-name> [--create]"
    echo ""
    echo "Options:"
    echo "  --create    Create the app in Dokku first"
    echo ""
    echo "Environment variables (required):"
    echo "  DOKKU_DOMAIN   Your domain (e.g., example.com)"
    exit 1
fi

if [ -z "$DOKKU_DOMAIN" ]; then
    echo "Error: DOKKU_DOMAIN not set"
    echo "Run: export DOKKU_DOMAIN=yourdomain.com"
    exit 1
fi

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

if [ "$CREATE_FLAG" = "--create" ]; then
    echo "Creating app '$APP_NAME'..."
    ssh "$DOKKU_HOST" apps:create "$APP_NAME" || true
    ssh "$DOKKU_HOST" domains:set "$APP_NAME" "$APP_NAME.$DOKKU_DOMAIN"
fi

REMOTE_URL="$DOKKU_HOST:$APP_NAME"
if git remote get-url dokku > /dev/null 2>&1; then
    git remote set-url dokku "$REMOTE_URL"
else
    git remote add dokku "$REMOTE_URL"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Deploying $APP_NAME..."
git push dokku "$BRANCH:main"

echo ""
echo "Deployed: http://$APP_NAME.$DOKKU_DOMAIN"'''


@app.get("/status")
async def status():
    """Current Dokku apps status."""
    return {
        'note': 'Run "ssh dokku apps:list" to see deployed apps',
        'domain': DOMAIN,
        'check_command': 'ssh dokku apps:list'
    }


@app.get("/setup", response_class=PlainTextResponse)
async def setup():
    """Human-readable setup instructions."""
    ip = get_tailscale_ip()
    return f"""# Homelab Remote Machine Setup

## Prerequisites
- Connected to the same Tailnet as the homelab server
- SSH key at ~/.ssh/id_ed25519

## Step 1: Add SSH Config

Append to ~/.ssh/config:

```
Host dokku
  HostName {ip}
  Port {SSH_PORT}
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

## Step 2: Add Your SSH Key to Dokku

Run this command (you'll need to authenticate to the server):

```bash
cat ~/.ssh/id_ed25519.pub | ssh YOUR_USER@{ip} "docker exec -i dokku dokku ssh-keys:add $(whoami)"
```

Replace YOUR_USER with your username on the homelab server.

## Step 3: Set Environment Variable

Add to your shell profile (~/.zshrc or ~/.bashrc):

```bash
export DOKKU_DOMAIN="{DOMAIN}"
```

Then run: source ~/.zshrc

## Step 4: Install Deploy Script

```bash
sudo curl -o /usr/local/bin/deploy {GITHUB_REPO}/raw/main/deploy
sudo chmod +x /usr/local/bin/deploy
```

## Step 5: Deploy an App

```bash
cd your-app
deploy myapp --create   # First time
deploy myapp            # Updates
```

Your app will be at: http://myapp.{DOMAIN}"""


@app.get("/setup/agent")
async def setup_agent():
    """Machine-readable setup for AI assistants."""
    ip = get_tailscale_ip()
    return {
        'instructions': 'Follow these steps to configure this machine for homelab deployments',
        'config': {
            'domain': DOMAIN,
            'tailscale_ip': ip,
            'ssh_port': SSH_PORT,
            'github_repo': GITHUB_REPO
        },
        'steps': [
            {
                'step': 1,
                'name': 'Check SSH key exists',
                'description': 'Verify ~/.ssh/id_ed25519 exists, or generate one',
                'command': 'test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""',
                'check': 'test -f ~/.ssh/id_ed25519'
            },
            {
                'step': 2,
                'name': 'Add SSH config',
                'description': 'Add dokku host to SSH config if not present',
                'check': 'grep -q "Host dokku" ~/.ssh/config 2>/dev/null',
                'command': f'''cat >> ~/.ssh/config << 'EOF'

Host dokku
  HostName {ip}
  Port {SSH_PORT}
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF''',
                'skip_if_check_passes': True
            },
            {
                'step': 3,
                'name': 'Add SSH key to Dokku',
                'description': 'Register the SSH public key with Dokku. User must authenticate to the server.',
                'requires_user_action': True,
                'command': f'cat ~/.ssh/id_ed25519.pub | ssh USER@{ip} "docker exec -i dokku dokku ssh-keys:add $(whoami)"',
                'note': 'Replace USER with the username on the homelab server. User will be prompted for password.',
                'verify': 'ssh dokku version'
            },
            {
                'step': 4,
                'name': 'Set DOKKU_DOMAIN environment variable',
                'description': 'Add domain to shell profile',
                'check': f'grep -q "DOKKU_DOMAIN=" ~/.zshrc 2>/dev/null || grep -q "DOKKU_DOMAIN=" ~/.bashrc 2>/dev/null',
                'command_zsh': f'echo \'export DOKKU_DOMAIN="{DOMAIN}"\' >> ~/.zshrc && source ~/.zshrc',
                'command_bash': f'echo \'export DOKKU_DOMAIN="{DOMAIN}"\' >> ~/.bashrc && source ~/.bashrc',
                'skip_if_check_passes': True
            },
            {
                'step': 5,
                'name': 'Install deploy script',
                'description': 'Download and install the deploy helper script',
                'check': 'test -x /usr/local/bin/deploy',
                'command': f'sudo curl -o /usr/local/bin/deploy {GITHUB_REPO}/raw/main/deploy && sudo chmod +x /usr/local/bin/deploy',
                'skip_if_check_passes': True
            }
        ],
        'verification': {
            'command': 'ssh dokku version',
            'expected': 'Should output dokku version number'
        },
        'usage': {
            'first_deploy': 'deploy appname --create',
            'subsequent': 'deploy appname',
            'app_url_pattern': f'http://APPNAME.{DOMAIN}'
        }
    }
