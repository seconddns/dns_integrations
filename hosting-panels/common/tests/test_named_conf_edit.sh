#!/bin/bash
# cPanel ships a named.conf with views; inserting before every "};" lands inside
# the logging block and named stops parsing the file.
# Run: bash hosting-panels/common/tests/test_named_conf_edit.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

checked=0
for panel in cpanel plesk directadmin cyberpanel; do
    src="$HERE/../../$panel/install.sh"
    [ -f "$src" ] || { echo "missing $src"; exit 1; }
    grep -q "named.conf\|NAMED_CONF\|NAMED_OPTIONS" "$src" || continue
    grep -q "allow-transfer" "$src" || continue
    checked=$((checked+1))
    echo "== $panel"

    # an insert that is not bounded by the options block hits every closing brace
    if grep -qE '^\s*sed -i "/\^\[\[:space:\]\]\*\};/i' "$src"; then
        fail "inserts before every closing brace"
    else
        ok "insert is bounded"
    fi
    grep -qE 'sed -i "/\^options\[\[:space:\]\]\*\{/,/\^\};/' "$src" \
        && ok "bounded to the options block" || fail "no options-bounded insert"

    # the ACL cPanel ships is quoted
    grep -q 'none"\\?;//g' "$src" \
        && ok 'removes a quoted "none"' || fail 'only removes an unquoted none'

    grep -q "named-checkconf" "$src" && ok "verifies the config" || fail "reloads without verifying"
    grep -q "did not validate" "$src" \
        && ok "reports a config named cannot parse" || fail "would report success over a broken config"
    grep -qE 'cp "\$NAMED_BAK"' "$src" \
        && ok "restores the backup on a bad config" || fail "no rollback"
done

# a lower bound: a rename that stops matching the installers fails here
[ "$checked" -ge 3 ] && ok "checked $checked installers" || fail "only $checked matched"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
