#!/bin/bash
# Tests for valid_ip() in every panel installer: a value that is not an address
# must be refused, because an accepted one installs cleanly and then fails every
# zone with an opaque HTTP 400 from the API.
# Run: bash hosting-panels/common/tests/test_valid_ip.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PANELS="cyberpanel cpanel directadmin plesk"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

for panel in $PANELS; do
    src="$HERE/../../$panel/install.sh"
    [ -f "$src" ] || { echo "missing $src"; exit 1; }
    # pull the function out of the installer and run it on its own
    fn=$(sed -n '/^valid_ip() {/,/^}/p' "$src")
    [ -n "$fn" ] || { echo "$panel: valid_ip not found"; exit 1; }
    eval "$fn"

    echo "== $panel"
    while IFS='|' read -r in want; do
        if valid_ip "$in"; then got=accept; else got=reject; fi
        [ "$got" = "$want" ] && ok "'$in' -> $want" || fail "'$in' -> $got, want $want"
    done <<'CASES'
135.125.191.39|accept
0.0.0.0|accept
255.255.255.255|accept
2001:db8::1|accept
::1|accept
y|reject
Y|reject
|reject
1.2.3|reject
1.2.3.4.5|reject
1.2.3.256|reject
1.2.3.999|reject
127.0.0.1abc|reject
localhost|reject
1.2.3.-1|reject
 1.2.3.4|reject
example.com|reject
CASES
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
