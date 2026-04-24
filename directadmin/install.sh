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

# Detect server IPs
SERVER_V4=$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
SERVER_V6=$(curl -6 -sf --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")

# Get secondary DNS IPs from API
API_DNS_IPS=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Installer/1.0" \
    "$API_URL/api/server-info" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('dnsIps',''))" 2>/dev/null || echo "")

API_HAS_V4=$(echo "$API_DNS_IPS" | tr ',' '\n' | tr -d ' ' | grep -v ':' | grep -v '^$' | head -1)
API_HAS_V6=$(echo "$API_DNS_IPS" | tr ',' '\n' | tr -d ' ' | grep ':' | head -1)

# Determine available protocols
CAN_V4="" ; [ -n "$SERVER_V4" ] && [ -n "$API_HAS_V4" ] && CAN_V4=1
CAN_V6="" ; [ -n "$SERVER_V6" ] && [ -n "$API_HAS_V6" ] && CAN_V6=1

IP_PREFERENCE=""
if [ -n "$CAN_V4" ] && [ -n "$CAN_V6" ]; then
    echo "[+] Both protocols available:"
    echo "    1) IPv4: server $SERVER_V4 ↔ secondary $API_HAS_V4"
    echo "    2) IPv6: server $SERVER_V6 ↔ secondary $API_HAS_V6"
    while true; do
        read -p "    Choose (1 or 2): " -n 1 -r < /dev/tty
        echo
        case $REPLY in
            1) IP_PREFERENCE="v4"; break ;;
            2) IP_PREFERENCE="v6"; break ;;
            *) echo "    Please enter 1 or 2" ;;
        esac
    done
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

# Set secondary DNS IP based on preference
if [ "$IP_PREFERENCE" = "v6" ] && [ -n "$API_HAS_V6" ]; then
    DNS_IPS="$API_HAS_V6"
elif [ -n "$API_HAS_V4" ]; then
    DNS_IPS="$API_HAS_V4"
else
    DNS_IPS="$API_DNS_IPS"
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
    curl -sf --max-time 10 -o "$HOOKS_DIR/$hook" "$REPO_URL/$hook?t=$(date +%s)"
    chmod +x "$HOOKS_DIR/$hook"
    echo "[+] Installed hook: $HOOKS_DIR/$hook"
done

# --- Detect DNS server and configure AXFR ---
echo ""
echo "--- DNS Server detection & AXFR configuration ---"

if [ -z "$DNS_IPS" ]; then
    echo "[!] No secondary DNS IP — skipping AXFR config"
fi

