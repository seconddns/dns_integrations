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

# cPanel stores all domains in Punycode internally — no IDN conversion needed

log "Zone created: $ZONE_NAME (cpanel hook)"

QUEUE="/usr/local/bin/seconddns-queue"
"$QUEUE" enqueue create "$ZONE_NAME" "$MASTER_IP"
log "[>] Zone $ZONE_NAME queued for SecondDNS"

exit 0
