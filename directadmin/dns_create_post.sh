#!/bin/bash
# SecondDNS integration — DirectAdmin hook
# Triggered after a DNS zone is created
# Env: domain, username, caller

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0
[ -z "$domain" ] && exit 0

# Skip non-zone events
case "$caller" in
    create:zone|create:domain) ;;
    *) exit 0 ;;
esac

log "Zone created: $domain (caller=$caller, user=$username)"

# Add zone to SecondDNS
response=$(curl -sf --max-time 15 \
    -X POST \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: SecondDNS-DirectAdmin/1.0" \
    -d "{\"name\":\"$domain\",\"masterIp\":\"$MASTER_IP\"}" \
    "$API_URL/api/zones" 2>/dev/null)

if [ $? -eq 0 ]; then
    log "[+] Zone $domain added to SecondDNS"
else
    log "[!] Failed to add zone $domain to SecondDNS"
fi

exit 0
