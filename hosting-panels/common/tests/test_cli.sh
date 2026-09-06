#!/bin/bash
# The seconddns CLI: deleting is never implicit, and every change goes through
# the queue rather than straight to the API.
# Run: bash hosting-panels/common/tests/test_cli.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../seconddns"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

command -v idn2 >/dev/null || { echo "idn2 required"; exit 1; }

TMP="$(mktemp -d)"; PORT=$((20000 + RANDOM % 10000))
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$TMP"' EXIT

python3 - "$PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys
port, tmp = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = open(tmp + '/zones.json', 'rb').read()
        self.send_response(200); self.send_header('Content-Length', str(len(b))); self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
MOCK_PID=$!
disown $MOCK_PID 2>/dev/null || true
sleep 1

cat > "$TMP/seconddns.conf" <<CONF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10
CONF
printf '#!/bin/bash\necho "$*" >> "$CALLS"\n' > "$TMP/queue"; chmod +x "$TMP/queue"

zones() { printf '%s' "$1" > "$TMP/zones.json"; }
cli() { : > "$TMP/calls"
        env SECONDDNS_CONF="$TMP/seconddns.conf" SECONDDNS_QUEUE_BIN="$TMP/queue" \
            SECONDDNS_DOMAIN_BIN="$HERE/../seconddns-domain" \
            SECONDDNS_PANEL_ZONES_CMD="${PANEL:-true}" CALLS="$TMP/calls" \
            python3 "$CLI" "$@" > "$TMP/out" 2>&1; }

MINE='{"name":"%s","masterIp":"192.0.2.10","status":"synced"}'
zones "[$(printf "$MINE" a.example.com),$(printf "$MINE" b.example.com)]"

echo "== add and remove go through the queue"
cli add new.example.com
grep -q "enqueue create new.example.com 192.0.2.10" "$TMP/calls" && ok "add queues a create" || fail "add: $(cat "$TMP/calls")"
cli remove a.example.com
grep -q "enqueue delete a.example.com 192.0.2.10" "$TMP/calls" && ok "remove queues a delete" || fail "remove: $(cat "$TMP/calls")"
cli add ПРИКЛАД.УКР
grep -q "enqueue create xn--80aikifvh.xn--j1amh" "$TMP/calls" && ok "an IDN is queued in punycode" || fail "IDN: $(cat "$TMP/calls")"
cli add "not a domain"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$TMP/calls" ] && ok "an unusable name is refused, nothing queued" || fail "unusable name accepted"

echo "== sync only adds"
PANEL="printf '%s\n' a.example.com b.example.com c.example.com" cli sync
grep -q "enqueue create c.example.com" "$TMP/calls" && ok "sync queues the missing zone" || fail "sync missing"
grep -q "enqueue delete" "$TMP/calls" && fail "plain sync queued a delete" || ok "plain sync deletes nothing"

echo "== sync --prune removes, within the guard"
# exactly half is allowed, more than half is not — check both sides of the line
PANEL="printf '%s\n' a.example.com" cli sync --prune; rc=$?
[ "$rc" -eq 0 ] && ok "half of two is allowed" || fail "refused exactly half (rc=$rc)"
grep -q "enqueue delete b.example.com" "$TMP/calls" && ok "the stale one is queued" || fail "half: $(cat "$TMP/calls")"

zones "[$(printf "$MINE" a.example.com),$(printf "$MINE" b.example.com),$(printf "$MINE" c.example.com)]"
PANEL="printf '%s\n' a.example.com" cli sync --prune; rc=$?
[ "$rc" -eq 2 ] && ok "two of three is refused" || fail "prune proceeded (rc=$rc)"
grep -q "enqueue delete" "$TMP/calls" && fail "queued a delete while refusing" || ok "nothing queued while refusing"

zones "[$(printf "$MINE" a.example.com),$(printf "$MINE" b.example.com),$(printf "$MINE" c.example.com),$(printf "$MINE" d.example.com)]"
PANEL="printf '%s\n' a.example.com b.example.com c.example.com" cli sync --prune
grep -q "enqueue delete d.example.com" "$TMP/calls" && ok "prunes one of four" || fail "prune of one: $(cat "$TMP/calls")"

PANEL="printf '%s\n' a.example.com" cli sync --prune --force
n=$(grep -c "enqueue delete" "$TMP/calls")
[ "$n" -eq 3 ] && ok "--force allows the bulk prune" || fail "--force queued $n deletes, want 3"

echo "== a zone mastered elsewhere is never touched"
zones '[{"name":"a.example.com","masterIp":"192.0.2.10","status":"synced"},{"name":"other.example.com","masterIp":"203.0.113.9","status":"synced"}]'
PANEL="printf '%s\n' a.example.com" cli sync --prune
grep -q "other.example.com" "$TMP/calls" && fail "queued a zone mastered elsewhere" || ok "another server's zone left alone"

echo "== remove-all asks"
zones "[$(printf "$MINE" a.example.com),$(printf "$MINE" b.example.com)]"
cli remove-all < /dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "refuses without a confirmation" || fail "remove-all proceeded unconfirmed (rc=$rc)"
[ ! -s "$TMP/calls" ] && ok "nothing queued unconfirmed" || fail "queued: $(cat "$TMP/calls")"
cli remove-all --yes
n=$(grep -c "enqueue delete" "$TMP/calls")
[ "$n" -eq 2 ] && ok "--yes removes this server's zones" || fail "--yes queued $n, want 2"

echo "== status and list read, never write"
cli list; grep -q "a.example.com" "$TMP/out" && ok "list shows the zones" || fail "list: $(cat "$TMP/out")"
[ ! -s "$TMP/calls" ] && ok "list queues nothing" || fail "list queued something"
cli status a.example.com; grep -q "mastered by 192.0.2.10" "$TMP/out" && ok "status reports one zone" || fail "status: $(cat "$TMP/out")"
cli status unknown.example.com; rc=$?
[ "$rc" -eq 1 ] && ok "an unknown zone exits 1" || fail "unknown zone rc=$rc"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
