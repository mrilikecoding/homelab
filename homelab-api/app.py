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
HOMELAB_USER = os.environ.get('HOMELAB_USER', '')  # Username for SSH to homelab server


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
    ssh "$DOKKU_HOST" domains:set "$APP_NAME" "$APP_NAME.homelab.$DOKKU_DOMAIN"
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
echo "Deployed: http://$APP_NAME.homelab.$DOKKU_DOMAIN"'''


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
    user_str = HOMELAB_USER if HOMELAB_USER else 'YOUR_USER'
    user_note = '' if HOMELAB_USER else '\n\nReplace YOUR_USER with your username on the homelab server.'

    return f"""# Homelab Remote Machine Setup

## Prerequisites
- Connected to the same Tailnet as the homelab server
- SSH key at ~/.ssh/id_ed25519 (will be created if missing)

## Step 1: Trust Host Key & Add SSH Config

```bash
# Trust the host key
ssh-keyscan -p {SSH_PORT} {ip} >> ~/.ssh/known_hosts

# Add SSH config (if not already present)
grep -q "Host dokku" ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config << 'EOF'

Host dokku
  HostName {ip}
  Port {SSH_PORT}
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
```

## Step 2: Add Your SSH Key to Dokku

Run this command (you'll need to authenticate to the server):

```bash
cat ~/.ssh/id_ed25519.pub | ssh {user_str}@{ip} "docker exec -i dokku dokku ssh-keys:add $(whoami)"
```{user_note}

## Step 3: Set Environment Variable

Add to your shell profile (~/.zshrc or ~/.bashrc):

```bash
export DOKKU_DOMAIN="{DOMAIN}"
export PATH="$HOME/.local/bin:$PATH"
```

Then run: source ~/.zshrc

## Step 4: Install Deploy Script

```bash
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/deploy {GITHUB_REPO}/raw/main/deploy
chmod +x ~/.local/bin/deploy
```

## Step 5: Deploy an App

```bash
cd your-app
deploy myapp --create   # First time
deploy myapp            # Updates
```

Your app will be at: http://myapp.homelab.{DOMAIN}"""


@app.get("/setup/agent")
async def setup_agent():
    """Machine-readable setup for AI assistants."""
    ip = get_tailscale_ip()

    # Build the SSH key registration command
    # Use full docker path and a descriptive key name instead of $(whoami) which expands locally
    if HOMELAB_USER:
        ssh_key_cmd = f'KEYNAME="$(hostname -s)" && cat ~/.ssh/id_ed25519.pub | ssh {HOMELAB_USER}@{ip} "/usr/local/bin/docker exec -i dokku dokku ssh-keys:add $KEYNAME"'
        ssh_key_note = f'User will be prompted for {HOMELAB_USER}\'s password on the homelab server. Key will be named after this machine\'s hostname.'
    else:
        ssh_key_cmd = f'KEYNAME="$(hostname -s)" && cat ~/.ssh/id_ed25519.pub | ssh USER@{ip} "/usr/local/bin/docker exec -i dokku dokku ssh-keys:add $KEYNAME"'
        ssh_key_note = 'Replace USER with the username on the homelab server. User will be prompted for password. Key will be named after this machine\'s hostname.'

    return {
        'instructions': 'Follow these steps to configure this machine for homelab deployments',
        'config': {
            'domain': DOMAIN,
            'tailscale_ip': ip,
            'ssh_port': SSH_PORT,
            'github_repo': GITHUB_REPO,
            'homelab_user': HOMELAB_USER or None
        },
        'preflight': {
            'name': 'Check connectivity to homelab',
            'check': f'ping -c1 -W2 {ip} >/dev/null 2>&1',
            'error': f'Cannot reach homelab server at {ip}. Are you connected to the Tailnet?'
        },
        'steps': [
            {
                'step': 1,
                'name': 'Trust host key',
                'description': 'Add homelab server to known_hosts (idempotent)',
                'run_as': 'agent',
                'command': f'mkdir -p ~/.ssh && (ssh-keygen -F "[{ip}]:{SSH_PORT}" >/dev/null 2>&1 || ssh-keyscan -p {SSH_PORT} {ip} >> ~/.ssh/known_hosts 2>/dev/null)',
            },
            {
                'step': 2,
                'name': 'Ensure SSH key exists',
                'description': 'Generate SSH key if not present (idempotent)',
                'run_as': 'agent',
                'command': 'test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""',
            },
            {
                'step': 3,
                'name': 'Add SSH config',
                'description': 'Add dokku host to SSH config if not present (idempotent)',
                'run_as': 'agent',
                'command': f'''mkdir -p ~/.ssh && touch ~/.ssh/config && (grep -q "Host dokku" ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config << 'EOF'

Host dokku
  HostName {ip}
  Port {SSH_PORT}
  User dokku
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
)''',
            },
            {
                'step': 4,
                'name': 'Add SSH key to Dokku',
                'description': 'Register the SSH public key with Dokku. User must authenticate to the server.',
                'run_as': 'human',
                'requires_user_action': True,
                'command': ssh_key_cmd,
                'note': ssh_key_note,
                'verify': 'ssh -o BatchMode=yes dokku version'
            },
            {
                'step': 5,
                'name': 'Set DOKKU_DOMAIN and PATH in shell profile',
                'description': 'Add DOKKU_DOMAIN and ~/.local/bin to PATH if not present (idempotent, detects shell)',
                'run_as': 'agent',
                'command': f'''PROFILE="$HOME/.$(basename "$SHELL")rc" && touch "$PROFILE" && (grep -q "DOKKU_DOMAIN=" "$PROFILE" 2>/dev/null || echo 'export DOKKU_DOMAIN="{DOMAIN}"' >> "$PROFILE") && (grep -q 'local/bin' "$PROFILE" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$PROFILE")''',
            },
            {
                'step': 6,
                'name': 'Install deploy script',
                'description': 'Download deploy script to ~/.local/bin (idempotent, always fetches latest)',
                'run_as': 'agent',
                'command': f'mkdir -p ~/.local/bin && curl -fsSL -o ~/.local/bin/deploy {GITHUB_REPO}/raw/main/deploy && chmod +x ~/.local/bin/deploy',
            }
        ],
        'verification': {
            'command': 'ssh -o BatchMode=yes dokku version',
            'expected': 'Should output dokku version number without prompting for password'
        },
        'usage': {
            'first_deploy': 'deploy appname --create',
            'subsequent': 'deploy appname',
            'app_url_pattern': f'http://APPNAME.homelab.{DOMAIN}'
        }
    }
