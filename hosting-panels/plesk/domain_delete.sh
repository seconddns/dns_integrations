#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — Plesk event handler
# Triggered after a domain or domain alias is deleted
# Env: OLD_DOMAIN_NAME, OLD_DOMAIN_ALIAS_NAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] && exit 0

# For alias events, use the alias name; for domain events, use domain name
ZONE_NAME="${OLD_DOMAIN_ALIAS_NAME:-$OLD_DOMAIN_NAME}"
[ -z "$ZONE_NAME" ] && exit 0

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
if ! canonical_domain "$ZONE_NAME"; then
    log "[!] Zone '$ZONE_NAME' refused: $DOMAIN_ERROR (plesk event handler)"
    exit 0
fi
ZONE_NAME="$DOMAIN"

log "Zone deleted: $ZONE_NAME (plesk event handler)"

QUEUE="/usr/local/bin/seconddns-queue"
if "$QUEUE" enqueue delete "$ZONE_NAME"; then
    log "[>] Zone $ZONE_NAME removal queued for SecondDNS"
else
    log "[!] Zone $ZONE_NAME removal NOT queued (seconddns-queue failed)"
fi

exit 0
