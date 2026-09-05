#!/bin/bash
# detect_v4/detect_v6 in every installer: the route names the source address,
# and an echo service is a fallback, never the verdict.
# Run: bash hosting-panels/common/tests/test_ip_detection.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# fake `ip`: prints what $ROUTE_V4 / $ROUTE_V6 say, or nothing
cat > "$TMP/bin/ip" <<'IPEOF'
#!/bin/bash
case "$1" in
  -4) [ -n "${ROUTE_V4:-}" ] && echo "1.1.1.1 via 10.0.0.1 dev eth0 src $ROUTE_V4 uid 0"; exit 0 ;;
  -6) [ -n "${ROUTE_V6:-}" ] && echo "2606:4700:4700::1111 from :: dev eth0 src $ROUTE_V6 metric 1024"; exit 0 ;;
esac
exit 1
IPEOF
# fake `curl`: records that it was asked, answers with $ECHO_V4
cat > "$TMP/bin/curl" <<'CURLEOF'
#!/bin/bash
echo asked >> "$CURL_CALLS"
[ -n "${ECHO_V4:-}" ] && echo "$ECHO_V4"
exit 0
CURLEOF
chmod +x "$TMP/bin/ip" "$TMP/bin/curl"

for panel in directadmin cpanel plesk cyberpanel; do
    src="$HERE/../../$panel/install.sh"
    fn4=$(sed -n '/^detect_v4() {/,/^}/p' "$src")
    fn6=$(sed -n '/^detect_v6() {/,/^}/p' "$src")
    [ -n "$fn4" ] && [ -n "$fn6" ] || { echo "$panel: detect functions not found"; exit 1; }
    eval "$fn4"; eval "$fn6"

    echo "== $panel"
    run4() { CURL_CALLS="$TMP/calls"; : > "$CURL_CALLS"
             PATH="$TMP/bin:$PATH" ROUTE_V4="$1" ECHO_V4="${2:-}" detect_v4; }
    run6() { PATH="$TMP/bin:$PATH" ROUTE_V6="$1" detect_v6; }

    [ "$(run4 203.0.113.7)" = "203.0.113.7" ] && ok "public v4 from the route" || fail "public v4"
    [ ! -s "$TMP/calls" ] && ok "no outside call when the route answers" || fail "called the echo service anyway"

    [ "$(run4 10.0.0.5 198.51.100.9)" = "198.51.100.9" ] && ok "NAT: falls back to the echo service" || fail "NAT fallback"
    [ "$(run4 192.168.1.10 198.51.100.9)" = "198.51.100.9" ] && ok "192.168 is private" || fail "192.168"
    [ "$(run4 172.20.0.4 198.51.100.9)" = "198.51.100.9" ] && ok "172.20 is private" || fail "172.20"
    [ "$(run4 172.32.0.4)" = "172.32.0.4" ] && ok "172.32 is public, not part of the block" || fail "172.32 treated as private"
    [ "$(run4 100.64.0.1 198.51.100.9)" = "198.51.100.9" ] && ok "CGNAT is private" || fail "CGNAT"
    [ "$(run4 169.254.1.1 198.51.100.9)" = "198.51.100.9" ] && ok "link-local v4 is not an address" || fail "169.254"
    [ "$(run4 "" 198.51.100.9)" = "198.51.100.9" ] && ok "no route: asks the outside" || fail "no route"

    [ "$(run6 2001:db8::1)" = "2001:db8::1" ] && ok "public v6 from the route" || fail "public v6"
    [ -z "$(run6 fe80::1)" ] && ok "link-local v6 refused" || fail "fe80 accepted"
    [ -z "$(run6 fd00::1)" ] && ok "unique-local v6 refused" || fail "fd00 accepted"
    [ -z "$(run6 fc00::1)" ] && ok "fc00 refused" || fail "fc00 accepted"
    [ -z "$(run6 "")" ] && ok "no v6 route: no address" || fail "invented a v6 address"
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
