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


def panel_domains():
    """Domain names hosted on this panel, raw as the panel reports them."""
    def run(cmd):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            return r.stdout if r.returncode == 0 else ""
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return ""
    if os.path.exists("/usr/sbin/plesk") or os.path.exists("/usr/local/psa"):
        return [l.strip() for l in run(["plesk", "bin", "site", "--list"]).splitlines() if l.strip()]
    if os.path.exists("/etc/userdomains"):  # cPanel: "domain: user"
        return [l.split(":", 1)[0].strip() for l in open("/etc/userdomains") if ":" in l and not l.startswith("*")]
    if os.path.isdir("/etc/virtual"):  # DirectAdmin
        return [d for d in os.listdir("/etc/virtual")
                if d not in ("default", "majordomo") and os.path.isfile(f"/etc/virtual/{d}/domains")]
    out = run(["cyberpanel", "listWebsitesJson"])
    if out:
        try:
            return [s.get("domain") or s.get("domainName") for s in json.loads(out) if s]
        except ValueError:
            pass
    sys.exit("could not detect the panel; use --from-file")


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
