# CyberPanel Integration

Automatic secondary DNS zone management for CyberPanel servers. When a DNS zone is created or deleted in CyberPanel, the secondary DNS zone is instantly synced via API.

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

That's it. The installer handles everything — config, signals, PowerDNS AXFR, systemd hook.

See [INSTALL.md](INSTALL.md) for options, troubleshooting, and uninstall instructions.

## How It Works

```
Domain/zone created in CyberPanel
       ↓
Django signal (postWebsiteCreation / postZoneCreation)
       ↓
seconddns_plugin.py:
  1. Changes zone type NATIVE → MASTER (so AXFR works)
  2. POST /api/zones → SecondDNS creates slave zone
       ↓
AXFR transfer from your master to SecondDNS
```

Listens to both website signals (`postWebsiteCreation`, `postWebsiteDeletion`) and DNS zone signals (`postZoneCreation`, `postSubmitZoneDeletion`) — covers domain creation from any CyberPanel UI path.

CyberPanel creates zones as `NATIVE` type by default, which blocks AXFR transfers. The plugin automatically updates the zone type to `MASTER` via Django DB connection before registering it with the secondary DNS.

## CyberPanel Update Resilience

CyberPanel updates can overwrite `wsgi.py` and remove our signal hooks. To handle this, the installer adds a systemd service (`seconddns-signals.service`) that is bound to `lscpd.service`. On every lscpd restart — including after CyberPanel updates — it automatically:

1. Cleans any duplicate signal blocks
2. Re-registers exactly one signal block in `wsgi.py`

No manual intervention needed.

## CLI Commands

```bash
seconddns list               # Show zones on secondary DNS
seconddns sync               # Sync all CyberPanel domains
seconddns add example.com    # Add zone manually
seconddns remove example.com # Remove zone manually
```

## Files

| File | Purpose |
|------|---------|
| `/usr/local/bin/seconddns` | CLI tool |
| `/etc/seconddns.conf` | Config (API key, master IP) |
| `/var/log/seconddns.log` | Log file |
| `/usr/local/CyberCP/plogical/seconddns_plugin.py` | Signal plugin |
| `/etc/systemd/system/seconddns-signals.service` | Update resilience hook |

## Requirements

- CyberPanel 2.x+ with PowerDNS
- Root access
- SecondDNS API key ([get one here](https://seconddns.com/dashboard/api-key))
