#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# seconddns-tsig enable / disable / restore on BIND, with a mock API and a stand-in for
# named-checkconf and rndc. The real named run is test_tsig_bind_named.sh.
# Requires: bash, python3. No network.
#
# Usage: ./test_tsig_bind.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TSIG="$HERE/../seconddns-tsig"
FIXTURE="$HERE/fixtures/cpanel-named.conf"
TMP="$(mktemp -d)"
PORT=8896
OUR="203.0.113.9"

export SECONDDNS_CONF="$TMP/seconddns.conf"
export SECONDDNS_TSIG_SECRET="$TMP/etc-seconddns/tsig.secret"
export SECONDDNS_NAMED_OPTIONS="$TMP/named/named.conf"
export SECONDDNS_NAMED_CHECKCONF="sh -c 'test ! -e $TMP/checkconf-fails'"
export SECONDDNS_NAMED_RELOAD="true"
export SECONDDNS_QUEUED_RESTART="sh -c 'echo restart >> $TMP/restarts.log'"
KEYFILE="$TMP/named/seconddns-tsig.key"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"; }
at() { grep -E '^[[:space:]]*allow-transfer' "$SECONDDNS_NAMED_OPTIONS" | sed 's/^[[:space:]]*//'; }

reset() {
    mkdir -p "$TMP/named"
    cp "$FIXTURE" "$SECONDDNS_NAMED_OPTIONS"
    # what the installer leaves: our IP next to the customer's own secondary
    sed 's/allow-transfer    { "none"; };/allow-transfer    { 198.51.100.7; 203.0.113.9; };/' "$FIXTURE" > "$SECONDDNS_NAMED_OPTIONS"
    rm -f "$KEYFILE" "$TMP/checkconf-fails" "$TMP/patch-fails" "$SECONDDNS_TSIG_SECRET"
    : > "$TMP/patches.log"; : > "$TMP/restarts.log"
    cat > "$SECONDDNS_CONF" <<EOF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10
EOF
    echo '[{"id":"z1","name":"a.example","masterIp":"192.0.2.10","tsigKeyId":null},
           {"id":"z2","name":"b.example","masterIp":"192.0.2.10","tsigKeyId":null},
           {"id":"z3","name":"other.example","masterIp":"192.0.2.99","tsigKeyId":null}]' > "$TMP/zones"
}

SECRET=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')
echo '[{"id":"k1","label":"web","name":"acct-web","algorithm":"hmac-sha256","isDefault":false}]' > "$TMP/keys"

# Mock API: keys, server-info, zones; PATCH /api/zones/<id> updates $TMP/zones and is
# logged; $TMP/patch-fails makes the PATCH of z2 answer 500.
python3 - "$PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys, json, os
port, tmp = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        self.send_response(code); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/api/user/tsig-keys': self.reply(200, open(tmp+'/keys','rb').read())
        elif p == '/api/server-info': self.reply(200, {"dnsIps": "203.0.113.9,2001:db8::9"})
        elif p == '/api/zones': self.reply(200, open(tmp+'/zones','rb').read())
        else: self.reply(404, {})
    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        zid = self.path.rsplit('/', 1)[1]
        if zid == 'z2' and os.path.exists(tmp+'/patch-fails'):
            self.reply(500, {}); return
        zones = json.load(open(tmp+'/zones'))
        for z in zones:
            if z['id'] == zid: z['tsigKeyId'] = body.get('tsigKeyId')
        json.dump(zones, open(tmp+'/zones','w'))
        with open(tmp+'/patches.log','a') as f: f.write(f"{zid} {body.get('tsigKeyId')}\n")
        self.reply(200, {})
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
MOCK_PID=$!
disown $MOCK_PID 2>/dev/null || true
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1

