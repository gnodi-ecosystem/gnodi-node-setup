#!/usr/bin/env bash
set -euo pipefail

AGENT_VERSION="2.0.0"
API_BASE="https://api.gnodiservices.com"
AGENT_DIR="/opt/gnodi-agent"
KEY_FILE="$AGENT_DIR/license.key"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [gnodi-agent] $*"; }

[ -f "$KEY_FILE" ] || { log "No license key at $KEY_FILE — run the installer first."; exit 1; }
LICENSE_KEY=$(cat "$KEY_FILE")

# ── Heartbeat ─────────────────────────────────────────────────────────────────
log "Sending heartbeat (agent: $AGENT_VERSION)..."

RESPONSE=$(curl -sf -X POST "$API_BASE/nodes/heartbeat" \
    -H "X-LICENSE-KEY: $LICENSE_KEY" \
    -H "X-NODE-VERSION: $AGENT_VERSION") || { log "Heartbeat request failed."; exit 1; }

RECORDED=$(echo "$RESPONSE" | jq -r '.recorded')
POINTS=$(echo "$RESPONSE"   | jq -r '.points')

if [ "$RECORDED" = "true" ]; then
    log "Heartbeat recorded. Points earned: $POINTS"
else
    log "Heartbeat received (already recorded today)."
fi
