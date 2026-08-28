#!/bin/bash
# Tests for seconddns-domain: lowercase -> IDNA2008 Punycode -> LDH.
# Run: bash hosting-panels/common/tests/test_domain.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../seconddns-domain"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

command -v idn2 >/dev/null || { echo "idn2 required"; exit 1; }

echo "== accepted, canonical form"
while IFS='|' read -r in want; do
    got=$("$BIN" "$in" 2>&1); rc=$?
    [ $rc -eq 0 ] && [ "$got" = "$want" ] && ok "$in -> $want" || fail "$in (rc=$rc, got '$got', want '$want')"
done <<'EOF'
example.com|example.com
Example.COM|example.com
MiXeD.Example.ORG|mixed.example.org
xn--e1afmkfd.xn--p1ai|xn--e1afmkfd.xn--p1ai
ПРИКЛАД.УКР|xn--80aikifvh.xn--j1amh
тест.example.com|xn--e1aybc.example.com
日本.jp|xn--wgv71a.jp
a-b.example.com|a-b.example.com
1.2.3.4.in-addr.arpa|1.2.3.4.in-addr.arpa
EOF

echo "== refused, with a reason"
while IFS='|' read -r in want; do
    err=$("$BIN" "$in" 2>&1 >/dev/null); rc=$?
    [ $rc -eq 1 ] && [[ "$err" == *"$want"* ]] && ok "'$in' -> $err" || fail "'$in' (rc=$rc, stderr '$err', want *$want*)"
done <<'EOF'
|empty name
tld|no dot
example.com.|empty label
.example.com|empty label
a..b|empty label
under_score.example.com|outside a-z 0-9 -
o'brien.example.com|outside a-z 0-9 -
 lead.example.com|outside a-z 0-9 -
trail.example.com |outside a-z 0-9 -
-lead.example.com|hyphen
trail-.example.com|hyphen
🙂.example.com|IDNA2008 rejected
a‌b.example.com|IDNA2008 rejected
EOF
long=$(printf 'a%.0s' $(seq 64)).com
err=$("$BIN" "$long" 2>&1 >/dev/null); [[ "$err" == *"63"* ]] && ok "64-char label refused" || fail "64-char label ($err)"
long=$(for i in $(seq 1 5); do printf '%s.' "$(printf 'a%.0s' $(seq 50))"; done)com
err=$("$BIN" "$long" 2>&1 >/dev/null); [[ "$err" == *"253"* ]] && ok "254-char name refused" || fail "254-char name ($err)"

echo "== sourced as a library"
( SECONDDNS_DOMAIN_LIB=1 . "$BIN"
  canonical_domain "ПРИКЛАД.УКР" && [ "$DOMAIN" = "xn--80aikifvh.xn--j1amh" ] && exit 0; exit 1 ) \
    && ok "canonical_domain sets DOMAIN" || fail "canonical_domain sets DOMAIN"
( SECONDDNS_DOMAIN_LIB=1 . "$BIN"
  canonical_domain "🙂.com" && exit 1; [ -n "$DOMAIN_ERROR" ] && [ -z "$DOMAIN" ] ) \
    && ok "refusal sets DOMAIN_ERROR, clears DOMAIN" || fail "refusal sets DOMAIN_ERROR"
( SECONDDNS_DOMAIN_LIB=1 . "$BIN"
  T=$(mktemp -d); ln -s "$(command -v tr)" "$T/tr"; PATH="$T"
  canonical_domain "ПРИКЛАД.УКР" && exit 1; [[ "$DOMAIN_ERROR" == *"idn2 not installed"* ]] ) \
    && ok "missing idn2 is a refusal, not a pass-through" || fail "missing idn2 handling"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
