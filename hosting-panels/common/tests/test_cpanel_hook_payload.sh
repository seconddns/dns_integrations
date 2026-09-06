#!/bin/bash
# cPanel nests the event under "data", and Accounts::Remove carries only the
# user — reading the top level finds nothing and the hook exits silently.
# Run: bash hosting-panels/common/tests/test_cpanel_hook_payload.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# the parser as each hook embeds it, so the test cannot drift from the code
extract() { # $1 hook file, $2 json
    local py
    py=$(sed -n '/^import sys, json/,/^    pass$/p' "$1")
    [ -n "$py" ] || { echo "PARSER-NOT-FOUND"; return; }
    printf '%s' "$2" | python3 -c "$py"
}

REAL='{"context":{"category":"Whostmgr","event":"Accounts::Create","stage":"post"},"hook":{"exectype":"script"},"data":{"user":"acct","domain":"real.example.com","plan":"default"}}'

for hook in domain_create domain_delete; do
    f="$HERE/../../cpanel/$hook.sh"
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
    echo "== $hook"
    [ "$(extract "$f" "$REAL")" = "real.example.com" ] \
        && ok "reads domain from data" || fail "got '$(extract "$f" "$REAL")'"
    [ "$(extract "$f" '{"domain":"flat.example.com"}')" = "flat.example.com" ] \
        && ok "still reads a top-level domain" || fail "flat shape broken"
    [ -z "$(extract "$f" 'not json')" ] && ok "malformed input yields nothing" || fail "malformed input"
done

echo "== an addon domain arrives as newdomain"
[ "$(extract "$HERE/../../cpanel/domain_create.sh" '{"data":{"newdomain":"addon.example.com"}}')" = "addon.example.com" ] \
    && ok "reads newdomain from data" || fail "newdomain not read"

echo "== Accounts::Remove carries only the user"
DEL="$HERE/../../cpanel/domain_delete.sh"
REMOVE='{"context":{"event":"Accounts::Remove","stage":"pre"},"data":{"user":"acct","killdns":1}}'

mkdir -p "$TMP/userdata/acct"
cat > "$TMP/userdata/acct/main" <<'YAML'
---
addon_domains:
  addon.example.com: addon.main.example.com
main_domain: main.example.com
parked_domains:
  - parked.example.com
sub_domains: []
YAML
got=$(SECONDDNS_CPANEL_ROOT="$TMP" extract "$DEL" "$REMOVE" | sort | tr '\n' ' ')
[ "$got" = "addon.example.com main.example.com parked.example.com " ] \
    && ok "every domain of the account is listed" || fail "got '$got'"

FB="$(mktemp -d)"; mkdir -p "$FB/users"
printf 'DNS=fallback.example.com\nUSER=acct\n' > "$FB/users/acct"
got=$(SECONDDNS_CPANEL_ROOT="$FB" extract "$DEL" "$REMOVE" | tr '\n' ' ')
[ "$got" = "fallback.example.com " ] && ok "falls back to the user file" || fail "fallback got '$got'"
rm -rf "$FB"

got=$(SECONDDNS_CPANEL_ROOT="$TMP" extract "$DEL" '{"data":{"user":"nosuch"}}')
[ -z "$got" ] && ok "unknown user yields nothing" || fail "invented '$got'"

got=$(SECONDDNS_CPANEL_ROOT="$TMP" extract "$DEL" "$REAL")
[ "$got" = "real.example.com" ] && ok "an explicit domain still wins" || fail "explicit domain got '$got'"

echo "== park sends new_domain"
PARK='{"context":{"category":"Whostmgr","event":"Domain::park","stage":"post"},"data":{"target_domain":"main.example.com","new_domain":"addon.example.com","user":"acct"}}'
[ "$(extract "$HERE/../../cpanel/domain_create.sh" "$PARK")" = "addon.example.com" ] \
    && ok "create reads new_domain, not the target" || fail "create got '$(extract "$HERE/../../cpanel/domain_create.sh" "$PARK")'"
[ "$(extract "$DEL" "$PARK")" = "addon.example.com" ] \
    && ok "delete reads new_domain, not the target" || fail "delete got '$(extract "$DEL" "$PARK")'"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