if [ -n "$DNS_IPS" ]; then
    echo "[+] Secondary DNS IP: $DNS_IPS"
    SECONDARY_IP="${DNS_IPS%%,*}"

    # Detect which DNS server is running
    DNS_SERVER=""
    PDNS_CONF=""
    NAMED_CONF=""

    # Check DirectAdmin CustomBuild config
    if [ -f "/usr/local/directadmin/custombuild/options.conf" ]; then
        DA_DNS=$(grep "^dns=" /usr/local/directadmin/custombuild/options.conf 2>/dev/null | cut -d= -f2)
        echo "[=] DirectAdmin CustomBuild dns=$DA_DNS"
    fi

    # Detect PowerDNS
    if command -v pdns_server &>/dev/null || systemctl is-active pdns &>/dev/null 2>&1; then
        DNS_SERVER="powerdns"
        for f in /etc/pdns/pdns.conf /etc/powerdns/pdns.conf /etc/pdns.conf; do
            [ -f "$f" ] && PDNS_CONF="$f" && break
        done
    fi

    # Detect BIND/named
    if command -v named &>/dev/null || systemctl is-active named &>/dev/null 2>&1; then
        DNS_SERVER="${DNS_SERVER:+$DNS_SERVER+}named"
        for f in /etc/named.conf /etc/bind/named.conf /etc/named/named.conf; do
            [ -f "$f" ] && NAMED_CONF="$f" && break
        done
    fi

    if [ -z "$DNS_SERVER" ]; then
        echo "[!] Could not detect DNS server (neither PowerDNS nor BIND/named found)"
        echo "    Configure AXFR manually to allow transfers to $SECONDARY_IP"
    fi

    # Check if chosen protocol is supported by DNS server
    if [ -n "$NAMED_CONF" ]; then
        NAMED_OPTIONS=""
        for f in /etc/named.conf.options /etc/bind/named.conf.options; do
            [ -f "$f" ] && NAMED_OPTIONS="$f" && break
        done
        [ -z "$NAMED_OPTIONS" ] && NAMED_OPTIONS="$NAMED_CONF"

        if [ "$IP_PREFERENCE" = "v6" ]; then
            if grep -q "listen-on-v6" "$NAMED_OPTIONS" 2>/dev/null; then
                if grep -q 'listen-on-v6.*none' "$NAMED_OPTIONS" 2>/dev/null; then
                    echo "[!] WARNING: BIND has listen-on-v6 set to none — IPv6 disabled"
                    echo "    Secondary DNS won't be able to reach this server via IPv6"
                fi
            fi
        elif [ "$IP_PREFERENCE" = "v4" ]; then
            if grep -q 'listen-on\s' "$NAMED_OPTIONS" 2>/dev/null && ! grep -q 'listen-on-v6' "$NAMED_OPTIONS" 2>/dev/null; then
                if grep -q 'listen-on.*none' "$NAMED_OPTIONS" 2>/dev/null; then
                    echo "[!] WARNING: BIND has listen-on set to none — IPv4 disabled"
                fi
            fi
        fi
    fi

    if [ -n "$PDNS_CONF" ]; then
        PDNS_LOCAL=$(grep "^local-address=" "$PDNS_CONF" 2>/dev/null | sed 's/^local-address=//')
        if [ -n "$PDNS_LOCAL" ]; then
            if [ "$IP_PREFERENCE" = "v6" ] && ! echo "$PDNS_LOCAL" | grep -q ':'; then
                echo "[!] WARNING: PowerDNS local-address has no IPv6 — only listening on $PDNS_LOCAL"
            elif [ "$IP_PREFERENCE" = "v4" ] && ! echo "$PDNS_LOCAL" | grep -qE '^[0-9]'; then
                echo "[!] WARNING: PowerDNS local-address has no IPv4 — only listening on $PDNS_LOCAL"
            fi
        fi
    fi

    # --- PowerDNS configuration ---
    if [ -n "$PDNS_CONF" ]; then
        echo "[=] Detected PowerDNS: $PDNS_CONF"
        ISSUES=0

        if ! grep -qE "^master=yes" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] master=yes is missing"
            ISSUES=$((ISSUES+1))
        fi
        if ! grep -qE "^allow-axfr-ips=.*$SECONDARY_IP" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] allow-axfr-ips does not include $SECONDARY_IP"
            ISSUES=$((ISSUES+1))
        fi
        if ! grep -qE "^also-notify=.*$SECONDARY_IP" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] also-notify does not include $SECONDARY_IP"
            ISSUES=$((ISSUES+1))
        fi
        if ! grep -qE "^default-soa-edit=INCEPTION-INCREMENT" "$PDNS_CONF" 2>/dev/null; then
            echo "[!] default-soa-edit=INCEPTION-INCREMENT is missing"
            ISSUES=$((ISSUES+1))
        fi

        if [ "$ISSUES" -gt 0 ]; then
            if confirm "Apply PowerDNS fixes automatically? (backup will be created)"; then
                cp "$PDNS_CONF" "${PDNS_CONF}.bak.$(date +%s)"

                grep -qE "^master=yes" "$PDNS_CONF" || echo "master=yes" >> "$PDNS_CONF"
                grep -qE "^default-soa-edit=" "$PDNS_CONF" || echo "default-soa-edit=INCEPTION-INCREMENT" >> "$PDNS_CONF"

                if grep -qE "^allow-axfr-ips=" "$PDNS_CONF"; then
                    grep -qE "^allow-axfr-ips=.*$SECONDARY_IP" "$PDNS_CONF" || \
                        sed -i "s|^allow-axfr-ips=\(.*\)|allow-axfr-ips=\1,$DNS_IPS|" "$PDNS_CONF"
                else
                    echo "allow-axfr-ips=127.0.0.0/8,::1,$DNS_IPS" >> "$PDNS_CONF"
                fi

                if grep -qE "^also-notify=" "$PDNS_CONF"; then
                    grep -qE "^also-notify=.*$SECONDARY_IP" "$PDNS_CONF" || \
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

    # --- BIND/named configuration ---
    if [ -n "$NAMED_CONF" ]; then
        echo "[=] Detected BIND/named: $NAMED_CONF"

        # Check named.conf.options or named.conf for allow-transfer
        NAMED_OPTIONS=""
        for f in /etc/named.conf.options /etc/bind/named.conf.options "$NAMED_CONF"; do
            [ -f "$f" ] && NAMED_OPTIONS="$f" && break
        done

        if [ -n "$NAMED_OPTIONS" ]; then
            if grep -q "allow-transfer" "$NAMED_OPTIONS" 2>/dev/null; then
                if grep -q "$SECONDARY_IP" "$NAMED_OPTIONS" 2>/dev/null; then
                    echo "[+] BIND allow-transfer already includes $SECONDARY_IP"
                else
                    echo "[!] BIND allow-transfer does not include $SECONDARY_IP"
                    if confirm "Add $SECONDARY_IP to allow-transfer in $NAMED_OPTIONS?"; then
                        cp "$NAMED_OPTIONS" "${NAMED_OPTIONS}.bak.$(date +%s)"
                        # Remove 'none;' if present, then add our IP
                        sed -i "s|allow-transfer\s*{|allow-transfer { $SECONDARY_IP; |" "$NAMED_OPTIONS"
                        sed -i "s|\s*none\s*;||g" "$NAMED_OPTIONS"
                        echo "[+] Added $SECONDARY_IP to allow-transfer"
                    fi
                fi
            else
                echo "[!] No allow-transfer directive found"
                if confirm "Add allow-transfer and also-notify to $NAMED_OPTIONS?"; then
                    cp "$NAMED_OPTIONS" "${NAMED_OPTIONS}.bak.$(date +%s)"
                    # Add before closing }; of options block
                    sed -i "/^options\s*{/,/^};/ {
                        /^};/ i\\
