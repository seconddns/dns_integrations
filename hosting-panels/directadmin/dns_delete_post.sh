#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — DirectAdmin hook
# Triggered after a DNS zone is deleted
# Env: domain, USERNAME

CONFIG="/etc/seconddns.conf"
LOG="/var/log/seconddns.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url\s*=\s*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key\s*=\s*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip\s*=\s*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] && exit 0
[ -z "$domain" ] && exit 0

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
RAW_NAME="$domain"
if ! canonical_domain "$domain"; then
    log "[!] Zone '$domain' refused: $DOMAIN_ERROR (directadmin hook)"
    exit 0
fi
domain="$DOMAIN"
# keep what the panel actually handed over, for later diagnosis
RAW_NOTE=""; [ "$RAW_NAME" != "$domain" ] && RAW_NOTE=" (received as '$RAW_NAME')"
log "Zone deleted: $domain (user=$USERNAME)$RAW_NOTE"

OWNER_LIB="/usr/local/bin/seconddns-owner"
[ -r "$OWNER_LIB" ] && SECONDDNS_OWNER_LIB=1 . "$OWNER_LIB"
if type owner_check >/dev/null 2>&1; then
    owner_check "$domain" "$MASTER_IP"
    case $? in
        1) log "[~] Zone $domain is mastered by $OWNER_IP, not this server — delete skipped"; exit 0 ;;
        2) log "[~] Zone $domain owner check: API unreachable, queued; checked again at delivery" ;;
        4) log "[!] Zone $domain owner check skipped: api_url/api_key/master_ip missing in config, queued WITHOUT check" ;;
    esac
fi

QUEUE="/usr/local/bin/seconddns-queue"
if "$QUEUE" enqueue delete "$domain" "$MASTER_IP"; then
    log "[>] Zone $domain removal queued for SecondDNS"
else
    log "[!] Zone $domain removal NOT queued (seconddns-queue failed)"
fi

exit 0
