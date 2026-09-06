#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — cPanel/WHM hook
# Triggered before an account is modified: WHM sends the new main domain, and
# the old one is still on disk at this stage.

CONFIG="${SECONDDNS_CONFIG:-/etc/seconddns.conf}"
LOG="${SECONDDNS_LOG:-/var/log/seconddns.log}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url[[:space:]]*=[[:space:]]*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key[[:space:]]*=[[:space:]]*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip[[:space:]]*=[[:space:]]*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] || [ -z "$MASTER_IP" ] && exit 0

STDIN_DATA=$(cat)
PAIR=$(echo "$STDIN_DATA" | python3 -c "
import sys, json, os
def main_domain(user):
    root = os.environ.get('SECONDDNS_CPANEL_ROOT', '/var/cpanel')
    try:
        with open('%s/userdata/%s/main' % (root, user)) as fh:
            for line in fh:
                if line.startswith('main_domain:'):
                    return line.split(':', 1)[1].strip()
    except Exception:
        pass
    try:
        with open('%s/users/%s' % (root, user)) as fh:
            for line in fh:
                if line.startswith('DNS='):
                    return line.split('=', 1)[1].strip()
    except Exception:
        pass
    return ''

try:
    d = json.load(sys.stdin)
    src = d.get('data') if isinstance(d.get('data'), dict) else d
    new = (src.get('domain') or '').strip()
    user = (src.get('user') or '').strip()
    old = main_domain(user) if user else ''
    if new and old and new != old:
        print(old)
        print(new)
except Exception:
    pass
" 2>/dev/null)

# nothing to do when the main domain is unchanged: WHM fires this hook for
# every account change, quota and package included
[ -z "$PAIR" ] && exit 0

OLD_NAME=$(echo "$PAIR" | sed -n 1p)
NEW_NAME=$(echo "$PAIR" | sed -n 2p)

DOMAIN_LIB="${SECONDDNS_DOMAIN_BIN:-/usr/local/bin/seconddns-domain}"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"
QUEUE="${SECONDDNS_QUEUE_BIN:-/usr/local/bin/seconddns-queue}"

if canonical_domain "$OLD_NAME"; then
    OLD_CANON="$DOMAIN"
    if "$QUEUE" enqueue delete "$OLD_CANON" "$MASTER_IP"; then
        log "[>] Zone $OLD_CANON removal queued for SecondDNS (renamed)"
    else
        log "[!] Zone $OLD_CANON removal NOT queued (seconddns-queue failed)"
    fi
else
    log "[!] Old zone '$OLD_NAME' refused: $DOMAIN_ERROR (cpanel rename hook)"
fi

if ! canonical_domain "$NEW_NAME"; then
    log "[!] Zone '$NEW_NAME' refused: $DOMAIN_ERROR (cpanel rename hook)"
    exit 0
fi
NEW_CANON="$DOMAIN"
RAW_NOTE=""; [ "$NEW_NAME" != "$NEW_CANON" ] && RAW_NOTE=" (received as '$NEW_NAME')"
log "Zone renamed: $OLD_NAME -> $NEW_CANON (cpanel hook)$RAW_NOTE"

if "$QUEUE" enqueue create "$NEW_CANON" "$MASTER_IP"; then
    log "[>] Zone $NEW_CANON queued for SecondDNS"
else
    log "[!] Zone $NEW_CANON NOT queued (seconddns-queue failed)"
fi

exit 0
