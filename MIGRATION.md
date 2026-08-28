# Migrating a panel server

This is for the case where a customer moves domains from one panel server to
another and **both** servers are integrated with SecondDNS under the same
account. Without care, the old server deletes zones that are alive on the new
one, and zones keep pointing at the old master.

## What protects you

**Delete checks the master.** Every delete hook asks SecondDNS who masters the
zone before doing anything (`GET /api/zones/by-name/<name>` → `masterIp`):

- mastered by this server, or absent → the delete is queued as usual
- mastered by another server → the delete is skipped and logged:
  `Zone <name> is mastered by <ip>, not this server — delete skipped`
- API unreachable → the delete is queued with this server's IP, and
  `seconddns-queued` repeats the same check when it delivers

The check is on by default. To turn it off on a server:

```ini
# /etc/seconddns.conf
[seconddns]
delete_check_master_ip = false
```

**`seconddns-migrate-master` re-points zones.** Run on the **new** server
after the data has moved. It lists the subscription's zones, takes those
hosted on this panel, and changes their `masterIp` to this server.
SecondDNS pulls the zone from the new master right after the change.

```bash
seconddns-migrate-master                 # dry run: shows what would change
seconddns-migrate-master --apply         # change masterIp for zones on this panel
seconddns-migrate-master --all --apply   # every zone of the subscription
seconddns-migrate-master --from-file domains.txt --apply
seconddns-migrate-master --master-ip 203.0.113.5 --apply   # overrides the config
```

`[changed]` means SecondDNS accepted the new master: the zone goes to
`pending` and is pulled from the new server asynchronously. Check the
result per zone in the dashboard or with
`curl -H "X-API-Key: …" https://seconddns.com/api/zones/by-name/<name>` —
`status: synced` and an empty `lastError` mean the transfer from the new
master worked.

The domain list comes from the panel (Plesk, cPanel, DirectAdmin, CyberPanel)
and goes through the same name canonicalisation as the hooks, so IDN names
match their Punycode zones. Zones not hosted on this panel are left alone
unless you pass `--all`.

**`seconddns-reconcile` shows the difference.** It compares the **DNS
zones this panel's DNS server masters** — the same set the hooks act on —
with the zones in SecondDNS. The list comes from Plesk's `dns_zone` table,
`whmapi1 listzones` on cPanel, `/var/named/*.db` on DirectAdmin, the
PowerDNS `domains` table on CyberPanel; `--from-file` replaces it. Sites and
subdomains without a zone of their own are not in that list, and DNS-only
zones (mail, parked, zones added in the panel's DNS manager) are.

Four lists: `ok`, `missing` (a zone on the panel only), `stale` (in
SecondDNS only — meaning *not a zone on this panel*, not *unneeded*; each
with its master), `mismatch` (in both, mastered elsewhere — that is
`seconddns-migrate-master`'s job). `--add-missing` and `--remove-stale`
show what would be queued; add `--apply` to queue it. A stale zone mastered
by another server is never deleted from here. If the panel cannot be read
or reports no zones the tool stops instead of treating everything as stale,
and `--remove-stale` refuses to drop more than half of this server's zones
unless you pass `--force-bulk-delete`.

```bash
seconddns-reconcile                                   # report only
seconddns-reconcile --add-missing --remove-stale      # what would change
seconddns-reconcile --add-missing --remove-stale --apply
```

## Order of operations

1. Install the integration on the new server (same API key as the old one).
   Answer **no** to the initial sync if the zones already exist in SecondDNS.
2. Move the accounts / domains to the new server.
3. On the new server: `seconddns-migrate-master` (check the table), then
   `seconddns-migrate-master --apply`. Confirm with `seconddns-queue status`
   and in the dashboard that the zones show `synced` with the new master.
   A domain created on the new panel while its zone still points at the
   old master is not re-pointed automatically: the hook's create gets a
   409, the worker logs `exists, mastered by <old ip> — run
   seconddns-migrate-master`, and the queue moves on.
4. Make sure the old server runs hooks with the master check (any version
   that ships `seconddns-owner`), then delete the domains there. Each delete
   is skipped with a log line because the zone is now mastered by the new
   server.
5. `seconddns-reconcile` on the new server: everything should be `ok`;
   `--add-missing --apply` picks up anything the migration left behind.
6. Uninstall the integration on the old server once it is empty.

Accounts that stay on the old server for a while are not touched by
`seconddns-migrate-master` unless you pass `--all`; their zones keep the old
master until they move.
