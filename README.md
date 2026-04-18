# dns_integrations

Integrations for the [SecondDNS](https://seconddns.com) secondary DNS service — hosting panels, monitoring systems, and more.

## Available Integrations

| Integration | Directory | Description |
|---|---|---|
| CyberPanel | [cyberpanel/](cyberpanel/) | Auto-sync DNS zones on domain create/delete |
| Nagios / Icinga | [nagios_plugins/](nagios_plugins/) | Health check plugin with Nagios exit codes |
| Zabbix | [zabbix_templates/](zabbix_templates/) | HTTP Agent template with triggers |

## Quick Start — CyberPanel

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

See [cyberpanel/INSTALL.md](cyberpanel/INSTALL.md) for detailed instructions.

## Quick Start — Monitoring

**Nagios / Icinga:**
```bash
curl -o /usr/lib/nagios/plugins/check_seconddns.sh \
  https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/nagios_plugins/check_seconddns.sh
chmod +x /usr/lib/nagios/plugins/check_seconddns.sh

./check_seconddns.sh -k YOUR_API_KEY
```

**Zabbix:**
```bash
curl -O https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/zabbix_templates/seconddns_health.yaml
# Import in Zabbix: Data collection → Templates → Import
```

See [nagios_plugins/README.md](nagios_plugins/README.md) and [zabbix_templates/README.md](zabbix_templates/README.md) for full setup guides.

## API

All integrations use the SecondDNS REST API:

```
GET    /api/zones                    — List zones
POST   /api/zones                    — Add zone { "name": "...", "masterIp": "..." }
GET    /api/zones/by-name/{name}     — Find zone by domain
DELETE /api/zones/{id}               — Remove zone
GET    /api/health/zones             — Zone health status (JSON)
GET    /api/health/zones?format=nagios — Nagios-compatible output
GET    /api/server-info              — DNS server IPs
```

Authentication: `X-API-Key` header. Get your key from [Dashboard → API Key](https://seconddns.com/dashboard/api-key).

Full API documentation: [seconddns.com/docs/api](https://seconddns.com/docs/api)
