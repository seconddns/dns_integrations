#!/bin/bash
set -e

# SecondDNS CyberPanel Integration Uninstaller
# Usage: curl -sL .../uninstall.sh | bash
#    or: ./uninstall.sh [--yes]

CYBERPANEL_DIR="/usr/local/CyberCP"
WSGI_FILE="$CYBERPANEL_DIR/CyberCP/wsgi.py"
INIT_FILE="$CYBERPANEL_DIR/CyberCP/__init__.py"
READY_FILE="$CYBERPANEL_DIR/CyberCP/ready.py"

AUTO_YES=0
for arg in "$@"; do
    case $arg in --yes|-y) AUTO_YES=1 ;; esac
done

confirm() {
    [ "$AUTO_YES" -eq 1 ] && return 0
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        echo "[!] No interactive terminal. Use --yes to skip prompts."
        exit 1
    fi
    read -p "$1 [y/N] " -n 1 -r < /dev/tty
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

echo "=== SecondDNS CyberPanel Uninstaller ==="
echo ""

if ! confirm "Remove SecondDNS integration?"; then
    echo "Cancelled."
    exit 0
fi

# Remove signal blocks from all CyberPanel files
for f in "$WSGI_FILE" "$INIT_FILE" "$READY_FILE"; do
    [ -f "$f" ] || continue
    if grep -q "seconddns_plugin" "$f" 2>/dev/null; then
        python3 -c "
import re, sys
p = sys.argv[1]
with open(p) as f: c = f.read()
c = re.sub(r'\n*# SecondDNS integration[^\n]*\ntry:\n\s+from plogical\.seconddns_plugin.*?except[^\n]*\n\s+import logging\n\s+logging\.getLogger.*?\n', '', c, flags=re.DOTALL)
with open(p, 'w') as f: f.write(c)
" "$f"
        echo "[+] Removed signal block from $f"
    fi
done

# Remove systemd service
if [ -f /etc/systemd/system/seconddns-signals.service ]; then
    systemctl disable seconddns-signals.service 2>/dev/null
    rm -f /etc/systemd/system/seconddns-signals.service
    systemctl daemon-reload
    echo "[+] Removed systemd hook"
fi

# Remove files
rm -f /usr/local/bin/seconddns
echo "[+] Removed CLI"

rm -f "$CYBERPANEL_DIR/plogical/seconddns_plugin.py"
echo "[+] Removed plugin"

rm -f /etc/seconddns.conf
echo "[+] Removed config"

rm -f /var/log/seconddns.log
echo "[+] Removed log file"

# Clean lock files
rm -f /tmp/.seconddns_*.lock 2>/dev/null

# Restart CyberPanel
if confirm "Restart CyberPanel (lscpd)?"; then
    systemctl restart lscpd
    echo "[+] CyberPanel restarted"
fi

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "Note: DNS zones on SecondDNS were NOT removed."
echo "Delete them manually via Dashboard or API if needed."
