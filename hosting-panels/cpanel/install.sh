#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
set -e

# SecondDNS cPanel/WHM Integration Installer
# Usage:
#   ./install.sh --api-key=YOUR_API_KEY [--api-url=URL] [--master-ip=IP] [--yes]
#   curl -sL https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/cpanel/install.sh | bash -s -- --api-key=YOUR_KEY

CONFIG_FILE="/etc/seconddns.conf"
LOG_FILE="/var/log/seconddns.log"
SCRIPT_DIR="/usr/local/bin"
HOOKS_BIN="/usr/local/cpanel/bin/manage_hooks"
REPO_URL="https://raw.githubusercontent.com/seconddns/dns_integrations/main/hosting-panels/cpanel"

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

echo "=== SecondDNS cPanel/WHM Integration ==="
echo ""

# Check cPanel
if [ ! -x "$HOOKS_BIN" ]; then
    echo "[!] cPanel not found (manage_hooks not at $HOOKS_BIN)"
    exit 1
fi

CPANEL_VER=$(cat /usr/local/cpanel/version 2>/dev/null || echo "unknown")
echo "[+] cPanel detected: $CPANEL_VER"

# Install IDN utilities
echo "[*] Checking IDN utilities..."
if ! command -v idn2 &>/dev/null && ! command -v idn &>/dev/null; then
    echo "[*] Installing idn2 for IDN domain support..."
    IDN_INSTALLED=0

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
    fi

    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq idn2 2>/dev/null && IDN_INSTALLED=1
            ;;
        fedora|rhel|centos|almalinux|rocky)
            if command -v dnf &>/dev/null; then
                dnf install -y idn2 2>/dev/null && IDN_INSTALLED=1
            elif command -v yum &>/dev/null; then
                yum install -y idn2 2>/dev/null && IDN_INSTALLED=1
            fi
            ;;
        *)
            if command -v dnf &>/dev/null; then
                dnf install -y idn2 2>/dev/null && IDN_INSTALLED=1
            elif command -v yum &>/dev/null; then
                yum install -y idn2 2>/dev/null && IDN_INSTALLED=1
            fi
            ;;
    esac

    if [ "$IDN_INSTALLED" -eq 1 ] && (command -v idn2 &>/dev/null || command -v idn &>/dev/null); then
        echo "[+] IDN utilities installed successfully"
    else
        echo "[!] Warning: Could not install IDN utilities"
        echo "    Install manually: dnf install idn2  or  yum install idn2"
    fi
else
    echo "[+] IDN utilities already installed"
fi

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

touch "$LOG_FILE"
chmod 664 "$LOG_FILE"
echo "[+] Log file: $LOG_FILE"

# Install hook scripts
for script in domain_create.sh domain_delete.sh; do
    curl -sf --max-time 10 -o "$SCRIPT_DIR/seconddns-cpanel-${script}" "$REPO_URL/$script?t=$(date +%s)"
    chmod +x "$SCRIPT_DIR/seconddns-cpanel-${script}"
    echo "[+] Installed: $SCRIPT_DIR/seconddns-cpanel-${script}"
done

# Register hooks
echo ""
echo "--- Registering cPanel/WHM hooks ---"

# Remove existing SecondDNS hooks
"$HOOKS_BIN" list 2>/dev/null | grep "seconddns-cpanel" | while read -r line; do
    hook_id=$(echo "$line" | awk '{print $1}')
    [ -n "$hook_id" ] && "$HOOKS_BIN" remove "$hook_id" 2>/dev/null && echo "[=] Removed old hook: $hook_id"
done

REGISTERED=0

# WHM account create (post)
if "$HOOKS_BIN" add script "$SCRIPT_DIR/seconddns-cpanel-domain_create.sh" \
    --category Whostmgr --event Accounts::Create --stage post 2>/dev/null; then
    echo "[+] Registered: Whostmgr::Accounts::Create (post)"
    REGISTERED=$((REGISTERED+1))
else
    echo "[!] Failed: Whostmgr::Accounts::Create"
fi

# WHM account remove (pre — domain data available before account is gone)
if "$HOOKS_BIN" add script "$SCRIPT_DIR/seconddns-cpanel-domain_delete.sh" \
    --category Whostmgr --event Accounts::Remove --stage pre 2>/dev/null; then
    echo "[+] Registered: Whostmgr::Accounts::Remove (pre)"
    REGISTERED=$((REGISTERED+1))
else
    echo "[!] Failed: Whostmgr::Accounts::Remove"
