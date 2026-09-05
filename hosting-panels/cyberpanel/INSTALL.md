# CyberPanel — Installation

## Requirements

- CyberPanel 2.x+ with PowerDNS
- `python3` and `sqlite3` — the installer stops if `python3` is missing
- `git` installed
- Root access
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/cyberpanel/uninstall.sh \
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
- **NS2:** the nameserver shown in your SecondDNS dashboard (for example `ns2.seconddns.com`)

This ensures all new zones include the secondary nameserver in their NS records.

## Existing zones

The installer offers to queue everything the panel already serves, so a server
with domains on it does not wait for each one to be touched by hand. It asks
the panel for its zone list and queues the ones SecondDNS does not have yet;
zones already there are left alone, and nothing is ever deleted by this step.

Run it again at any time — it queues only what is missing:

```bash
seconddns-reconcile                        # report: missing / stale / ok
seconddns-reconcile --add-missing --apply  # queue the missing ones
```

## Troubleshooting

**Zone did not reach the secondary — is it stuck in the queue?**
```bash
seconddns-queue status              # pending / failed / oldest age / last error
systemctl status seconddns-queued   # the delivery worker
```
An unreachable API is not a loss: operations wait in the queue and the worker
retries with a growing delay until they land.

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**Verify AXFR config:**
```bash
grep -E "^master=|^allow-axfr-ips=|^also-notify=" /etc/pdns/pdns.conf
```

## Moving to another server

See [MIGRATION.md](../../MIGRATION.md): deletes check the zone's master first, and `seconddns-migrate-master` re-points moved zones to the new server.
