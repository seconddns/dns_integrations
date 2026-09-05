#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — DirectAdmin hook
# Triggered after a domain is renamed
# Env: domain (old name), newdomain, username

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0
[ -z "$newdomain" ] && exit 0

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"

QUEUE="/usr/local/bin/seconddns-queue"

# DirectAdmin fires dns_delete_post for the old name and then this hook, so the
# old zone is normally already queued for removal; queue it again only if the
# old name is usable, since a duplicate delete is treated as success anyway.
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
