#!/bin/bash
set -e

# SecondDNS Plesk Integration Installer
# Usage:
#   ./install.sh --api-key=YOUR_API_KEY [--api-url=URL] [--master-ip=IP] [--yes]
#   curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/plesk/install.sh | bash -s -- --api-key=YOUR_KEY

CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"
SCRIPT_DIR="/usr/local/bin"
REPO_URL="https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/hosting-panels/plesk"

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

echo "=== SecondDNS Plesk Integration ==="
echo ""

# Check Plesk
if ! command -v plesk &>/dev/null; then
    echo "[!] Plesk not found"
    exit 1
fi

PLESK_VER=$(plesk version 2>/dev/null | head -1 || echo "unknown")
echo "[+] Plesk detected: $PLESK_VER"

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

# Get secondary DNS info from API
API_SERVER_INFO=$(curl -sf --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "User-Agent: SecondDNS-Installer/1.0" \
    "$API_URL/api/server-info" 2>/dev/null || echo "{}")

API_DNS_IPS=$(echo "$API_SERVER_INFO" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('dnsIps',''))" 2>/dev/null || echo "")

API_NS=$(echo "$API_SERVER_INFO" | \
    python3 -c "import sys,json; ns=json.load(sys.stdin).get('nameservers',[]); print(ns[0] if ns else '')" 2>/dev/null || echo "")

API_HAS_V4=$(echo "$API_DNS_IPS" | tr ',' '\n' | tr -d ' ' | grep -v ':' | grep -v '^$' | head -1)
API_HAS_V6=$(echo "$API_DNS_IPS" | tr ',' '\n' | tr -d ' ' | grep ':' | head -1)

# Determine available protocols
CAN_V4="" ; [ -n "$SERVER_V4" ] && [ -n "$API_HAS_V4" ] && CAN_V4=1
CAN_V6="" ; [ -n "$SERVER_V6" ] && [ -n "$API_HAS_V6" ] && CAN_V6=1

IP_PREFERENCE=""
if [ -n "$CAN_V4" ] && [ -n "$CAN_V6" ]; then
    echo "[+] Both protocols available:"
    echo "    1) IPv4: server $SERVER_V4 <-> secondary $API_HAS_V4"
    echo "    2) IPv6: server $SERVER_V6 <-> secondary $API_HAS_V6"
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

# Install event handler scripts
for script in domain_create.sh domain_delete.sh; do
    curl -sf --max-time 10 -o "$SCRIPT_DIR/seconddns-plesk-${script}" "$REPO_URL/$script?t=$(date +%s)"
    chmod +x "$SCRIPT_DIR/seconddns-plesk-${script}"
    echo "[+] Installed: $SCRIPT_DIR/seconddns-plesk-${script}"
done

# --- Register Plesk event handlers ---
echo ""
echo "--- Registering Plesk event handlers ---"

# Plesk has two domain types:
#   domain_create/domain_delete — default domain (first domain in a subscription)
#   site_create/site_delete     — additional domains
# Both pass NEW_DOMAIN_NAME / OLD_DOMAIN_NAME env vars.

# Remove any existing SecondDNS handlers (re-install safe)
# --list output has Id and Command on separate lines, so we track the current Id
# and delete when the Command line matches our scripts
CURRENT_ID=""
while IFS= read -r line; do
    case "$line" in
        *"Id "*)
            CURRENT_ID=$(echo "$line" | awk '{print $NF}')
            ;;
        *"seconddns-plesk"*)
            if [ -n "$CURRENT_ID" ]; then
                plesk bin event_handler --delete "$CURRENT_ID" 2>/dev/null || true
                CURRENT_ID=""
            fi
            ;;
    esac
done < <(plesk bin event_handler --list 2>/dev/null)

REGISTERED=0

# Creation events: domain_create (default domain) + site_create (additional domains)
for ev in domain_create site_create; do
    plesk bin event_handler --create \
        -command "$SCRIPT_DIR/seconddns-plesk-domain_create.sh" \
        -priority 10 \
        -user root \
        -event "$ev" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "[+] Registered handler: $ev"
        REGISTERED=$((REGISTERED+1))
    else
        echo "[!] Failed to register handler for $ev"
    fi
done

