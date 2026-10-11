#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# seconddns-tsig (key lookup, secret check, [tsig] section, secret file) and
# the queue sending tsigKeyId. Requires: bash, python3, sqlite3. No network.
#
# Usage: ./test_tsig.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TSIG="$HERE/../seconddns-tsig"
QUEUE="$HERE/../seconddns-queue"
export SECONDDNS_QUEUED_BIN="$HERE/../seconddns-queued"
TMP="$(mktemp -d)"
PORT=8897

export SECONDDNS_CONF="$TMP/seconddns.conf"
export SECONDDNS_TSIG_SECRET="$TMP/etc-seconddns/tsig.secret"
export SECONDDNS_QUEUE_DB="$TMP/queue.db"
export SECONDDNS_QUEUE_LOCK="$TMP/queue.lock"
export SECONDDNS_LOG="$TMP/seconddns.log"
export SECONDDNS_QUEUE_SOCK="$TMP/w.sock"

write_conf() {
    cat > "$SECONDDNS_CONF" <<EOF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10

[queue]
poll_interval = 1
http_timeout = 5
backoff_min = 1
backoff_max = 2
EOF
    chmod 644 "$SECONDDNS_CONF"
}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"; }

# Mock API. $TMP/keys holds the GET /api/user/tsig-keys body; POST /api/zones
# bodies are appended to $TMP/posts.log; $TMP/mode=reject answers creates with 422.
python3 - "$PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys
port, tmp = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b'{}'):
        self.send_response(code); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.split('?')[0] == '/api/user/tsig-keys':
            self.reply(200, open(tmp+'/keys','rb').read()); return
        self.reply(404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(tmp+'/posts.log','ab') as f: f.write(body + b'\n')
        try: mode = open(tmp+'/mode').read().strip()
        except Exception: mode = 'ok'
        self.reply(422, b'{"error":"unknown tsigKeyId"}') if mode == 'reject' else self.reply(201, b'{"id":"z1"}')
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
MOCK_PID=$!
disown $MOCK_PID 2>/dev/null || true
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1

KEYS_TWO='[{"id":"k1","label":"main","name":"acct-main","algorithm":"hmac-sha256","isDefault":false},
           {"id":"k2","label":"web","name":"acct-web","algorithm":"hmac-sha512","isDefault":true}]'
SECRET256=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')
SECRET512=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(64)).decode())')
write_conf

echo "== 1. resolve: default key, label, errors"
echo "$KEYS_TWO" > "$TMP/keys"
assert_eq "$("$TSIG" resolve)" "k2 acct-web hmac-sha512" "no label picks the default key"
assert_eq "$("$TSIG" resolve --key=main)" "k1 acct-main hmac-sha256" "label picks that key"
"$TSIG" resolve --key=nope > /dev/null 2>&1 && fail "unknown label accepted" || ok "unknown label exits non-zero"
echo '[{"id":"k1","label":"main","name":"acct-main","algorithm":"hmac-sha256","isDefault":false}]' > "$TMP/keys"
"$TSIG" resolve > /dev/null 2>&1 && fail "no default key accepted" || ok "no default and no label exits non-zero"

echo "== 2. check-secret"
"$TSIG" check-secret hmac-sha256 "$SECRET256" && ok "32-byte secret fits hmac-sha256" || fail "32-byte secret rejected"
"$TSIG" check-secret hmac-sha512 "$SECRET256" 2>/dev/null && fail "32-byte secret accepted for hmac-sha512" || ok "32-byte secret rejected for hmac-sha512"
"$TSIG" check-secret hmac-sha512 "$SECRET512" && ok "64-byte secret fits hmac-sha512" || fail "64-byte secret rejected"
"$TSIG" check-secret hmac-sha256 'not*base64' 2>/dev/null && fail "non-base64 accepted" || ok "non-base64 rejected"
"$TSIG" check-secret hmac-md5 "$SECRET256" 2>/dev/null && fail "hmac-md5 accepted" || ok "unsupported algorithm rejected"

echo "== 3. resolve --write: section and secret file"
echo "$KEYS_TWO" > "$TMP/keys"
"$TSIG" resolve --key=main --write --secret="$SECRET512" > /dev/null 2>&1 && fail "secret of the wrong length written" || ok "wrong-length secret refused before writing"
[ -e "$SECONDDNS_TSIG_SECRET" ] && fail "secret file created by a refused write" || ok "nothing written on refusal"
"$TSIG" resolve --key=main --write --secret="$SECRET256" > /dev/null
section=$(python3 -c "import configparser,sys;c=configparser.ConfigParser();c.read(sys.argv[1]);print(c['tsig']['key_id'],c['tsig']['key_name'],c['tsig']['algorithm'],c['tsig']['secret_file'])" "$SECONDDNS_CONF")
assert_eq "$section" "k1 acct-main hmac-sha256 $SECONDDNS_TSIG_SECRET" "[tsig] section written"
grep -q "$SECRET256" "$SECONDDNS_CONF" && fail "secret leaked into the world-readable config" || ok "secret not in the config"
assert_eq "$(stat -c %a "$SECONDDNS_TSIG_SECRET" 2>/dev/null || stat -f %Lp "$SECONDDNS_TSIG_SECRET")" 600 "secret file is 0600"
assert_eq "$("$TSIG" secret)" "$SECRET256" "secret reads back"
grep -q '^api_key = test-key$' "$SECONDDNS_CONF" && ok "rest of the config kept" || fail "rest of the config lost"
assert_eq "$(stat -c %a "$SECONDDNS_CONF" 2>/dev/null || stat -f %Lp "$SECONDDNS_CONF")" 644 "config mode kept"
"$TSIG" resolve --write > /dev/null
assert_eq "$(grep -c '^\[tsig\]' "$SECONDDNS_CONF")" 1 "rewrite keeps one [tsig] section"
assert_eq "$(python3 -c "import configparser,sys;c=configparser.ConfigParser();c.read(sys.argv[1]);print(c['tsig']['key_id'])" "$SECONDDNS_CONF")" k2 "rewrite replaces the key"

echo "== 4. queue sends tsigKeyId only with a [tsig] section"
"$TSIG" resolve --key=main --write --secret="$SECRET256" > /dev/null
: > "$TMP/posts.log"
"$QUEUE" enqueue create signed.example.com 192.0.2.10 && "$QUEUE" flush
assert_eq "$(python3 -c "import json,sys;print(json.loads(open(sys.argv[1]).readline()).get('tsigKeyId'))" "$TMP/posts.log")" k1 "create carries tsigKeyId"
echo reject > "$TMP/mode"
"$QUEUE" enqueue create rejected.example.com 192.0.2.10; "$QUEUE" flush
grep -q "rejected with TSIG key k1" "$SECONDDNS_LOG" && ok "422 with a key is logged with the key id" || fail "422 with a key not explained in the log"
rm -f "$TMP/mode"
"$TSIG" clear
grep -q '^\[tsig\]' "$SECONDDNS_CONF" && fail "clear left the section" || ok "clear removes the section"
[ -e "$SECONDDNS_TSIG_SECRET" ] && fail "clear left the secret file" || ok "clear removes the secret file"
: > "$TMP/posts.log"
"$QUEUE" enqueue create plain.example.com 192.0.2.10 && "$QUEUE" flush
assert_eq "$(head -1 "$TMP/posts.log")" '{"name": "plain.example.com", "masterIp": "192.0.2.10"}' "without [tsig] the create body is unchanged"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
