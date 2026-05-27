# Gnodi Node Setup

## New Installation

Install and register a Gnodi node with a single command:

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/gnodi-ecosystem/gnodi-node-setup/main/install.sh)
```

You will be prompted for your license key during setup. Your license key is visible in your Gnodi account.

## Transitioning an Existing Node

If you are already running a Gnodi node, run the same command:

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/gnodi-ecosystem/gnodi-node-setup/main/install.sh)
```

The script is safe to run on an existing node. It will:

- Skip the `gnodid` download if you are already on the latest version
- Register your license key with the new system
- Install the `gnodi-agent` service for daily heartbeat reporting

Your node will continue running uninterrupted during the process.

## What Gets Installed

| Component | Description |
|-----------|-------------|
| `gnodid` | The Gnodi blockchain node binary |
| `gnodi-agent` | A daily systemd service that sends your heartbeat and auto-updates `gnodid` when new versions are available |

## Requirements

- Ubuntu 16.04 or later (or any Debian-based Linux with systemd)
- Root / sudo access
- Your Gnodi license key
