#!/bin/bash
# Two rules: a name that will not canonicalise is refused, and a website check
# that cannot answer keeps the zone.
# Run: bash hosting-panels/common/tests/test_cyberpanel_plugin.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/../../cyberpanel/seconddns.py"
python3 - "$PLUGIN" <<'PY'
import importlib.util, sys, types

spec = importlib.util.spec_from_file_location("sdplugin", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0
def ok(t):
    global passed; passed += 1; print("  ok:", t)
def fail(t):
    global failed; failed += 1; print("  FAIL:", t)

class Req:  # the handlers only pass it to _extract_domain, which we replace
    pass

m._extract_domain = lambda request, response=None: RAW
# Truthy on purpose: an empty config returns before remove_zone, so the row
# would pass without proving anything.
m.load_config = lambda: {"api_key": "k", "api_url": "https://example.invalid"}
removed = []
added = []
m.remove_zone = lambda cfg, d: removed.append(d)
m.add_zone = lambda cfg, d: added.append(d)
m._set_zone_master = lambda d: None

print("== a name that will not canonicalise is refused on every path")
RAW = "тест.укр"
m.canonical_domain = lambda d: (None, "cannot encode")
for name, fn in (("zone created", m.on_zone_created),
                 ("website deleted", m.on_website_deleted),
                 ("dns zone deleted", m.on_dns_zone_deleted)):
    removed.clear(); added.clear()
    fn(None, request=Req(), response=None)
    if not removed and not added:
        ok(f"{name}: nothing acted on")
    else:
        fail(f"{name}: acted on {removed or added}")

print("== a website check that cannot answer keeps the zone")
RAW = "example.com"
m.canonical_domain = lambda d: (d, None)

class Boom:
    class objects:
        @staticmethod
        def filter(**kw):
            raise RuntimeError("database is gone")
sys.modules["websiteFunctions"] = types.ModuleType("websiteFunctions")
mod = types.ModuleType("websiteFunctions.models"); mod.Websites = Boom
sys.modules["websiteFunctions.models"] = mod

if m._domain_has_website("example.com"):
    ok("unanswerable check reports the domain as still in use")
else:
    fail("unanswerable check reported the domain as free — the zone would be removed")

removed.clear()
m.on_dns_zone_deleted(None, request=Req(), response=None)
if not removed:
    ok("zone kept when the website check cannot answer")
else:
    fail(f"zone removed on an unanswerable check: {removed}")

print()
print(f"passed: {passed}, failed: {failed}")
sys.exit(1 if failed else 0)
PY
