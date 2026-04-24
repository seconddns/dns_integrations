# DirectAdmin — SecondDNS Integration

Automatically sync DNS zones from DirectAdmin to SecondDNS via AXFR zone transfers.

## How it works

DirectAdmin provides [custom hook scripts](https://docs.directadmin.com/developer/hooks/dns.html) that run after DNS events. This integration installs two hooks:

- **dns_create_post.sh** — when a domain is created, adds the zone to SecondDNS
- **dns_delete_post.sh** — when a domain is deleted, removes the zone from SecondDNS

Zone data is transferred via AXFR from your DirectAdmin server to the SecondDNS secondary nameserver.

## Tested on

- DirectAdmin 1.699 with BIND/named on Ubuntu 22.04

## Requirements

- DirectAdmin 1.6+ with BIND/named or PowerDNS
- Root access
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL "https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/directadmin/install.sh?t=$(date +%s)" \
  | bash -s -- --api-key=YOUR_API_KEY
```

## Uninstall

```bash
curl -sL "https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/directadmin/uninstall.sh?t=$(date +%s)" \
  | bash
```

## AXFR Configuration

After installation, ensure your DNS server allows zone transfers to the SecondDNS secondary IP.

### BIND/named

In each zone block or `named.conf.options`:

```
allow-transfer { <secondary-ip>; };
also-notify { <secondary-ip>; };
```

### PowerDNS

In `pdns.conf`:

```
allow-axfr-ips=<secondary-ip>
also-notify=<secondary-ip>
```

## Nameserver Configuration

Add the secondary nameserver to your domains. In DirectAdmin:

1. Go to **DNS Administration** or **DNS Management**
2. Add an NS record: `ns2.seconddns.com`

Or update the default zone template to include it for all new domains.

## Troubleshooting

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**Verify hooks are installed:**
```bash
ls -la /usr/local/directadmin/scripts/custom/dns_*_post.sh
```

**Test hook manually:**
```bash
domain=example.com username=admin caller=create:domain \
  /usr/local/directadmin/scripts/custom/dns_create_post.sh
```

**Zone not syncing:**
- Check AXFR is allowed: `dig @your-server example.com AXFR`
- Check firewall rules for TCP port 53
- Verify NOTIFY is configured (`also-notify`)
