#!/bin/bash
set -e

INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/seconddns.conf"
CYBERPANEL_DIR="/usr/local/CyberCP"
PLUGIN_FILE="$CYBERPANEL_DIR/plogical/seconddns_plugin.py"
READY_FILE="$CYBERPANEL_DIR/CyberCP/ready.py"

echo "=== SecondDNS CyberPanel Integration ==="
echo ""

# Copy CLI script
cp seconddns.py "$INSTALL_DIR/seconddns"
chmod +x "$INSTALL_DIR/seconddns"
echo "[+] Installed CLI to $INSTALL_DIR/seconddns"

# Config
if [ ! -f "$CONFIG_FILE" ]; then
    cp seconddns.conf.example "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "[+] Created config at $CONFIG_FILE"
    echo "    Edit it and set your api_url and api_key"
else
    echo "[=] Config already exists at $CONFIG_FILE"
fi

# Log dir
mkdir -p /var/lib/seconddns
touch /var/log/seconddns.log
echo "[+] Created log file /var/log/seconddns.log"

# Install Django signal plugin into CyberPanel
if [ -d "$CYBERPANEL_DIR" ]; then
    cp seconddns.py "$PLUGIN_FILE"
    echo "[+] Installed plugin to $PLUGIN_FILE"

    # Register signals — wsgi.py is the actual entry point for lswsgi workers
    WSGI_FILE="$CYBERPANEL_DIR/CyberCP/wsgi.py"
    INIT_FILE="$CYBERPANEL_DIR/CyberCP/__init__.py"
    SIGNAL_TARGET=""
    if [ -f "$WSGI_FILE" ]; then
        SIGNAL_TARGET="$WSGI_FILE"
    elif [ -f "$READY_FILE" ]; then
        SIGNAL_TARGET="$READY_FILE"
    elif [ -f "$INIT_FILE" ]; then
        SIGNAL_TARGET="$INIT_FILE"
    fi

    if [ -n "$SIGNAL_TARGET" ]; then
        if ! grep -q "seconddns_plugin" "$SIGNAL_TARGET"; then
            cat >> "$SIGNAL_TARGET" << 'HOOK'

# SecondDNS integration — register domain create/delete signals
try:
    from plogical.seconddns_plugin import register_signals, setup_logging
    setup_logging()
    register_signals()
except Exception as e:
    import logging
    logging.getLogger("seconddns").error("Failed to register signals: %s", e)
HOOK
            echo "[+] Registered signals in $SIGNAL_TARGET"
        else
            echo "[=] Signals already registered in $SIGNAL_TARGET"
        fi
    else
        echo "[!] Neither $READY_FILE nor $INIT_FILE found"
        echo "    Register signals manually in CyberPanel startup:"
        echo "      from plogical.seconddns_plugin import register_signals, setup_logging"
        echo "      setup_logging(); register_signals()"
    fi

    # Restart CyberPanel to load signals
    echo ""
    read -p "Restart CyberPanel (lscpd) to activate? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl restart lscpd
        echo "[+] CyberPanel restarted"
    fi
else
    echo "[!] CyberPanel not found at $CYBERPANEL_DIR"
    echo "    Plugin signals not installed — use CLI commands instead"
fi

# Check PowerDNS AXFR configuration
echo ""
echo "--- PowerDNS AXFR check ---"
PDNS_CONF=""
for f in /etc/pdns/pdns.conf /etc/powerdns/pdns.conf /etc/pdns.conf; do
    [ -f "$f" ] && PDNS_CONF="$f" && break
done

