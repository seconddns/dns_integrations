#!/bin/bash
# SecondDNS integration — Plesk event handler
# Triggered after a domain is deleted
# Env: OLD_DOMAIN_NAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] && exit 0
[ -z "$OLD_DOMAIN_NAME" ] && exit 0

log "Zone deleted: $OLD_DOMAIN_NAME (plesk event handler)"

# Find zone ID by name
zone_id=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Plesk/1.0" \
    "$API_URL/api/zones/by-name/$OLD_DOMAIN_NAME" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$zone_id" ]; then
    curl -sf --max-time 15 \
        -X DELETE \
        -H "X-API-Key: $API_KEY" \
        -H "User-Agent: SecondDNS-Plesk/1.0" \
        "$API_URL/api/zones/$zone_id" 2>/dev/null

    if [ $? -eq 0 ]; then
        log "[+] Zone $OLD_DOMAIN_NAME removed from SecondDNS"
    else
        log "[!] Failed to remove zone $OLD_DOMAIN_NAME from SecondDNS"
    fi
else
    log "[~] Zone $OLD_DOMAIN_NAME not found in SecondDNS (already removed?)"
fi

exit 0
