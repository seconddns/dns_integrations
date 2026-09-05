#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# sqlite3 holds the offline queue: without it, work done while the API is
# unreachable is lost rather than replayed. RHEL calls the package sqlite.
if ! command -v sqlite3 &>/dev/null; then
    echo "[*] Installing sqlite3..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null; apt-get install -y -qq sqlite3 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y sqlite 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y sqlite 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache sqlite 2>/dev/null
    fi
    command -v sqlite3 &>/dev/null && echo "[+] sqlite3 installed" \
        || echo "[!] Warning: sqlite3 missing — the offline queue cannot run, so work done while the API is unreachable will be lost"
fi
