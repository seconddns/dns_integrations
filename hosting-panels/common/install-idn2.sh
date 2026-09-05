#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# idn2 (IDNA2008) is required by seconddns-domain for non-ASCII zone names.
if ! command -v idn2 &>/dev/null; then
    echo "[*] Installing idn2..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null; apt-get install -y -qq idn2 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y idn2 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y idn2 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache libidn2-tools 2>/dev/null
    fi
    command -v idn2 &>/dev/null && echo "[+] idn2 installed" \
        || echo "[!] Warning: idn2 missing — non-ASCII zone names will be refused until installed"
fi
