# DirectAdmin — Installation

## Requirements

- DirectAdmin (it writes zones for BIND/named, its only DNS server)
- `python3` and `sqlite3` — the installer stops if `python3` is missing
- Root access
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL "https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/directadmin/install.sh" \
  | bash -s -- --api-key=YOUR_API_KEY
```

Options:

- `--api-key=KEY` — Your SecondDNS API key (required)
- `--api-url=URL` — API base URL (default: https://seconddns.com)
- `--master-ip=IP` — Primary DNS server IP (default: auto-detect)
- `--yes` — Skip confirmation prompts

## AXFR — done by the installer

The installer does this: it finds `named.conf`, asks before editing, keeps a
`.bak` copy and reloads named. What it adds to the `options` block:

```
allow-transfer { <secondary-ip>; };
also-notify { <secondary-ip>; };
```

Add them by hand only if you declined the prompt, or if your BIND setup keeps
its options somewhere the installer did not find. Check what is in place:

```bash
grep -E "allow-transfer|also-notify" /etc/named.conf
```

## Post-install: Configure Nameservers

Add the nameserver shown in your SecondDNS dashboard (for example `ns2.seconddns.com.`) as a secondary for your domains. Accounts are served by different nameservers, so take the name from the dashboard.

**For new domains** — update the DirectAdmin DNS template:

```bash
vi /usr/local/directadmin/data/templates/dns_*.conf
```

Add an NS record line for that nameserver.

**For existing domains** — add NS record via DirectAdmin DNS Management or bulk update.

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/directadmin/uninstall.sh \
  | bash
```

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
dig @localhost example.com AXFR
```

## Moving to another server

See [MIGRATION.md](../../MIGRATION.md): deletes check the zone's master first, and `seconddns-migrate-master` re-points moved zones to the new server.
