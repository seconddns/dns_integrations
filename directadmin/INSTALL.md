# DirectAdmin — Installation

## Requirements

- DirectAdmin with BIND/named or PowerDNS
- Root access
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL "https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/directadmin/install.sh" \
  | bash -s -- --api-key=YOUR_API_KEY
```

Options:

- `--api-key=KEY` — Your SecondDNS API key (required)
- `--api-url=URL` — API base URL (default: https://seconddns.com)
- `--master-ip=IP` — Primary DNS server IP (default: auto-detect)
- `--yes` — Skip confirmation prompts

## Post-install: Configure AXFR

Ensure your DNS server allows zone transfers to the SecondDNS secondary IP.

### BIND/named

Add to `named.conf.options` or each zone block:

```
allow-transfer { <secondary-ip>; };
also-notify { <secondary-ip>; };
```

Then reload named:

```bash
rndc reload
```

### PowerDNS

Add to `pdns.conf`:

```
allow-axfr-ips=<secondary-ip>
also-notify=<secondary-ip>
```

Then restart:

```bash
systemctl restart pdns
```

## Post-install: Configure Nameservers

Add `ns2.seconddns.com` as a secondary nameserver for your domains.

**For new domains** — update the DirectAdmin DNS template:

```bash
vi /usr/local/directadmin/data/templates/dns_*.conf
```

Add an NS record line for `ns2.seconddns.com`.

**For existing domains** — add NS record via DirectAdmin DNS Management or bulk update.

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/directadmin/uninstall.sh \
  | bash
```

## Troubleshooting

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**Verify AXFR config:**
```bash
dig @localhost example.com AXFR
```
