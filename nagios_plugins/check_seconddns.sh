#!/bin/bash
# Nagios/Icinga check plugin for SecondDNS zone health.
#
# Queries the SecondDNS health API and returns Nagios-compatible output.
# Checks ALL zones by default; pass a zone name to check a single zone.
#
# Usage:
#   check_seconddns.sh                          # all zones
#   check_seconddns.sh example.com              # single zone
#
# Environment variables (or edit the defaults below):
#   SECONDDNS_API_URL   Base URL      (default: https://seconddns.com)
#   SECONDDNS_API_KEY   X-API-Key     (required)
#
# Exit codes:
#   0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN

set -euo pipefail

API_URL="${SECONDDNS_API_URL:-https://seconddns.com}"
API_KEY="${SECONDDNS_API_KEY:-}"

if [ -z "$API_KEY" ]; then
  echo "UNKNOWN - SECONDDNS_API_KEY not set"
  exit 3
fi

ZONE="${1:-}"

if [ -n "$ZONE" ]; then
  ENDPOINT="${API_URL}/api/health/zones/${ZONE}?format=nagios"
else
  ENDPOINT="${API_URL}/api/health/zones?format=nagios"
fi

RESULT=$(curl -sf --max-time 30 \
  -H "X-API-Key: ${API_KEY}" \
  "$ENDPOINT" 2>/dev/null) || {
  echo "UNKNOWN - API unreachable or returned error"
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
