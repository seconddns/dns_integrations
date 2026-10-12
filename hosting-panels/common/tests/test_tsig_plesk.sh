#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# seconddns-tsig on Plesk: key file in the chroot, include in the custom directives block,
# key in acl common-allow-transfer, and restore after Plesk rewrites named.conf. Mock API,
# stand-ins for named-checkconf, rndc and systemctl. The real named run is
# test_tsig_plesk_named.sh. Requires: bash, python3. No network.
#
# Usage: ./test_tsig_plesk.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TSIG="$HERE/../seconddns-tsig"
FIXTURE="$HERE/fixtures/plesk-named.conf"
TMP="$(mktemp -d)"
PORT=8894
CHROOT="$TMP/chroot"
CONF="$CHROOT/etc/named.conf"
KEYFILE="$CHROOT/etc/seconddns-tsig.key"

export SECONDDNS_TSIG_FLAVOR=plesk
export SECONDDNS_PLESK_CHROOT="$CHROOT"
export SECONDDNS_NAMED_OPTIONS="$CONF"
export SECONDDNS_CONF="$TMP/seconddns.conf"
export SECONDDNS_TSIG_SECRET="$TMP/etc-seconddns/tsig.secret"
export SECONDDNS_NAMED_CHECKCONF="sh -c 'test ! -e $TMP/checkconf-fails'"
export SECONDDNS_NAMED_RELOAD="true"
export SECONDDNS_NAMED_GID="$(id -g)"
export SECONDDNS_QUEUED_RESTART="true"
export SECONDDNS_SYSTEMD_DIR="$TMP/systemd"
export SECONDDNS_SYSTEMCTL="sh -c 'echo \"\$*\" >> $TMP/systemctl.log' systemctl"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"; }
acl() { awk '/^acl common-allow-transfer/,/^};/' "$CONF" | grep -v -e '^acl' -e '^};' | tr -d '\t;' | tr '\n' ' ' | sed 's/ $//'; }

# what Plesk writes on every rewrite: the ACL from its template, the custom block as it was
plesk_rewrite() {
    python3 - "$CONF" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"acl common-allow-transfer \{.*?\};", "acl common-allow-transfer {\n\t198.51.100.7;\n\t203.0.113.9;\n};", s, flags=re.S)
open(p, "w").write(s)
PY
}

reset() {
    rm -rf "$CHROOT" "$TMP/systemd" "$TMP/systemctl.log" "$TMP/checkconf-fails" "$SECONDDNS_TSIG_SECRET"
    mkdir -p "$CHROOT/etc" "$TMP/systemd"
    cp "$FIXTURE" "$CONF"
    : > "$TMP/patches.log"
    cat > "$SECONDDNS_CONF" <<EOF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10
EOF
    echo '[{"id":"z1","name":"example-one.test","masterIp":"192.0.2.10","tsigKeyId":null}]' > "$TMP/zones"
}

SECRET=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')
echo '[{"id":"k1","label":"web","name":"acct-web","algorithm":"hmac-sha256","isDefault":false}]' > "$TMP/keys"

python3 - "$PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys, json
port, tmp = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        self.send_response(code); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else json.dumps(body).encode())
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/api/user/tsig-keys': self.reply(200, open(tmp+'/keys','rb').read())
        elif p == '/api/server-info': self.reply(200, {"dnsIps": "203.0.113.9"})
        elif p == '/api/zones': self.reply(200, open(tmp+'/zones','rb').read())
        else: self.reply(404, {})
    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        zones = json.load(open(tmp+'/zones'))
        for z in zones: z['tsigKeyId'] = body.get('tsigKeyId')
        json.dump(zones, open(tmp+'/zones','w'))
        with open(tmp+'/patches.log','a') as f: f.write(f"{body.get('tsigKeyId')}\n")
        self.reply(200, {})
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
MOCK_PID=$!
disown $MOCK_PID 2>/dev/null || true
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1

echo "== 1. enable --zones on a Plesk named.conf"
reset
"$TSIG" enable --tsig="web:$SECRET" --zones > "$TMP/out" 2>&1; rc=$?
assert_eq "$rc" 0 "enable exits 0"
[ -e "$KEYFILE" ] && grep -q "secret \"$SECRET\";" "$KEYFILE" && ok "key file inside the chroot" || fail "key file missing in $CHROOT/etc"
awk '/PLEASE ADD YOUR CUSTOM DIRECTIVES/{getline; print; exit}' "$CONF" | grep -q '^include "/etc/seconddns-tsig.key"; // seconddns-tsig$' \
    && ok "include right below the custom directives line, chroot path" || fail "include: $(grep -n seconddns-tsig "$CONF")"
