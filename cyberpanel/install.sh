#!/bin/bash
set -e

# SecondDNS CyberPanel Integration Installer
# Usage:
#   ./install.sh --api-key=YOUR_API_KEY [--api-url=URL] [--master-ip=IP] [--yes]
#   curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel/install.sh | bash -s -- --api-key=YOUR_KEY

REPO_RAW="https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel"
INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/seconddns.conf"
CYBERPANEL_DIR="/usr/local/CyberCP"
PLUGIN_FILE="$CYBERPANEL_DIR/plogical/seconddns_plugin.py"
WSGI_FILE="$CYBERPANEL_DIR/CyberCP/wsgi.py"
INIT_FILE="$CYBERPANEL_DIR/CyberCP/__init__.py"
READY_FILE="$CYBERPANEL_DIR/CyberCP/ready.py"
LOG_FILE="/var/log/seconddns.log"

API_KEY=""
API_URL="https://seconddns.com"
MASTER_IP=""
AUTO_YES=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --api-key=*) API_KEY="${arg#*=}" ;;
        --api-url=*) API_URL="${arg#*=}" ;;
        --master-ip=*) MASTER_IP="${arg#*=}" ;;
        --yes|-y) AUTO_YES=1 ;;
        --help|-h)
            echo "Usage: $0 --api-key=KEY [--api-url=URL] [--master-ip=IP] [--yes]"
            echo ""
            echo "  --api-key=KEY     Your SecondDNS API key (required)"
            echo "  --api-url=URL     API base URL (default: https://seconddns.com)"
            echo "  --master-ip=IP    Primary DNS server IP (default: auto-detect)"
            echo "  --yes             Skip confirmation prompts"
            exit 0
            ;;
    esac
done

if [ -z "$API_KEY" ]; then
    echo "Error: --api-key is required"
    echo "Get your key from: ${API_URL}/dashboard/api-key"
    echo ""
    echo "Usage: $0 --api-key=YOUR_KEY"
    exit 1
fi

# Detect if running from repo clone or curl pipe
LOCAL_MODE=0
[ -f "seconddns.py" ] && LOCAL_MODE=1

download_file() {
    local file="$1" dest="$2"
    if [ "$LOCAL_MODE" -eq 1 ] && [ -f "$file" ]; then
        cp "$file" "$dest"
    else
        curl -sf --max-time 30 -o "$dest" "${REPO_RAW}/${file}" || {
            echo "[!] Failed to download $file"
            exit 1
        }
    fi
}

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

echo "=== SecondDNS CyberPanel Integration ==="
echo ""

# Verify API key
echo "[*] Verifying API key..."
VERIFY=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Installer/1.0" \
    "$API_URL/api/zones" 2>/dev/null) && {
    echo "[+] API key valid"
} || {
    echo "[!] API key verification failed — check your key and URL"
    echo "    URL: $API_URL"
    echo "    Key: ${API_KEY:0:8}..."
    exit 1
}

# Detect server IPs
SERVER_V4=$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
SERVER_V6=$(curl -6 -sf --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")

# Get available secondary DNS IPs from API
API_DNS_IPS=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Installer/1.0" \
    "$API_URL/api/server-info" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('dnsIps',''))" 2>/dev/null || echo "")

API_HAS_V4=$(echo "$API_DNS_IPS" | tr ',' '\n' | grep -v ':' | head -1)
API_HAS_V6=$(echo "$API_DNS_IPS" | tr ',' '\n' | grep ':' | head -1)

# Intersect: offer only protocols both server and API support
CAN_V4="" ; [ -n "$SERVER_V4" ] && [ -n "$API_HAS_V4" ] && CAN_V4=1
CAN_V6="" ; [ -n "$SERVER_V6" ] && [ -n "$API_HAS_V6" ] && CAN_V6=1

IP_PREFERENCE=""
if [ -n "$CAN_V4" ] && [ -n "$CAN_V6" ]; then
    echo "[+] Both protocols available:"
    echo "    1) IPv4: server $SERVER_V4 ↔ secondary $API_HAS_V4"
    echo "    2) IPv6: server $SERVER_V6 ↔ secondary $API_HAS_V6"
    read -p "    Choose [1]: " -n 1 -r < /dev/tty
    echo
    case $REPLY in
        2) IP_PREFERENCE="v6" ;;
        *) IP_PREFERENCE="v4" ;;
    esac
