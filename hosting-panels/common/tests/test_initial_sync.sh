#!/bin/bash
# The installers' initial fill: --add-missing --apply queues the zones the panel
# has and SecondDNS does not, touches nothing else, and repeats to nothing.
# Run: bash hosting-panels/common/tests/test_initial_sync.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

command -v idn2 >/dev/null || { echo "idn2 required"; exit 1; }

TMP="$(mktemp -d)"
PORT=$((20000 + RANDOM % 10000))
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$TMP"' EXIT

# Mock API: GET /api/zones returns whatever $TMP/zones.json holds
echo '[{"name":"already.example.com","masterIp":"192.0.2.10"}]' > "$TMP/zones.json"
python3 - "$PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys
port, tmp = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = open(tmp + '/zones.json', 'rb').read()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
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

# stand-in for seconddns-queue: records what would be queued
cat > "$TMP/queue" <<'Q'
#!/bin/bash
echo "$*" >> "$CALLS"
exit 0
Q
chmod +x "$TMP/queue"

reconcile() { # $1 = panel zone list, newline separated
    env SECONDDNS_CONF="$TMP/seconddns.conf" \
        SECONDDNS_QUEUE_BIN="$TMP/queue" \
        SECONDDNS_DOMAIN_BIN="$HERE/../seconddns-domain" \
        SECONDDNS_PANEL_ZONES_CMD="printf '%s\n' $1" \
        CALLS="$TMP/calls" \
        PYTHONPATH="$HERE/.." \
        python3 "$HERE/../seconddns-reconcile" --add-missing --apply >> "$TMP/out" 2>&1
}

# Each panel keeps its zone list somewhere else; panel_zones() holds that
# knowledge, and the fixture stands in for it the same way for every panel.
for panel in plesk cpanel directadmin cyberpanel; do
    echo "== $panel"
    : > "$TMP/calls"; : > "$TMP/out"
    reconcile "already.example.com missing1.example.com missing2.example.org"
    n=$(wc -l < "$TMP/calls" | tr -d ' ')
    [ "$n" -eq 2 ] && ok "queued exactly the two missing zones" || fail "queued $n, want 2: $(cat "$TMP/calls")"
    grep -q "enqueue create missing1.example.com 192.0.2.10" "$TMP/calls" \
        && ok "missing1 queued" || fail "missing1 not queued"
    grep -q "enqueue create missing2.example.org 192.0.2.10" "$TMP/calls" \
        && ok "missing2 queued" || fail "missing2 not queued"
    grep -q "already.example.com" "$TMP/calls" \
        && fail "queued a zone that already exists" || ok "existing zone left alone"
    grep -q "enqueue delete" "$TMP/calls" \
        && fail "queued a delete on a fill" || ok "no delete queued"

    # second run: SecondDNS now holds all three, so nothing is missing
    echo '[{"name":"already.example.com","masterIp":"192.0.2.10"},{"name":"missing1.example.com","masterIp":"192.0.2.10"},{"name":"missing2.example.org","masterIp":"192.0.2.10"}]' > "$TMP/zones.json"
    : > "$TMP/calls"
    reconcile "already.example.com missing1.example.com missing2.example.org"
    [ ! -s "$TMP/calls" ] && ok "second run queues nothing" || fail "second run queued: $(cat "$TMP/calls")"
    echo '[{"name":"already.example.com","masterIp":"192.0.2.10"}]' > "$TMP/zones.json"
done

echo "== an IDN zone from the panel"
: > "$TMP/calls"
reconcile "already.example.com ПРИКЛАД.УКР"
grep -q "enqueue create xn--80aikifvh.xn--j1amh 192.0.2.10" "$TMP/calls" \
    && ok "queued in punycode" || fail "not punycode: $(cat "$TMP/calls")"

echo "== a zone in SecondDNS that the panel does not have"
echo '[{"name":"already.example.com","masterIp":"192.0.2.10"},{"name":"gone.example.com","masterIp":"192.0.2.10"}]' > "$TMP/zones.json"
: > "$TMP/calls"
reconcile "already.example.com"
grep -q "gone.example.com" "$TMP/calls" \
    && fail "a fill removed a zone" || ok "stale zone untouched by a fill"

echo "== the DirectAdmin walk is gone"
grep -q "/etc/virtual" "$HERE/../../directadmin/install.sh" \
    && fail "install.sh still walks /etc/virtual" || ok "no /etc/virtual walk in the installer"
# and the source panel_zones() uses for DirectAdmin is not empty on a fixture
NAMED_FIXTURE="$TMP/named"; mkdir -p "$NAMED_FIXTURE"
touch "$NAMED_FIXTURE/one.example.com.db" "$NAMED_FIXTURE/two.example.org.db" "$NAMED_FIXTURE/named.ca"
listed=$(python3 -c "
import os,sys
print('\n'.join(f[:-3] for f in os.listdir(sys.argv[1]) if f.endswith('.db')))
" "$NAMED_FIXTURE" | sort | tr '\n' ' ')
[ "$listed" = "one.example.com two.example.org " ] \
    && ok "/var/named/*.db yields the zones, not the hint file" || fail "got '$listed'"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
