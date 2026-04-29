#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
set -e

# SecondDNS Plesk Integration Uninstaller

SCRIPT_DIR="/usr/local/bin"
CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"

confirm() {
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        return 1
    fi
    read -p "$1 [Y/n] " -n 1 -r < /dev/tty
    echo
    [[ ! $REPLY =~ ^[Nn]$ ]]
}

echo "=== SecondDNS Plesk Uninstaller ==="
echo ""

# Remove event handlers
if command -v plesk &>/dev/null; then
    removed=0
    CURRENT_ID=""
    while IFS= read -r line; do
        case "$line" in
            *"Id "*)
                CURRENT_ID=$(echo "$line" | awk '{print $NF}')
                ;;
            *"seconddns-plesk"*)
                if [ -n "$CURRENT_ID" ]; then
                    plesk bin event_handler --delete "$CURRENT_ID" 2>/dev/null && removed=$((removed+1))
                    CURRENT_ID=""
                fi
                ;;
        esac
    done < <(plesk bin event_handler --list 2>/dev/null)
    echo "[+] Removed $removed event handlers"

    # Restore default ns2.<domain> in DNS template
    NS_COUNT=$(plesk db "SELECT COUNT(*) AS cnt FROM dns_recs_t WHERE type='NS' AND val LIKE '%seconddns.com%'" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    if [ "${NS_COUNT:-0}" -gt 0 ]; then
        if confirm "Remove SecondDNS nameserver from DNS template and restore ns2.<domain>?"; then
            plesk db "DELETE FROM dns_recs_t WHERE type='NS' AND val LIKE '%seconddns.com%'" 2>/dev/null
            echo "[+] Removed SecondDNS NS from template"
            # Restore default ns2.<domain> if not present
            DEFAULT_NS2=$(plesk db "SELECT COUNT(*) AS cnt FROM dns_recs_t WHERE type='NS' AND val='ns2.<domain>.'" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
            if [ "${DEFAULT_NS2:-0}" -eq 0 ]; then
                plesk bin server_dns -a -ns "" -nameserver "ns2.<domain>" 2>/dev/null
                echo "[+] Restored default ns2.<domain> in template"
            fi
        fi
    fi
fi

# Remove scripts
for script in domain_create.sh domain_delete.sh; do
    target="$SCRIPT_DIR/seconddns-plesk-${script}"
    if [ -f "$target" ]; then
        rm -f "$target"
        echo "[+] Removed: $target"
    fi
done

# Clean BIND config
for f in /etc/bind/named.conf.options /etc/named.conf.options /etc/named.conf; do
    [ -f "$f" ] || continue
    if grep -q "seconddns\|SecondDNS" "$f" 2>/dev/null; then
        # No comment markers — check for IPs added by installer
        break
    fi
    # Remove allow-transfer and also-notify entries added by installer
    # Read the IP from config before we delete it
    SECONDARY_IP=""
    if [ -f "$CONFIG_FILE" ]; then
        # Config not yet deleted, get master_ip to find the secondary
        true
    fi
    break
done

# Try to clean BIND config by removing SecondDNS IPs
if [ -f "$CONFIG_FILE" ]; then
    # We can't easily know which IP was the secondary, so just warn
    true
fi

for f in /etc/bind/named.conf.options /etc/named.conf.options; do
    [ -f "$f" ] || continue
    # Check if our IPs are in allow-transfer or also-notify
    if grep -qE "allow-transfer|also-notify" "$f" 2>/dev/null; then
        echo ""
        echo "[!] BIND config may still contain SecondDNS IPs in: $f"
        echo "    Review allow-transfer and also-notify directives manually."
        echo "    Also check Plesk UI: Tools & Settings > DNS Settings >"
        echo "    Server-wide Settings > Additional DNS settings"
    fi
    break
done

# Remove config
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "[+] Removed config: $CONFIG_FILE"
fi

# Remove log
if [ -f "$LOG_FILE" ]; then
    if confirm "Remove log file $LOG_FILE?"; then
        rm -f "$LOG_FILE"
        echo "[+] Removed log: $LOG_FILE"
    else
        echo "[=] Log file kept at: $LOG_FILE"
    fi
fi

echo ""
echo "=== Uninstall complete ==="
echo "  Your zones on the secondary DNS are not deleted automatically."
