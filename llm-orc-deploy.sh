#!/usr/bin/env bash
# Deploy the llm-orc serve on this machine. Idempotent.
#
# Upgrades the brew package, renders the launchd unit from
# launchd/com.llm-orc.serve.plist.template with this machine's values
# (config.sh, else the defaults below), restarts the serve and waits until
# it answers with the installed version.
#
# Usage: ./llm-orc-deploy.sh [--no-upgrade] [--dry-run]
#   --no-upgrade  skip `brew upgrade llm-orchestra`
#   --dry-run     print the rendered unit and what would change; touch nothing
set -uo pipefail
# A non-interactive ssh session does not carry the brew prefixes.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/config.sh" ]] && source "$SCRIPT_DIR/config.sh"

UPGRADE=true
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --no-upgrade) UPGRADE=false ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# The serve runs from a plain directory: one with a .llm-orc inside it (or
# above it) is adopted as a project and shadows the serving project that
# ships in the package.
LLM_ORC_SERVE_DIR="${LLM_ORC_SERVE_DIR:-$HOME/llm-orc-serve}"
LLM_ORC_PORT="${LLM_ORC_PORT:-8765}"
LLM_ORC_BACKEND_PORT="${LLM_ORC_BACKEND_PORT:-8080}"
LLM_ORC_MODELS_MAX="${LLM_ORC_MODELS_MAX:-2}"
LLM_ORC_LIBRARY_PATH="${LLM_ORC_LIBRARY_PATH:-}"
LLAMA_CACHE="${LLAMA_CACHE:-$HOME/Library/Caches/llama.cpp}"

LABEL="com.llm-orc.serve"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$SCRIPT_DIR/launchd/$LABEL.plist.template"
LOG_FILE="$HOME/Library/Logs/llm-orc-serve.log"
DOMAIN="gui/$(id -u)"

log() { echo "$(date '+%F %T') $*"; }
die() { log "error: $*" >&2; exit 1; }

project_dir_above() {
    # The first .llm-orc at or above $1, the way the serve discovers one.
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        [[ -d "$dir/.llm-orc" ]] && { echo "$dir/.llm-orc"; return 0; }
        dir="$(dirname "$dir")"
    done
    return 1
}

render() {
    local library_env=""
    if [[ -n "$LLM_ORC_LIBRARY_PATH" ]]; then
        library_env="    <key>LLM_ORC_LIBRARY_PATH</key>\\
    <string>$LLM_ORC_LIBRARY_PATH</string>\\
"
    fi
    sed -e "s|@LLM_ORC_BIN@|$LLM_ORC_BIN|" \
        -e "s|@LLM_ORC_PORT@|$LLM_ORC_PORT|" \
        -e "s|@LLM_ORC_BACKEND_PORT@|$LLM_ORC_BACKEND_PORT|" \
        -e "s|@LLM_ORC_MODELS_MAX@|$LLM_ORC_MODELS_MAX|" \
        -e "s|@LLM_ORC_SERVE_DIR@|$LLM_ORC_SERVE_DIR|" \
        -e "s|@LLAMA_CACHE@|$LLAMA_CACHE|" \
        -e "s|@LOG_FILE@|$LOG_FILE|g" \
        -e "s|@LIBRARY_ENV@|$library_env|" \
        "$TEMPLATE"
}

running_version() {
    curl -fsS -m 5 "http://127.0.0.1:$LLM_ORC_PORT/health" 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

# 1. The package.
if [[ $UPGRADE == true && $DRY_RUN == false ]]; then
    log "brew upgrade llm-orchestra"
    brew upgrade llm-orchestra 2>&1 | tail -3 || true
fi
LLM_ORC_BIN="$(command -v llm-orc 2>/dev/null || true)"
[[ -x "$LLM_ORC_BIN" ]] || die "llm-orc is not on PATH (brew install llm-orchestra)"
INSTALLED="$("$LLM_ORC_BIN" --version 2>/dev/null | awk '{print $NF}')"
[[ -n "$INSTALLED" ]] || die "$LLM_ORC_BIN --version printed nothing"

# 2. A plain working directory.
if found="$(project_dir_above "$LLM_ORC_SERVE_DIR")"; then
    die "$found would be adopted as the serve's project; move it or set LLM_ORC_SERVE_DIR"
fi

# 3. The unit.
rendered="$(render)"
if [[ $DRY_RUN == true ]]; then
    echo "$rendered"
    if [[ -f "$PLIST" ]] && diff -q <(echo "$rendered") "$PLIST" >/dev/null; then
        log "dry run: installed unit is current; would kickstart $LABEL"
    else
        log "dry run: would write $PLIST and reload $LABEL"
        [[ -f "$PLIST" ]] && diff <(echo "$rendered") "$PLIST"
    fi
    log "dry run: installed llm-orc $INSTALLED, running $(running_version || true)"
    exit 0
fi

mkdir -p "$LLM_ORC_SERVE_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
if [[ -f "$PLIST" ]] && diff -q <(echo "$rendered") "$PLIST" >/dev/null; then
    # Same unit: a kickstart is enough to pick up an upgraded package.
    log "unit unchanged; kickstarting $LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL" || die "kickstart failed"
else
    # A changed unit needs bootout + bootstrap: kickstart keeps the old
    # arguments and working directory.
    [[ -f "$PLIST" ]] && cp "$PLIST" "$PLIST.previous"
    echo "$rendered" > "$PLIST"
    plutil -lint "$PLIST" >/dev/null || die "rendered unit does not lint: $PLIST"
    log "unit changed; reloading $LABEL"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 1
    done
    launchctl bootstrap "$DOMAIN" "$PLIST" || die "bootstrap failed"
fi

# 4. It answers, with the installed version.
running=""
for _ in $(seq 1 30); do
    sleep 2
    running="$(running_version)"
    [[ "$running" == "$INSTALLED" ]] && break
done
[[ "$running" == "$INSTALLED" ]] \
    || die "serve answers '${running:-nothing}', installed is $INSTALLED (see $LOG_FILE)"
log "llm-orc $running serving from $LLM_ORC_SERVE_DIR on 127.0.0.1:$LLM_ORC_PORT"
