# Homelab Diagnostics Guide

Troubleshooting reference for the homelab stack: Colima VM, Pi-hole, Dokku, socat DNS forwarding, Tailscale, and Cloudflare Tunnel.

## Architecture

### DNS Chain

```
Client device
  │
  ▼
Tailscale Split DNS (homelab.nate.green → server Tailscale IP)
  │
  ▼
socat on Mac (UDP :53 on Tailscale IP → Colima VM IP :53)
  │  LaunchDaemon: com.homelab.dns
  │  Plist: /Library/LaunchDaemons/com.homelab.dns.plist
  ▼
Colima VM (port 53)
  │
  ▼
Pi-hole (docker, --network=host)
  │  Container: pihole
  │  Config: ~/pihole/etc-pihole/pihole.toml
  ▼
Upstream DNS (1.1.1.1, 8.8.8.8)
```

Key detail: socat binds to the **Tailscale IP** on the Mac and forwards UDP to the **Colima VM IP**. If either IP changes (Colima restart, VM crash), the chain breaks and all Tailscale clients lose DNS for `*.homelab.nate.green`.

### HTTP Chain

```
Client device
  │
  ▼
Tailscale (or Cloudflare Tunnel for public apps)
  │
  ▼
Mac host ports 80/443
  │  (Docker port mapping from Colima VM)
  ▼
Dokku container (nginx reverse proxy)
  │  Container: dokku
  │  Compose: ~/homelab/dokku/docker-compose.yml
  ▼
App container (per-app, managed by Dokku)
```

---

## Failure Mode Table

| # | Failure | Symptoms | Root Cause | Diagnosis | Fix |
|---|---------|----------|------------|-----------|-----|
| 1 | Colima IP loss | All DNS and HTTP fails; `colima list` shows no IP or different IP than `.env` | Colima restarted without `--network-address`, or VM crashed | `colima list -j \| grep address` | `colima stop && colima start --network-address`; kill dnsmasq in VM; restart containers; update `.env` and socat plist |
| 2 | Pi-hole listening mode | DNS queries from Tailscale clients get dropped; local queries on the VM still work | `dns.listeningMode` set to `LOCAL` instead of `ALL` | `docker exec pihole pihole-FTL --config dns.listeningMode` | `docker exec pihole pihole-FTL --config dns.listeningMode ALL` |
| 3 | dnsmasq conflict | Pi-hole can't bind port 53; DNS fails even though Pi-hole container is running | Colima's built-in dnsmasq grabbed port 53 on VM restart | `colima ssh -- ss -ulnp \| grep :53` | `colima ssh -- sudo pkill dnsmasq`; restart pihole container |
| 4 | socat not running | DNS queries time out; HTTP still works | socat process died or LaunchDaemon failed to load | `pgrep -f 'socat.*UDP-RECVFROM:53'` | `sudo launchctl kickstart -k system/com.homelab.dns` |
| 5 | socat stale target | DNS queries time out; socat is running but forwarding to wrong IP | Colima IP changed but plist still has old IP | Check plist `UDP-SENDTO` IP vs `colima list -j` IP | Rewrite plist with correct IP; `sudo launchctl kickstart -k system/com.homelab.dns` |
| 6 | Tailscale disconnected | Can't reach server at all from other devices | Tailscale app not running or logged out | `tailscale status` on server | Start Tailscale app; re-authenticate if needed |
| 7 | Cloudflare Tunnel down | Public apps unreachable; private (Tailscale) access still works | Tunnel daemon crashed or not loaded | `sudo launchctl list \| grep com.homelab.tunnel` | `sudo launchctl kickstart -k system/com.homelab.tunnel` |
| 8 | Containers stopped | Apps return 502/connection refused; DNS may also fail | Docker containers stopped (crash, OOM, manual stop) | `docker ps --format '{{.Names}} {{.Status}}'` | `docker start pihole dokku` |
| 9 | TLS certs expired | Browser shows certificate warnings; HTTPS fails | Let's Encrypt certs not renewed | `openssl x509 -enddate -noout -in ~/homelab/dokku/certs/server.crt` | Run `renew-certs.sh` |

---

## Layer-by-Layer Diagnosis

When DNS or HTTP stops working, walk through each layer from the client inward.

### 1. Client connectivity

```bash
# Can you reach the server at all?
ping $SERVER_TAILSCALE_IP

# Is Tailscale connected?
tailscale status
```

If ping fails, check Tailscale on both client and server.

### 2. DNS forwarding (socat)

```bash
# Is socat running on the server Mac?
pgrep -f 'socat.*UDP-RECVFROM:53'

# What IP is socat forwarding to?
sudo cat /Library/LaunchDaemons/com.homelab.dns.plist | grep UDP-SENDTO

# Does the Colima IP match?
colima list -j | grep address

# Test DNS directly through the Tailscale IP
dig @$TAILSCALE_IP google.com +short +timeout=3
```

If socat is running but forwarding to a stale IP, the plist needs updating.

### 3. Colima VM

```bash
# Is the VM running with a routable IP?
colima list

# Is dnsmasq competing for port 53?
colima ssh -- ss -ulnp | grep :53

# If dnsmasq is there, kill it
colima ssh -- sudo pkill dnsmasq
```

### 4. Pi-hole

