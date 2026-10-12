#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# A real named with a Plesk-style named.conf: every zone has
# allow-transfer { common-allow-transfer; }. Our IP in the options block (what the old
# installer wrote) opens nothing; the same IP in the ACL, put there by
# configure_plesk_acl, does. Requires: named, dig. Skips itself when BIND is not installed.
#
# Usage: ./test_plesk_acl_named.sh

set -u

for t in named dig; do
    command -v "$t" > /dev/null || { echo "skipped: $t not installed"; exit 0; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../plesk/install.sh"
TMP="$(mktemp -d)"
PORT=5301
CONF="$TMP/named.conf"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

cat > "$TMP/a.example" <<'EOF'
$TTL 300
@   IN SOA ns1.a.example. hostmaster.a.example. 1 300 60 86400 60
@   IN NS  ns1.a.example.
ns1 IN A   192.0.2.53
www IN A   192.0.2.10
EOF

# written the way Plesk writes it; $TMP/acl holds misc.DNS_Allow_Transfer*
write_conf() {
    { cat <<EOF
options {
    directory "$TMP";
    pid-file "$TMP/named.pid";
    listen-on port $PORT { 127.0.0.1; };
    listen-on-v6 { none; };
    recursion no;
    allow-transfer { 127.0.0.1; };
};
EOF
      printf 'acl common-allow-transfer {\n'
      if [ -s "$TMP/acl" ]; then sed 's/^/\t/; s/$/;/' "$TMP/acl"; else printf '\tnone;\n'; fi
      printf '};\n'
      cat <<EOF
zone "a.example" {
	type master;
	file "a.example";
	allow-transfer {
		common-allow-transfer;
	};
};
EOF
    } > "$CONF"
}

# the stand-in rewrites the config like Plesk does, then named is reloaded
cat > "$TMP/plesk" <<EOF
#!/bin/bash
TMP="$TMP"; PORT=$PORT; CONF="$CONF"
$(declare -f write_conf)
case "\$1 \$2" in
  "db -Ne") cat "\$TMP/acl" 2>/dev/null ;;
  "bin server_dns") tr ',' '\n' <<< "\${5}" >> "\$TMP/acl"; write_conf; kill -HUP \$(cat "\$TMP/named.pid"); sleep 1 ;;
esac
EOF
chmod +x "$TMP/plesk"
export SECONDDNS_PLESK="$TMP/plesk" SECONDDNS_PLESK_NAMED_CONF="$CONF"

write_conf
named -c "$CONF" -g > "$TMP/named.log" 2>&1 &
NAMED_PID=$!
disown $NAMED_PID 2>/dev/null || true
trap 'kill $NAMED_PID 2>/dev/null; rm -rf "$TMP"' EXIT
for i in $(seq 1 20); do dig +short -p $PORT @127.0.0.1 a.example SOA > /dev/null 2>&1 && break; sleep 0.5; done

transfers() { dig +tries=1 +time=3 -p $PORT @127.0.0.1 -b "$1" a.example AXFR 2>&1 | grep -q 'www.a.example.*192.0.2.10'; }

echo "== 1. our IP only in options (the old installer): no transfer"
transfers 127.0.0.1 && fail "options allow-transfer opened a Plesk zone" || ok "zone-level ACL overrides options: refused"

echo "== 2. configure_plesk_acl puts our IP in the ACL"
eval "$(sed -n '/^configure_plesk_acl() {/,/^}/p' "$SRC")"
out=$(configure_plesk_acl "127.0.0.1"); rc=$?
[ "$rc" -eq 0 ] && ok "configure_plesk_acl succeeds" || fail "configure_plesk_acl: $out"
transfers 127.0.0.1 && ok "our IP transfers" || fail "still refused after the ACL change"
transfers 127.0.0.2 && fail "an address outside the ACL transfers" || ok "other addresses stay refused"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
