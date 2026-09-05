#!/bin/bash
# Tests for _cyberpanel_db(): reading CyberPanel's database settings.
# Run: bash hosting-panels/common/tests/test_cyberpanel_db.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
COMMON="$HERE/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/CyberCP"

probe() { # $1 = settings body, rest = environment assignments
    cat > "$WORK/CyberCP/settings.py"
    shift 0
    env "$@" python3 - "$COMMON" "$WORK/CyberCP/settings.py" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("c", sys.argv[1] + "/seconddns_common.py")
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
src = sys.argv[2]
real = open
c.open = lambda p, *a, **k: real(src) if p.endswith("settings.py") else real(p, *a, **k)
print("|".join(str(v) for v in (c._cyberpanel_db() or ("None",)*3)))
PY
}

echo "== the literal form, as older CyberPanel wrote it"
got=$(probe <<'SET'
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'cyberpanel',
        'USER': 'cyberpanel',
        'PASSWORD': 'literal-secret',
    },
}
SET
)
[ "$got" = "cyberpanel|literal-secret|cyberpanel" ] && ok "literal settings read" || fail "literal settings: got '$got'"

# The form current CyberPanel writes. Reading it as a literal finds nothing,
# which left every field empty and the zone list unreadable.
echo "== the os.getenv form, with defaults"
got=$(probe <<'SET'
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.getenv('DB_NAME', 'cyberpanel'),
        'USER': os.getenv('DB_USER', 'cyberpanel'),
        'PASSWORD': os.getenv('DB_PASSWORD', 'default-secret'),
    },
}
SET
)
[ "$got" = "cyberpanel|default-secret|cyberpanel" ] && ok "os.getenv defaults read" || fail "os.getenv defaults: got '$got'"

echo "== the environment wins over the default, as it does for Django"
got=$(probe DB_PASSWORD=from-environment <<'SET'
DATABASES = {
    'default': {
        'NAME': os.getenv('DB_NAME', 'cyberpanel'),
        'USER': os.getenv('DB_USER', 'cyberpanel'),
        'PASSWORD': os.getenv('DB_PASSWORD', 'default-secret'),
    },
}
SET
)
[ "$got" = "cyberpanel|from-environment|cyberpanel" ] && ok "environment overrides the default" || fail "environment override: got '$got'"

echo
echo "passed: $PASS, failed: $FAIL"
[ $FAIL -eq 0 ]
