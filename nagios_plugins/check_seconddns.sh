#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# Nagios/Icinga check plugin for SecondDNS zone health.
#
# Queries the SecondDNS health API and returns Nagios-compatible output.
#
# Usage:
#   check_seconddns.sh -k <API_KEY> [-u <URL>] [-t <TIMEOUT>] [-z <ZONE>]
#
# Options:
#   -k KEY       X-API-Key (required, or set SECONDDNS_API_KEY env)
#   -u URL       API base URL (default: https://seconddns.com)
#   -t SECONDS   Connection + response timeout (default: 30)
#   -z ZONE      Check a single zone by name (default: all zones)
#   -h           Show this help
#
# Environment variables (used as fallbacks when flags are not set):
#   SECONDDNS_API_KEY   X-API-Key
#   SECONDDNS_API_URL   Base URL
#
# Exit codes:
#   0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN

set -euo pipefail

API_URL="${SECONDDNS_API_URL:-https://seconddns.com}"
API_KEY="${SECONDDNS_API_KEY:-}"
TIMEOUT=30
ZONE=""

usage() {
  sed -n '2,/^$/s/^# \?//p' "$0"
  exit 3
}

while getopts "k:u:t:z:h" opt; do
  case $opt in
    k) API_KEY="$OPTARG" ;;
    u) API_URL="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    z) ZONE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$API_KEY" ]; then
  echo "UNKNOWN - API key not set"
  echo ""
  usage
fi

if [ -n "$ZONE" ]; then
  ENDPOINT="${API_URL}/api/health/zones/${ZONE}?format=nagios"
else
  ENDPOINT="${API_URL}/api/health/zones?format=nagios"
fi

RESULT=$(curl -sf --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
  -H "X-API-Key: ${API_KEY}" \
  "$ENDPOINT" 2>/dev/null) || {
  echo "UNKNOWN - API unreachable or returned error (${API_URL})"
  exit 3
}

echo "$RESULT"

if echo "$RESULT" | grep -q "^CRITICAL"; then
  exit 2
elif echo "$RESULT" | grep -q "^WARNING"; then
  exit 1
elif echo "$RESULT" | grep -q "^OK"; then
  exit 0
else
  exit 3
fi