```bash
# Is the container running?
docker ps --filter name=pihole --format '{{.Names}} {{.Status}}'

# Is it listening on all interfaces (not just local)?
docker exec pihole pihole-FTL --config dns.listeningMode
# Should return: ALL

# Test DNS from inside the VM
colima ssh -- dig @127.0.0.1 google.com +short
```

### 5. HTTP / Dokku

```bash
# Is the Dokku container running?
docker ps --filter name=dokku --format '{{.Names}} {{.Status}}'

# Can you reach the web server?
curl -sI http://$TAILSCALE_IP

# Check a specific app
curl -sI -H "Host: myapp.homelab.nate.green" http://$TAILSCALE_IP
```

### 6. Cloudflare Tunnel (public apps)

```bash
# Is the tunnel daemon loaded?
sudo launchctl list | grep com.homelab.tunnel

# Check tunnel logs
cat /tmp/homelab-tunnel.log | tail -20

# Restart the tunnel
sudo launchctl kickstart -k system/com.homelab.tunnel
```

---

## Recovery Procedures

### DNS Outage Recovery (the compound failure)

This procedure addresses the scenario where Colima IP loss + Pi-hole listening mode + dnsmasq conflict all combine to break DNS.

```bash
# 1. Restart Colima with a routable IP
colima stop
colima start --network-address

# 2. Kill dnsmasq inside the VM (it grabs port 53 on restart)
colima ssh -- sudo pkill dnsmasq

# 3. Get the new Colima IP
COLIMA_IP=$(colima list -j | grep -o '"address":"[^"]*"' | cut -d'"' -f4)
echo "New Colima IP: $COLIMA_IP"

# 4. Update the .env file
TAILSCALE_IP=$(tailscale ip -4)
cat > ~/homelab/.env << EOF
COLIMA_IP=$COLIMA_IP
TAILSCALE_IP=$TAILSCALE_IP
EOF

# 5. Update the socat plist with the new Colima IP
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

# 6. Restart socat
sudo launchctl kickstart -k system/com.homelab.dns

# 7. Restart containers
docker start pihole dokku

# 8. Fix Pi-hole listening mode
sleep 5
docker exec pihole pihole-FTL --config dns.listeningMode ALL

# 9. Verify
dig @$TAILSCALE_IP google.com +short
```

### Cold-Start Recovery (after reboot or full power loss)

The `com.homelab.startup` LaunchDaemon handles this automatically. If it fails:

```bash
# 1. Start Colima
colima start --network-address

# 2. Kill dnsmasq
colima ssh -- sudo pkill dnsmasq

# 3. Start containers
docker start pihole dokku

# 4. Restart DNS forwarder
sudo launchctl kickstart -k system/com.homelab.dns

# 5. (If tunnel configured) Restart tunnel
sudo launchctl kickstart -k system/com.homelab.tunnel

# 6. Verify DNS
TAILSCALE_IP=$(tailscale ip -4)
dig @$TAILSCALE_IP google.com +short
```

Or simply run:

```bash
homelab doctor --fix
```

---

## Reference

### Key Files

| File | Purpose |
|------|---------|
| `~/homelab/config.sh` | Active configuration (secrets, IPs, domains) |
| `~/homelab/.env` | Colima IP and Tailscale IP (written by install.sh) |
| `~/homelab/.homelab-server` | Server marker file (presence = this is the server) |
| `~/homelab/dokku/docker-compose.yml` | Dokku container definition |
| `~/homelab/dokku/certs/server.crt` | TLS certificate |
| `~/homelab/dokku/certs/server.key` | TLS private key |
| `~/pihole/etc-pihole/pihole.toml` | Pi-hole configuration |
| `~/pihole/etc-pihole/` | Pi-hole data directory |

### LaunchDaemons

| Plist | Label | Purpose |
|-------|-------|---------|
| `/Library/LaunchDaemons/com.homelab.dns.plist` | `com.homelab.dns` | socat DNS forwarder (Tailscale IP → Colima VM) |
| `/Library/LaunchDaemons/com.homelab.startup.plist` | `com.homelab.startup` | Boot-time startup (Colima, containers, dnsmasq kill) |
| `/Library/LaunchDaemons/com.homelab.tunnel.plist` | `com.homelab.tunnel` | Cloudflare Tunnel daemon |
| `/Library/LaunchDaemons/com.homelab.certrenew.plist` | `com.homelab.certrenew` | Weekly certificate renewal |
| `/Library/LaunchDaemons/com.homelab.circuitbreaker.plist` | `com.homelab.circuitbreaker` | Load monitoring (every 60s) |
| `/Library/LaunchDaemons/com.homelab.db-backup.plist` | `com.homelab.db-backup` | Daily database backup (3 AM) |

### Log Locations

| Log | Path |
|-----|------|
| Startup | `/tmp/homelab-startup.log` |
| Tunnel | `/tmp/homelab-tunnel.log` |
| Circuit breaker | `~/.homelab/circuit-breaker.log` |
| Certificate renewal | `~/.homelab/certs/logs/` |
| Pi-hole | `docker logs pihole` |
| Dokku | `docker logs dokku` |
| App logs | `homelab logs <app>` |

### Useful Commands

```bash
# Check all container status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Check Colima VM status and IP
colima list

# Check Tailscale status
tailscale status

# Check all LaunchDaemons
sudo launchctl list | grep com.homelab

# View Pi-hole config
docker exec pihole pihole-FTL --config dns.listeningMode

# Test DNS resolution end-to-end
dig @$(tailscale ip -4) myapp.homelab.nate.green +short
```
