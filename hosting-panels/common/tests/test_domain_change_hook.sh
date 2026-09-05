#!/bin/bash
# Tests for the DirectAdmin rename hook: a rename must queue the removal of the
# old name and the creation of the new one, in that order.
# Run: bash hosting-panels/common/tests/test_domain_change_hook.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../../directadmin/domain_change_post.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

command -v idn2 >/dev/null || { echo "idn2 required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/seconddns.conf" <<CONF
[seconddns]
api_url = https://example.invalid
api_key = test-key
master_ip = 192.0.2.10
CONF

# stand-in for seconddns-queue: records the calls instead of delivering them
cat > "$TMP/queue" <<'Q'
#!/bin/bash
echo "$*" >> "$CALLS"
exit 0
Q
chmod +x "$TMP/queue"

run_hook() { # $1 old, $2 new
    : > "$TMP/calls"; : > "$TMP/log"
    env SECONDDNS_CONFIG="$TMP/seconddns.conf" \
        SECONDDNS_LOG="$TMP/log" \
        SECONDDNS_DOMAIN_BIN="$HERE/../seconddns-domain" \
        SECONDDNS_QUEUE_BIN="$TMP/queue" \
        CALLS="$TMP/calls" \
        domain="$1" newdomain="$2" username=admin \
        bash "$HOOK"
}

echo "== a plain rename"
run_hook old.example.com new.example.com
n=$(wc -l < "$TMP/calls" | tr -d ' ')
[ "$n" -eq 2 ] && ok "two operations queued" || fail "queued $n operation(s), want 2"
first=$(sed -n 1p "$TMP/calls"); second=$(sed -n 2p "$TMP/calls")
[ "$first" = "enqueue delete old.example.com" ] \
    && ok "first: delete of the old name" || fail "first was '$first'"
[ "$second" = "enqueue create new.example.com 192.0.2.10" ] \
    && ok "second: create of the new name" || fail "second was '$second'"
grep -q "Zone renamed: old.example.com -> new.example.com" "$TMP/log" \
    && ok "rename logged" || fail "rename not logged"

echo "== an IDN new name is canonicalised"
run_hook old.example.com ПРИКЛАД.УКР
grep -q "enqueue create xn--80aikifvh.xn--j1amh 192.0.2.10" "$TMP/calls" \
    && ok "new name queued in punycode" || fail "not punycode: $(cat "$TMP/calls")"

echo "== an unusable new name"
run_hook old.example.com "not a domain"
grep -q "enqueue create" "$TMP/calls" \
    && fail "create queued for an unusable name" || ok "no create queued"
grep -q "enqueue delete old.example.com" "$TMP/calls" \
    && ok "old name still removed" || fail "old name not removed"
grep -qi "refused" "$TMP/log" \
    && ok "refusal logged" || fail "refusal not logged: $(cat "$TMP/log")"

echo "== no new name at all"
run_hook old.example.com ""
[ ! -s "$TMP/calls" ] && ok "nothing queued" || fail "queued: $(cat "$TMP/calls")"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
