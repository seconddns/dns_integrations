#!/bin/bash
# The cPanel rename hook: WHM sends the new main domain and keeps the old one
# on disk, so the pair has to be assembled from both.
# Run: bash hosting-panels/common/tests/test_cpanel_rename.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../../cpanel/domain_rename.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

command -v idn2 >/dev/null || { echo "idn2 required"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/userdata/acct"
printf -- '---\nmain_domain: old.example.com\naddon_domains: {}\nparked_domains: []\n' > "$TMP/userdata/acct/main"
cat > "$TMP/conf" <<CONF
[seconddns]
api_url = http://127.0.0.1:1
api_key = test-key
master_ip = 192.0.2.10
CONF
printf '#!/bin/bash\necho "$*" >> "$CALLS"\n' > "$TMP/queue"; chmod +x "$TMP/queue"

run() { : > "$TMP/calls"; : > "$TMP/log"
    printf '%s' "$1" | env SECONDDNS_CONFIG="$TMP/conf" SECONDDNS_LOG="$TMP/log" \
        SECONDDNS_CPANEL_ROOT="$TMP" SECONDDNS_QUEUE_BIN="$TMP/queue" CALLS="$TMP/calls" \
        SECONDDNS_DOMAIN_BIN="$HERE/../seconddns-domain" \
        bash "$HOOK" >/dev/null 2>&1; }

echo "== the main domain changes"
run '{"context":{"event":"Accounts::Modify","stage":"pre"},"data":{"user":"acct","domain":"new.example.com"}}'
n=$(wc -l < "$TMP/calls" | tr -d ' ')
[ "$n" -eq 2 ] && ok "two operations queued" || fail "queued $n, want 2: $(cat "$TMP/calls")"
[ "$(sed -n 1p "$TMP/calls")" = "enqueue delete old.example.com 192.0.2.10" ] \
    && ok "the old name goes first" || fail "first was '$(sed -n 1p "$TMP/calls")'"
[ "$(sed -n 2p "$TMP/calls")" = "enqueue create new.example.com 192.0.2.10" ] \
    && ok "the new name follows" || fail "second was '$(sed -n 2p "$TMP/calls")'"
grep -q "Zone renamed: old.example.com -> new.example.com" "$TMP/log" \
    && ok "rename logged" || fail "not logged: $(cat "$TMP/log")"

echo "== the same domain: WHM fires this on every account change"
run '{"data":{"user":"acct","domain":"old.example.com"}}'
[ ! -s "$TMP/calls" ] && ok "an unchanged domain queues nothing" || fail "queued: $(cat "$TMP/calls")"

echo "== a quota change carries no domain"
run '{"data":{"user":"acct","QUOTA":"500"}}'
[ ! -s "$TMP/calls" ] && ok "no domain, nothing queued" || fail "queued: $(cat "$TMP/calls")"

echo "== an unknown account"
run '{"data":{"user":"nosuch","domain":"new.example.com"}}'
[ ! -s "$TMP/calls" ] && ok "unknown account queues nothing" || fail "queued: $(cat "$TMP/calls")"

echo "== an IDN new name is canonicalised"
run '{"data":{"user":"acct","domain":"ПРИКЛАД.УКР"}}'
grep -q "enqueue create xn--80aikifvh.xn--j1amh 192.0.2.10" "$TMP/calls" \
    && ok "queued in punycode" || fail "not punycode: $(cat "$TMP/calls")"
grep -q "enqueue delete old.example.com" "$TMP/calls" \
    && ok "old name still removed" || fail "old name missing"

echo "== an unusable new name still removes the old one"
run '{"data":{"user":"acct","domain":"not a domain"}}'
grep -q "enqueue delete old.example.com" "$TMP/calls" && ok "old name removed" || fail "old name missing"
grep -q "enqueue create" "$TMP/calls" && fail "queued a create for an unusable name" || ok "no create queued"
grep -qi "refused" "$TMP/log" && ok "refusal logged" || fail "refusal not logged"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
