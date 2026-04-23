#!/bin/bash
set -e

# SecondDNS DirectAdmin Integration Installer
# Usage:
#   ./install.sh --api-key=YOUR_API_KEY [--api-url=URL] [--master-ip=IP] [--yes]
#   curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/directadmin/install.sh | bash -s -- --api-key=YOUR_KEY

CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"
HOOKS_DIR="/usr/local/directadmin/scripts/custom"
REPO_URL="https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/directadmin"

API_KEY=""
API_URL="https://seconddns.com"
MASTER_IP=""
AUTO_YES=0

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

echo "=== SecondDNS DirectAdmin Integration ==="
echo ""

# Verify API key
echo "[*] Verifying API key..."
curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Installer/1.0" \
    "$API_URL/api/zones" > /dev/null 2>&1 && {
    echo "[+] API key valid"
} || {
    echo "[!] API key verification failed — check your key and URL"
    exit 1
}

# Detect server IP
if [ -z "$MASTER_IP" ]; then
    MASTER_IP=$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$MASTER_IP" ]; then
        echo "[+] Detected server IP: $MASTER_IP"
    else
        echo "[!] Could not auto-detect server IP"
        read -p "    Enter your primary DNS server IP: " MASTER_IP < /dev/tty
    fi
fi

# Check DirectAdmin
if [ ! -d "/usr/local/directadmin" ]; then
    echo "[!] DirectAdmin not found at /usr/local/directadmin"
    exit 1
fi

# Create config
if [ -f "$CONFIG_FILE" ]; then
    echo "[=] Config exists at $CONFIG_FILE — updating"
fi
cat > "$CONFIG_FILE" << EOF
[seconddns]
api_url = $API_URL
api_key = $API_KEY
master_ip = $MASTER_IP
EOF
chown root:root "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"
echo "[+] Config written to $CONFIG_FILE"

# Log file
touch "$LOG_FILE"
chmod 664 "$LOG_FILE"
echo "[+] Log file: $LOG_FILE"

# Install hooks
mkdir -p "$HOOKS_DIR"

for hook in dns_create_post.sh dns_delete_post.sh; do
    curl -sf --max-time 10 -o "$HOOKS_DIR/$hook" "$REPO_URL/$hook"
    chmod +x "$HOOKS_DIR/$hook"
    echo "[+] Installed hook: $HOOKS_DIR/$hook"
done

# PowerDNS / named AXFR check
echo ""
echo "--- DNS Server AXFR check ---"

# Get secondary DNS IPs from API
DNS_IPS=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Installer/1.0" \
    "$API_URL/api/server-info" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('dnsIps',''))" 2>/dev/null || echo "")

if [ -n "$DNS_IPS" ]; then
    echo "[+] Secondary DNS IPs: $DNS_IPS"
    echo ""
    echo "    Make sure your DNS server allows AXFR from these IPs."
    echo "    For BIND/named, add to zone config:"
    echo "      allow-transfer { ${DNS_IPS%%,*}; };"
    echo "      also-notify { ${DNS_IPS%%,*}; };"
    echo ""
    echo "    For PowerDNS, add to pdns.conf:"
    echo "      allow-axfr-ips=${DNS_IPS}"
    echo "      also-notify=${DNS_IPS}"
else
    echo "[!] Could not fetch secondary DNS IPs"
fi

# Initial sync
echo ""
if confirm "Sync existing domains to secondary DNS now?"; then
    echo "[*] Syncing domains..."
    domains=$(ls /etc/virtual/ 2>/dev/null | grep -v "^default$" | grep -v "^majordomo$")
    added=0
    for domain in $domains; do
        [ -f "/etc/virtual/$domain/domains" ] || continue
        response=$(curl -sf --max-time 15 \
            -X POST \
            -H "X-API-Key: $API_KEY" \
            -H "Content-Type: application/json" \
            -H "User-Agent: SecondDNS-DirectAdmin/1.0" \
            -d "{\"name\":\"$domain\",\"masterIp\":\"$MASTER_IP\"}" \
            "$API_URL/api/zones" 2>/dev/null)
        if [ $? -eq 0 ]; then
            echo "    [+] $domain"
            added=$((added+1))
        fi
    done
    echo "[+] Synced $added domains"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Config:  $CONFIG_FILE"
echo "  Hooks:   $HOOKS_DIR/dns_create_post.sh"
echo "           $HOOKS_DIR/dns_delete_post.sh"
echo "  Logs:    tail -f $LOG_FILE"
echo ""
echo "  Domains created/deleted in DirectAdmin will be"
echo "  automatically synced to your secondary DNS."
