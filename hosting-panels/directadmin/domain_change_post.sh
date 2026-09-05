#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — DirectAdmin hook
# Triggered after a domain is renamed
# Env: domain (old name), newdomain, username

# overridable so the hook can be exercised without touching the real paths
CONFIG="${SECONDDNS_CONFIG:-/etc/seconddns.conf}"
LOG="${SECONDDNS_LOG:-/var/log/seconddns.log}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url[[:space:]]*=[[:space:]]*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key[[:space:]]*=[[:space:]]*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip[[:space:]]*=[[:space:]]*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0
[ -z "$newdomain" ] && exit 0

DOMAIN_LIB="${SECONDDNS_DOMAIN_BIN:-/usr/local/bin/seconddns-domain}"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"

QUEUE="${SECONDDNS_QUEUE_BIN:-/usr/local/bin/seconddns-queue}"

# dns_delete_post normally queued the old name already; a duplicate delete is
# treated as success, and the master no longer has that zone either way.
if [ -n "$domain" ] && canonical_domain "$domain"; then
    OLD="$DOMAIN"
    if "$QUEUE" enqueue delete "$OLD"; then
        log "[>] Zone $OLD removal queued for SecondDNS (renamed)"
    else
        log "[!] Zone $OLD removal NOT queued (seconddns-queue failed)"
    fi
fi

RAW_NEW="$newdomain"
if ! canonical_domain "$newdomain"; then
    log "[!] Zone '$newdomain' refused: $DOMAIN_ERROR (directadmin rename hook)"
    exit 0
fi
NEW="$DOMAIN"
RAW_NOTE=""; [ "$RAW_NEW" != "$NEW" ] && RAW_NOTE=" (received as '$RAW_NEW')"
log "Zone renamed: ${domain:-?} -> $NEW (user=$username)$RAW_NOTE"

if "$QUEUE" enqueue create "$NEW" "$MASTER_IP"; then
    log "[>] Zone $NEW queued for SecondDNS"
else
    log "[!] Zone $NEW NOT queued (seconddns-queue failed)"
fi

exit 0
