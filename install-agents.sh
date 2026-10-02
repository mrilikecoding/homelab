#!/usr/bin/env bash
# Render the homelab launchd agents into ~/Library/LaunchAgents. Idempotent.
#
# Fills @HOME@ and @HOMELAB_DIR@ in each *.plist.template (the reconcile
# agent and the status-refresh agent) with this machine's values, lints the
# result and writes it. It does not load anything; the bootstrap commands
# are printed at the end.
#
# Usage: ./install-agents.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
TEMPLATES=(
    "$SCRIPT_DIR/launchd/com.homelab.reconcile.plist.template"
    "$SCRIPT_DIR/status/com.homelab.status-refresh.plist.template"
)

die() { echo "error: $*" >&2; exit 1; }

mkdir -p "$AGENTS_DIR" "$HOME/Library/Logs"
for template in "${TEMPLATES[@]}"; do
    [[ -f "$template" ]] || die "template not found: $template"
    plist="$AGENTS_DIR/$(basename "$template" .template)"
    sed -e "s|@HOMELAB_DIR@|$SCRIPT_DIR|g" \
        -e "s|@HOME@|$HOME|g" \
        "$template" > "$plist.tmp"
    plutil -lint "$plist.tmp" >/dev/null || { rm -f "$plist.tmp"; die "rendered unit does not lint: $template"; }
    mv "$plist.tmp" "$plist"
    echo "wrote $plist"
done

echo "To load an agent:"
echo "  launchctl bootstrap gui/$(id -u) $AGENTS_DIR/com.homelab.reconcile.plist"
echo "  launchctl bootstrap gui/$(id -u) $AGENTS_DIR/com.homelab.status-refresh.plist"
echo "To pick up a changed unit, bootout first: launchctl bootout gui/$(id -u)/<label>"