fi

# cPanel addon domain create (post)
if "$HOOKS_BIN" add script "$SCRIPT_DIR/seconddns-cpanel-domain_create.sh" \
    --category Api2 --event AddonDomain::addaddon --stage post 2>/dev/null; then
    echo "[+] Registered: Api2::AddonDomain::addaddon (post)"
    REGISTERED=$((REGISTERED+1))
else
    echo "[!] Failed: Api2::AddonDomain::addaddon"
fi

# cPanel addon domain delete (post)
if "$HOOKS_BIN" add script "$SCRIPT_DIR/seconddns-cpanel-domain_delete.sh" \
    --category Api2 --event AddonDomain::deladdondomain --stage post 2>/dev/null; then
    echo "[+] Registered: Api2::AddonDomain::deladdondomain (post)"
    REGISTERED=$((REGISTERED+1))
else
    echo "[!] Failed: Api2::AddonDomain::deladdondomain"
fi

echo "[+] Registered $REGISTERED hooks"

# DNS backend detection
echo ""
echo "--- DNS server detection ---"

DNS_BACKEND=""
for _cfg in /var/cpanel/cpanel.config /usr/local/cpanel/etc/cpanel.config; do
    if [ -f "$_cfg" ]; then
        _ns=$(grep "^nameservertype" "$_cfg" 2>/dev/null | sed 's/nameservertype=//' | tr -d ' ')
        [ -n "$_ns" ] && DNS_BACKEND="$_ns" && break
    fi
done

if [ -z "$DNS_BACKEND" ]; then
    if pgrep -x pdns_server &>/dev/null 2>&1 || systemctl is-active pdns &>/dev/null 2>&1; then
        DNS_BACKEND="powerdns"
    else
        DNS_BACKEND="bind"
    fi
fi

case "$DNS_BACKEND" in
    *powerdns*|*pdns*) DNS_BACKEND="powerdns" ;;
    *) DNS_BACKEND="bind" ;;
esac

echo "[+] Detected DNS server: $DNS_BACKEND"

if [ "$AUTO_YES" -ne 1 ] && [ -e /dev/tty ]; then
    _ALT="$([ "$DNS_BACKEND" = "bind" ] && echo "p=PowerDNS" || echo "b=BIND")"
    read -p "    Configure AXFR for ${DNS_BACKEND}? [Y/n/${_ALT}/s=skip] " -n 1 -r _DNS_CHOICE < /dev/tty
    echo
    case "$_DNS_CHOICE" in
        b|B) DNS_BACKEND="bind" ;;
        p|P) DNS_BACKEND="powerdns" ;;
        n|N|s|S) DNS_BACKEND="" ;;
    esac
fi

# AXFR configuration
echo ""
echo "--- AXFR configuration ---"

if [ -z "$DNS_IPS" ]; then
    echo "[!] No secondary DNS IP — configure AXFR manually"
elif [ -z "$DNS_BACKEND" ]; then
    echo "[!] AXFR configuration skipped"
