#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — DirectAdmin hook
# Triggered after a DNS zone is deleted
# Env: domain, USERNAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] && exit 0
[ -z "$domain" ] && exit 0

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
if ! canonical_domain "$domain"; then
    log "[!] Zone '$domain' refused: $DOMAIN_ERROR (directadmin hook)"
    exit 0
fi
domain="$DOMAIN"
log "Zone deleted: $domain (user=$USERNAME)"

QUEUE="/usr/local/bin/seconddns-queue"
if "$QUEUE" enqueue delete "$domain"; then
    log "[>] Zone $domain removal queued for SecondDNS"
else
    log "[!] Zone $domain removal NOT queued (seconddns-queue failed)"
fi

exit 0