if [ -n "$PDNS_CONF" ]; then
    echo "[=] Found $PDNS_CONF"
    ISSUES=0

    # Resolve secondary DNS server IPs: API -> config -> env -> prompt
    DNS_IPS=""
    if [ -f "$CONFIG_FILE" ]; then
        API_URL=$(grep -E "^api_url\s*=" "$CONFIG_FILE" 2>/dev/null | sed 's/^api_url\s*=\s*//' | tr -d ' ')
        API_KEY=$(grep -E "^api_key\s*=" "$CONFIG_FILE" 2>/dev/null | sed 's/^api_key\s*=\s*//' | tr -d ' ')
        # Try fetching DNS IPs from the service API
        if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
            API_DNS_IPS=$(curl -sf --max-time 10 \
                -H "X-API-Key: $API_KEY" \
                -H "User-Agent: SecondDNS-Installer/1.0" \
                "$API_URL/api/server-info" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('dnsIps',''))" 2>/dev/null)
            if [ -n "$API_DNS_IPS" ]; then
                DNS_IPS="$API_DNS_IPS"
                echo "[+] Got DNS server IPs from API: $DNS_IPS"
            fi
        fi
        # Fallback to config file
        if [ -z "$DNS_IPS" ]; then
            DNS_IPS=$(grep -E "^dns_ips\s*=" "$CONFIG_FILE" 2>/dev/null | sed 's/^dns_ips\s*=\s*//' | tr -d ' ')
        fi
    fi
    DNS_IPS="${SECONDDNS_IPS:-$DNS_IPS}"
    if [ -z "$DNS_IPS" ]; then
        echo "[?] Could not determine secondary DNS server IPs automatically."
        read -p "    Enter secondary DNS IPs (comma-separated, e.g. 1.2.3.4,2001:db8::1): " DNS_IPS
    fi
    if [ -z "$DNS_IPS" ]; then
        echo "[!] No DNS IPs provided — skipping AXFR config check"
    fi

    # Check master mode
    if grep -qE "^master=yes" "$PDNS_CONF" 2>/dev/null; then
        echo "[+] master=yes is set"
    else
        echo "[!] master is NOT enabled. AXFR transfers will not work."
        echo "    Add to $PDNS_CONF:"
        echo "      master=yes"
        ISSUES=$((ISSUES+1))
    fi

    # Check allow-axfr-ips
    if grep -qE "^allow-axfr-ips=.*$DNS_IPS" "$PDNS_CONF" 2>/dev/null; then
        echo "[+] allow-axfr-ips includes $DNS_IPS"
    else
        CURRENT_AXFR=$(grep -E "^allow-axfr-ips=" "$PDNS_CONF" 2>/dev/null | head -1)
        if [ -n "$CURRENT_AXFR" ]; then
            echo "[!] allow-axfr-ips is set but does NOT include $DNS_IPS"
            echo "    Current: $CURRENT_AXFR"
            echo "    Update to: allow-axfr-ips=127.0.0.0/8,::1,$DNS_IPS"
        else
            echo "[!] allow-axfr-ips is not set (default: localhost only)"
            echo "    Add to $PDNS_CONF:"
            echo "      allow-axfr-ips=127.0.0.0/8,::1,$DNS_IPS"
        fi
        ISSUES=$((ISSUES+1))
    fi

    # Check also-notify
    if grep -qE "^also-notify=.*$DNS_IPS" "$PDNS_CONF" 2>/dev/null; then
        echo "[+] also-notify includes $DNS_IPS"
    else
        echo "[!] also-notify does not include $DNS_IPS"
        echo "    Add to $PDNS_CONF:"
        echo "      also-notify=$DNS_IPS"
        echo "    This ensures your secondary is notified instantly on zone changes."
        ISSUES=$((ISSUES+1))
    fi

    if [ "$ISSUES" -gt 0 ]; then
        echo ""
        read -p "Apply these fixes automatically? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cp "$PDNS_CONF" "${PDNS_CONF}.bak.$(date +%s)"

            # master=yes
            if ! grep -qE "^master=yes" "$PDNS_CONF"; then
                sed -i '/^# master=no/a master=yes' "$PDNS_CONF"
                # fallback if comment not found
                grep -qE "^master=yes" "$PDNS_CONF" || echo "master=yes" >> "$PDNS_CONF"
            fi

            # allow-axfr-ips
            if grep -qE "^allow-axfr-ips=" "$PDNS_CONF"; then
                if ! grep -qE "^allow-axfr-ips=.*$DNS_IPS" "$PDNS_CONF"; then
                    sed -i "s|^allow-axfr-ips=\(.*\)|allow-axfr-ips=\1,$DNS_IPS|" "$PDNS_CONF"
                fi
            else
                echo "allow-axfr-ips=127.0.0.0/8,::1,$DNS_IPS" >> "$PDNS_CONF"
            fi

            # also-notify
            if grep -qE "^also-notify=" "$PDNS_CONF"; then
                if ! grep -qE "^also-notify=.*$DNS_IPS" "$PDNS_CONF"; then
                    sed -i "s|^also-notify=\(.*\)|also-notify=\1,$DNS_IPS|" "$PDNS_CONF"
                fi
            else
                echo "also-notify=$DNS_IPS" >> "$PDNS_CONF"
            fi

            echo "[+] PowerDNS config updated. Backup: ${PDNS_CONF}.bak.*"
            echo "[+] Restarting PowerDNS..."
            systemctl restart pdns 2>/dev/null || service pdns restart 2>/dev/null
            echo "[+] Done."
        fi
    else
        echo "[+] PowerDNS AXFR config looks good."
    fi
else
    echo "[!] pdns.conf not found — check PowerDNS AXFR config manually:"
    echo "    master=yes"
    echo "    allow-axfr-ips=127.0.0.0/8,::1,<SECONDARY_DNS_IP>"
    echo "    also-notify=<SECONDARY_DNS_IP>"
fi

echo ""
echo "=== Done ==="
echo ""
echo "How it works:"
echo "  Domains created/deleted in CyberPanel are automatically"
echo "  synced to your secondary DNS service via Django signals."
echo ""
echo "CLI commands (for manual use):"
echo "  seconddns sync      — full sync of all domains"
echo "  seconddns list      — show zones on secondary DNS"
echo "  seconddns add X     — add domain manually"
echo "  seconddns remove X  — remove domain manually"
echo ""
echo "Logs: tail -f /var/log/seconddns.log"
