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

log "Zone deleted: $ZONE_NAME (plesk event handler)"

# Convert IDN to Punycode if idn2/idn is available
if command -v idn2 &>/dev/null; then
    ZONE_NAME=$(idn2 --quiet "$ZONE_NAME" 2>/dev/null || echo "$ZONE_NAME")
elif command -v idn &>/dev/null; then
    ZONE_NAME=$(idn --quiet "$ZONE_NAME" 2>/dev/null || echo "$ZONE_NAME")
fi
# If neither is available, the domain name is sent as-is (API will handle it)

# Find zone ID by name
zone_id=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Plesk/1.0" \
    "$API_URL/api/zones/by-name/$ZONE_NAME" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$zone_id" ]; then
    curl -sf --max-time 15 \
        -X DELETE \
        -H "X-API-Key: $API_KEY" \
        -H "User-Agent: SecondDNS-Plesk/1.0" \
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
