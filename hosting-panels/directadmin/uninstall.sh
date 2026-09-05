#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
set -e

# SecondDNS DirectAdmin Integration Uninstaller

HOOKS_DIR="/usr/local/directadmin/scripts/custom"
CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"

echo "=== SecondDNS DirectAdmin Uninstaller ==="
echo ""

# Remove hooks
for hook in dns_create_post.sh dns_delete_post.sh domain_change_post.sh; do
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

# Remove offline queue
systemctl disable --now seconddns-queued.service 2>/dev/null
rm -f /etc/systemd/system/seconddns-queued.service
systemctl daemon-reload 2>/dev/null
rm -f /usr/local/bin/seconddns /usr/local/bin/seconddns-domain /usr/local/bin/seconddns-owner /usr/local/bin/seconddns-migrate-master /usr/local/bin/seconddns-reconcile /usr/local/bin/seconddns_common.py /usr/local/bin/seconddns-queue /usr/local/bin/seconddns-queued
if [ -f /var/lib/seconddns/queue.db ] && command -v sqlite3 &>/dev/null; then
    n=$(sqlite3 /var/lib/seconddns/queue.db "SELECT COUNT(*) FROM ops WHERE status='pending';" 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] && echo "[!] Discarding $n pending zone operation(s) that were never delivered to SecondDNS"
fi
rm -rf /var/lib/seconddns
