#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 - see LICENSE file
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

log "Zone deleted: $domain (user=$USERNAME)"

# Find zone ID by name
zone_id=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-DirectAdmin/1.0" \
    "$API_URL/api/zones/by-name/$domain" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$zone_id" ]; then
    curl -sf --max-time 15 \
        -X DELETE \
        -H "X-API-Key: $API_KEY" \
        -H "User-Agent: SecondDNS-DirectAdmin/1.0" \
        "$API_URL/api/zones/$zone_id" 2>/dev/null

    if [ $? -eq 0 ]; then
        log "[+] Zone $domain removed from SecondDNS"
    else
        log "[!] Failed to remove zone $domain from SecondDNS"
    fi
else
    log "[~] Zone $domain not found in SecondDNS (already removed?)"
fi

exit 0
