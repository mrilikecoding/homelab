#!/bin/bash
# Generates status.html from Dokku app status

OUTPUT_DIR="${1:-/Users/nathanielgreen/homelab/status/html}"
mkdir -p "$OUTPUT_DIR"

# Use full path to docker for launchd compatibility
DOCKER="/usr/local/bin/docker"

# Get app list and status
APPS=$($DOCKER exec dokku dokku apps:list 2>/dev/null | tail -n +2)

cat > "$OUTPUT_DIR/index.html" << 'HEADER'
<!DOCTYPE html>
<html>
<head>
  <title>Homelab Status</title>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      max-width: 600px;
      margin: 40px auto;
      padding: 20px;
      background: #0d1117;
      color: #c9d1d9;
    }
    h1 { color: #58a6ff; margin-bottom: 8px; }
    .updated { color: #8b949e; font-size: 14px; margin-bottom: 24px; }
    .app {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 6px;
      padding: 16px;
      margin-bottom: 12px;
    }
    .app-name { font-weight: 600; font-size: 18px; }
    .app-status { margin-top: 8px; }
    .running { color: #3fb950; }
    .stopped { color: #f85149; }
    .unknown { color: #8b949e; }
    .no-apps { color: #8b949e; font-style: italic; }
  </style>
</head>
<body>
  <h1>Homelab Status</h1>
HEADER

echo "  <div class=\"updated\">Updated: $(date '+%Y-%m-%d %H:%M:%S')</div>" >> "$OUTPUT_DIR/index.html"

if [ -z "$APPS" ]; then
  echo '  <div class="no-apps">No apps deployed</div>' >> "$OUTPUT_DIR/index.html"
else
  for app in $APPS; do
    STATUS=$($DOCKER exec dokku dokku ps:report "$app" 2>/dev/null | grep "running" | head -1)
    RUNNING_COUNT=$(echo "$STATUS" | grep -oE '[0-9]+' | head -1)

    if [ -n "$RUNNING_COUNT" ] && [ "$RUNNING_COUNT" -gt 0 ]; then
      STATUS_CLASS="running"
      STATUS_TEXT="Running ($RUNNING_COUNT)"
    else
      # Check if it's stopped or just has no processes
      DEPLOYED=$($DOCKER exec dokku dokku ps:report "$app" 2>/dev/null | grep "Deployed" | grep -v "false")
      if [ -n "$DEPLOYED" ]; then
        STATUS_CLASS="stopped"
        STATUS_TEXT="Stopped"
      else
        STATUS_CLASS="unknown"
        STATUS_TEXT="Not deployed"
      fi
    fi

    cat >> "$OUTPUT_DIR/index.html" << EOF
  <div class="app">
    <div class="app-name">$app</div>
    <div class="app-status $STATUS_CLASS">$STATUS_TEXT</div>
  </div>
EOF
  done
fi

cat >> "$OUTPUT_DIR/index.html" << 'FOOTER'
</body>
</html>
FOOTER

echo "Status page generated at $OUTPUT_DIR/index.html"
