# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
"""Shared bits for the SecondDNS command-line tools (config, API, panel domains)."""
import configparser
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

DOMAIN_BIN = os.environ.get("SECONDDNS_DOMAIN_BIN", "/usr/local/bin/seconddns-domain")
QUEUE_BIN = os.environ.get("SECONDDNS_QUEUE_BIN", "/usr/local/bin/seconddns-queue")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(_NoRedirect)


def api(cfg, method, path, payload=None, ua="SecondDNS-Tools/1.0"):
    """Returns (status, body). status 0 = no usable answer."""
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(cfg["api_url"] + path, data=body, method=method, headers={
        "X-API-Key": cfg["api_key"], "Content-Type": "application/json", "User-Agent": ua})
    try:
        with OPENER.open(req, timeout=15) as r:
            raw = r.read()
            try:
                return r.status, (json.loads(raw) if raw else {})
            except ValueError:
                return 0, {"error": f"HTTP {r.status} with non-JSON body"}
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return 0, {"error": f"network: {e}"}


def load_config(path):
    cp = configparser.ConfigParser()
    cp.read(path)
    cfg = {
        "api_url": cp.get("seconddns", "api_url", fallback="").strip().rstrip("/"),
        "api_key": cp.get("seconddns", "api_key", fallback="").strip(),
        "master_ip": cp.get("seconddns", "master_ip", fallback="").strip(),
    }
    if not cfg["api_url"] or not cfg["api_key"]:
        sys.exit(f"api_url/api_key missing in {path}")
    return cfg


def canonical(name):
    """(canonical_name, None) or (None, reason) via seconddns-domain."""
    r = subprocess.run([DOMAIN_BIN, name], capture_output=True, text=True)
    return (r.stdout.strip(), None) if r.returncode == 0 else (None, r.stderr.strip() or "refused")


class PanelError(SystemExit):
    pass


def _run(cmd, timeout=30, env=None):
    """stdout of a command, or None when it is missing, fails or hangs."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=isinstance(cmd, str),
                           env=env)
        return r.stdout if r.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def _cyberpanel_db():
    """(user, password, name) of CyberPanel's MariaDB from its Django settings."""
    import re
    try:
        text = open("/usr/local/CyberCP/CyberCP/settings.py").read()
    except OSError:
        return None
    m = re.search(r"'default'\s*:\s*\{(.*?)\}", text, re.S)
    if not m:
        return None
    block = m.group(1)

    # CyberPanel writes os.getenv('DB_NAME', 'cyberpanel') here, not a bare
    # literal; the environment wins when it is set, as it does for Django.
    def field(k, env):
        f = re.search(r"'%s'\s*:\s*'([^']*)'" % k, block)
        if f:
            return os.environ.get(env) or f.group(1)
        g = re.search(r"'%s'\s*:\s*os\.getenv\(\s*'([^']*)'\s*(?:,\s*'([^']*)')?\s*\)" % k, block)
        if g:
            return os.environ.get(g.group(1)) or g.group(2)
        return None

    return field("USER", "DB_USER"), field("PASSWORD", "DB_PASSWORD"), field("NAME", "DB_NAME")


def panel_zones():
    """Names of the DNS zones this panel's DNS server masters — the same set
    the hooks act on. A panel that cannot be read is an error, never an
    empty list: an empty list would make every zone look stale."""
    override = os.environ.get("SECONDDNS_PANEL_ZONES_CMD")  # tests
    if override:
        out = _run(override)
        source = "SECONDDNS_PANEL_ZONES_CMD"
    elif os.path.exists("/usr/sbin/plesk") or os.path.exists("/usr/local/psa"):
        out = _run(["plesk", "db", "-Ne", "SELECT name FROM dns_zone WHERE type='master'"])
        source = "Plesk dns_zone"
    elif os.path.exists("/usr/local/cpanel"):
        raw = _run(["whmapi1", "--output=json", "listzones"])
        out = None
        if raw:
            try:
                out = "\n".join(z["domain"] for z in json.loads(raw)["data"]["zone"])
            except (ValueError, KeyError, TypeError):
                out = None
        source = "whmapi1 listzones"
    elif os.path.isdir("/usr/local/directadmin"):
        try:
            out = "\n".join(f[:-3] for f in os.listdir("/var/named") if f.endswith(".db"))
        except OSError:
            out = None
        source = "/var/named/*.db"
    elif os.path.isdir("/usr/local/CyberCP"):
        creds = _cyberpanel_db()
        out = None
        if creds and all(creds):
            user, pw, name = creds
            # password via the environment, not argv: argv is visible in ps
            out = _run(["mysql", "-u", user, name, "-Ne", "SELECT name FROM domains"],
                       env={**os.environ, "MYSQL_PWD": pw})
        source = "CyberPanel PowerDNS domains"
    else:
        raise PanelError("could not detect the panel; use --from-file")
    zones = [l.strip() for l in (out or "").splitlines() if l.strip()]
    if out is None:
        raise PanelError(f"could not read the zone list ({source}); refusing to continue")
    if not zones:
        raise PanelError(f"the panel reports no DNS zones ({source}); refusing to continue")
    return zones


def zones_from_file(path):
    zones = [l.strip() for l in open(path) if l.strip() and not l.startswith("#")]
    if not zones:
        raise PanelError(f"{path} is empty; refusing to continue")
    return zones


def canonical_targets(raw_names):
    """Canonical, de-duplicated names plus [(raw, reason)] for the refused ones."""
    targets, skipped = [], []
    for name in raw_names:
        name = (name or "").strip()
        if not name:
            continue
        canon, why = canonical(name)
        if canon is None:
            skipped.append((name, why))
        elif canon not in targets:
            targets.append(canon)
    return targets, skipped


def enqueue(op, domain, master_ip=""):
    """Hand an operation to the local queue. Returns True when accepted."""
    r = subprocess.run([QUEUE_BIN, "enqueue", op, domain, master_ip], capture_output=True, text=True)
    return r.returncode == 0
