#!/bin/bash
# cPanel nests the event under "data"; reading the top level finds nothing and
# the hook exits silently, which is how account creation went unnoticed.
# Run: bash hosting-panels/common/tests/test_cpanel_hook_payload.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# the parser as the hooks embed it, extracted so the test cannot drift from them
extract() { # $1 = hook file, $2 = json
    local py
    py=$(sed -n '/^import sys, json$/,/^    pass$/p' "$1")
    [ -n "$py" ] || { echo "PARSER-NOT-FOUND"; return; }
    printf '%s' "$2" | python3 -c "$py"
}

for hook in domain_create domain_delete; do
    f="$HERE/../../cpanel/$hook.sh"
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
    echo "== $hook"

    # what WHM actually sends on Accounts::Create, trimmed to shape
    real='{"context":{"category":"Whostmgr","event":"Accounts::Create","stage":"post"},"hook":{"stage":"post","exectype":"script"},"data":{"user":"acct","domain":"real.example.com","plan":"default"}}'
    [ "$(extract "$f" "$real")" = "real.example.com" ] \
        && ok "reads domain from data" || fail "got '$(extract "$f" "$real")'"

    # the top-level shape must keep working
    flat='{"domain":"flat.example.com"}'
    [ "$(extract "$f" "$flat")" = "flat.example.com" ] \
        && ok "still reads a top-level domain" || fail "flat shape broken"

    # context carries an unrelated "domain"-free payload: nothing to do
    empty='{"context":{"event":"Accounts::Create"},"hook":{},"data":{"user":"acct","plan":"default"}}'
    [ -z "$(extract "$f" "$empty")" ] \
        && ok "no domain in data yields nothing" || fail "invented a name"

    [ -z "$(extract "$f" 'not json')" ] && ok "malformed input yields nothing" || fail "malformed input"
done

echo "== an addon domain arrives as newdomain"
f="$HERE/../../cpanel/domain_create.sh"
addon='{"context":{"event":"Api2::AddonDomain::addaddon"},"data":{"newdomain":"addon.example.com","user":"acct"}}'
[ "$(extract "$f" "$addon")" = "addon.example.com" ] \
    && ok "reads newdomain from data" || fail "got '$(extract "$f" "$addon")'"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