elif [ -n "$CAN_V6" ]; then
    IP_PREFERENCE="v6"
elif [ -n "$CAN_V4" ]; then
    IP_PREFERENCE="v4"
fi

# Set master IP based on preference
if [ -z "$MASTER_IP" ]; then
    if [ "$IP_PREFERENCE" = "v6" ]; then
        MASTER_IP="$SERVER_V6"
    elif [ "$IP_PREFERENCE" = "v4" ]; then
        MASTER_IP="$SERVER_V4"
    fi

    if [ -n "$MASTER_IP" ]; then
        echo "[+] Master IP: $MASTER_IP"
    else
        echo "[!] Could not auto-detect master IP"
        read -p "    Enter your primary DNS server IP: " MASTER_IP < /dev/tty
    fi
fi

# Install CLI
echo ""
download_file "seconddns.py" "$INSTALL_DIR/seconddns"
chmod +x "$INSTALL_DIR/seconddns"
echo "[+] Installed CLI to $INSTALL_DIR/seconddns"

# Create config
cat > "$CONFIG_FILE" << EOF
[seconddns]
api_url = $API_URL
api_key = $API_KEY
master_ip = $MASTER_IP
EOF
chown root:root "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"
echo "[+] Config written to $CONFIG_FILE"

# Log file with correct permissions
touch "$LOG_FILE"
if id cyberpanel &>/dev/null; then
    chown cyberpanel:cyberpanel "$LOG_FILE"
fi
chmod 664 "$LOG_FILE"
echo "[+] Log file: $LOG_FILE"

# Install CyberPanel plugin
if [ -d "$CYBERPANEL_DIR" ]; then
    download_file "seconddns.py" "$PLUGIN_FILE"
    echo "[+] Installed plugin to $PLUGIN_FILE"

    # Clean and register signals
    SIGNAL_BLOCK='
# SecondDNS integration — register domain create/delete signals
try:
    from plogical.seconddns_plugin import register_signals, setup_logging
    setup_logging()
    register_signals()
except Exception as e:
    import logging
    logging.getLogger("seconddns").error("Failed to register signals: %s", e)'

    SIGNAL_TARGET=""
    [ -f "$WSGI_FILE" ] && SIGNAL_TARGET="$WSGI_FILE"
    [ -z "$SIGNAL_TARGET" ] && [ -f "$READY_FILE" ] && SIGNAL_TARGET="$READY_FILE"
    [ -z "$SIGNAL_TARGET" ] && [ -f "$INIT_FILE" ] && SIGNAL_TARGET="$INIT_FILE"

    if [ -n "$SIGNAL_TARGET" ]; then
        for f in "$WSGI_FILE" "$INIT_FILE" "$READY_FILE"; do
            [ -f "$f" ] && grep -q "seconddns_plugin" "$f" 2>/dev/null && \
                python3 -c "
import re, sys
p = sys.argv[1]
with open(p) as f: c = f.read()
c = re.sub(r'\n*# SecondDNS integration[^\n]*\ntry:\n\s+from plogical\.seconddns_plugin.*?except[^\n]*\n\s+import logging\n\s+logging\.getLogger.*?\n', '', c, flags=re.DOTALL)
with open(p, 'w') as f: f.write(c)
" "$f" && echo "[~] Cleaned old blocks from $f"
        done
        printf '%s\n' "$SIGNAL_BLOCK" >> "$SIGNAL_TARGET"
        echo "[+] Registered signals in $SIGNAL_TARGET"
    else
        echo "[!] No CyberPanel entry point found — register signals manually"
    fi

    # Systemd hook
    SYSTEMD_SERVICE="/etc/systemd/system/seconddns-signals.service"
    download_file "seconddns-signals.service" "$SYSTEMD_SERVICE"
    systemctl daemon-reload
    systemctl enable seconddns-signals.service 2>/dev/null
    echo "[+] Systemd hook installed (survives CyberPanel updates)"

    # Restart
    echo ""
    if confirm "Restart CyberPanel (lscpd) to activate?"; then
        systemctl restart lscpd
        echo "[+] CyberPanel restarted"
    fi
else
    echo "[!] CyberPanel not found — CLI-only mode"
fi

