#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — Plesk event handler
# Triggered after a domain or domain alias is renamed
# Env: OLD_DOMAIN_NAME, NEW_DOMAIN_NAME, OLD_DOMAIN_ALIAS_NAME, NEW_DOMAIN_ALIAS_NAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0

# For alias events, use the alias names; for domain events, use domain names
OLD_ZONE="${OLD_DOMAIN_ALIAS_NAME:-$OLD_DOMAIN_NAME}"
NEW_ZONE="${NEW_DOMAIN_ALIAS_NAME:-$NEW_DOMAIN_NAME}"

[ -z "$OLD_ZONE" ] || [ -z "$NEW_ZONE" ] && exit 0
# Not a rename — domain_update fires for all changes, not only renames
[ "$OLD_ZONE" = "$NEW_ZONE" ] && exit 0

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
for var in OLD_ZONE NEW_ZONE; do
    if ! canonical_domain "${!var}"; then
        log "[!] Zone '${!var}' refused: $DOMAIN_ERROR (plesk event handler)"
        exit 0
    fi
    printf -v "$var" '%s' "$DOMAIN"
done

log "Zone rename: $OLD_ZONE -> $NEW_ZONE (plesk event handler)"

QUEUE="/usr/local/bin/seconddns-queue"
rc=0
"$QUEUE" enqueue delete "$OLD_ZONE" || rc=1
"$QUEUE" enqueue create "$NEW_ZONE" "$MASTER_IP" || rc=1
if [ $rc -eq 0 ]; then
    log "[>] Zone rename $OLD_ZONE -> $NEW_ZONE queued for SecondDNS"
else
    log "[!] Zone rename $OLD_ZONE -> $NEW_ZONE NOT fully queued (seconddns-queue failed)"
fi

exit 0
