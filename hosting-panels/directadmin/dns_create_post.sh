#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — DirectAdmin hook
# Triggered after a DNS zone is created
# Env: domain, username, caller

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url[[:space:]]*=[[:space:]]*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key[[:space:]]*=[[:space:]]*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip[[:space:]]*=[[:space:]]*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0
[ -z "$domain" ] && exit 0

# Skip non-zone events
case "$caller" in
    create:zone|create:domain|create:pointer) ;;
    *) exit 0 ;;
esac

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
RAW_NAME="$domain"
if ! canonical_domain "$domain"; then
    log "[!] Zone '$domain' refused: $DOMAIN_ERROR (directadmin hook)"
    exit 0
fi
domain="$DOMAIN"
# keep what the panel actually handed over, for later diagnosis
RAW_NOTE=""; [ "$RAW_NAME" != "$domain" ] && RAW_NOTE=" (received as '$RAW_NAME')"
log "Zone created: $domain (caller=$caller, user=$username)$RAW_NOTE"

QUEUE="/usr/local/bin/seconddns-queue"
if "$QUEUE" enqueue create "$domain" "$MASTER_IP"; then
    log "[>] Zone $domain queued for SecondDNS"
else
    log "[!] Zone $domain NOT queued (seconddns-queue failed)"
fi

exit 0