# PowerDNS AXFR check
echo ""
echo "--- PowerDNS AXFR check ---"
PDNS_CONF=""
for f in /etc/pdns/pdns.conf /etc/powerdns/pdns.conf /etc/pdns.conf; do
    [ -f "$f" ] && PDNS_CONF="$f" && break
done

if [ -n "$PDNS_CONF" ]; then
    echo "[=] Found $PDNS_CONF"

    # Use the IP matching chosen protocol
    if [ "$IP_PREFERENCE" = "v6" ] && [ -n "$API_HAS_V6" ]; then
        DNS_IPS="$API_HAS_V6"
    elif [ -n "$API_HAS_V4" ]; then
        DNS_IPS="$API_HAS_V4"
    else
        DNS_IPS="$API_DNS_IPS"
    fi

    if [ -z "$DNS_IPS" ]; then
        DNS_IPS=$(grep -E "^dns_ips\s*=" "$CONFIG_FILE" 2>/dev/null | sed 's/^dns_ips\s*=\s*//' | tr -d ' ')
        [ -z "$DNS_IPS" ] && read -p "    Enter secondary DNS IP: " DNS_IPS < /dev/tty
    fi

    echo "[+] Secondary DNS IP: $DNS_IPS"

    if [ -n "$DNS_IPS" ]; then
        ISSUES=0
        if ! grep -qE "^master=yes" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] master=yes is missing"
            ISSUES=$((ISSUES+1))
        fi
        if ! grep -qE "^allow-axfr-ips=.*${DNS_IPS%%,*}" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] allow-axfr-ips does not include ${DNS_IPS%%,*}"
            ISSUES=$((ISSUES+1))
        fi
        if ! grep -qE "^also-notify=" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] also-notify is not configured"
            ISSUES=$((ISSUES+1))
        fi

        if [ "$ISSUES" -gt 0 ]; then
            if confirm "Apply fixes automatically? (backup will be created)"; then
                cp "$PDNS_CONF" "${PDNS_CONF}.bak.$(date +%s)"

                grep -qE "^master=yes" "$PDNS_CONF" || echo "master=yes" >> "$PDNS_CONF"

                if grep -qE "^allow-axfr-ips=" "$PDNS_CONF"; then
                    grep -qE "^allow-axfr-ips=.*${DNS_IPS%%,*}" "$PDNS_CONF" || \
                        sed -i "s|^allow-axfr-ips=\(.*\)|allow-axfr-ips=\1,$DNS_IPS|" "$PDNS_CONF"
                else
                    echo "allow-axfr-ips=127.0.0.0/8,::1,$DNS_IPS" >> "$PDNS_CONF"
                fi

                if grep -qE "^also-notify=" "$PDNS_CONF"; then
                    grep -qE "^also-notify=.*${DNS_IPS%%,*}" "$PDNS_CONF" || \
                        sed -i "s|^also-notify=\(.*\)|also-notify=\1,$DNS_IPS|" "$PDNS_CONF"
                else
                    echo "also-notify=$DNS_IPS" >> "$PDNS_CONF"
                fi

                systemctl restart pdns 2>/dev/null || service pdns restart 2>/dev/null
                echo "[+] PowerDNS configured and restarted"
            fi
        else
            echo "[+] PowerDNS AXFR config OK"
        fi
    fi
else
    echo "[!] pdns.conf not found — configure AXFR manually"
fi

# Initial sync — check CyberPanel domains, ask if any exist
DOMAIN_COUNT=$(python3 -c "
import sys; sys.path.insert(0, '/usr/local/CyberCP')
try:
    import os; os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'CyberCP.settings')
    import django; django.setup()
    from websiteFunctions.models import Websites
    print(Websites.objects.count())
except: print(0)
" 2>/dev/null || echo "0")

if [ "$DOMAIN_COUNT" -gt 0 ]; then
    echo ""
    if confirm "Found $DOMAIN_COUNT domains. Sync to secondary DNS now?"; then
        "$INSTALL_DIR/seconddns" sync
    fi
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Config:  $CONFIG_FILE"
echo "  CLI:     seconddns {sync|list|add|remove} DOMAIN"
echo "  Logs:    tail -f $LOG_FILE"
echo ""
echo "  Domains created/deleted in CyberPanel will be"
echo "  automatically synced to your secondary DNS."
