#!/usr/bin/env bash
set -euo pipefail

AGENT_VERSION="2.0.0"
API_BASE="https://api.gnodiservices.com"
AGENT_DIR="/opt/gnodi-agent"
SERVICE_NAME="gnodi-agent"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[gnodi]${NC} $*"; }
warn()  { echo -e "${YELLOW}[gnodi]${NC} $*"; }
error() { echo -e "${RED}[gnodi]${NC} $*"; exit 1; }

# ── Requirements ──────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "Run this script as root (sudo bash install.sh)"
command -v systemctl &>/dev/null || error "systemd is required but not found."

MISSING_PKGS=()
command -v curl &>/dev/null || MISSING_PKGS+=(curl)
command -v jq   &>/dev/null || MISSING_PKGS+=(jq)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    info "Installing dependencies: ${MISSING_PKGS[*]}..."
    apt-get update -q && apt-get install -y "${MISSING_PKGS[@]}" > /dev/null \
        || error "Failed to install dependencies. Run: apt-get install ${MISSING_PKGS[*]}"
fi

# ── Clean up legacy gnodid installation ───────────────────────────────────────
if [ -f "/usr/local/bin/gnodid" ] || [ -d "/var/lib/gnodi-nodes" ]; then
    warn "Legacy gnodid installation detected."
    info "Removing gnodid binary and node data..."
    rm -f /usr/local/bin/gnodid
    rm -rf /var/lib/gnodi-nodes
    rm -f "$AGENT_DIR/node.home" "$AGENT_DIR/node.id"
    info "Legacy files removed."
fi

# ── License key ───────────────────────────────────────────────────────────────
if [ -f "$AGENT_DIR/license.key" ]; then
    EXISTING_KEY=$(cat "$AGENT_DIR/license.key")
    warn "Existing license key found: ${EXISTING_KEY:0:9}..."
    read -rp "Re-use existing key? [Y/n]: " REUSE
    if [[ "${REUSE:-Y}" =~ ^[Yy]$ ]]; then
        LICENSE_KEY="$EXISTING_KEY"
    else
        read -rp "Enter new license key: " LICENSE_KEY
    fi
else
    read -rp "Enter your license key: " LICENSE_KEY
fi
[ -n "$LICENSE_KEY" ] || error "License key is required."

# ── Activate license ──────────────────────────────────────────────────────────
info "Activating license..."
ACTIVATE_RESPONSE=$(curl -sf -w "\n%{http_code}" -X POST "$API_BASE/nodes/activate" \
    -H "Content-Type: application/json" \
    -d "{\"licenseKey\": \"$LICENSE_KEY\", \"nodeVersion\": \"$AGENT_VERSION\"}")
HTTP_CODE=$(echo "$ACTIVATE_RESPONSE" | tail -1)
BODY=$(echo "$ACTIVATE_RESPONSE" | head -1)

if [ "$HTTP_CODE" != "200" ]; then
    MSG=$(echo "$BODY" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "$BODY")
    error "Activation failed ($HTTP_CODE): $MSG"
fi

MEMBER_ID=$(echo "$BODY"    | jq -r '.memberId')
LICENSE_TYPE=$(echo "$BODY" | jq -r '.licenseType')
info "Activated! Member: $MEMBER_ID | License: $LICENSE_TYPE"

# ── Save agent state ──────────────────────────────────────────────────────────
mkdir -p "$AGENT_DIR"
echo "$LICENSE_KEY" > "$AGENT_DIR/license.key"
chmod 600 "$AGENT_DIR/license.key"

# ── Install agent script ──────────────────────────────────────────────────────
AGENT_SCRIPT="$AGENT_DIR/gnodi-agent.sh"
AGENT_URL="https://raw.githubusercontent.com/gnodi-ecosystem/gnodi-node-setup/main/gnodi-agent.sh"
info "Installing gnodi-agent..."
curl -fsSL "$AGENT_URL" -o "$AGENT_SCRIPT" || error "Failed to download gnodi-agent.sh"
chmod +x "$AGENT_SCRIPT"

# ── Systemd: gnodi-agent heartbeat timer ──────────────────────────────────────
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Gnodi Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AGENT_SCRIPT}
StandardOutput=journal
StandardError=journal
EOF

cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Gnodi Node Agent Daily Heartbeat
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=*-*-* 00:30:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.timer"

# ── Run first heartbeat ───────────────────────────────────────────────────────
info "Sending initial heartbeat..."
systemctl start "${SERVICE_NAME}.service" \
    && info "Heartbeat sent." \
    || warn "Heartbeat failed — will retry tomorrow."

echo ""
info "Setup complete!"
echo "  Agent version  : $AGENT_VERSION"
echo "  Member ID      : $MEMBER_ID"
echo "  License type   : $LICENSE_TYPE"
echo "  Heartbeat      : daily at 00:30 UTC (±1h jitter)"
echo ""
info "Useful commands:"
echo "  Heartbeat logs : journalctl -u gnodi-agent -f"
echo "  Timer status   : systemctl status gnodi-agent.timer"
