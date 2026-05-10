#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — cPanel/WHM hook
# Triggered before a cPanel account or addon domain is removed
# Input: JSON on stdin — field: domain

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] && exit 0

STDIN_DATA=$(cat)
ZONE_NAME=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('domain') or '')
except Exception:
    pass
" 2>/dev/null)

[ -z "$ZONE_NAME" ] && exit 0

# cPanel stores all domains in Punycode internally — no IDN conversion needed

log "Zone deleted: $ZONE_NAME (cpanel hook)"

zone_id=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-cPanel/1.0" \
    "$API_URL/api/zones/by-name/$ZONE_NAME" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$zone_id" ]; then
    curl -sf --max-time 15 \
        -X DELETE \
        -H "X-API-Key: $API_KEY" \
        -H "User-Agent: SecondDNS-cPanel/1.0" \
        "$API_URL/api/zones/$zone_id" 2>/dev/null

    if [ $? -eq 0 ]; then
        log "[+] Zone $ZONE_NAME removed from SecondDNS"
    else
        log "[!] Failed to remove zone $ZONE_NAME from SecondDNS"
    fi
else
    log "[~] Zone $ZONE_NAME not found in SecondDNS (already removed?)"
fi

exit 0
