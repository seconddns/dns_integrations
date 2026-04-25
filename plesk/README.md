# SecondDNS — Plesk Hosting Panel Integration

Automatic secondary DNS for Plesk servers. Uses Plesk Event Manager to sync domain creation and deletion to SecondDNS via API + AXFR.

## How It Works

Two shell scripts are registered as Plesk event handlers:

1. **Domain created** — calls SecondDNS API to register the zone
2. **Domain deleted** — removes the zone from SecondDNS

After zone registration, SecondDNS pulls the full zone via AXFR. Subsequent changes propagate via BIND/PowerDNS NOTIFY.

Handles both regular domains and default (subscription) domains.

## Requirements

- Plesk Obsidian (18.x+)
- Root access
- BIND or PowerDNS as DNS server
- TCP port 53 open to SecondDNS
- SecondDNS API key

## Installation

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/plesk/install.sh | bash -s -- --api-key=YOUR_API_KEY
```

The installer:
- Verifies the API key
- Detects server IP (IPv4/IPv6)
- Installs event handler scripts to `/usr/local/bin/`
- Registers Plesk event handlers via CLI
- Configures BIND/PowerDNS for AXFR (allow-transfer, also-notify)
- Offers to sync existing domains

### Options

| Flag | Description |
|---|---|
| `--api-key=KEY` | SecondDNS API key (required) |
| `--api-url=URL` | API base URL (default: `https://seconddns.com`) |
| `--master-ip=IP` | Primary DNS IP (default: auto-detect) |
| `--yes` | Skip confirmation prompts |

## Nameserver Configuration

After installation, add the secondary nameserver in Plesk:

1. Go to **Tools & Settings** → **DNS Template**
2. Add NS record: `ns2.seconddns.com`

For existing domains, add the NS record through each domain's DNS settings or use the Plesk mass update feature.

## Verification

```bash
# Check registered handlers
plesk bin event_handler --list

# Watch the log
tail -f /var/log/seconddns.log

# Compare SOA on both nameservers
dig @your-server-ip example.com SOA +short
dig @ns2.seconddns.com example.com SOA +short
```

## Supported Events

| Plesk Event ID | Description | Action |
|---|---|---|
| `domain_create` | Default domain (first in subscription) created | Add zone to SecondDNS |
| `site_create` | Additional domain created | Add zone to SecondDNS |
| `domain_delete` | Default domain deleted | Remove zone from SecondDNS |
| `site_delete` | Additional domain deleted | Remove zone from SecondDNS |

## Troubleshooting

**Zone not appearing on secondary:**
Check `/var/log/seconddns.log`. Verify event handlers are registered:
```bash
plesk bin event_handler --list | grep seconddns
```

**AXFR refused:**
Check BIND `allow-transfer` in `named.conf` or PowerDNS `allow-axfr-ips` in `pdns.conf`.

**Timeout:**
Verify TCP port 53 is open. AXFR uses TCP.

**Test handler manually:**
```bash
NEW_DOMAIN_NAME=example.com /usr/local/bin/seconddns-plesk-domain_create.sh
```

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/plesk/uninstall.sh | bash
```

Removes event handlers, scripts, and config. Zones on the secondary are not deleted automatically.

## Files

| Path | Description |
|---|---|
| `/etc/seconddns.conf` | API credentials and master IP |
| `/usr/local/bin/seconddns-plesk-domain_create.sh` | Domain creation handler |
| `/usr/local/bin/seconddns-plesk-domain_delete.sh` | Domain deletion handler |
| `/var/log/seconddns.log` | Integration log |
