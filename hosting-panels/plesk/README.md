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
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/plesk/install.sh | bash -s -- --api-key=YOUR_API_KEY
```

The installer:
- Verifies the API key
- Detects server IP (IPv4/IPv6)
- Installs event handler scripts to `/usr/local/bin/`
- Registers Plesk event handlers via CLI
- Adds the secondary nameserver to the DNS template
- Offers to sync existing domains

### Options

| Flag | Description |
|---|---|
| `--api-key=KEY` | SecondDNS API key (required) |
| `--api-url=URL` | API base URL (default: `https://seconddns.com`) |
| `--master-ip=IP` | Primary DNS IP (default: auto-detect) |
| `--yes` | Skip confirmation prompts |

## AXFR Configuration (Required)

After installation, configure zone transfers in Plesk:

1. Go to **Tools & Settings** → **DNS Settings** → **Server-wide Settings**
2. In the **Additional DNS settings** field, add:

```
allow-transfer { SECONDARY_IP; };
also-notify { SECONDARY_IP; };
```

Replace `SECONDARY_IP` with the IP shown by the installer. Click **Apply**.

Plesk manages BIND/PowerDNS configuration through its own UI. Direct config file edits may be overwritten by Plesk, so always use the panel UI for these settings.

## Nameserver Configuration

The installer adds the secondary nameserver to the DNS template automatically. To verify:

```bash
plesk bin server_dns --info
```

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
| `domain_alias_create` | Default domain alias created | Add zone to SecondDNS |
| `site_alias_create` | Domain alias created | Add zone to SecondDNS |
| `domain_delete` | Default domain deleted | Remove zone from SecondDNS |
| `site_delete` | Additional domain deleted | Remove zone from SecondDNS |
| `domain_alias_delete` | Default domain alias deleted | Remove zone from SecondDNS |
| `site_alias_delete` | Domain alias deleted | Remove zone from SecondDNS |

## Troubleshooting

**Zone not appearing on secondary:**
Check `/var/log/seconddns.log`. Verify event handlers are registered:
```bash
plesk bin event_handler --list | grep seconddns
```

**AXFR refused:**
Make sure you configured AXFR in Plesk UI (Tools & Settings → DNS Settings → Server-wide Settings → Additional DNS settings). See the AXFR Configuration section above.

**Timeout:**
Verify TCP port 53 is open. AXFR uses TCP.

**Test handler manually:**
```bash
NEW_DOMAIN_NAME=example.com /usr/local/bin/seconddns-plesk-domain_create.sh
```

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/plesk/uninstall.sh | bash
```

Removes event handlers, scripts, and config. Zones on the secondary are not deleted automatically.

## Files

| Path | Description |
|---|---|
| `/etc/seconddns.conf` | API credentials and master IP |
| `/usr/local/bin/seconddns-plesk-domain_create.sh` | Domain creation handler |
| `/usr/local/bin/seconddns-plesk-domain_delete.sh` | Domain deletion handler |
| `/var/log/seconddns.log` | Integration log |
