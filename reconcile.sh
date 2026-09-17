#!/usr/bin/env bash
# Bring the homelab up after a reboot or a power loss. Idempotent; safe to run
# every 10 minutes. Exit 0 only when doctor.sh passes.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LIMA_HOME="$HOME/.colima/_lima"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "$(date '+%F %T') $*"; }

# 1. Colima. A stale disk lock survives an unclean shutdown and blocks boot.
if ! colima status >/dev/null 2>&1; then
  if [[ -L "$LIMA_HOME/_disks/colima/in_use_by" ]] && ! pgrep -qf 'limactl.*hostagent'; then
    log "colima stopped with a stale disk lock; unlocking"
    limactl disk unlock colima
  fi
  log "starting colima"
  colima stop >/dev/null 2>&1 || true
  colima start --network-address || { log "colima start failed"; exit 1; }
fi
# Docker must answer before doctor.sh can inspect containers.
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

# 2. Everything else is doctor.sh's job (dnsmasq on :53, listening mode, certs,
#    containers, DNS answering). --fix applies its known repairs.
doctor_ok=false
"$SCRIPT_DIR/doctor.sh" --fix && doctor_ok=true

# 3. Publish what is true right now. WP4's Worker reads this through the tunnel.
dns_ok=false;    dig +time=2 +tries=1 @100.92.166.102 pi.hole +short 2>/dev/null | grep -q . && dns_ok=true
serve_ok=false;  curl -fsS -m 5 http://127.0.0.1:8765/api/models 2>/dev/null | grep -q '"models"' && serve_ok=true
colima_ok=false; colima status >/dev/null 2>&1 && colima_ok=true
ph=$(docker inspect --format '{{.State.Health.Status}}' pihole 2>/dev/null); pihole_ok=false; [[ "$ph" == "healthy" || -z "$ph" ]] && pihole_ok=true
all_ok=false; [[ $doctor_ok == true && $dns_ok == true && $serve_ok == true && $colima_ok == true && $pihole_ok == true ]] && all_ok=true
mkdir -p "$SCRIPT_DIR/status/html"
printf '{"generated":"%s","ok":%s,"checks":{"colima":%s,"dns":%s,"pihole_healthy":%s,"apps":%s,"serve":%s}}\n' \
  "$(date +%FT%T%z)" "$all_ok" "$colima_ok" "$dns_ok" "$pihole_ok" "$doctor_ok" "$serve_ok" \
  > "$SCRIPT_DIR/status/html/status.json.tmp" && mv "$SCRIPT_DIR/status/html/status.json.tmp" "$SCRIPT_DIR/status/html/status.json"

if [[ $all_ok == true ]]; then log "all checks pass"; exit 0; fi
log "checks failing: doctor=$doctor_ok dns=$dns_ok serve=$serve_ok colima=$colima_ok pihole=$pihole_ok"
exit 1
