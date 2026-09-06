#!/bin/bash
# The server's own hostname is not a customer zone: cPanel lists it, the API
# refuses it, and every install left a failed op behind.
# Run: bash hosting-panels/common/tests/test_hostname_filter.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

zones() { # $1 = hostname, $2 = panel zone list
    env SECONDDNS_HOSTNAME="$1" SECONDDNS_PANEL_ZONES_CMD="printf '%s\n' $2" \
        PYTHONPATH="$HERE/.." python3 -c "
from seconddns_common import panel_zones
print(' '.join(panel_zones()))
" 2>&1
}

echo "== the hostname zone is dropped"
out=$(zones "server1.seconddns.com" "a.example.com server1.seconddns.com b.example.com")
[ "$out" = "a.example.com b.example.com" ] && ok "hostname removed, order kept" || fail "got '$out'"

echo "== matching is case- and dot-insensitive"
out=$(zones "server1.seconddns.com" "SERVER1.SecondDNS.com a.example.com")
[ "$out" = "a.example.com" ] && ok "uppercase form removed" || fail "got '$out'"
out=$(zones "server1.seconddns.com" "server1.seconddns.com. a.example.com")
[ "$out" = "a.example.com" ] && ok "trailing dot removed" || fail "got '$out'"

echo "== only the exact name goes"
out=$(zones "server1.seconddns.com" "seconddns.com sub.server1.seconddns.com a.example.com")
[ "$out" = "seconddns.com sub.server1.seconddns.com a.example.com" ] \
    && ok "parent and child zones kept" || fail "got '$out'"

echo "== a bare hostname is not a zone name"
out=$(zones "localhost" "localhost a.example.com")
[ "$out" = "localhost a.example.com" ] && ok "no dot, nothing dropped" || fail "got '$out'"

echo "== an empty panel stays empty, not an error"
out=$(zones "server1.seconddns.com" "")
[ -z "$out" ] && ok "empty list survives the filter" || fail "got '$out'"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
