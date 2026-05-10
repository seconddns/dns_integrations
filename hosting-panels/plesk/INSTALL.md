# Plesk — Installation

## Requirements

- Plesk Obsidian 18.x+
- Root access
- BIND as DNS server
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL "https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/plesk/install.sh" \
  | bash -s -- --api-key=YOUR_API_KEY
```

Options:

- `--api-key=KEY` — Your SecondDNS API key (required)
- `--api-url=URL` — API base URL (default: https://seconddns.com)
- `--master-ip=IP` — Primary DNS server IP (default: auto-detect)
- `--yes` — Skip confirmation prompts

The installer registers 12 Plesk event handlers, configures AXFR in `named.conf.options`, and adds the secondary NS to the DNS zone template.

## Post-install: Make AXFR Permanent

Plesk may overwrite direct `named.conf.options` changes. To make AXFR settings permanent:

**Tools & Settings → DNS Settings → Server-wide Settings → Additional DNS settings:**

```
allow-transfer { <SecondDNS_IP>; };
also-notify { <SecondDNS_IP>; };
```

Click **Apply**.

## Post-install: Verify DNS Template

1. **Tools & Settings → DNS Settings → Zone Records Template** — confirm the secondary NS record (`ns2.seconddns.com.` or as shown in your dashboard) is present and the default `ns2.<domain>.` is removed.
2. **Tools & Settings → DNS Settings → Zone Settings Template** — set **Primary Name Server** to `ns1.<domain>.` (not Autoselect).

See the [README](README.md) for CLI commands to inspect and update the template.

## Post-install: Existing Domains

For existing domains, add the NS record manually via each domain's DNS settings, or use the Plesk mass update feature.

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/plesk/uninstall.sh \
  | bash
```

## Troubleshooting

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**Verify event handlers (should show 12):**
```bash
plesk bin event_handler --list | grep seconddns
```

**Verify AXFR:**
```bash
dig @localhost example.com AXFR
```
