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
