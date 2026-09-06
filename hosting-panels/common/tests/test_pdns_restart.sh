#!/bin/bash
# PowerDNS rereads zones on a reload but not allow-axfr-ips, so a reload after
# editing pdns.conf leaves AXFR refused and every zone stuck pending.
# Run: bash hosting-panels/common/tests/test_pdns_restart.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PANELS="cpanel cyberpanel directadmin plesk"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

checked=0
for panel in $PANELS; do
    src="$HERE/../../$panel/install.sh"
    [ -f "$src" ] || { echo "missing $src"; exit 1; }
    grep -q "pdns" "$src" || continue
    checked=$((checked+1))
    echo "== $panel"

    if grep -qE "systemctl reload pdns|pdns_control reload|service pdns reload" "$src"; then
        fail "reloads PowerDNS after editing pdns.conf"
    else
        ok "no PowerDNS reload"
    fi

    # editing the config at all obliges a restart
    if grep -q 'allow-axfr-ips' "$src"; then
        grep -qE "(systemctl|service) .*pdns.* restart|systemctl restart pdns" "$src" \
            && ok "restarts PowerDNS" || fail "edits allow-axfr-ips without restarting"
        # a restart that does not come back must not be reported as success:
        # the config is restored and the operator told, not a cheerful "[+]"
        grep -q 'did not come back' "$src" \
            && ok "reports a PowerDNS that stayed down" || fail "a dead PowerDNS would be reported as success"
        grep -qE 'cp "[^"]*(BAK|bak)[^"]*" "\$PDNS_CONF"' "$src" \
            && ok "restores the config on a failed restart" || fail "no rollback on a failed restart"
    fi
done

# a lower bound: a rename that stops matching the installers fails here
[ "$checked" -ge 3 ] && ok "checked $checked installers" || fail "only $checked installers matched"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
