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

QUEUE="/usr/local/bin/seconddns-queue"
"$QUEUE" enqueue delete "$ZONE_NAME"
log "[>] Zone $ZONE_NAME removal queued for SecondDNS"
( "$QUEUE" flush >/dev/null 2>&1 & )

exit 0
