#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 - see LICENSE file
set -e

# SecondDNS DirectAdmin Integration Uninstaller

HOOKS_DIR="/usr/local/directadmin/scripts/custom"
CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"

echo "=== SecondDNS DirectAdmin Uninstaller ==="
echo ""

# Remove hooks
for hook in dns_create_post.sh dns_delete_post.sh; do
    if [ -f "$HOOKS_DIR/$hook" ] && grep -q "seconddns" "$HOOKS_DIR/$hook" 2>/dev/null; then
        rm -f "$HOOKS_DIR/$hook"
        echo "[+] Removed hook: $HOOKS_DIR/$hook"
    fi
done

# Remove config
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "[+] Removed config: $CONFIG_FILE"
fi

echo ""
echo "=== Uninstall complete ==="
echo "  Log file kept at: $LOG_FILE"
echo "  Your zones on the secondary DNS are not deleted automatically."