else
    SECONDARY_IP="${DNS_IPS%%,*}"
    echo "[+] Secondary DNS IP: $SECONDARY_IP"

    if [ "$DNS_BACKEND" = "powerdns" ]; then
        # --- PowerDNS ---
        PDNS_CONF="/etc/pdns/pdns.conf"
        if [ ! -f "$PDNS_CONF" ]; then
            echo "[!] pdns.conf not found at $PDNS_CONF — configure AXFR manually"
        else
            cp "$PDNS_CONF" "${PDNS_CONF}.bak.$(date +%s)"

            # primary / master mode (name differs by pdns version)
            if grep -q "^master=" "$PDNS_CONF" 2>/dev/null; then
                sed -i "s|^master=.*|master=yes|" "$PDNS_CONF"
                echo "[+] PowerDNS: master=yes"
            elif grep -q "^primary=" "$PDNS_CONF" 2>/dev/null; then
                sed -i "s|^primary=.*|primary=yes|" "$PDNS_CONF"
                echo "[+] PowerDNS: primary=yes"
            else
                echo "primary=yes" >> "$PDNS_CONF"
                echo "[+] PowerDNS: primary=yes (added)"
            fi

            # disable-axfr=no
            if grep -q "^disable-axfr=" "$PDNS_CONF" 2>/dev/null; then
                sed -i "s|^disable-axfr=.*|disable-axfr=no|" "$PDNS_CONF"
            else
                echo "disable-axfr=no" >> "$PDNS_CONF"
            fi
            echo "[+] PowerDNS: disable-axfr=no"

            # allow-axfr-ips
            if grep -q "^allow-axfr-ips=" "$PDNS_CONF" 2>/dev/null; then
                _cur=$(grep "^allow-axfr-ips=" "$PDNS_CONF" | sed 's/allow-axfr-ips=//')
                if echo "$_cur" | grep -qF "$SECONDARY_IP"; then
                    echo "[=] allow-axfr-ips already includes $SECONDARY_IP"
                else
                    sed -i "s|^allow-axfr-ips=.*|allow-axfr-ips=${_cur},${SECONDARY_IP}|" "$PDNS_CONF"
                    echo "[+] PowerDNS: allow-axfr-ips updated"
                fi
            else
                echo "allow-axfr-ips=$SECONDARY_IP" >> "$PDNS_CONF"
                echo "[+] PowerDNS: allow-axfr-ips=$SECONDARY_IP"
            fi

            # also-notify
            if grep -q "^also-notify=" "$PDNS_CONF" 2>/dev/null; then
                _cur=$(grep "^also-notify=" "$PDNS_CONF" | sed 's/also-notify=//')
                if echo "$_cur" | grep -qF "$SECONDARY_IP"; then
                    echo "[=] also-notify already includes $SECONDARY_IP"
                else
                    sed -i "s|^also-notify=.*|also-notify=${_cur},${SECONDARY_IP}|" "$PDNS_CONF"
                    echo "[+] PowerDNS: also-notify updated"
                fi
            else
                echo "also-notify=$SECONDARY_IP" >> "$PDNS_CONF"
                echo "[+] PowerDNS: also-notify=$SECONDARY_IP"
            fi

            # Reload
            if systemctl reload pdns &>/dev/null 2>&1; then
                echo "[+] PowerDNS reloaded"
            elif pdns_control reload &>/dev/null 2>&1; then
                echo "[+] PowerDNS reloaded via pdns_control"
            else
                echo "[!] Restart PowerDNS manually: systemctl restart pdns"
            fi
        fi

    else
        # --- BIND ---
        NAMED_CONF=""
        for f in /etc/named.conf /etc/bind/named.conf; do
            [ -f "$f" ] && NAMED_CONF="$f" && break
        done

        if [ -n "$NAMED_CONF" ]; then
            echo "[=] Detected BIND config: $NAMED_CONF"

            NEEDS_FIX=0
            grep -q "allow-transfer.*$SECONDARY_IP" "$NAMED_CONF" 2>/dev/null || NEEDS_FIX=1
            grep -q "also-notify.*$SECONDARY_IP" "$NAMED_CONF" 2>/dev/null || NEEDS_FIX=1

            if [ "$NEEDS_FIX" -eq 1 ]; then
                if confirm "Add allow-transfer and also-notify for $SECONDARY_IP to $NAMED_CONF?"; then
                    cp "$NAMED_CONF" "${NAMED_CONF}.bak.$(date +%s)"

                    if grep -q "allow-transfer" "$NAMED_CONF"; then
                        sed -i '/allow-transfer/s/none;//g' "$NAMED_CONF"
                        if ! grep -q "allow-transfer.*$SECONDARY_IP" "$NAMED_CONF"; then
                            sed -i "s|allow-transfer\s*{|allow-transfer { $SECONDARY_IP; |" "$NAMED_CONF"
                        fi
                    else
                        sed -i "/^[[:space:]]*};/i\\
\\tallow-transfer { $SECONDARY_IP; };" "$NAMED_CONF"
                    fi

                    if grep -q "also-notify" "$NAMED_CONF"; then
                        sed -i '/also-notify/s/none;//g' "$NAMED_CONF"
                        if ! grep -q "also-notify.*$SECONDARY_IP" "$NAMED_CONF"; then
                            sed -i "s|also-notify\s*{|also-notify { $SECONDARY_IP; |" "$NAMED_CONF"
                        fi
                    else
                        sed -i "/^[[:space:]]*};/i\\
