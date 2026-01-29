#!/bin/bash

# Copy this file to config.sh and edit for your setup

# =============================================================================
# Pi-hole settings
# =============================================================================
PIHOLE_PASSWORD="change-me"
PIHOLE_TIMEZONE="America/Los_Angeles"
PIHOLE_UPSTREAM_DNS="1.1.1.1;8.8.8.8"

# =============================================================================
# Colima VM resources
# =============================================================================
COLIMA_CPUS=2
COLIMA_MEMORY=4

# =============================================================================
# Dokku settings
# =============================================================================
# The hostname Dokku will use (your Tailscale MagicDNS name)
DOKKU_HOSTNAME="ng-mini.corgi-woodpecker.ts.net"

# SSH port for git push (3022 avoids conflict with macOS SSH on 22)
DOKKU_SSH_PORT=3022

# =============================================================================
# Domain settings
# =============================================================================
# Base domain for your apps (Pi-hole will resolve these via local DNS)
# Examples: "nate.green", "home.lan", "apps.local"
APP_DOMAIN="nate.green"

# Your server's Tailscale IP (found via: tailscale ip -4)
TAILSCALE_IP=""  # Will be auto-detected if left empty

# =============================================================================
# Homelab API settings
# =============================================================================
# Username for SSH access to this homelab server (for remote machine setup)
# This enables fully automated setup - agents won't need to ask for the username
HOMELAB_USER=""  # e.g., "nate" - leave empty to require manual entry

# =============================================================================
# HTTPS / Let's Encrypt settings
# =============================================================================
# Email for Let's Encrypt certificate notifications
LETSENCRYPT_EMAIL=""  # e.g., "you@example.com"

# DNS provider for certificate validation (optional - will prompt if not set)
# Supported: porkbun, cloudflare, route53, google, digitalocean, namecheap, manual
CERTBOT_DNS_PLUGIN=""  # e.g., "porkbun"

# =============================================================================
# Circuit Breaker settings (auto-disables public apps if overloaded)
# =============================================================================
# CPU percentage threshold (0-100)
CIRCUIT_BREAKER_CPU_THRESHOLD=80

# Load average threshold (1-minute)
CIRCUIT_BREAKER_LOAD_THRESHOLD=4.0

# Number of consecutive high-load checks before tripping
CIRCUIT_BREAKER_CHECKS=3

# Optional: Webhook URL for notifications (Slack, Discord, etc.)
# CIRCUIT_BREAKER_WEBHOOK="https://hooks.slack.com/services/xxx"

# =============================================================================
# Cloudflare R2 settings (for backups and object storage)
# =============================================================================
R2_ACCOUNT_ID=""
R2_ACCESS_KEY_ID=""
R2_SECRET_ACCESS_KEY=""
R2_BACKUP_BUCKET="nextcloud-backup"
R2_REGION="auto"
