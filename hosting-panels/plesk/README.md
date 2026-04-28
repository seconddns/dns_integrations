# SecondDNS — Plesk Hosting Panel Integration

Automatic secondary DNS for Plesk servers. Uses Plesk Event Manager to sync domain creation, deletion, and domain aliases to SecondDNS via API + AXFR.

Tested on Plesk Obsidian 18.0.77.2 (Ubuntu 24.04).

## How It Works

Two shell scripts are registered as Plesk event handlers for 8 events:

1. **Domain/alias created** — calls SecondDNS API to register the zone
2. **Domain/alias deleted** — removes the zone from SecondDNS

After zone registration, SecondDNS pulls the full zone via AXFR. Subsequent changes propagate via BIND NOTIFY.

Handles all Plesk domain types: default domains (first in subscription), additional domains, and domain aliases.

## Internationalized Domain Names (IDN)

The integration supports IDN domains (e.g. `каба-жаба.укр`, `münchen.de`, `中国.cn`).

For best results, IDN domains should be converted to Punycode format (e.g. `xn----7sbabacd2b5a.xn--j1amh`) before being synced to SecondDNS.

**IDN utilities:**
- The installer attempts to install `idn2` (or `idn` as fallback) for automatic Punycode conversion
- If installation fails, domains will still be synced but may not be converted
- **For systems without idn2/idn:** Install manually using:
  - Debian/Ubuntu: `apt-get install idn2`
  - AlmaLinux/Rocky (dnf): `dnf install idn2`
  - RHEL/CentOS (yum): `yum install idn2`
  - Alpine: `apk add libidn2-tools`
  - Other distributions: search for `idn2` package

## Requirements

- Plesk Obsidian (18.x+)
- Root access
- BIND as DNS server
- TCP port 53 open to SecondDNS
- SecondDNS API key (get one at seconddns.com/dashboard/api-key)

## Installation

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/plesk/install.sh | bash -s -- --api-key=YOUR_API_KEY
```

The installer:
- Verifies the API key
- Detects server IP (IPv4/IPv6)
- Installs event handler scripts to `/usr/local/bin/`
- Registers 8 Plesk event handlers via CLI
- Replaces default `ns2.<domain>` with secondary nameserver in DNS template
- Configures BIND for AXFR (allow-transfer, also-notify)
- Offers to sync existing domains

### Options

| Flag | Description |
|---|---|
| `--api-key=KEY` | SecondDNS API key (required) |
| `--api-url=URL` | API base URL (default: `https://seconddns.com`) |
| `--master-ip=IP` | Primary DNS IP (default: auto-detect) |
| `--yes` | Skip confirmation prompts |

## AXFR Configuration

The installer configures `allow-transfer` and `also-notify` in `named.conf.options` directly. However, Plesk may overwrite these settings during config regeneration.

To make AXFR settings permanent, also add them via Plesk UI:

1. Go to **Tools & Settings** → **DNS Settings** → **Server-wide Settings**
2. In the **Additional DNS settings** field, add:

```
allow-transfer { SECONDARY_IP; };
also-notify { SECONDARY_IP; };
```

Replace `SECONDARY_IP` with the IP shown by the installer. Click **Apply**.

## DNS Template

The installer automatically:
- Adds the secondary nameserver (e.g. `ns2.seconddns.com`) to the DNS zone template
- Offers to remove the default `ns2.<domain>` record (which points to the same server and provides no redundancy)

To verify the current NS records in the template:

```bash
plesk db "SELECT val FROM dns_recs_t WHERE type='NS'"
```

For existing domains, add the NS record through each domain's DNS settings or use the Plesk mass update feature.

## Verification

```bash
# Check registered handlers (should show 8)
plesk bin event_handler --list | grep seconddns

# Watch the log
tail -f /var/log/seconddns.log

# Compare SOA on both nameservers
dig @your-server-ip example.com SOA +short
dig @ns2.seconddns.com example.com SOA +short
```

## Supported Events

| Plesk Event ID | Description | Action |
|---|---|---|
| `domain_create` | Default domain (first in subscription) created | Add zone |
| `site_create` | Additional domain created | Add zone |
| `domain_alias_create` | Default domain alias created | Add zone |
| `site_alias_create` | Domain alias created | Add zone |
| `domain_delete` | Default domain deleted | Remove zone |
| `site_delete` | Additional domain deleted | Remove zone |
| `domain_alias_delete` | Default domain alias deleted | Remove zone |
| `site_alias_delete` | Domain alias deleted | Remove zone |

## Troubleshooting

**Zone not appearing on secondary:**
Check `/var/log/seconddns.log`. Verify event handlers are registered:
```bash
plesk bin event_handler --list | grep seconddns
```

**AXFR refused:**
Make sure AXFR is configured both in `named.conf.options` and in Plesk UI (Tools & Settings → DNS Settings → Server-wide Settings → Additional DNS settings).

**Timeout:**
Verify TCP port 53 is open between your server and SecondDNS. AXFR uses TCP.

**Duplicate handlers after re-install:**
The installer removes existing SecondDNS handlers before registering new ones. If you see duplicates, run the uninstaller first, then re-install.

**IDN domain not syncing:**
Verify `idn2` (or `idn`) is installed: `which idn2` or `which idn`. If not found, run the installer again or manually install `libidn2-bin` (Debian) / `libidn2` (RHEL).

Check the log for the Punycode-converted domain name:
```bash
tail -f /var/log/seconddns.log | grep "Zone created"
```
IDN domains should appear as `xn--...` in the logs.

**Test handler manually:**
```bash
NEW_DOMAIN_NAME=example.com bash -c /usr/local/bin/seconddns-plesk-domain_create.sh
```

For IDN testing:
```bash
NEW_DOMAIN_NAME=каба-жаба.укр bash -c /usr/local/bin/seconddns-plesk-domain_create.sh
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
