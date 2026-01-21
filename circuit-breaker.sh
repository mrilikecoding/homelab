#!/bin/bash
# Circuit Breaker for Homelab
# Monitors system load and automatically disables public apps if overloaded

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$HOME/.homelab/circuit-breaker-state"
LOG_FILE="$HOME/.homelab/circuit-breaker.log"
PUBLIC_APPS_FILE="$SCRIPT_DIR/.public-apps"

# Configuration (can be overridden in config.sh)
CPU_THRESHOLD="${CIRCUIT_BREAKER_CPU_THRESHOLD:-80}"        # CPU % to trigger
LOAD_THRESHOLD="${CIRCUIT_BREAKER_LOAD_THRESHOLD:-4.0}"     # Load average to trigger
CONSECUTIVE_CHECKS="${CIRCUIT_BREAKER_CHECKS:-3}"           # How many checks before tripping
CHECK_INTERVAL="${CIRCUIT_BREAKER_INTERVAL:-60}"            # Seconds between checks (for launchd)
WEBHOOK_URL="${CIRCUIT_BREAKER_WEBHOOK:-}"                  # Optional webhook for notifications

# Load config if available
[[ -f "$SCRIPT_DIR/config.sh" ]] && source "$SCRIPT_DIR/config.sh"

# Ensure state directory exists
mkdir -p "$(dirname "$STATE_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

# Get current CPU usage (macOS)
get_cpu_usage() {
    # Get CPU usage from top (idle percentage, then subtract from 100)
    local idle=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $7}' | tr -d '%')
    echo "scale=0; 100 - ${idle%.*}" | bc 2>/dev/null || echo "0"
}

# Get load average (1 minute)
get_load_average() {
    sysctl -n vm.loadavg | awk '{print $2}'
}

# Get current high-load count from state file
get_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "0"
    fi
}

# Save state
set_state() {
    echo "$1" > "$STATE_FILE"
}

# Check if any apps are public
has_public_apps() {
    [[ -f "$PUBLIC_APPS_FILE" && -s "$PUBLIC_APPS_FILE" ]]
}

# Disable all public apps
trip_breaker() {
    log "🚨 CIRCUIT BREAKER TRIPPED - Disabling all public apps"

    if [[ -f "$PUBLIC_APPS_FILE" ]]; then
        # Save current public apps so we know what was disabled
        cp "$PUBLIC_APPS_FILE" "$HOME/.homelab/circuit-breaker-disabled-apps"

        while IFS=: read -r app hostname; do
            if [[ -n "$app" ]]; then
                log "  Disabling: $app ($hostname)"
                "$SCRIPT_DIR/tunnel-remove-app.sh" "$app" 2>/dev/null || true
            fi
        done < "$PUBLIC_APPS_FILE"

        # Restart tunnel to apply changes
        sudo launchctl kickstart -k system/com.homelab.tunnel 2>/dev/null || true
    fi

    # Send notification if webhook configured
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"🚨 Homelab circuit breaker tripped! All public apps disabled due to high load.\"}" \
            2>/dev/null || true
    fi

    # Reset state
    set_state "0"

    log "All public apps disabled. Run 'homelab circuit-breaker:restore' to re-enable."
}

# Main check
main() {
    # Skip if no public apps
    if ! has_public_apps; then
        set_state "0"
        exit 0
    fi

    local cpu=$(get_cpu_usage)
    local load=$(get_load_average)
    local current_count=$(get_state)

    # Check if we're over threshold
    local over_threshold=false

    if (( cpu > CPU_THRESHOLD )); then
        over_threshold=true
        log "High CPU detected: ${cpu}% (threshold: ${CPU_THRESHOLD}%)"
    fi

    # Compare load average (using bc for floating point)
    if (( $(echo "$load > $LOAD_THRESHOLD" | bc -l) )); then
        over_threshold=true
        log "High load detected: ${load} (threshold: ${LOAD_THRESHOLD})"
    fi

    if [[ "$over_threshold" == "true" ]]; then
        current_count=$((current_count + 1))
        log "Consecutive high-load checks: $current_count / $CONSECUTIVE_CHECKS"

        if (( current_count >= CONSECUTIVE_CHECKS )); then
            trip_breaker
        else
            set_state "$current_count"
        fi
    else
        # Reset counter if load is normal
        if (( current_count > 0 )); then
            log "Load normal (CPU: ${cpu}%, Load: ${load}) - resetting counter"
        fi
        set_state "0"
    fi
}

# Command handling
case "${1:-check}" in
    check)
        main
        ;;
    status)
        echo "Circuit Breaker Status"
        echo "======================"
        echo "CPU Threshold:    ${CPU_THRESHOLD}%"
        echo "Load Threshold:   ${LOAD_THRESHOLD}"
        echo "Checks to trip:   ${CONSECUTIVE_CHECKS}"
        echo ""
        echo "Current CPU:      $(get_cpu_usage)%"
        echo "Current Load:     $(get_load_average)"
        echo "Warning count:    $(get_state) / ${CONSECUTIVE_CHECKS}"
        echo ""
        if has_public_apps; then
            echo "Public apps:      $(wc -l < "$PUBLIC_APPS_FILE" | tr -d ' ')"
        else
            echo "Public apps:      0"
        fi
        if [[ -f "$HOME/.homelab/circuit-breaker-disabled-apps" ]]; then
            echo ""
            echo "⚠️  Previously disabled apps (run 'homelab circuit-breaker:restore' to re-enable):"
            cat "$HOME/.homelab/circuit-breaker-disabled-apps" | while IFS=: read -r app hostname; do
                echo "    $app -> $hostname"
            done
        fi
        ;;
    restore)
        if [[ -f "$HOME/.homelab/circuit-breaker-disabled-apps" ]]; then
            echo "Restoring previously disabled apps..."
            while IFS=: read -r app hostname; do
                if [[ -n "$app" && -n "$hostname" ]]; then
                    echo "  Enabling: $app ($hostname)"
                    "$SCRIPT_DIR/tunnel-add-app.sh" "$app" "$hostname" 2>/dev/null || true
                fi
            done < "$HOME/.homelab/circuit-breaker-disabled-apps"
            rm "$HOME/.homelab/circuit-breaker-disabled-apps"
            sudo launchctl kickstart -k system/com.homelab.tunnel 2>/dev/null || true
            echo "Done! Apps restored."
        else
            echo "No disabled apps to restore."
        fi
        ;;
    test)
        echo "Testing circuit breaker (will trip immediately)..."
        CONSECUTIVE_CHECKS=1
        CPU_THRESHOLD=0
        main
        ;;
    logs)
        if [[ -f "$LOG_FILE" ]]; then
            tail -50 "$LOG_FILE"
        else
            echo "No logs yet."
        fi
        ;;
    *)
        echo "Usage: $0 {check|status|restore|test|logs}"
        exit 1
        ;;
esac
