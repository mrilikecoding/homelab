#!/bin/bash
# Homelab Doctor - Health check and auto-fix for homelab infrastructure
# Usage: homelab doctor [--fix]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# Load config if available
[[ -f "$SCRIPT_DIR/config.sh" ]] && source "$SCRIPT_DIR/config.sh"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

# Parse args
FIX=false
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=true ;;
    esac
done

# Counters
PASSED=0
FIXED=0
FAILED=0
TOTAL=0

# Check if running on the server
is_server() {
    [[ -f "$SCRIPT_DIR/.homelab-server" ]]
}

# Print a check result
check_pass() {
    local detail="${1:-}"
    if [[ -n "$detail" ]]; then
        echo -e " ${GREEN}✓${NC} ($detail)"
    else
        echo -e " ${GREEN}✓${NC}"
    fi
    PASSED=$((PASSED + 1))
}

check_fail() {
    local detail="${1:-}"
    if [[ -n "$detail" ]]; then
        echo -e " ${RED}✗${NC} ($detail)"
    else
        echo -e " ${RED}✗${NC}"
    fi
    FAILED=$((FAILED + 1))
}

check_fixed() {
    echo -e " ${GREEN}✓${NC} (fixed)"
    FIXED=$((FIXED + 1))
}

try_fix() {
    local description="$1"
    shift
    if [[ "$FIX" == "true" ]]; then
        echo -e "      → Fixing: ${description}..."
        if "$@" 2>/dev/null; then
            return 0
        else
            echo -e "      → ${RED}Fix failed${NC}"
            return 1
        fi
    fi
    return 1
}

