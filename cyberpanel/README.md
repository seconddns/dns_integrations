# CyberPanel Integration

Automatic secondary DNS zone management for CyberPanel servers.

## How It Works

Hooks into CyberPanel's Django signal system (`postWebsiteCreation`, `postWebsiteDeletion`). When a domain is created or deleted in CyberPanel, the secondary DNS zone is instantly added or removed via API. No polling, no delays.

## Quick Install

```bash
git clone https://github.com/0kaba0hub/dns_integrations.git
cd dns_integrations/cyberpanel
sudo bash install.sh
```

Edit `/etc/seconddns.conf`:

```ini
[seconddns]
api_url = https://seconddns.com
api_key = YOUR_API_KEY_HERE
master_ip =
```

Run initial sync:

```bash
seconddns sync
```

## Usage

```bash
# Sync all existing domains
seconddns sync

# List zones on secondary DNS
seconddns list

# Manually add/remove
seconddns add example.com
seconddns remove example.com
```

## What Gets Installed

| File | Purpose |
|---|---|
| `/usr/local/bin/seconddns` | CLI script |
| `/etc/seconddns.conf` | Configuration (API key, URL) |
| `/usr/local/CyberCP/plogical/seconddns_plugin.py` | Django signal handlers |
| `/var/log/seconddns.log` | Log file |

The installer also registers signal handlers in CyberPanel's startup (`ready.py`).

## Logs

```bash
tail -f /var/log/seconddns.log
```

## Uninstall

```bash
sudo rm /usr/local/bin/seconddns
sudo rm /usr/local/CyberCP/plogical/seconddns_plugin.py
# Remove the seconddns block from /usr/local/CyberCP/CyberCP/ready.py
sudo systemctl restart lscpd
# Optionally: sudo rm /etc/seconddns.conf
```

## Requirements

- Python 3.6+ (ships with CyberPanel)
- CyberPanel 2.x+
- Network access to secondary DNS API
- Primary DNS configured to allow AXFR from secondary DNS server IP
