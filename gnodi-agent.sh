#!/usr/bin/env bash
set -euo pipefail

API_BASE="https://api.gnodiservices.com"
AGENT_DIR="/opt/gnodi-agent"
GNODID_BIN="/usr/local/bin/gnodid"
KEY_FILE="$AGENT_DIR/license.key"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [gnodi-agent] $*"; }

[ -f "$KEY_FILE" ] || { log "No license key at $KEY_FILE — run the installer first."; exit 1; }
LICENSE_KEY=$(cat "$KEY_FILE")
CURRENT_VERSION=$(${GNODID_BIN} version 2>/dev/null | head -1 || echo "unknown")

# ── Heartbeat ─────────────────────────────────────────────────────────────────
log "Sending heartbeat (version: $CURRENT_VERSION)..."
RESPONSE=$(curl -sf -X POST "$API_BASE/nodes/heartbeat" \
    -H "X-LICENSE-KEY: $LICENSE_KEY" \
    -H "X-NODE-VERSION: $CURRENT_VERSION") || { log "Heartbeat request failed."; exit 1; }

RECORDED=$(echo "$RESPONSE"      | jq -r '.recorded')
POINTS=$(echo "$RESPONSE"        | jq -r '.points')
LATEST_VERSION=$(echo "$RESPONSE" | jq -r '.latestVersion // empty')
DOWNLOAD_URL=$(echo "$RESPONSE"   | jq -r '.downloadUrl // empty')

if [ "$RECORDED" = "true" ]; then
    log "Heartbeat recorded. Points earned: $POINTS"
else
    log "Heartbeat received (already recorded today)."
fi

# ── Auto-update ───────────────────────────────────────────────────────────────
if [ -n "$LATEST_VERSION" ] && [ -n "$DOWNLOAD_URL" ]; then
    log "New version available: $LATEST_VERSION (current: $CURRENT_VERSION). Updating..."
    TMP_BIN=$(mktemp)
    if curl -fL "$DOWNLOAD_URL" -o "$TMP_BIN"; then
        chmod +x "$TMP_BIN"
        mv "$TMP_BIN" "$GNODID_BIN"
        log "Updated to $LATEST_VERSION."
        # Restart gnodid if it is running as a service
        if systemctl is-active --quiet gnodid 2>/dev/null; then
            systemctl restart gnodid
            log "gnodid service restarted."
        fi
    else
        rm -f "$TMP_BIN"
        log "Download failed — will retry on next heartbeat."
    fi
fi
