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
