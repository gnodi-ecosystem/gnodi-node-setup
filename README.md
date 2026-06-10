# Gnodi Node Setup

## New Installation

Install and register a Gnodi node with a single command:

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/gnodi-ecosystem/gnodi-node-setup/main/install.sh)
```

You will be prompted for your license key during setup. Your license key is visible in your Gnodi account.

## Transitioning an Existing Node

If you previously installed a Gnodi node, run the same command:

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/gnodi-ecosystem/gnodi-node-setup/main/install.sh)
```

The script is safe to run on an existing node. It will:

- Automatically remove the legacy `gnodid` binary and node data directory
- Register your license key with the updated agent
- Reconfigure the `gnodi-agent` systemd service

## What Gets Installed

| Component | Description |
|-----------|-------------|
| `gnodi-agent` | A lightweight daily systemd service that sends your heartbeat to the Gnodi network |

## Requirements

- Ubuntu 16.04 or later (or any Debian-based Linux with systemd)
- Root / sudo access
- Your Gnodi license key
