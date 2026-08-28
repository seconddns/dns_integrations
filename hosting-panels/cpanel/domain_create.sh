#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — cPanel/WHM hook
# Triggered after a cPanel account or addon domain is created
# Input: JSON on stdin — fields: domain (WHM account), newdomain (addon domain)

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0

# WHM account: field "domain"; addon domain: field "newdomain"
STDIN_DATA=$(cat)
ZONE_NAME=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('domain') or d.get('newdomain') or '')
except Exception:
    pass
" 2>/dev/null)

[ -z "$ZONE_NAME" ] && exit 0

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
RAW_NAME="$ZONE_NAME"
if ! canonical_domain "$ZONE_NAME"; then
    log "[!] Zone '$ZONE_NAME' refused: $DOMAIN_ERROR (cpanel hook)"
    exit 0
fi
ZONE_NAME="$DOMAIN"
# keep what the panel actually handed over, for later diagnosis
RAW_NOTE=""; [ "$RAW_NAME" != "$ZONE_NAME" ] && RAW_NOTE=" (received as '$RAW_NAME')"

log "Zone created: $ZONE_NAME (cpanel hook)$RAW_NOTE"

QUEUE="/usr/local/bin/seconddns-queue"
if "$QUEUE" enqueue create "$ZONE_NAME" "$MASTER_IP"; then
    log "[>] Zone $ZONE_NAME queued for SecondDNS"
else
    log "[!] Zone $ZONE_NAME NOT queued (seconddns-queue failed)"
fi

exit 0
