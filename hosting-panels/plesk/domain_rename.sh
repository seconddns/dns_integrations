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

QUEUE="/usr/local/bin/seconddns-queue"
"$QUEUE" enqueue delete "$OLD_ZONE"
"$QUEUE" enqueue create "$NEW_ZONE" "$MASTER_IP"
log "[>] Zone rename $OLD_ZONE -> $NEW_ZONE queued for SecondDNS"
( "$QUEUE" flush >/dev/null 2>&1 & )

exit 0
