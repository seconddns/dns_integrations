# Plesk — Installation

## Requirements

- Plesk Obsidian 18.x+
- `python3` and `sqlite3` — the installer stops if `python3` is missing
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

**Verify event handlers (should show 12):**
```bash
plesk bin event_handler --list | grep seconddns
```

**Verify AXFR:**
```bash
dig @localhost example.com AXFR
```

## Moving to another server

See [MIGRATION.md](../../MIGRATION.md): deletes check the zone's master first, and `seconddns-migrate-master` re-points moved zones to the new server.