echo "== 1. allow-transfer edits on the real cPanel named.conf"
out=$(python3 - "$HERE/.." "$FIXTURE" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import seconddns_bind as b
t = open(sys.argv[2]).read()
k = b.key_entry("acct-web")
n, _ = b.edit_allow_transfer(t, add=[k])
print([l.strip() for l in n.splitlines() if "allow-transfer" in l and not l.strip().startswith("//")][0])
n2, _ = b.edit_allow_transfer(n, add=[k])
print("idempotent" if n2 == n else "changed twice")
multi = t.replace('allow-transfer    { "none"; };', 'allow-transfer {\n        203.0.113.9;\n        10.0.0.0/8; // office\n    };')
m, _ = b.edit_allow_transfer(multi, add=[k], drop=["203.0.113.9"])
print(repr(m[m.index("allow-transfer"):m.index("};", m.index("allow-transfer"))+2]))
decoy = "// options { allow-transfer { 1.2.3.4; }; }\n/* allow-transfer { 5.6.7.8; }; */\n" + t
d, _ = b.edit_allow_transfer(decoy, add=[k])
print("comments untouched" if d.startswith("// options { allow-transfer { 1.2.3.4; }; }\n/* allow-transfer { 5.6.7.8; }; */") else "comment edited")
print(b.edit_allow_transfer("logging { };\n", add=[k])[1])
PY
)
assert_eq "$(sed -n 1p <<<"$out")" 'allow-transfer    { key "acct-web"; };' '"none" replaced by the key'
assert_eq "$(sed -n 2p <<<"$out")" "idempotent" "adding the key twice changes nothing"
assert_eq "$(sed -n 3p <<<"$out")" "'allow-transfer {\\n        10.0.0.0/8; // office\\n        key \"acct-web\";\\n    };'" "multi-line list: our IP dropped, comment kept, key on its own line"
assert_eq "$(sed -n 4p <<<"$out")" "comments untouched" "allow-transfer inside comments is not edited"
assert_eq "$(sed -n 5p <<<"$out")" "no options { } block" "config without options is refused"

echo "== 2. enable --no-zones: key accepted next to our IP, zones untouched"
reset
"$TSIG" enable --tsig="web:$SECRET" --no-zones > "$TMP/out" 2>&1; rc=$?
assert_eq "$rc" 0 "enable exits 0"
assert_eq "$(at)" 'allow-transfer    { 198.51.100.7; 203.0.113.9; key "acct-web"; };' "our IP kept while zones are unsigned"
grep -q "include \"$KEYFILE\"; // seconddns-tsig" "$SECONDDNS_NAMED_OPTIONS" && ok "key file included" || fail "include missing"
grep -q "secret \"$SECRET\";" "$KEYFILE" && ok "key file holds the secret" || fail "key file content"
assert_eq "$(stat -c %a "$KEYFILE" 2>/dev/null || stat -f %Lp "$KEYFILE")" 640 "key file is 0640"
assert_eq "$(wc -l < "$TMP/patches.log" | tr -d ' ')" 0 "no zone patched"
grep -q "our IPs stay in allow-transfer" "$TMP/out" && ok "says why our IP stays" || fail "no hint about our IP"

echo "== 3. enable --zones: this server's zones get the key, then our IP goes"
"$TSIG" enable --tsig="web:$SECRET" --zones > /dev/null 2>&1
assert_eq "$(sort "$TMP/patches.log" | tr '\n' ' ')" "z1 k1 z2 k1 " "only zones mastered here patched"
assert_eq "$(at)" 'allow-transfer    { 198.51.100.7; key "acct-web"; };' "our IP removed, customer's secondary kept"

echo "== 4. a zone PATCH fails: our IP stays"
reset
touch "$TMP/patch-fails"
"$TSIG" enable --tsig="web:$SECRET" --zones > /dev/null 2>&1
assert_eq "$(at)" 'allow-transfer    { 198.51.100.7; 203.0.113.9; key "acct-web"; };' "IP kept while a zone is still unsigned"

echo "== 5. named-checkconf rejects: nothing kept"
reset
cp "$SECONDDNS_NAMED_OPTIONS" "$TMP/before"
touch "$TMP/checkconf-fails"
"$TSIG" enable --tsig="web:$SECRET" --zones > /dev/null 2>&1 && fail "enable succeeded with a rejected config" || ok "enable fails"
cmp -s "$TMP/before" "$SECONDDNS_NAMED_OPTIONS" && ok "named.conf restored" || fail "named.conf left edited"
[ -e "$KEYFILE" ] && fail "key file left behind" || ok "key file removed"
grep -q '^\[tsig\]' "$SECONDDNS_CONF" && fail "[tsig] stored after a failed enable" || ok "nothing stored"
assert_eq "$(wc -l < "$TMP/patches.log" | tr -d ' ')" 0 "no zone patched"

echo "== 6. restore after the panel rewrote named.conf"
reset
"$TSIG" enable --tsig="web:$SECRET" --zones > /dev/null 2>&1
cp "$FIXTURE" "$SECONDDNS_NAMED_OPTIONS"; rm -f "$KEYFILE"   # panel regenerated its config
"$TSIG" restore > "$TMP/out" 2>&1
assert_eq "$(at)" 'allow-transfer    { key "acct-web"; };' "key back in allow-transfer"
[ -e "$KEYFILE" ] && grep -q "include \"$KEYFILE\"" "$SECONDDNS_NAMED_OPTIONS" && ok "key file and include back" || fail "restore incomplete"
cp "$SECONDDNS_NAMED_OPTIONS" "$TMP/after"
"$TSIG" restore > "$TMP/out" 2>&1
cmp -s "$TMP/after" "$SECONDDNS_NAMED_OPTIONS" && [ ! -s "$TMP/out" ] && ok "second restore is a quiet no-op" || fail "second restore changed something"

