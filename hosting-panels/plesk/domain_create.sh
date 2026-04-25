#!/bin/bash
# SecondDNS integration — Plesk event handler
# Triggered after a domain or domain alias is created
# Env: NEW_DOMAIN_NAME, NEW_DOMAIN_ALIAS_NAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0

# For alias events, use the alias name; for domain events, use domain name
ZONE_NAME="${NEW_DOMAIN_ALIAS_NAME:-$NEW_DOMAIN_NAME}"
[ -z "$ZONE_NAME" ] && exit 0

log "Zone created: $ZONE_NAME (plesk event handler)"

# Add zone to SecondDNS
response=$(curl -sf --max-time 15 \
    -X POST \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: SecondDNS-Plesk/1.0" \
    -d "{\"name\":\"$ZONE_NAME\",\"masterIp\":\"$MASTER_IP\"}" \
    "$API_URL/api/zones" 2>/dev/null)

if [ $? -eq 0 ]; then
    log "[+] Zone $ZONE_NAME added to SecondDNS"
else
    log "[!] Failed to add zone $ZONE_NAME to SecondDNS"
fi

exit 0