assert_eq "$(acl)" '198.51.100.7 key "acct-web"' "our IP out of the ACL, key in, customer's secondary kept"
assert_eq "$(grep -c 'common-allow-transfer;' "$CONF")" 2 "zones untouched"
grep -q '^removed_entries = 203.0.113.9$' "$SECONDDNS_CONF" && ok "removed IP remembered" || fail "removed_entries missing"
grep -q "^PathChanged=$CONF$" "$TMP/systemd/seconddns-tsig-restore.path" && ok "path unit watches named.conf" || fail "path unit"
grep -q '^ExecStart=/usr/local/bin/seconddns-tsig restore$' "$TMP/systemd/seconddns-tsig-restore.service" && ok "service runs restore" || fail "service unit"
[ -e "$TMP/systemd/seconddns-tsig-restore.timer" ] && ok "fallback timer written" || fail "no timer"
grep -q "enable --now seconddns-tsig-restore.path seconddns-tsig-restore.timer" "$TMP/systemctl.log" && ok "path unit and timer enabled" || fail "systemctl: $(cat "$TMP/systemctl.log")"

echo "== 2. Plesk rewrites named.conf: restore puts the key back and our IP out again"
plesk_rewrite
assert_eq "$(acl)" '198.51.100.7 203.0.113.9' "after the rewrite: template ACL, no key"
"$TSIG" restore > "$TMP/out" 2>&1; rc=$?
assert_eq "$rc" 0 "restore exits 0"
assert_eq "$(acl)" '198.51.100.7 key "acct-web"' "key back, our IP out"
cp "$CONF" "$TMP/after"
"$TSIG" restore > "$TMP/out" 2>&1
cmp -s "$TMP/after" "$CONF" && [ ! -s "$TMP/out" ] && ok "second restore is a quiet no-op (the path unit fires on our own write too)" || fail "second restore changed something"

echo "== 3. custom block lost its include: restore puts it back"
python3 - "$CONF" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace('include "/etc/seconddns-tsig.key"; // seconddns-tsig\n', ''))
PY
"$TSIG" restore > /dev/null 2>&1
grep -q 'include "/etc/seconddns-tsig.key"; // seconddns-tsig' "$CONF" && ok "include restored" || fail "include not restored"

echo "== 4. disable --zones: units stop first, IP back, key and include gone"
: > "$TMP/systemctl.log"; : > "$TMP/patches.log"
"$TSIG" disable --zones > "$TMP/out" 2>&1; rc=$?
assert_eq "$rc" 0 "disable exits 0"
head -1 "$TMP/systemctl.log" | grep -q "^disable --now seconddns-tsig-restore.path" && ok "restore units stopped before any edit" || fail "systemctl order: $(cat "$TMP/systemctl.log")"
assert_eq "$(acl)" '198.51.100.7 203.0.113.9' "our IP back in the ACL, key gone"
grep -q seconddns-tsig "$CONF" && fail "include left" || ok "include removed"
[ -e "$KEYFILE" ] && fail "key file left" || ok "key file removed"
[ -e "$TMP/systemd/seconddns-tsig-restore.path" ] && fail "unit files left" || ok "unit files removed"
assert_eq "$(cat "$TMP/patches.log")" "None" "zone set back to unsigned"

echo "== 5. no custom directives line: refused, nothing kept"
reset
grep -v "PLEASE ADD YOUR CUSTOM DIRECTIVES" "$FIXTURE" > "$CONF"
cp "$CONF" "$TMP/before"
"$TSIG" enable --tsig="web:$SECRET" --zones > "$TMP/out" 2>&1 && fail "enable succeeded without the custom block" || ok "enable refuses"
grep -q "PLEASE ADD YOUR CUSTOM DIRECTIVES" "$TMP/out" && ok "says what is missing" || fail "message: $(cat "$TMP/out")"
cmp -s "$TMP/before" "$CONF" && ok "named.conf unchanged" || fail "named.conf edited"
[ -e "$KEYFILE" ] && fail "key file left" || ok "no key file"
grep -q '^\[tsig\]' "$SECONDDNS_CONF" && fail "[tsig] stored" || ok "nothing stored"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
