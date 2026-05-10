# cPanel/WHM — Installation

## Requirements

- cPanel/WHM v82+
- Root access
- BIND or PowerDNS as DNS server
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL "https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/cpanel/install.sh" \
  | bash -s -- --api-key=YOUR_API_KEY
```

Options:

- `--api-key=KEY` — Your SecondDNS API key (required)
- `--api-url=URL` — API base URL (default: https://seconddns.com)
- `--master-ip=IP` — Primary DNS server IP (default: auto-detect)
- `--yes` — Skip confirmation prompts

The installer:

1. Detects your DNS server (BIND or PowerDNS) and confirms with you
2. Configures AXFR (`allow-transfer`, `also-notify`) for the detected backend
3. Adds the SecondDNS nameserver to all zone templates in `/var/cpanel/zonetemplates/`
4. Registers 4 WHM hooks via `manage_hooks`
5. Optionally syncs existing cPanel accounts

## Post-install: Make AXFR Permanent (BIND only)

cPanel may overwrite direct `named.conf` changes when it rebuilds the DNS config. To make AXFR settings permanent:

**WHM > Service Configuration > DNS Server (BIND) > Additional zone configuration:**

```
allow-transfer { <SecondDNS_IP>; };
also-notify { <SecondDNS_IP>; };
```

Then click **Save**.

> PowerDNS users: no extra step needed — `/etc/pdns/pdns.conf` changes survive cPanel rebuilds.

## Post-install: Existing Zones

The zone template change only affects **new** zones. To add the secondary NS record to existing zones, resync them via the SecondDNS dashboard or add the NS record manually via WHM > DNS Functions > Edit DNS Zone.

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/cpanel/uninstall.sh \
  | bash
```

## Troubleshooting

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**List registered hooks:**
```bash
/usr/local/cpanel/bin/manage_hooks list
```

**Verify AXFR:**
```bash
dig @localhost example.com AXFR
```
