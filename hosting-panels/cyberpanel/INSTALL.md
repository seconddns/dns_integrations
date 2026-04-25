# CyberPanel — Installation

## Requirements

- CyberPanel 2.x+ with PowerDNS
- `git` installed
- Root access
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/cyberpanel/uninstall.sh \
  | bash
```

## Post-install: Fix PowerDNS schema (CyberPanel v2.4.5 / Ubuntu)

CyberPanel v2.4.5 ships with an outdated PowerDNS database schema — missing columns cause `pdns_server` to crash on zone updates.

Run these SQL queries:

```sql
ALTER TABLE cyberpanel.domains ADD COLUMN `options` TEXT DEFAULT NULL;
ALTER TABLE cyberpanel.domains ADD COLUMN `catalog` VARCHAR(255) DEFAULT NULL;
```

Then restart PowerDNS:

```bash
systemctl restart pdns
```

## Post-install: Configure nameservers in CyberPanel

After installation, go to **CyberPanel → DNS → Create/Edit Nameservers** and set:

- **NS1:** your primary nameserver (e.g. `ns1.yourdomain.com`)
- **NS2:** `ns2.seconddns.com`

This ensures all new zones include the secondary nameserver in their NS records.

## Troubleshooting

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**Verify AXFR config:**
```bash
grep -E "^master=|^allow-axfr-ips=|^also-notify=" /etc/pdns/pdns.conf
```