echo "== 7. disable --no-zones while zones use the key: refused, IP back, key kept"
"$TSIG" disable --no-zones > /dev/null 2>&1 && fail "disable succeeded with signed zones left" || ok "disable refuses"
assert_eq "$(at)" 'allow-transfer    { key "acct-web"; 203.0.113.9; };' "our IP back, key still accepted"
[ -e "$KEYFILE" ] && ok "key file kept" || fail "key file removed too early"

echo "== 8. disable --zones: zones unsigned, key and include gone"
: > "$TMP/patches.log"
"$TSIG" disable --zones > /dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "disable exits 0"
assert_eq "$(sort "$TMP/patches.log" | tr '\n' ' ')" "z1 None z2 None " "zones set back to unsigned"
assert_eq "$(at)" 'allow-transfer    { 203.0.113.9; };' "only our IP left"
grep -q "seconddns-tsig" "$SECONDDNS_NAMED_OPTIONS" && fail "include left" || ok "include removed"
[ -e "$KEYFILE" ] && fail "key file left" || ok "key file removed"
grep -q '^\[tsig\]' "$SECONDDNS_CONF" && fail "[tsig] left" || ok "[tsig] removed"

echo "== 9. the queue worker is restarted when [tsig] changes"
reset
"$TSIG" enable --tsig="web:$SECRET" --zones > /dev/null 2>&1
assert_eq "$(wc -l < "$TMP/restarts.log" | tr -d ' ')" 1 "enable restarts seconddns-queued once"
"$TSIG" disable --zones > /dev/null 2>&1
assert_eq "$(wc -l < "$TMP/restarts.log" | tr -d ' ')" 2 "disable restarts it again"

echo "== 10. a failed disable keeps [tsig], so it can be rerun"
reset
"$TSIG" enable --tsig="web:$SECRET" --zones > /dev/null 2>&1
touch "$TMP/patch-fails"
"$TSIG" disable --zones > /dev/null 2>&1 && fail "disable succeeded with a zone still signed" || ok "disable fails when a zone keeps the key"
grep -q '^key_id = k1$' "$SECONDDNS_CONF" && ok "[tsig] put back" || fail "[tsig] lost after a failed disable"
[ -e "$KEYFILE" ] && ok "key still on BIND for the signed zone" || fail "key removed under a signed zone"
rm -f "$TMP/patch-fails"
"$TSIG" disable --zones > /dev/null 2>&1 && ok "rerun of disable completes" || fail "rerun of disable failed"

echo "== 11. zone-level allow-transfer naming our IP is reported"
reset
printf 'zone "a.example" { type master; file "a.db"; allow-transfer { 203.0.113.9; }; };\n' >> "$SECONDDNS_NAMED_OPTIONS"
"$TSIG" enable --tsig="web:$SECRET" --zones > "$TMP/out" 2>&1
grep -q "1 zone-level allow-transfer entry name our IP" "$TMP/out" && ok "zone-level entry counted" || fail "no warning: $(cat "$TMP/out")"
grep -q 'allow-transfer { key "acct-web"; };' "$TMP/out" && ok "WHM line printed with the key" || fail "no WHM line"

echo "== 12. setup: --tsig enables, no terminal or --yes keeps our IP"
reset
SECONDDNS_AUTO_YES=1 "$TSIG" setup < /dev/null > "$TMP/out" 2>&1
grep -q "by our IP address" "$TMP/out" && ok "--yes without --tsig keeps IP" || fail "setup --yes: $(cat "$TMP/out")"
grep -q '^\[tsig\]' "$SECONDDNS_CONF" && fail "[tsig] written without a choice" || ok "nothing written"
"$TSIG" setup --tsig="web:$SECRET" > /dev/null 2>&1
assert_eq "$(at)" 'allow-transfer    { 198.51.100.7; key "acct-web"; };' "setup --tsig enables and sets the zones"
SECONDDNS_NAMED_OPTIONS="$TMP/absent.conf" "$TSIG" setup --tsig="web:$SECRET" > /dev/null 2>&1 && fail "--tsig accepted without BIND" || ok "--tsig without BIND is refused"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
