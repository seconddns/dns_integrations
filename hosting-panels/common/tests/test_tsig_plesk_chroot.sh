#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# The real named-checkconf against a Plesk-like chroot, through seconddns-tsig enable: the
# include names /etc/seconddns-tsig.key as named sees it from /var/named/chroot, so the
# check only passes when it runs with -t <chroot>. Needs root (chroot) and
# named-checkconf; skips itself otherwise.
#
# Usage: sudo ./test_tsig_plesk_chroot.sh

set -u

[ "$(id -u)" -eq 0 ] || { echo "skipped: needs root for named-checkconf -t"; exit 0; }
command -v named-checkconf > /dev/null || { echo "skipped: named-checkconf not installed"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
TSIG="$HERE/../seconddns-tsig"
TMP="$(mktemp -d)"
CHROOT="$TMP/chroot"
PORT=8892

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

mkdir -p "$CHROOT/etc" "$CHROOT/var"
cp "$HERE/fixtures/plesk-named.conf" "$CHROOT/etc/named.conf"
cat > "$TMP/seconddns.conf" <<EOF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10
EOF
python3 - "$PORT" > /dev/null 2>&1 <<'PYEOF' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path.split('?')[0]
        body = ([{"id": "k1", "label": "web", "name": "acct-web", "algorithm": "hmac-sha256", "isDefault": False}]
                if p == '/api/user/tsig-keys' else {"dnsIps": "203.0.113.9"} if p == '/api/server-info' else [])
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYEOF
API_PID=$!
disown $API_PID 2>/dev/null || true
trap 'kill $API_PID 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1

SECRET=$(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')
export SECONDDNS_TSIG_FLAVOR=plesk SECONDDNS_PLESK_CHROOT="$CHROOT" SECONDDNS_NAMED_OPTIONS="$CHROOT/etc/named.conf" \
       SECONDDNS_CONF="$TMP/seconddns.conf" SECONDDNS_TSIG_SECRET="$TMP/tsig.secret" SECONDDNS_NAMED_RELOAD=true \
       SECONDDNS_NAMED_GID=0 SECONDDNS_QUEUED_RESTART=true SECONDDNS_SYSTEMD_DIR="$TMP" SECONDDNS_SYSTEMCTL=true
unset SECONDDNS_NAMED_CHECKCONF   # the real one

echo "== the check that enable runs, with the real named-checkconf"
named-checkconf "$CHROOT/etc/named.conf" > /dev/null 2>&1 && ok "fixture valid before" || fail "fixture invalid before enable"
"$TSIG" enable --tsig="web:$SECRET" --zones > "$TMP/out" 2>&1 && ok "enable passes named-checkconf -t <chroot>" || fail "enable rolled back: $(tail -2 "$TMP/out")"
grep -q 'include "/etc/seconddns-tsig.key"' "$CHROOT/etc/named.conf" && ok "include kept (not rolled back)" || fail "include missing after enable"
named-checkconf -t "$CHROOT" /etc/named.conf > /dev/null 2>&1 && ok "named-checkconf -t accepts the result" || fail "named-checkconf -t rejects the result"
named-checkconf "$CHROOT/etc/named.conf" > /dev/null 2>&1 && fail "outside the chroot the include resolved (the case this test exists for is not covered)" || ok "outside the chroot the include does not resolve, so -t is what makes it pass"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