# =============================================================================
# Server-side checks
# =============================================================================
run_server_checks() {
    TOTAL=9

    # --- Check 1: Colima VM has routable IP ---
    echo -n "[1/${TOTAL}] Colima VM has routable IP ..."
    local colima_ip
    colima_ip=$(colima list -j 2>/dev/null | grep -o '"address":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$colima_ip" ]]; then
        check_pass "$colima_ip"
    else
        check_fail "no routable IP"
        if try_fix "restarting Colima with --network-address" \
            bash -c 'colima stop 2>/dev/null; colima start --network-address'; then
            # Kill dnsmasq, restart containers, update .env
            colima ssh -- sudo pkill dnsmasq 2>/dev/null || true
            colima_ip=$(colima list -j 2>/dev/null | grep -o '"address":"[^"]*"' | cut -d'"' -f4)
            if [[ -n "$colima_ip" ]]; then
                local ts_ip
                ts_ip=$(tailscale ip -4 2>/dev/null)
                cat > "$SCRIPT_DIR/.env" << EOF
COLIMA_IP=$colima_ip
TAILSCALE_IP=${ts_ip:-$TAILSCALE_IP}
EOF
                COLIMA_IP="$colima_ip"
                docker start pihole dokku 2>/dev/null || true
                sleep 5
                echo -n "      → Re-checking ..."
                check_fixed
            else
                check_fail "Colima restarted but still no IP"
            fi
        fi
    fi

    # Update COLIMA_IP for subsequent checks
    COLIMA_IP="${colima_ip:-${COLIMA_IP:-}}"

    # --- Check 2: socat target matches Colima IP ---
    echo -n "[2/${TOTAL}] socat target matches Colima IP ..."
    local plist="/Library/LaunchDaemons/com.homelab.dns.plist"
    if [[ -f "$plist" && -n "$COLIMA_IP" ]]; then
        local plist_target
        plist_target=$(grep -o 'UDP-SENDTO:[^<]*' "$plist" 2>/dev/null | sed 's/UDP-SENDTO://' | cut -d: -f1)
        if [[ "$plist_target" == "$COLIMA_IP" ]]; then
            check_pass
        else
            check_fail "plist has $plist_target, Colima is $COLIMA_IP"
            local ts_ip="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null)}"
            if [[ -n "$ts_ip" ]] && try_fix "rewriting plist with correct IP" \
                bash -c "sudo tee '$plist' > /dev/null << PLIST
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>com.homelab.dns</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/socat</string>
        <string>UDP-RECVFROM:53,bind=${ts_ip},fork,reuseaddr</string>
        <string>UDP-SENDTO:${COLIMA_IP}:53</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST"; then
                sudo launchctl kickstart -k system/com.homelab.dns 2>/dev/null || true
                sleep 1
                echo -n "      → Re-checking ..."
                check_fixed
            fi
        fi
    elif [[ ! -f "$plist" ]]; then
        check_fail "plist not found"
    else
        check_fail "no Colima IP to compare"
    fi

    # --- Check 3: socat DNS forwarder running ---
    echo -n "[3/${TOTAL}] socat DNS forwarder running ..."
    if pgrep -f 'socat.*UDP-RECVFROM:53' > /dev/null 2>&1; then
        check_pass
    else
        check_fail "socat not running"
        if try_fix "kickstarting com.homelab.dns" \
            sudo launchctl kickstart -k system/com.homelab.dns; then
            sleep 1
            if pgrep -f 'socat.*UDP-RECVFROM:53' > /dev/null 2>&1; then
                echo -n "      → Re-checking ..."
                check_fixed
            else
                check_fail "still not running after kickstart"
            fi
        fi
    fi

    # --- Check 4: Pi-hole listening mode ---
    echo -n "[4/${TOTAL}] Pi-hole listening mode ..."
    local listen_mode
    listen_mode=$(docker exec pihole pihole-FTL --config dns.listeningMode 2>/dev/null)
    if [[ "$listen_mode" == "ALL" ]]; then
        check_pass "ALL"
    elif [[ -n "$listen_mode" ]]; then
        check_fail "$listen_mode, should be ALL"
        if try_fix "setting listeningMode to ALL" \
            docker exec pihole pihole-FTL --config dns.listeningMode ALL; then
            sleep 1
            local recheck
            recheck=$(docker exec pihole pihole-FTL --config dns.listeningMode 2>/dev/null)
            if [[ "$recheck" == "ALL" ]]; then
                echo -n "      → Re-checking ..."
                check_fixed
            else
                check_fail "still $recheck after fix"
            fi
        fi
    else
        check_fail "could not query Pi-hole (container down?)"
    fi

    # --- Check 5: dnsmasq conflict ---
    echo -n "[5/${TOTAL}] No dnsmasq conflict on port 53 ..."
    local dnsmasq_on_53
    dnsmasq_on_53=$(colima ssh -- ss -ulnp 2>/dev/null | grep ':53 ' | grep dnsmasq || true)
    if [[ -z "$dnsmasq_on_53" ]]; then
        check_pass
    else
        check_fail "dnsmasq holding port 53 in VM"
        if try_fix "killing dnsmasq in VM" \
            colima ssh -- sudo pkill dnsmasq; then
            sleep 1
            docker restart pihole 2>/dev/null || true
            sleep 3
            local recheck
            recheck=$(colima ssh -- ss -ulnp 2>/dev/null | grep ':53 ' | grep dnsmasq || true)
            if [[ -z "$recheck" ]]; then
                echo -n "      → Re-checking ..."
                check_fixed
            else
                check_fail "dnsmasq still on port 53"
            fi
        fi
    fi

    # --- Check 6: DNS responds ---
    echo -n "[6/${TOTAL}] DNS responds to queries ..."
    local ts_ip="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null)}"
    if [[ -n "$ts_ip" ]]; then
        local dns_result
        dns_result=$(dig @"$ts_ip" google.com +short +timeout=3 +tries=1 2>/dev/null)
        if [[ -n "$dns_result" ]]; then
            check_pass
        else
            check_fail "no response from dig @$ts_ip"
            echo "      → No auto-fix. Check upstream failures (socat, Pi-hole, dnsmasq)."
            echo "      → See: docs/diagnostics.md for layer-by-layer diagnosis."
        fi
    else
        check_fail "no Tailscale IP available"
    fi

    # --- Check 7: Containers running ---
    echo -n "[7/${TOTAL}] Containers running ..."
    local missing=""
    for container in dokku pihole; do
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            missing="${missing} ${container}"
        fi
    done
    if [[ -z "$missing" ]]; then
        check_pass "dokku, pihole"
    else
        check_fail "stopped:${missing}"
        if [[ "$FIX" == "true" ]]; then
            for container in $missing; do
                try_fix "starting $container" docker start "$container"
            done
            sleep 3
            local still_missing=""
            for container in $missing; do
                if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
                    still_missing="${still_missing} ${container}"
                fi
            done
            if [[ -z "$still_missing" ]]; then
                echo -n "      → Re-checking ..."
                check_fixed
            else
                check_fail "still stopped:${still_missing}"
            fi
        fi
    fi

    # --- Check 8: TLS certs valid ---
    echo -n "[8/${TOTAL}] TLS certificates valid ..."
    local cert_file="$SCRIPT_DIR/dokku/certs/server.crt"
    if [[ -f "$cert_file" ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        if [[ -n "$expiry" ]]; then
            local expiry_epoch
            expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry" "+%s" 2>/dev/null || date -d "$expiry" "+%s" 2>/dev/null)
            local now_epoch
            now_epoch=$(date "+%s")
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            if (( days_left > 14 )); then
                check_pass "${days_left} days remaining"
            elif (( days_left > 0 )); then
                check_fail "expiring in ${days_left} days"
                if try_fix "renewing certificates" "$SCRIPT_DIR/renew-certs.sh"; then
                    echo -n "      → Re-checking ..."
                    check_fixed
                fi
            else
                check_fail "expired"
                if try_fix "renewing certificates" "$SCRIPT_DIR/renew-certs.sh"; then
                    echo -n "      → Re-checking ..."
                    check_fixed
                fi
            fi
        else
            check_fail "could not read expiry date"
        fi
    else
        check_pass "no certs configured (HTTP-only)"
    fi

    # --- Check 9: Cloudflare Tunnel ---
    echo -n "[9/${TOTAL}] Cloudflare Tunnel ..."
    local tunnel_plist="/Library/LaunchDaemons/com.homelab.tunnel.plist"
    if [[ -f "$tunnel_plist" ]]; then
        if sudo launchctl list 2>/dev/null | grep -q "com.homelab.tunnel"; then
            check_pass "loaded"
        else
            check_fail "plist exists but daemon not loaded"
            if try_fix "kickstarting com.homelab.tunnel" \
                sudo launchctl kickstart -k system/com.homelab.tunnel; then
                sleep 2
                if sudo launchctl list 2>/dev/null | grep -q "com.homelab.tunnel"; then
                    echo -n "      → Re-checking ..."
                    check_fixed
                else
                    check_fail "still not loaded"
                fi
            fi
        fi
    else
        check_pass "not configured (skipped)"
    fi
}

# =============================================================================
# Client-side checks
# =============================================================================
run_client_checks() {
    TOTAL=4

    # Determine server IP
    local server_ip="${TAILSCALE_IP:-}"
    if [[ -z "$server_ip" ]]; then
        echo -e "${YELLOW}Warning: TAILSCALE_IP not set in config.sh${NC}"
        echo "Set TAILSCALE_IP in $SCRIPT_DIR/config.sh or export it."
        echo ""
        TOTAL=0
        FAILED=1
        return
    fi

    # --- Check 1: Tailscale connectivity ---
    echo -n "[1/${TOTAL}] Server reachable via Tailscale ..."
    if ping -c 1 -W 3 "$server_ip" > /dev/null 2>&1; then
        check_pass "$server_ip"
    else
        check_fail "cannot ping $server_ip"
        echo "      → Check that Tailscale is running on both client and server."
    fi

    # --- Check 2: DNS resolution ---
    echo -n "[2/${TOTAL}] DNS resolution ..."
    local test_domain="${APP_DOMAIN:-nate.green}"
    local dns_result
    dns_result=$(dig @"$server_ip" "test.homelab.${test_domain}" +short +timeout=3 +tries=1 2>/dev/null)
    if [[ -n "$dns_result" ]]; then
        check_pass "test.homelab.${test_domain} → ${dns_result}"
    else
        check_fail "dig @$server_ip test.homelab.${test_domain} returned nothing"
        echo "      → This is likely a server-side issue (socat, Pi-hole, or dnsmasq)."
        echo "      → SSH to the server and run: homelab doctor --fix"
    fi

    # --- Check 3: HTTP/HTTPS ---
    echo -n "[3/${TOTAL}] HTTP connectivity ..."
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${server_ip}" 2>/dev/null)
    if [[ "$http_status" =~ ^[2345] ]]; then
        check_pass "HTTP $http_status"
    else
        check_fail "no HTTP response"
        echo "      → SSH to the server and run: homelab doctor --fix"
    fi

    # --- Check 4: SSH to Dokku ---
    echo -n "[4/${TOTAL}] SSH to Dokku ..."
    local dokku_ver
    dokku_ver=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no dokku version 2>/dev/null)
    if [[ -n "$dokku_ver" ]]; then
        check_pass "$dokku_ver"
    else
        check_fail "ssh dokku version failed"
        echo "      → Check SSH config (~/.ssh/config) has 'dokku' host alias."
        echo "      → Verify SSH key is added and port is correct."
    fi
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}Homelab Doctor${NC}"

if is_server; then
    echo -e "Mode: ${CYAN}Server${NC}"
    echo ""
    run_server_checks
else
    echo -e "Mode: ${CYAN}Client${NC}"
    echo ""
    run_client_checks
fi

# Summary
echo ""
echo -n "Results: "
echo -n "${GREEN}${PASSED} passed${NC}"
if (( FIXED > 0 )); then
    echo -n ", ${YELLOW}${FIXED} fixed${NC}"
fi
if (( FAILED > 0 )); then
    echo -n ", ${RED}${FAILED} failed${NC}"
fi
echo ""

if (( FAILED > 0 )); then
    if [[ "$FIX" != "true" ]]; then
        echo -e "Run ${CYAN}homelab doctor --fix${NC} to attempt auto-repair."
    fi
    exit 1
else
    exit 0
fi
