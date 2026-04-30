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

log "Zone rename: $OLD_ZONE -> $NEW_ZONE (plesk event handler)"

idn_encode() {
    local name="$1"
    if command -v idn2 &>/dev/null; then
        idn2 --quiet "$name" 2>/dev/null || echo "$name"
    elif command -v idn &>/dev/null; then
        idn --quiet "$name" 2>/dev/null || echo "$name"
    else
        echo "$name"
    fi
}

OLD_ZONE=$(idn_encode "$OLD_ZONE")
NEW_ZONE=$(idn_encode "$NEW_ZONE")

# Delete old zone
zone_id=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Plesk/1.0" \
    "$API_URL/api/zones/by-name/$OLD_ZONE" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$zone_id" ]; then
    curl -sf --max-time 15 \
        -X DELETE \
        -H "X-API-Key: $API_KEY" \
        -H "User-Agent: SecondDNS-Plesk/1.0" \
        "$API_URL/api/zones/$zone_id" 2>/dev/null
    if [ $? -eq 0 ]; then
        log "[+] Old zone $OLD_ZONE removed from SecondDNS"
    else
        log "[!] Failed to remove old zone $OLD_ZONE from SecondDNS"
    fi
else
    log "[~] Old zone $OLD_ZONE not found in SecondDNS (skipping delete)"
fi

# Create new zone
response=$(curl -sf --max-time 15 \
    -X POST \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: SecondDNS-Plesk/1.0" \
    -d "{\"name\":\"$NEW_ZONE\",\"masterIp\":\"$MASTER_IP\"}" \
    "$API_URL/api/zones" 2>/dev/null)

if [ $? -eq 0 ]; then
    log "[+] New zone $NEW_ZONE added to SecondDNS"
else
    log "[!] Failed to add new zone $NEW_ZONE to SecondDNS"
fi

exit 0
