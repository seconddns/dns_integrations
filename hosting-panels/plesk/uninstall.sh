#!/bin/bash
set -e

# SecondDNS Plesk Integration Uninstaller

SCRIPT_DIR="/usr/local/bin"
CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"

echo "=== SecondDNS Plesk Uninstaller ==="
echo ""

# Remove event handlers
if command -v plesk &>/dev/null; then
    removed=0
    while IFS= read -r handler_id; do
        if [ -n "$handler_id" ]; then
            plesk bin event_handler --delete "$handler_id" 2>/dev/null && removed=$((removed+1))
        fi
    done < <(plesk bin event_handler --list 2>/dev/null | grep "seconddns-plesk" | awk '{print $1}')
    echo "[+] Removed $removed event handlers"
fi

# Remove scripts
for script in domain_create.sh domain_delete.sh; do
    target="$SCRIPT_DIR/seconddns-plesk-${script}"
    if [ -f "$target" ]; then
        rm -f "$target"
        echo "[+] Removed: $target"
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
