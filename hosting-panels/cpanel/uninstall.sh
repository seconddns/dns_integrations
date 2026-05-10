#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
set -e

# SecondDNS cPanel/WHM Integration Uninstaller

HOOKS_BIN="/usr/local/cpanel/bin/manage_hooks"
SCRIPT_DIR="/usr/local/bin"

AUTO_YES=0
for arg in "$@"; do
    case $arg in
        --yes|-y) AUTO_YES=1 ;;
    esac
done

confirm() {
    [ "$AUTO_YES" -eq 1 ] && return 0
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        echo "[!] No interactive terminal. Use --yes to skip prompts."
        exit 1
    fi
    read -p "$1 [Y/n] " -n 1 -r < /dev/tty
    echo
    [[ ! $REPLY =~ ^[Nn]$ ]]
}

echo "=== SecondDNS cPanel/WHM Uninstaller ==="
echo ""

if ! confirm "Remove SecondDNS cPanel integration?"; then
    echo "Aborted."
    exit 0
fi

# Remove hooks
if [ -x "$HOOKS_BIN" ]; then
    echo "[*] Removing hooks..."
    "$HOOKS_BIN" list 2>/dev/null | grep "seconddns-cpanel" | while read -r line; do
        hook_id=$(echo "$line" | awk '{print $1}')
        if [ -n "$hook_id" ]; then
            "$HOOKS_BIN" remove "$hook_id" 2>/dev/null && echo "[+] Removed hook: $hook_id" || true
        fi
    done
else
    echo "[!] manage_hooks not found — skipping hook removal"
fi

# Remove scripts
for script in domain_create.sh domain_delete.sh; do
    target="$SCRIPT_DIR/seconddns-cpanel-${script}"
    if [ -f "$target" ]; then
        rm -f "$target"
        echo "[+] Removed: $target"
    fi
done

# Remove secondary NS from zone templates
ZONE_TEMPLATE_DIR="/var/cpanel/zonetemplates"
CONFIG="/etc/seconddns.conf"
if [ -d "$ZONE_TEMPLATE_DIR" ]; then
    API_URL_CONF=$(grep "^api_url" "$CONFIG" 2>/dev/null | sed 's/^api_url\s*=\s*//')
    API_KEY_CONF=$(grep "^api_key" "$CONFIG" 2>/dev/null | sed 's/^api_key\s*=\s*//')
    API_NS_CONF=""
    if [ -n "$API_URL_CONF" ] && [ -n "$API_KEY_CONF" ]; then
        API_NS_CONF=$(curl -sf --max-time 10 \
            -H "X-API-Key: $API_KEY_CONF" \
            -H "User-Agent: SecondDNS-cPanel/1.0" \
            "$API_URL_CONF/api/server-info" 2>/dev/null | \
            python3 -c "import sys,json; ns=json.load(sys.stdin).get('nameservers',[]); print(ns[0] if ns else '')" 2>/dev/null || echo "")
    fi

    if [ -n "$API_NS_CONF" ]; then
        echo "[*] Removing NS records from zone templates..."
        for tmpl in "$ZONE_TEMPLATE_DIR"/*; do
            [ -f "$tmpl" ] || continue
            if grep -qF "$API_NS_CONF" "$tmpl" 2>/dev/null; then
                sed -i "/$API_NS_CONF/d" "$tmpl"
                echo "[+] Removed NS from template: $(basename "$tmpl")"
            fi
        done
    else
        echo "[!] Could not fetch NS name — remove SecondDNS NS entries from"
        echo "    $ZONE_TEMPLATE_DIR manually via WHM > DNS Functions > Edit Zone Templates"
    fi
fi

# Optionally remove config
if [ -f /etc/seconddns.conf ]; then
    if confirm "Remove /etc/seconddns.conf?"; then
        rm -f /etc/seconddns.conf
        echo "[+] Removed: /etc/seconddns.conf"
    fi
fi

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "  Note: AXFR settings in WHM and BIND config must be removed manually."
echo "  Verify: $HOOKS_BIN list"
