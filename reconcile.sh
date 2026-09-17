#!/usr/bin/env bash
# Bring the homelab up after a reboot or a power loss. Idempotent; safe to run
# every 10 minutes. Exit 0 only when doctor.sh passes.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LIMA_HOME="$HOME/.colima/_lima"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "$(date '+%F %T') $*"; }

# 1. Colima. A stale disk lock survives an unclean shutdown and blocks boot.
colima_start_ok=true
if ! colima status >/dev/null 2>&1; then
  # The guard: never unlock a disk a live hostagent is using. Runs are
  # serialized by launchd (StartInterval jobs do not overlap), so this is
  # a sanity check, not a lock.
  if [[ -L "$LIMA_HOME/_disks/colima/in_use_by" ]] && ! pgrep -qf 'limactl.*hostagent'; then
    log "colima stopped with a stale disk lock; unlocking"
    limactl disk unlock colima 2>/dev/null || true
  fi
  log "starting colima"
  colima stop >/dev/null 2>&1 || true
  colima start --network-address || { log "colima start failed"; colima_start_ok=false; }
fi
# Docker must answer before doctor.sh can inspect containers.
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

# 2. Everything else is doctor.sh's job (dnsmasq on :53, listening mode, certs,
#    containers, DNS answering). --fix applies its known repairs.
doctor_ok=false
[[ $colima_start_ok == true ]] && "$SCRIPT_DIR/doctor.sh" --fix && doctor_ok=true

# 3. Publish what is true right now, after repairs. WP4's Worker reads this
#    through the tunnel. Every run reaches this block.
colima_ok=false; colima status >/dev/null 2>&1 && colima_ok=true
dns_ok=false;    dig +time=2 +tries=1 @100.92.166.102 pi.hole +short 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.' && dns_ok=true   # dig prints its timeout banner to stdout; require an IP
serve_ok=false;  curl -fsS -m 5 http://127.0.0.1:8765/api/models 2>/dev/null | grep -q '"models"' && serve_ok=true
apps_ok=false;   [[ "$(docker inspect --format '{{.State.Running}}' dokku pihole 2>/dev/null | grep -c '^true$')" == "2" ]] && apps_ok=true
ph=$(docker inspect --format '{{.State.Health.Status}}' pihole 2>/dev/null); pihole_ok=false; [[ "$ph" == "healthy" ]] && pihole_ok=true
all_ok=false; [[ $doctor_ok == true && $dns_ok == true && $serve_ok == true && $colima_ok == true && $apps_ok == true && $pihole_ok == true ]] && all_ok=true
mkdir -p "$SCRIPT_DIR/status/html"
printf '{"generated":"%s","ok":%s,"checks":{"colima":%s,"doctor":%s,"dns":%s,"pihole_healthy":%s,"apps":%s,"serve":%s}}\n' \
  "$(date -u +%FT%TZ)" "$all_ok" "$colima_ok" "$doctor_ok" "$dns_ok" "$pihole_ok" "$apps_ok" "$serve_ok" \
  > "$SCRIPT_DIR/status/html/status.json.tmp" && mv "$SCRIPT_DIR/status/html/status.json.tmp" "$SCRIPT_DIR/status/html/status.json"

if [[ $all_ok == true ]]; then log "all checks pass"; exit 0; fi
log "checks failing: colima=$colima_ok doctor=$doctor_ok dns=$dns_ok apps=$apps_ok pihole=$pihole_ok serve=$serve_ok"
exit 1