# Deletion events: domain_delete (default domain) + site_delete (additional domains)
for ev in domain_delete site_delete; do
    plesk bin event_handler --create \
        -command "$SCRIPT_DIR/seconddns-plesk-domain_delete.sh" \
        -priority 10 \
        -user root \
        -event "$ev" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "[+] Registered handler: $ev"
        REGISTERED=$((REGISTERED+1))
    else
        echo "[!] Failed to register handler for $ev"
    fi
done

echo "[+] Registered $REGISTERED event handlers"

# --- DNS template: replace default ns2 with secondary ---
echo ""
echo "--- DNS template configuration ---"

if [ -z "$API_NS" ]; then
    echo "[!] Could not get nameserver from API — skipping DNS template"
else
    # Plesk stores NS values with trailing dot (e.g. ns2.seconddns.com.)
    NS2_COUNT=$(plesk db "SELECT COUNT(*) AS cnt FROM dns_recs_t WHERE type='NS' AND val LIKE '%${API_NS}%'" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    DEFAULT_NS2_COUNT=$(plesk db "SELECT COUNT(*) AS cnt FROM dns_recs_t WHERE type='NS' AND val='ns2.<domain>.'" 2>/dev/null | grep -oE '[0-9]+' | tail -1)

    echo "[*] Current NS records in DNS template:"
    plesk db "SELECT val FROM dns_recs_t WHERE type='NS'" 2>/dev/null | grep -oE '[a-zA-Z0-9.<>-]+\.' | sed 's/^/    /' || true

    if [ "${NS2_COUNT:-0}" -gt 0 ]; then
        echo "[+] $API_NS already in DNS template"
        # Still check if default ns2.<domain>. should be removed
        if [ "${DEFAULT_NS2_COUNT:-0}" -gt 0 ]; then
            echo "[*] Default ns2.<domain>. is redundant — points to the same server."
            if confirm "Remove ns2.<domain>. from DNS template?"; then
                plesk db "DELETE FROM dns_recs_t WHERE type='NS' AND val='ns2.<domain>.'" 2>/dev/null
                echo "[+] Removed ns2.<domain>. from template"
            fi
        fi
    else
        echo ""
        if [ "${DEFAULT_NS2_COUNT:-0}" -gt 0 ]; then
            echo "[*] Default ns2.<domain>. points to the same server — not a real secondary."
            if confirm "Replace ns2.<domain>. with $API_NS in DNS template?"; then
                plesk db "DELETE FROM dns_recs_t WHERE type='NS' AND val='ns2.<domain>.'" 2>/dev/null
                echo "[+] Removed ns2.<domain>. from template"
                plesk bin server_dns -a -ns "" -nameserver "$API_NS" 2>/dev/null
                echo "[+] Added $API_NS to DNS template"
            fi
        else
            if confirm "Add $API_NS as NS2 to the default DNS template?"; then
                plesk bin server_dns -a -ns "" -nameserver "$API_NS" 2>/dev/null
                echo "[+] Added $API_NS to DNS template"
            fi
        fi
    fi
fi

# --- AXFR configuration ---
echo ""
echo "--- AXFR configuration ---"

if [ -z "$DNS_IPS" ]; then
    echo "[!] No secondary DNS IP — configure AXFR manually"
else
    SECONDARY_IP="${DNS_IPS%%,*}"
    echo "[+] Secondary DNS IP: $SECONDARY_IP"

    # Find BIND config
    NAMED_OPTIONS=""
    for f in /etc/bind/named.conf.options /etc/named.conf.options /etc/named.conf; do
        [ -f "$f" ] && NAMED_OPTIONS="$f" && break
    done

    if [ -n "$NAMED_OPTIONS" ]; then
        echo "[=] Detected BIND config: $NAMED_OPTIONS"

        NEEDS_FIX=0
        if ! grep -q "allow-transfer.*$SECONDARY_IP" "$NAMED_OPTIONS" 2>/dev/null; then
            NEEDS_FIX=1
        fi
        if ! grep -q "also-notify.*$SECONDARY_IP" "$NAMED_OPTIONS" 2>/dev/null; then
            NEEDS_FIX=1
        fi

        if [ "$NEEDS_FIX" -eq 1 ]; then
            if confirm "Add allow-transfer and also-notify to $NAMED_OPTIONS?"; then
                cp "$NAMED_OPTIONS" "${NAMED_OPTIONS}.bak.$(date +%s)"

                # allow-transfer
                if grep -q "allow-transfer" "$NAMED_OPTIONS"; then
                    # Remove none; from allow-transfer line only
                    sed -i '/allow-transfer/s/none;//g' "$NAMED_OPTIONS"
                    # Add our IP if not already there
                    if ! grep -q "allow-transfer.*$SECONDARY_IP" "$NAMED_OPTIONS"; then
                        sed -i "s|allow-transfer\s*{|allow-transfer { $SECONDARY_IP; |" "$NAMED_OPTIONS"
                    fi
                else
                    sed -i "/^[[:space:]]*};/i\\
\\tallow-transfer { $SECONDARY_IP; };" "$NAMED_OPTIONS"
                fi

                # also-notify
                if grep -q "also-notify" "$NAMED_OPTIONS"; then
                    sed -i '/also-notify/s/none;//g' "$NAMED_OPTIONS"
                    if ! grep -q "also-notify.*$SECONDARY_IP" "$NAMED_OPTIONS"; then
                        sed -i "s|also-notify\s*{|also-notify { $SECONDARY_IP; |" "$NAMED_OPTIONS"
                    fi
                else
                    sed -i "/^[[:space:]]*};/i\\
\\talso-notify { $SECONDARY_IP; };" "$NAMED_OPTIONS"
                fi

                rndc reload 2>/dev/null || systemctl reload named 2>/dev/null || true
                echo "[+] BIND configured and reloaded"
            fi
        else
            echo "[+] BIND AXFR config already includes $SECONDARY_IP"
        fi
    fi

    echo ""
    echo -e "\033[1;33m[!] IMPORTANT: Plesk may overwrite direct config changes.\033[0m"
    echo -e "\033[1;33m    To make AXFR settings permanent, also add them in:\033[0m"
    echo ""
    echo -e "    \033[1mTools & Settings > DNS Settings > Server-wide Settings\033[0m"
    echo -e "    \033[1m> Additional DNS settings:\033[0m"
    echo ""
    echo -e "      \033[1;32mallow-transfer { $SECONDARY_IP; };\033[0m"
    echo -e "      \033[1;32malso-notify { $SECONDARY_IP; };\033[0m"
    echo ""
    echo -e "    \033[1;33mThen click Apply.\033[0m"
fi

# Initial sync
echo ""
if confirm "Sync existing domains to secondary DNS now?"; then
    echo "[*] Syncing domains..."
    added=0
    while IFS= read -r sdomain; do
        [ -z "$sdomain" ] && continue
        response=$(curl -sf --max-time 15 \
            -X POST \
            -H "X-API-Key: $API_KEY" \
            -H "Content-Type: application/json" \
            -H "User-Agent: SecondDNS-Plesk/1.0" \
            -d "{\"name\":\"$sdomain\",\"masterIp\":\"$MASTER_IP\"}" \
            "$API_URL/api/zones" 2>/dev/null)
        if [ $? -eq 0 ]; then
            echo "    [+] $sdomain"
            added=$((added+1))
        fi
    done < <(plesk bin site --list 2>/dev/null)
    echo "[+] Synced $added domains"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Config:   $CONFIG_FILE"
echo "  Scripts:  $SCRIPT_DIR/seconddns-plesk-domain_create.sh"
echo "            $SCRIPT_DIR/seconddns-plesk-domain_delete.sh"
echo "  Logs:     tail -f $LOG_FILE"
echo ""
echo "  Domains created/deleted in Plesk will be"
echo "  automatically synced to your secondary DNS."
echo ""
echo "  Verify handlers:  plesk bin event_handler --list"
if [ -n "$DNS_IPS" ]; then
    SECONDARY_IP="${DNS_IPS%%,*}"
    echo ""
    echo -e "\033[1;33m[!] Don't forget to configure AXFR in Plesk UI:\033[0m"
    echo -e "    \033[1mTools & Settings > DNS Settings > Server-wide Settings\033[0m"
    echo -e "    Add to 'Additional DNS settings':"
    echo -e "      \033[1;32mallow-transfer { $SECONDARY_IP; };\033[0m"
    echo -e "      \033[1;32malso-notify { $SECONDARY_IP; };\033[0m"
fi
