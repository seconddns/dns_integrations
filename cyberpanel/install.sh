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
