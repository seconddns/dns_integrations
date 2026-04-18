# CyberPanel Installation Guide

## One-command install

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

This will:
- Verify your API key
- Auto-detect your server's public IP (master DNS)
- Install the CLI tool (`/usr/local/bin/seconddns`)
- Write config to `/etc/seconddns.conf`
- Register Django signals in CyberPanel (auto-sync on domain create/delete)
- Install a systemd hook to survive CyberPanel updates
- Configure PowerDNS for AXFR zone transfers
- Offer to sync existing domains

## Prerequisites

- CyberPanel installed at `/usr/local/CyberCP`
- PowerDNS running as the DNS server
- A SecondDNS account with an API key ([get one here](https://seconddns.com/dashboard/api-key))
- Root access

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--api-key=KEY` | Your SecondDNS API key | **required** |
| `--api-url=URL` | API base URL | `https://seconddns.com` |
| `--master-ip=IP` | Primary DNS server IP | auto-detect via ipify |
| `--yes` / `-y` | Skip all confirmation prompts | interactive |

## Examples

```bash
# Basic (interactive — will ask confirmations)
curl -sL .../install.sh | bash -s -- --api-key=abc123

# Non-interactive (CI/automation)
curl -sL .../install.sh | bash -s -- --api-key=abc123 --yes

# Custom master IP (PowerDNS on a different server)
curl -sL .../install.sh | bash -s -- --api-key=abc123 --master-ip=203.0.113.10

# Self-hosted SecondDNS
curl -sL .../install.sh | bash -s -- --api-key=abc123 --api-url=https://dns.example.com
```

## What gets installed

| File | Purpose |
|------|---------|
| `/usr/local/bin/seconddns` | CLI tool |
| `/etc/seconddns.conf` | Configuration (API key, master IP) |
| `/var/log/seconddns.log` | Log file |
| `/usr/local/CyberCP/plogical/seconddns_plugin.py` | Django signal plugin |
| `/etc/systemd/system/seconddns-signals.service` | Systemd hook for update resilience |

## CLI commands

After installation, you can manage zones manually:

```bash
seconddns list                  # Show zones on secondary DNS
seconddns sync                  # Sync all CyberPanel domains
seconddns add example.com       # Add zone manually
seconddns remove example.com    # Remove zone manually
seconddns ensure-signals        # Re-register signals (runs automatically on lscpd restart)
```

## How auto-sync works

```
Domain created in CyberPanel
       ↓
Django signal (postZoneCreation)
       ↓
seconddns_plugin.py → POST /api/zones
       ↓
SecondDNS creates slave zone → AXFR from your master
```

Same flow in reverse on domain deletion.

## CyberPanel updates

The installer adds a systemd service (`seconddns-signals.service`) that re-registers signals every time CyberPanel (lscpd) restarts. If an update overwrites `wsgi.py`, signals are restored automatically on the next restart.

## Uninstall

```bash
# Remove signals from wsgi.py
seconddns ensure-signals  # cleans first, but we won't re-add
python3 -c "
import re
for p in ['/usr/local/CyberCP/CyberCP/wsgi.py']:
    with open(p) as f: c = f.read()
    c = re.sub(r'\n*# SecondDNS.*?getLogger.*?\n', '', c, flags=re.DOTALL)
    with open(p, 'w') as f: f.write(c)
"

# Remove files
rm -f /usr/local/bin/seconddns
rm -f /etc/seconddns.conf
rm -f /usr/local/CyberCP/plogical/seconddns_plugin.py
rm -f /etc/systemd/system/seconddns-signals.service
systemctl daemon-reload

# Restart CyberPanel
systemctl restart lscpd
```

## Troubleshooting

**Signals not firing:**
```bash
tail -f /var/log/seconddns.log
# Should show "SecondDNS signals registered (dns zone hooks)." after lscpd restart
```

**Permission denied on log:**
```bash
chown cyberpanel:cyberpanel /var/log/seconddns.log
chmod 664 /var/log/seconddns.log
```

**API key error:**
```bash
curl -sI -H "X-API-Key: YOUR_KEY" https://seconddns.com/api/zones
# Should return HTTP 200, not 401/403
```

**AXFR not working:**
```bash
grep -E "^master=|^allow-axfr-ips=|^also-notify=" /etc/pdns/pdns.conf
# Should show master=yes, allow-axfr-ips with secondary DNS IP, also-notify
```

**Duplicate log entries:**
```bash
grep -c "seconddns_plugin" /usr/local/CyberCP/CyberCP/wsgi.py
# Should be exactly 1. If more, run:
seconddns ensure-signals
systemctl restart lscpd
```
