#!/bin/bash
# SecondDNS integration — Plesk event handler
# Triggered after a domain is created
# Env: NEW_DOMAIN_NAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0
[ -z "$NEW_DOMAIN_NAME" ] && exit 0

log "Zone created: $NEW_DOMAIN_NAME (plesk event handler)"

# Add zone to SecondDNS
response=$(curl -sf --max-time 15 \
    -X POST \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: SecondDNS-Plesk/1.0" \
    -d "{\"name\":\"$NEW_DOMAIN_NAME\",\"masterIp\":\"$MASTER_IP\"}" \
    "$API_URL/api/zones" 2>/dev/null)

if [ $? -eq 0 ]; then
    log "[+] Zone $NEW_DOMAIN_NAME added to SecondDNS"
else
    log "[!] Failed to add zone $NEW_DOMAIN_NAME to SecondDNS"
fi

exit 0
