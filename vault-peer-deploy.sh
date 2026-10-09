#!/usr/bin/env bash
# Deploy the vault inbox peer on this machine. Idempotent.
#
# The peer is a Node process (`node inbox.mjs`) that joins a vault's sync
# server and runs llm-orc ensembles for request notes. This script renders
# a wrapper script and a launchd user agent from launchd/vault-peer.plist.template
# with this machine's values (config.sh, else the defaults below) and loads
# the agent. The code and the .env file are installed by hand; see
# docs/vault-peer.md.
#
# Usage: ./vault-peer-deploy.sh [--dry-run] [--render-only]
#   --dry-run      print what would change; touch nothing
#   --render-only  print the wrapper and the unit to stdout and exit; skips
#                  every check on the target directory
set -uo pipefail
# A non-interactive ssh session does not carry the brew prefixes.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/config.sh" ]] && source "$SCRIPT_DIR/config.sh"

DRY_RUN=false
RENDER_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --render-only) RENDER_ONLY=true ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

VAULT_PEER_DIR="${VAULT_PEER_DIR:-$HOME/og-cloud-headless}"
VAULT_PEER_LABEL="${VAULT_PEER_LABEL:-com.vault-peer.inbox}"
# Empty means: let the wrapper pick node through nvm at start, else PATH.
VAULT_PEER_NODE="${VAULT_PEER_NODE:-}"

LABEL="$VAULT_PEER_LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$SCRIPT_DIR/launchd/vault-peer.plist.template"
WRAPPER="$VAULT_PEER_DIR/run.sh"
ENV_FILE="$VAULT_PEER_DIR/.env"
LOG_FILE="$HOME/Library/Logs/vault-peer.log"
DOMAIN="gui/$(id -u)"

log() { echo "$(date '+%F %T') $*"; }
die() { log "error: $*" >&2; exit 1; }

render_wrapper() {
    # The paths are quoted when the wrapper runs, so a space in one is safe.
    cat <<WRAP
#!/bin/bash
# Rendered by vault-peer-deploy.sh; edit config.sh, not this copy.
# Loads node (nvm if present), then the settings file, then runs the peer.
cd "$VAULT_PEER_DIR" || exit 1
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
if [ -s "\$NVM_DIR/nvm.sh" ]; then
    . "\$NVM_DIR/nvm.sh"
    nvm use 22 >/dev/null 2>&1 || true
fi
set -a
. "$VAULT_PEER_DIR/.env"
set +a
exec ${VAULT_PEER_NODE:-node} inbox.mjs
WRAP
}

render_plist() {
    sed -e "s|@LABEL@|$LABEL|" \
        -e "s|@WRAPPER@|$WRAPPER|" \
        -e "s|@VAULT_PEER_DIR@|$VAULT_PEER_DIR|" \
        -e "s|@LOG_FILE@|$LOG_FILE|g" \
        "$TEMPLATE"
}

file_mode() {
    stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

resolve_node() {
    # What the wrapper will run, the way the wrapper finds it.
    if [[ -n "$VAULT_PEER_NODE" ]]; then
        echo "$VAULT_PEER_NODE"
        return
    fi
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$nvm_dir/nvm.sh" ]]; then
        # shellcheck disable=SC1091
        bash -c ". '$nvm_dir/nvm.sh' >/dev/null 2>&1; nvm use 22 >/dev/null 2>&1; command -v node"
    else
        command -v node
    fi
}

[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

if [[ $RENDER_ONLY == true ]]; then
    render_wrapper
    echo "-----"
    render_plist
    exit 0
fi

# 1. What the unit needs on disk.
[[ -d "$VAULT_PEER_DIR" ]] || die "$VAULT_PEER_DIR does not exist (copy the peer's code there)"
[[ -f "$VAULT_PEER_DIR/inbox.mjs" ]] || die "$VAULT_PEER_DIR/inbox.mjs not found"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE is missing; create it (mode 600) with OG_HOST, OG_VAULT_ID, OG_TOKEN, OG_DEVICE, LLM_ORC_URL"
mode="$(file_mode "$ENV_FILE")"
[[ "$mode" == "600" ]] || die "$ENV_FILE is mode $mode; run: chmod 600 $ENV_FILE"
[[ -d "$VAULT_PEER_DIR/node_modules" ]] || die "$VAULT_PEER_DIR/node_modules is missing; run: cd $VAULT_PEER_DIR && npm install"
NODE_BIN="$(resolve_node)"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || die "no node found (install node 22 with nvm, or set VAULT_PEER_NODE)"
NODE_VERSION="$("$NODE_BIN" --version 2>/dev/null)"
case "$NODE_VERSION" in
    v22.*) ;;
    *) log "warning: node is $NODE_VERSION, the peer expects v22" ;;
esac

# 2. The wrapper and the unit.
wrapper="$(render_wrapper)"
rendered="$(render_plist)"
if [[ $DRY_RUN == true ]]; then
    echo "$wrapper"
    echo "-----"
    echo "$rendered"
    if [[ -f "$PLIST" ]] && diff -q <(echo "$rendered") "$PLIST" >/dev/null; then
        log "dry run: installed unit is current"
    else
        log "dry run: would write $PLIST and reload $LABEL"
        [[ -f "$PLIST" ]] && diff <(echo "$rendered") "$PLIST"
    fi
    log "dry run: node $NODE_VERSION at $NODE_BIN"
    exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
echo "$wrapper" > "$WRAPPER"
chmod 755 "$WRAPPER"

if [[ -f "$PLIST" ]] && diff -q <(echo "$rendered") "$PLIST" >/dev/null; then
    # Same unit: a kickstart restarts the peer on the code just installed.
    log "unit unchanged; kickstarting $LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null \
        || launchctl bootstrap "$DOMAIN" "$PLIST" \
        || die "kickstart and bootstrap failed"
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

# 3. It stays up. A peer that exits on bad settings is restarted by
# KeepAlive, so look twice.
sleep 5
launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running' \
    || die "$LABEL is not running (see $LOG_FILE)"
sleep 5
launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running' \
    || die "$LABEL exited after starting (see $LOG_FILE)"
log "$LABEL running with node $NODE_VERSION from $VAULT_PEER_DIR; log: $LOG_FILE"