\\talso-notify { $SECONDARY_IP; };" "$NAMED_CONF"
                    fi

                    rndc reload 2>/dev/null || systemctl reload named 2>/dev/null || true
                    echo "[+] BIND configured and reloaded"
                fi
            else
                echo "[+] BIND AXFR config already includes $SECONDARY_IP"
            fi
        fi

        echo ""
        echo -e "\033[1;33m[!] IMPORTANT: cPanel may overwrite direct named.conf changes.\033[0m"
        echo -e "\033[1;33m    To make AXFR settings permanent, add them in WHM:\033[0m"
        echo ""
        echo -e "    \033[1mWHM > Service Configuration > DNS Server (BIND)\033[0m"
        echo -e "    \033[1m> Additional zone configuration:\033[0m"
        echo ""
        echo -e "      \033[1;32mallow-transfer { $SECONDARY_IP; };\033[0m"
        echo -e "      \033[1;32malso-notify { $SECONDARY_IP; };\033[0m"
        echo ""
        echo -e "    \033[1;33mThen click Save.\033[0m"
    fi
fi

# Zone template — add secondary NS record
ZONE_TEMPLATE_DIR="/var/cpanel/zonetemplates"
if [ -n "$API_NS" ]; then
    echo ""
    echo "--- Zone template NS configuration ---"

    # Ensure trailing dot (FQDN in zone files)
    NS_FQDN="${API_NS%%.}."

    if [ -d "$ZONE_TEMPLATE_DIR" ]; then
        TMPL_UPDATED=0
        for tmpl in "$ZONE_TEMPLATE_DIR"/*; do
            [ -f "$tmpl" ] || continue
            if grep -qF "$API_NS" "$tmpl" 2>/dev/null; then
                echo "[=] NS already present: $(basename "$tmpl")"
            else
                printf '\n%%nsttl%%\tIN\tNS\t%s\n' "$NS_FQDN" >> "$tmpl"
                echo "[+] Added NS to template: $(basename "$tmpl")"
                TMPL_UPDATED=$((TMPL_UPDATED+1))
            fi
        done
        if [ "$TMPL_UPDATED" -gt 0 ]; then
            echo "[+] Zone templates updated — new zones will include $NS_FQDN as NS"
            echo "    Note: existing zones are not affected; resync them via the SecondDNS dashboard."
        fi
    else
        echo "[!] $ZONE_TEMPLATE_DIR not found — add NS record manually in:"
        echo "    WHM > DNS Functions > Edit Zone Templates"
        echo "    Line to add: %nsttl%  IN  NS  ${NS_FQDN}"
    fi
fi

# Initial sync
echo ""
if confirm "Sync existing cPanel accounts to secondary DNS now?"; then
    echo "[*] Syncing accounts..."
    added=0
    failed=0

    if [ -d /var/cpanel/users ]; then
        for user_file in /var/cpanel/users/*; do
            [ -f "$user_file" ] || continue
            sdomain=$(grep "^DNS=" "$user_file" 2>/dev/null | cut -d= -f2)
            [ -z "$sdomain" ] && continue

            if command -v idn2 &>/dev/null; then
                sdomain=$(idn2 --quiet "$sdomain" 2>/dev/null || echo "$sdomain")
            fi

            response=$(curl -sf --max-time 15 \
                -X POST \
                -H "X-API-Key: $API_KEY" \
                -H "Content-Type: application/json" \
                -H "User-Agent: SecondDNS-cPanel/1.0" \
                -d "{\"name\":\"$sdomain\",\"masterIp\":\"$MASTER_IP\"}" \
                "$API_URL/api/zones" 2>/dev/null)
            if [ $? -eq 0 ]; then
                echo "    [+] $sdomain"
                added=$((added+1))
            else
                failed=$((failed+1))
            fi
        done
    else
        echo "[!] /var/cpanel/users not found — skipping sync"
    fi

    echo "[+] Synced: $added domains, failed: $failed"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Config:   $CONFIG_FILE"
echo "  Scripts:  $SCRIPT_DIR/seconddns-cpanel-domain_create.sh"
echo "            $SCRIPT_DIR/seconddns-cpanel-domain_delete.sh"
echo "  Logs:     tail -f $LOG_FILE"
echo ""
echo "  cPanel accounts created/deleted in WHM will be"
echo "  automatically synced to your secondary DNS."
echo ""
echo "  Verify hooks:  $HOOKS_BIN list"
if [ -n "$DNS_IPS" ] && [ "$DNS_BACKEND" = "bind" ]; then
    SECONDARY_IP="${DNS_IPS%%,*}"
    echo ""
    echo -e "\033[1;33m[!] Don't forget to make AXFR permanent in WHM:\033[0m"
    echo -e "    WHM > Service Configuration > DNS Server (BIND)"
    echo -e "    > Additional zone configuration:"
    echo -e "      allow-transfer { $SECONDARY_IP; };"
    echo -e "      also-notify { $SECONDARY_IP; };"
fi
