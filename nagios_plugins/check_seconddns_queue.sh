#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# Nagios/Icinga check for the SecondDNS offline operation queue.
#
# Runs on the panel server where the SecondDNS integration is installed and
# inspects the local queue (/var/lib/seconddns/queue.db). A growing or stale
# queue means zone operations are not reaching the SecondDNS API.
#
# Usage:
#   check_seconddns_queue.sh [-w <warn_age_min>] [-c <crit_age_min>]
#
# Options:
#   -w MINUTES   WARNING when the oldest pending op is older (default: 10)
#   -c MINUTES   CRITICAL when the oldest pending op is older (default: 30)
#   -h           Show this help
#
# failed ops > 0 always raises at least WARNING.
#
# Exit codes: 0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN

set -euo pipefail

QUEUE_BIN="${SECONDDNS_QUEUE_BIN:-/usr/local/bin/seconddns-queue}"
WARN_MIN=10
CRIT_MIN=30

usage() {
  sed -n '2,/^$/s/^# \?//p' "$0"
  exit 3
}

while getopts "w:c:h" opt; do
  case $opt in
    w) WARN_MIN="$OPTARG" ;;
    c) CRIT_MIN="$OPTARG" ;;
    h|*) usage ;;
  esac
done

if [ ! -x "$QUEUE_BIN" ]; then
  echo "UNKNOWN - $QUEUE_BIN not installed"
  exit 3
fi

json=$("$QUEUE_BIN" status --json 2>/dev/null) || true
if [ -z "$json" ]; then
  echo "UNKNOWN - queue status unavailable"
  exit 3
fi

read -r pending failed oldest <<< "$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['pending'], d['failed'], d['oldest_age_seconds'])")"
last_error=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_error',''))")

perfdata="pending=$pending failed=$failed oldest_age=${oldest}s;$((WARN_MIN*60));$((CRIT_MIN*60))"
# same thresholds and exit codes; the text tells "service down" from "key revoked"
note=""
case "$last_error" in
  *"auth rejected"*) note=" - auth rejected, retrying" ;;
  ?*) note=" - $last_error" ;;
esac

if [ "$oldest" -ge $((CRIT_MIN*60)) ]; then
  echo "CRITICAL - oldest queued op is $((oldest/60)) min old ($pending pending, $failed failed)$note | $perfdata"
  exit 2
fi
if [ "$oldest" -ge $((WARN_MIN*60)) ] || [ "$failed" -gt 0 ]; then
  echo "WARNING - $pending pending (oldest $((oldest/60)) min), $failed failed$note | $perfdata"
  exit 1
fi
if [ "$pending" -gt 0 ]; then
  echo "OK - $pending op(s) queued, draining$note | $perfdata"
else
  echo "OK - queue empty | $perfdata"
fi
exit 0
