#!/usr/bin/env bash
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
API_BASE="https://api.gnodiservices.com"
AGENT_DIR="/opt/gnodi-agent"
GNODID_BIN="/usr/local/bin/gnodid"
NODES_BASE_DIR="/var/lib/gnodi-nodes"
SERVICE_NAME="gnodi-agent"

# Chain configuration
CHAIN_ID="gnodi"
EVM_CHAIN_ID="46634"
MIN_GAS_PRICES="0.025uGNOD"
GENESIS_URL="https://raw.githubusercontent.com/gnodi-network/genesis-mainnet/refs/heads/main/genesis.json"
PERSISTENT_PEERS="cd0f4a3e82fa723b5b2d41480d72b0488b49ef34@146.190.38.60:26656,55bb9b88bcfdd0de814426c024550b2599ae43c6@peer-gnodi.vinjan-inc.com:15556"

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
command -v lz4  &>/dev/null || MISSING_PKGS+=(lz4)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    info "Installing dependencies: ${MISSING_PKGS[*]}..."
    apt-get update -q && apt-get install -y "${MISSING_PKGS[@]}" > /dev/null \
        || error "Failed to install dependencies. Run: apt-get install ${MISSING_PKGS[*]}"
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

# ── Fetch current gnodid version ──────────────────────────────────────────────
info "Fetching current node version..."
VERSION_JSON=$(curl -sf "$API_BASE/nodes/version") || error "Could not reach $API_BASE. Check your connection."
GNODID_VERSION=$(echo "$VERSION_JSON" | jq -r '.version')
DOWNLOAD_URL=$(echo "$VERSION_JSON"   | jq -r '.downloadUrl')
[ -n "$GNODID_VERSION" ] || error "No version info returned from server."

# ── Install gnodid ────────────────────────────────────────────────────────────
CURRENT_VERSION=""
if command -v gnodid &>/dev/null; then
    CURRENT_VERSION=$(gnodid version 2>/dev/null | head -1 || echo "")
fi

if [ "$CURRENT_VERSION" = "$GNODID_VERSION" ]; then
    info "gnodid $GNODID_VERSION already installed."
else
    info "Downloading gnodid $GNODID_VERSION..."
    curl -fL "$DOWNLOAD_URL" -o "$GNODID_BIN" || error "Failed to download gnodid from $DOWNLOAD_URL"
    chmod +x "$GNODID_BIN"
    info "gnodid $GNODID_VERSION installed."
fi

# ── Activate license ──────────────────────────────────────────────────────────
info "Activating license..."
ACTIVATE_RESPONSE=$(curl -sf -w "\n%{http_code}" -X POST "$API_BASE/nodes/activate" \
    -H "Content-Type: application/json" \
    -d "{\"licenseKey\": \"$LICENSE_KEY\", \"nodeVersion\": \"$GNODID_VERSION\"}")
HTTP_CODE=$(echo "$ACTIVATE_RESPONSE" | tail -1)
BODY=$(echo "$ACTIVATE_RESPONSE" | head -1)

if [ "$HTTP_CODE" != "200" ]; then
    MSG=$(echo "$BODY" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "$BODY")
    error "Activation failed ($HTTP_CODE): $MSG"
fi

MEMBER_ID=$(echo "$BODY"    | jq -r '.memberId')
LICENSE_TYPE=$(echo "$BODY" | jq -r '.licenseType')
info "Activated! Member: $MEMBER_ID | License: $LICENSE_TYPE"

# ── Node home directory ───────────────────────────────────────────────────────
# Derive a stable, filesystem-safe node ID from the license key.
# Uses first 16 alphanumeric chars (lowercase) — unique per key, stable across reinstalls.
NODE_ID=$(echo "$LICENSE_KEY" | tr -dc 'A-Za-z0-9' | tr '[:upper:]' '[:lower:]' | head -c 16)
NODE_HOME="$NODES_BASE_DIR/$NODE_ID"
MONIKER="gnodi-$NODE_ID"

info "Node home: $NODE_HOME"
mkdir -p "$NODE_HOME"

