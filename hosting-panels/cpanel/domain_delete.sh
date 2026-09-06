#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# SecondDNS integration — cPanel/WHM hook
# Triggered before a cPanel account or addon domain is removed
# Input: JSON on stdin — field: domain

CONFIG="${SECONDDNS_CONFIG:-/etc/seconddns.conf}"
LOG="${SECONDDNS_LOG:-/var/log/seconddns.log}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

[ -f "$CONFIG" ] || exit 0

API_URL=$(grep "^api_url" "$CONFIG" | sed 's/^api_url[[:space:]]*=[[:space:]]*//')
API_KEY=$(grep "^api_key" "$CONFIG" | sed 's/^api_key[[:space:]]*=[[:space:]]*//')
MASTER_IP=$(grep "^master_ip" "$CONFIG" | sed 's/^master_ip[[:space:]]*=[[:space:]]*//')

[ -z "$API_URL" ] || [ -z "$API_KEY" ] && exit 0

STDIN_DATA=$(cat)
# Accounts::Remove carries only the user: every domain of the account has to be
# read from its userdata, which stage "pre" still has on disk.
ZONE_NAMES=$(echo "$STDIN_DATA" | python3 -c "
import sys, json, os
def account_domains(user):
    # userdata/<user>/main lists every domain of the account; parsed by hand so
    # the hook does not depend on PyYAML being installed
    root = os.environ.get('SECONDDNS_CPANEL_ROOT', '/var/cpanel')
    names, section = [], None
    try:
        with open('%s/userdata/%s/main' % (root, user)) as fh:
            for line in fh:
                line = line.rstrip('\n')
                if not line or line.startswith('---'):
                    continue
                if not line[:1].isspace():
                    key, _, value = line.partition(':')
                    section, value = key.strip(), value.strip()
                    if section == 'main_domain' and value:
                        names.append(value)
                    continue
                item = line.strip()
                if section == 'addon_domains' and ':' in item:
                    names.append(item.split(':', 1)[0].strip())
                elif section == 'parked_domains' and item.startswith('- '):
                    names.append(item[2:].strip())
    except Exception:
        try:
            with open('%s/users/%s' % (root, user)) as fh:
                for line in fh:
                    if line.startswith('DNS'):
                        names.append(line.split('=', 1)[1].strip())
        except Exception:
            pass
    return [n for n in names if n]

try:
    d = json.load(sys.stdin)
    src = d.get('data') if isinstance(d.get('data'), dict) else d
    one = src.get('new_domain') or src.get('domain') or src.get('newdomain')
    if one:
        print(one)
    elif src.get('user'):
        for n in account_domains(src['user']):
            print(n)
except Exception:
    pass
" 2>/dev/null)

if [ -z "$ZONE_NAMES" ]; then
    # an account whose userdata cannot be read would otherwise leave every one
    # of its zones on the secondary, silently
    HOOK_USER=$(echo "$STDIN_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    src = d.get('data') if isinstance(d.get('data'), dict) else d
    print(src.get('user') or '')
except Exception:
    pass
" 2>/dev/null)
    [ -n "$HOOK_USER" ] && log "[!] No domains found for account '$HOOK_USER' — its zones stay on the secondary; check /var/cpanel/userdata/$HOOK_USER/main"
    exit 0
fi

DOMAIN_LIB="/usr/local/bin/seconddns-domain"
[ -r "$DOMAIN_LIB" ] || { log "[!] $DOMAIN_LIB missing, cannot validate zone name"; exit 0; }
SECONDDNS_DOMAIN_LIB=1 . "$DOMAIN_LIB"

OWNER_LIB="/usr/local/bin/seconddns-owner"
[ -r "$OWNER_LIB" ] && SECONDDNS_OWNER_LIB=1 . "$OWNER_LIB"
QUEUE="/usr/local/bin/seconddns-queue"

echo "$ZONE_NAMES" | while IFS= read -r ZONE_NAME; do
[ -z "$ZONE_NAME" ] && continue
RAW_NAME="$ZONE_NAME"
if ! canonical_domain "$ZONE_NAME"; then
    log "[!] Zone '$ZONE_NAME' refused: $DOMAIN_ERROR (cpanel hook)"
    continue
fi
ZONE_NAME="$DOMAIN"
# keep what the panel actually handed over, for later diagnosis
RAW_NOTE=""; [ "$RAW_NAME" != "$ZONE_NAME" ] && RAW_NOTE=" (received as '$RAW_NAME')"

log "Zone deleted: $ZONE_NAME (cpanel hook)$RAW_NOTE"

if type owner_check >/dev/null 2>&1; then
    owner_check "$ZONE_NAME" "$MASTER_IP"
    case $? in
        1) log "[~] Zone $ZONE_NAME is mastered by $OWNER_IP, not this server — delete skipped"; continue ;;
        2) log "[~] Zone $ZONE_NAME owner check: API unreachable, queued; checked again at delivery" ;;
        4) log "[!] Zone $ZONE_NAME owner check skipped: api_url/api_key/master_ip missing in config, queued WITHOUT check" ;;
    esac
fi

if "$QUEUE" enqueue delete "$ZONE_NAME" "$MASTER_IP"; then
    log "[>] Zone $ZONE_NAME removal queued for SecondDNS"
else
    log "[!] Zone $ZONE_NAME removal NOT queued (seconddns-queue failed)"
fi
done

exit 0
