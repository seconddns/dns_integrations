# dns_integrations

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![License: Commercial](https://img.shields.io/badge/License-Commercial-blue.svg)](LICENSE.COMMERCIAL)

Integrations for [SecondDNS](https://seconddns.com) — a secondary DNS service that keeps your zones in sync via AXFR zone transfers. This repository contains hosting panel plugins and monitoring templates that automate zone registration and health checks.

---

## How it works

```
Domain created in hosting panel
         ↓
Hook / Event handler (this repo)
         ↓
POST /api/zones → SecondDNS registers slave zone
         ↓
AXFR transfer: your master → SecondDNS secondary
         ↓
NOTIFY on every subsequent change → instant propagation
```

All integrations use the same pattern: catch the panel event, call the SecondDNS API, let AXFR do the rest.

---

## Hosting panels

| Panel | Mechanism | Tested on |
|:------|:----------|:----------|
| [CyberPanel](hosting-panels/cyberpanel/) | Django signals (`postWebsiteCreation`, `postZoneCreation`) | CyberPanel 2.4.5 |
| [DirectAdmin](hosting-panels/directadmin/) | Custom hooks (`dns_create_post`, `dns_delete_post`) | DirectAdmin 1.699 |
| [Plesk](hosting-panels/plesk/) | Event Manager (12 events, incl. rename + aliases) | Plesk Obsidian 18.0.77.2 |

### Quick install

All installers accept `--api-key=YOUR_API_KEY` and are safe to run as root:

```bash
# CyberPanel
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY

# DirectAdmin
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/directadmin/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY

# Plesk
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/plesk/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

See the README in each directory for options, AXFR configuration, and troubleshooting.

---

## Monitoring

| Tool | Type | What it checks |
|:-----|:-----|:---------------|
| [Nagios / Icinga](nagios_plugins/) | Check plugin (bash) | Zone sync status, stale zones, master reachability |
| [Zabbix](zabbix_templates/) | HTTP Agent template | Zone counters, triggers, graphs — no agent required |

Both integrations use the SecondDNS API key. See the README in each directory for installation and configuration.

---

## Requirements

- SecondDNS account and API key — [get one here](https://seconddns.com/dashboard/api-key)
- TCP port 53 open from your server to the SecondDNS secondary nameserver IP
- BIND or PowerDNS configured with `allow-transfer` and `also-notify` for the secondary IP

---

## License

Dual-licensed:

- **[GPL-3.0](LICENSE)** — free for open-source and personal use
- **[Commercial](LICENSE.COMMERCIAL)** — available for commercial deployments; contact [SecondDNS](https://seconddns.com) for details
