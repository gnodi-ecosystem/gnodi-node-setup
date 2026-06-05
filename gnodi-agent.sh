#!/usr/bin/env bash
set -euo pipefail

API_BASE="https://api.gnodiservices.com"
AGENT_DIR="/opt/gnodi-agent"
GNODID_BIN="/usr/local/bin/gnodid"
KEY_FILE="$AGENT_DIR/license.key"
HOME_FILE="$AGENT_DIR/node.home"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [gnodi-agent] $*"; }

[ -f "$KEY_FILE" ] || { log "No license key at $KEY_FILE — run the installer first."; exit 1; }
LICENSE_KEY=$(cat "$KEY_FILE")
CURRENT_VERSION=$("$GNODID_BIN" version 2>/dev/null | head -1 || echo "unknown")

# ── Collect node metrics ───────────────────────────────────────────────────────
BLOCK_HEIGHT="0"
CATCHING_UP="unknown"
NUM_PEERS="0"

if [ -f "$HOME_FILE" ]; then
    NODE_HOME=$(cat "$HOME_FILE")
    STATUS_JSON=$("$GNODID_BIN" status --home "$NODE_HOME" 2>/dev/null || echo "{}")
    BLOCK_HEIGHT=$(echo "$STATUS_JSON" | jq -r '.sync_info.latest_block_height // "0"' 2>/dev/null || echo "0")
    CATCHING_UP=$(echo "$STATUS_JSON"  | jq -r '.sync_info.catching_up // "unknown"' 2>/dev/null || echo "unknown")
    NUM_PEERS=$(curl -sf "http://localhost:26657/net_info" 2>/dev/null \
        | jq -r '.result.n_peers // "0"' 2>/dev/null || echo "0")
fi

# ── Heartbeat ─────────────────────────────────────────────────────────────────
log "Sending heartbeat (version: $CURRENT_VERSION, block: $BLOCK_HEIGHT, syncing: $CATCHING_UP, peers: $NUM_PEERS)..."
RESPONSE=$(curl -sf -X POST "$API_BASE/nodes/heartbeat" \
    -H "X-LICENSE-KEY: $LICENSE_KEY" \
    -H "X-NODE-VERSION: $CURRENT_VERSION" \
    -H "X-BLOCK-HEIGHT: $BLOCK_HEIGHT" \
    -H "X-CATCHING-UP: $CATCHING_UP" \
    -H "X-NUM-PEERS: $NUM_PEERS") || { log "Heartbeat request failed."; exit 1; }

RECORDED=$(echo "$RESPONSE"       | jq -r '.recorded')
POINTS=$(echo "$RESPONSE"         | jq -r '.points')
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
        if systemctl is-active --quiet gnodid 2>/dev/null; then
            systemctl restart gnodid
            log "gnodid service restarted."
        fi
    else
        rm -f "$TMP_BIN"
        log "Download failed — will retry on next heartbeat."
    fi
fi