# ── Initialize chain (once per node) ──────────────────────────────────────────
if [ ! -f "$NODE_HOME/config/genesis.json" ]; then
    info "Initializing node for Gnodi mainnet..."
    "$GNODID_BIN" init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME" > /dev/null

    info "Downloading genesis..."
    curl -fsSL "$GENESIS_URL" -o "$NODE_HOME/config/genesis.json" \
        || error "Failed to download genesis from $GENESIS_URL"

    info "Configuring peers..."
    sed -i "s|^persistent_peers = .*|persistent_peers = \"$PERSISTENT_PEERS\"|" \
        "$NODE_HOME/config/config.toml"

    info "Configuring app settings..."
    sed -i "s|^minimum-gas-prices = .*|minimum-gas-prices = \"$MIN_GAS_PRICES\"|" \
        "$NODE_HOME/config/app.toml"

    # Enable Prometheus metrics endpoint (localhost:26660)
    sed -i 's|^prometheus = false|prometheus = true|' \
        "$NODE_HOME/config/config.toml"

    # Pruning: keep last 100k blocks, prune every 100 — balances disk use vs. query range
    sed -i 's|^pruning = .*|pruning = "custom"|' \
        "$NODE_HOME/config/app.toml"
    sed -i 's|^pruning-keep-recent = .*|pruning-keep-recent = "100000"|' \
        "$NODE_HOME/config/app.toml"
    sed -i 's|^pruning-interval = .*|pruning-interval = "100"|' \
        "$NODE_HOME/config/app.toml"

    # ── State sync ────────────────────────────────────────────────────────────
    # Configures CometBFT state sync so the node catches up in minutes instead
    # of days. Trust height is set 1000 blocks behind the current tip.
    SNAP_RPC="https://rpc.gnodi.nodestake.org"
    info "Fetching state sync trust height from $SNAP_RPC..."
    LATEST_HEIGHT=$(curl -sf "$SNAP_RPC/block" | jq -r '.result.block.header.height')
    BLOCK_HEIGHT=$((LATEST_HEIGHT - 1000))
    TRUST_HASH=$(curl -sf "$SNAP_RPC/block?height=$BLOCK_HEIGHT" | jq -r '.result.block_id.hash')
    info "State sync: trust height=$BLOCK_HEIGHT hash=${TRUST_HASH:0:16}..."

    # Scope edits to the [statesync] section only to avoid touching other 'enable' fields
    sed -i '/^\[statesync\]/,/^\[/{
        s|^enable = .*|enable = true|
        s|^rpc_servers = .*|rpc_servers = "'"$SNAP_RPC"','"$SNAP_RPC"'"|
        s|^trust_height = .*|trust_height = '"$BLOCK_HEIGHT"'|
        s|^trust_hash = .*|trust_hash = "'"$TRUST_HASH"'"|
    }' "$NODE_HOME/config/config.toml"

    # Download wasm state — not included in state sync snapshots
    info "Downloading wasm state..."
    rm -rf "$NODE_HOME/wasm"
    curl -o - -L "https://ss.gnodi.nodestake.org/wasm.tar.lz4" \
        | lz4 -dc - | tar -xf - -C "$NODE_HOME" \
        || warn "Wasm download failed — node may need manual wasm restore if EVM fails to start."

    info "Node initialized."
else
    info "Node already initialized at $NODE_HOME — skipping chain init."
fi

# ── Save agent state ──────────────────────────────────────────────────────────
mkdir -p "$AGENT_DIR"
echo "$LICENSE_KEY" > "$AGENT_DIR/license.key"
chmod 600 "$AGENT_DIR/license.key"
echo "$NODE_HOME" > "$AGENT_DIR/node.home"
echo "$NODE_ID"   > "$AGENT_DIR/node.id"

# ── Install agent script ──────────────────────────────────────────────────────
AGENT_SCRIPT="$AGENT_DIR/gnodi-agent.sh"
AGENT_URL="https://raw.githubusercontent.com/gnodi-ecosystem/gnodi-node-setup/main/gnodi-agent.sh"
info "Installing gnodi-agent..."
curl -fsSL "$AGENT_URL" -o "$AGENT_SCRIPT" || error "Failed to download gnodi-agent.sh"
chmod +x "$AGENT_SCRIPT"

# ── Systemd: gnodid node service ──────────────────────────────────────────────
info "Creating gnodid systemd service..."
cat > /etc/systemd/system/gnodid.service <<EOF
[Unit]
Description=Gnodi Node ($NODE_ID)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$GNODID_BIN start \\
    --chain-id $CHAIN_ID \\
    --evm.evm-chain-id $EVM_CHAIN_ID \\
    --minimum-gas-prices $MIN_GAS_PRICES \\
    --home $NODE_HOME
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

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
systemctl enable gnodid
systemctl enable --now "${SERVICE_NAME}.timer"

# ── Start gnodid ──────────────────────────────────────────────────────────────
info "Starting gnodid..."
systemctl start gnodid

# ── Run first heartbeat ───────────────────────────────────────────────────────
info "Sending initial heartbeat..."
systemctl start "${SERVICE_NAME}.service" \
    && info "Heartbeat sent." \
    || warn "Heartbeat failed — will retry tomorrow."

echo ""
info "Setup complete!"
echo "  gnodid version : $GNODID_VERSION"
echo "  Member ID      : $MEMBER_ID"
echo "  License type   : $LICENSE_TYPE"
echo "  Node ID        : $NODE_ID"
echo "  Node home      : $NODE_HOME"
echo "  Chain          : $CHAIN_ID (EVM chain ID: $EVM_CHAIN_ID)"
echo "  Heartbeat      : daily at 00:30 UTC (±1h jitter)"
echo ""
info "Useful commands:"
echo "  Status  : systemctl status gnodid"
echo "  Logs    : journalctl -u gnodid -f"
echo "  Sync    : $GNODID_BIN status --home $NODE_HOME | jq .sync_info"
