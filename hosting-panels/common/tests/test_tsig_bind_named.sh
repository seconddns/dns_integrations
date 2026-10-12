#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# seconddns-tsig against a real named: after enable, AXFR from our IP needs the key while
# the customer's other secondary still transfers by IP; after disable our IP works again.
# Requires: named, named-checkconf, dig, python3. Skips itself when BIND is not installed.
#
# Usage: ./test_tsig_bind_named.sh

set -u

for t in named named-checkconf dig; do
    command -v "$t" > /dev/null || { echo "skipped: $t not installed"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
TSIG="$HERE/../seconddns-tsig"
TMP="$(mktemp -d)"
API_PORT=8895
DNS_PORT=5300
CONF="$TMP/named.conf"

export SECONDDNS_CONF="$TMP/seconddns.conf"
export SECONDDNS_TSIG_SECRET="$TMP/etc-seconddns/tsig.secret"
export SECONDDNS_NAMED_OPTIONS="$CONF"
export SECONDDNS_NAMED_CHECKCONF="named-checkconf $CONF"
export SECONDDNS_NAMED_RELOAD="sh -c 'kill -HUP \$(cat $TMP/named.pid) && sleep 1'"
export SECONDDNS_QUEUED_RESTART="true"
# the runner may also run the distribution's named as bind; ours runs as us
export SECONDDNS_NAMED_GID="$(id -g)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

cat > "$TMP/example.test.db" <<'EOF'
$TTL 300
@   IN SOA ns1.example.test. hostmaster.example.test. 1 300 60 86400 60
@   IN NS  ns1.example.test.
ns1 IN A   192.0.2.53
www IN A   192.0.2.10
EOF
cat > "$CONF" <<EOF
options {
    directory "$TMP";
    pid-file "$TMP/named.pid";
    listen-on port $DNS_PORT { 127.0.0.1; };
    listen-on-v6 { none; };
    recursion no;
    // our IP (127.0.0.1) and the customer's own secondary (127.0.0.2)
    allow-transfer { 127.0.0.2; 127.0.0.1; };
};
zone "example.test" { type primary; file "$TMP/example.test.db"; };
EOF
cat > "$SECONDDNS_CONF" <<EOF
[seconddns]
api_url = http://127.0.0.1:$API_PORT
api_key = test-key
master_ip = 192.0.2.10
EOF
SECRET=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')

python3 - "$API_PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys, json
port, tmp = int(sys.argv[1]), sys.argv[2]
zones = [{"id": "z1", "name": "example.test", "masterIp": "192.0.2.10", "tsigKeyId": None}]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        self.send_response(code); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/api/user/tsig-keys':
            self.reply(200, [{"id": "k1", "label": "web", "name": "acct-web", "algorithm": "hmac-sha256", "isDefault": False}])
        elif p == '/api/server-info': self.reply(200, {"dnsIps": "127.0.0.1"})
        elif p == '/api/zones': self.reply(200, zones)
        else: self.reply(404, {})
    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        for z in zones: z['tsigKeyId'] = body.get('tsigKeyId')
        self.reply(200, {})
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
API_PID=$!
disown $API_PID 2>/dev/null || true
named -c "$CONF" -g > "$TMP/named.log" 2>&1 &
NAMED_PID=$!
disown $NAMED_PID 2>/dev/null || true
trap 'kill $API_PID $NAMED_PID 2>/dev/null; rm -rf "$TMP"' EXIT
for i in $(seq 1 20); do dig +short -p $DNS_PORT @127.0.0.1 example.test SOA > /dev/null 2>&1 && break; sleep 0.5; done

axfr() { # $1 source address, $2 optional -y key spec
    dig +tries=1 +time=3 -p $DNS_PORT @127.0.0.1 -b "$1" ${2:+-y "$2"} example.test AXFR 2>&1
}
transfers() { axfr "$@" | grep -q 'www.example.test.*192.0.2.10'; }

echo "== 0. before: both secondaries transfer by IP"
transfers 127.0.0.1 && ok "our IP transfers without a key" || fail "baseline broken: $(axfr 127.0.0.1 | tail -2)"

echo "== 1. enable --zones on a real named"
"$TSIG" enable --tsig="web:$SECRET" --zones > "$TMP/out" 2>&1 || fail "enable failed: $(cat "$TMP/out")"
named-checkconf "$CONF" && ok "named-checkconf accepts the result" || fail "named-checkconf rejects the result"
transfers 127.0.0.1 && fail "our IP still transfers without the key" || ok "our IP without the key is refused"
transfers 127.0.0.1 "hmac-sha256:acct-web:$SECRET" && ok "our IP with the key transfers" || fail "signed AXFR failed: $(axfr 127.0.0.1 "hmac-sha256:acct-web:$SECRET" | tail -2)"
OTHER=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')
transfers 127.0.0.1 "hmac-sha256:acct-web:$OTHER" && fail "a wrong secret transfers" || ok "a wrong secret is refused"
transfers 127.0.0.2 && ok "the customer's other secondary still transfers by IP" || fail "the customer's secondary lost access"

echo "== 2. restore after the key file and include were lost"
rm -f "$TMP/seconddns-tsig.key"
sed -i.bak '/seconddns-tsig/d' "$CONF"
"$TSIG" restore > /dev/null 2>&1
transfers 127.0.0.1 "hmac-sha256:acct-web:$SECRET" && ok "restore brings signed transfers back" || fail "restore did not work"

echo "== 3. disable --zones"
"$TSIG" disable --zones > "$TMP/out" 2>&1 || fail "disable failed: $(cat "$TMP/out")"
transfers 127.0.0.1 && ok "our IP transfers without a key again" || fail "our IP still refused after disable"
[ -e "$TMP/seconddns-tsig.key" ] && fail "key file left" || ok "key file removed"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