\\tallow-transfer { $SECONDARY_IP; };\\
\\talso-notify { $SECONDARY_IP; };
                    }" "$NAMED_OPTIONS"
                    echo "[+] Added allow-transfer and also-notify"
                fi
            fi

            # Check also-notify
            if grep -q "also-notify" "$NAMED_OPTIONS" 2>/dev/null; then
                if ! grep -q "also-notify.*$SECONDARY_IP" "$NAMED_OPTIONS" 2>/dev/null; then
                    echo "[!] also-notify does not include $SECONDARY_IP"
                    if confirm "Add $SECONDARY_IP to also-notify?"; then
                        sed -i "s|also-notify\s*{|also-notify { $SECONDARY_IP; |" "$NAMED_OPTIONS"
                        sed -i "/also-notify/s|\s*none\s*;||g" "$NAMED_OPTIONS"
                        echo "[+] Added $SECONDARY_IP to also-notify"
                    fi
                fi
            else
                if confirm "Add also-notify for $SECONDARY_IP?"; then
                    sed -i "/^options\s*{/,/^};/ {
                        /^};/ i\\
\\talso-notify { $SECONDARY_IP; };
                    }" "$NAMED_OPTIONS"
                    echo "[+] Added also-notify"
                fi
            fi

            # Reload named
            if confirm "Reload named to apply changes?"; then
                rndc reload 2>/dev/null || systemctl reload named 2>/dev/null || service named reload 2>/dev/null
                echo "[+] named reloaded"
            fi
        else
            echo "[!] Could not find named options file"
            echo "    Add manually: allow-transfer { $SECONDARY_IP; }; also-notify { $SECONDARY_IP; };"
        fi
    fi
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
