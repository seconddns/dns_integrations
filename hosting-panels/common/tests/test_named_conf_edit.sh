#!/bin/bash
# cPanel ships a named.conf with views; inserting before every "};" lands inside
# the logging block and named stops parsing the file.
# Run: bash hosting-panels/common/tests/test_named_conf_edit.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$HERE/fixtures/cpanel-named.conf"
IP="203.0.113.9"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

[ -f "$FIXTURE" ] || { echo "missing fixture $FIXTURE"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# section boundaries of a block that starts at column 0
block() { # $1 file, $2 block name -> prints the block
    awk -v b="$2" '$0 ~ "^"b { inb=1 } inb { print } inb && /^};/ { exit }' "$1"
}

checked=0
for panel in cpanel plesk directadmin; do
    src="$HERE/../../$panel/install.sh"
    [ -f "$src" ] || { echo "missing $src"; exit 1; }
    grep -q "configure_named_axfr" "$src" || { echo "$panel: no configure_named_axfr"; exit 1; }
    checked=$((checked+1))
    echo "== $panel, applied to the real cPanel named.conf"

    # the function as the installer defines it, run against a copy of the fixture
    eval "$(sed -n '/^configure_named_axfr() {/,/^}/p' "$src")"
    f="$TMP/$panel.conf"; cp "$FIXTURE" "$f"
    configure_named_axfr "$f" "$IP"

    n=$(grep -c "allow-transfer.*$IP" "$f")
    [ "$n" -eq 1 ] && ok "one allow-transfer with the secondary" || fail "allow-transfer written $n times"
    n=$(grep -c "also-notify.*$IP" "$f")
    [ "$n" -eq 1 ] && ok "one also-notify with the secondary" || fail "also-notify written $n times"

    # both must be inside options, and nowhere else
    opts=$(block "$f" "options")
    echo "$opts" | grep -q "allow-transfer.*$IP" && ok "allow-transfer is inside options" || fail "allow-transfer outside options"
    echo "$opts" | grep -q "also-notify.*$IP" && ok "also-notify is inside options" || fail "also-notify outside options"
    block "$f" "logging" | grep -qE "allow-transfer|also-notify" \
        && fail "wrote into the logging block" || ok "logging untouched"
    awk '/^view/ { inv=1 } inv && /also-notify|allow-transfer/ { found=1 } END { exit !found }' "$f" \
        && fail "wrote into a view" || ok "views untouched"

    grep -qE 'allow-transfer[^}]*"?none"?;' "$f" && fail '"none" survived beside the address' || ok '"none" replaced'

    opened=$(tr -cd '{' < "$f" | wc -c | tr -d ' ')
    closed=$(tr -cd '}' < "$f" | wc -c | tr -d ' ')
    [ "$opened" -eq "$closed" ] \
        && ok "braces balanced ($opened)" || fail "braces unbalanced: $opened open, $closed closed"

    if command -v named-checkconf >/dev/null 2>&1; then
        named-checkconf "$f" >/dev/null 2>&1 && ok "named-checkconf accepts it" || fail "named-checkconf rejects it"
    fi
done

echo "== cheap greps: every installer verifies before reporting"
for panel in cpanel plesk directadmin; do
    src="$HERE/../../$panel/install.sh"
    grep -qE 'if named-checkconf' "$src" && ok "$panel gates the reload on named-checkconf" || fail "$panel reloads without verifying"
    grep -q "did not validate" "$src" && ok "$panel reports a broken config" || fail "$panel would claim success"
    grep -qE 'cp "\$NAMED_BAK"' "$src" && ok "$panel restores the backup" || fail "$panel has no rollback"
done

[ "$checked" -ge 3 ] && ok "checked $checked installers" || fail "only $checked matched"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
