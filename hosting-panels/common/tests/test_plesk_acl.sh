#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# configure_plesk_acl, as the Plesk installer defines it, against a stand-in for the plesk
# CLI that behaves like Plesk 18.0.81 (checked on a live server): the transfer ACL lives in
# misc.DNS_Allow_Transfer*, and server_dns -u -add-acl adds to it and rewrites
# acl common-allow-transfer in named.conf at once.
# Requires: bash, awk. No network.
#
# Usage: ./test_plesk_acl.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../plesk/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"; }

# stand-in plesk: $TMP/acl is misc.DNS_Allow_Transfer*, one IP per line
cat > "$TMP/plesk" <<'EOF'
#!/bin/bash
T="$(dirname "$0")"
case "$1 $2" in
  "db -Ne") cat "$T/acl" 2>/dev/null ;;
  "bin server_dns")
    echo "$*" >> "$T/calls"
    [ -e "$T/add-fails" ] && exit 1
    tr ',' '\n' <<< "${5}" >> "$T/acl"
    [ -e "$T/no-regen" ] && exit 0
    { echo 'options { directory "/var"; };'
      printf 'acl common-allow-transfer {\n'; sed 's/^/\t/; s/$/;/' "$T/acl"; printf '};\n'
      echo 'zone "a.example" { type master; file "a.example"; allow-transfer { common-allow-transfer; }; };'
    } > "$T/named.conf" ;;
esac
EOF
chmod +x "$TMP/plesk"
export SECONDDNS_PLESK="$TMP/plesk" SECONDDNS_PLESK_NAMED_CONF="$TMP/named.conf"

reset() {
    rm -f "$TMP/acl" "$TMP/calls" "$TMP/add-fails" "$TMP/no-regen"
    printf 'options { directory "/var"; };\nacl common-allow-transfer {\n\tnone;\n};\n' > "$TMP/named.conf"
}
acl() { awk '/^acl common-allow-transfer/,/^};/' "$TMP/named.conf" | grep -v -e acl -e '};' | tr -d '\t;' | tr '\n' ' '; }

grep -q '^configure_plesk_acl() {' "$SRC" || { echo "configure_plesk_acl not found in $SRC"; exit 1; }
eval "$(sed -n '/^configure_plesk_acl() {/,/^}/p' "$SRC")"

echo "== 1. empty ACL: both addresses added in one call, named.conf has them"
reset
out=$(configure_plesk_acl "203.0.113.9,2001:db8::9"); rc=$?
assert_eq "$rc" 0 "returns 0"
assert_eq "$(cat "$TMP/calls")" "bin server_dns -u -add-acl 203.0.113.9,2001:db8::9" "one add-acl call with both IPs"
assert_eq "$(acl)" "203.0.113.9 2001:db8::9 " "acl common-allow-transfer lists both"

echo "== 2. second run: nothing added"
: > "$TMP/calls"
out=$(configure_plesk_acl "203.0.113.9,2001:db8::9"); rc=$?
assert_eq "$rc" 0 "returns 0"
assert_eq "$(wc -l < "$TMP/calls" | tr -d ' ')" 0 "no add-acl call"
echo "$out" | grep -q "already allows" && ok "says it is already there" || fail "output: $out"

echo "== 3. one address present: only the other is added"
reset
echo "203.0.113.9" > "$TMP/acl"
configure_plesk_acl "203.0.113.9,2001:db8::9" > /dev/null
assert_eq "$(cat "$TMP/calls")" "bin server_dns -u -add-acl 2001:db8::9" "only the missing IP"

echo "== 4. a similar address is not taken for ours"
reset
echo "203.0.113.90" > "$TMP/acl"
configure_plesk_acl "203.0.113.9" > /dev/null
assert_eq "$(cat "$TMP/calls")" "bin server_dns -u -add-acl 203.0.113.9" "203.0.113.90 does not count as 203.0.113.9"

echo "== 5. named.conf not rewritten: reported, not claimed"
reset
touch "$TMP/no-regen"
out=$(configure_plesk_acl "203.0.113.9"); rc=$?
[ "$rc" -ne 0 ] && ok "returns non-zero" || fail "claimed success with the ACL still none"
echo "$out" | grep -q "not in acl common-allow-transfer" && ok "names the problem" || fail "output: $out"
echo "$out" | grep -q "Transfer Restrictions Template" && ok "says where to add it" || fail "no hint: $out"

echo "== 6. add-acl fails: reported"
reset
touch "$TMP/add-fails"
out=$(configure_plesk_acl "203.0.113.9"); rc=$?
[ "$rc" -ne 0 ] && ok "returns non-zero" || fail "claimed success after a failed add-acl"
assert_eq "$(acl)" "none " "ACL untouched"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
