#!/usr/bin/env python3
"""
CyberPanel integration for secondary DNS service.

Works in two modes:
  1. Django signal plugin — hooks into CyberPanel's postWebsiteCreation/Deletion signals
  2. CLI — manual add/remove/sync/list commands

CLI usage:
  seconddns add <domain>       — Register domain as secondary zone
  seconddns remove <domain>    — Remove domain from secondary DNS
  seconddns sync               — Sync all CyberPanel domains with secondary DNS
  seconddns list               — List zones on secondary DNS

Configuration: /etc/seconddns.conf
"""

import json
import os
import sys
import socket
import subprocess
import urllib.request
import urllib.error
import configparser
import logging

CONFIG_FILE = "/etc/seconddns.conf"
LOG_FILE = "/var/log/seconddns.log"

logger = logging.getLogger("seconddns")


def setup_logging():
    handler = logging.FileHandler(LOG_FILE)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    logger.addHandler(logging.StreamHandler())
    logger.setLevel(logging.INFO)


def load_config():
    config = {}

    if os.path.exists(CONFIG_FILE):
        cp = configparser.ConfigParser()
        cp.read(CONFIG_FILE, encoding="utf-8")
        if cp.has_section("seconddns"):
            config["api_url"] = cp.get("seconddns", "api_url", fallback="")
            config["api_key"] = cp.get("seconddns", "api_key", fallback="")
            config["master_ip"] = cp.get("seconddns", "master_ip", fallback="")

    config["api_url"] = os.environ.get("SECONDDNS_API_URL", config.get("api_url", "")).rstrip("/")
    config["api_key"] = os.environ.get("SECONDDNS_API_KEY", config.get("api_key", ""))
    config["master_ip"] = os.environ.get("SECONDDNS_MASTER_IP", config.get("master_ip", ""))

    if not config["api_url"] or not config["api_key"]:
        logger.error("SECONDDNS_API_URL and SECONDDNS_API_KEY are required. Set them in %s", CONFIG_FILE)
        return None

    if not config["master_ip"]:
        config["master_ip"] = detect_master_ip()

    return config


def detect_master_ip():
    try:
        resp = urllib.request.urlopen("https://api.ipify.org", timeout=5)
        return resp.read().decode().strip()
    except Exception:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            logger.error("Could not detect master IP. Set SECONDDNS_MASTER_IP.")
            return None


def api_request(config, method, path, data=None):
    url = f"{config['api_url']}{path}"
    headers = {
        "X-API-Key": config["api_key"],
        "Content-Type": "application/json",
        "User-Agent": "SecondDNS-CyberPanel/1.0",
    }
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        resp = urllib.request.urlopen(req, timeout=15)
        return json.loads(resp.read().decode()) if resp.status != 204 else None
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        try:
            error_data = json.loads(error_body)
        except Exception:
            error_data = {"error": error_body}
        return {"_status": e.code, **error_data}


def list_zones(config):
    result = api_request(config, "GET", "/api/zones")
    if isinstance(result, list):
        return result
    logger.error("Error listing zones: %s", result)
    return []


def add_zone(config, domain):
    domain = domain.lower().rstrip(".")
    if not config or not config.get("master_ip"):
        return False
    logger.info("[+] Adding zone: %s (master: %s)", domain, config["master_ip"])
    result = api_request(config, "POST", "/api/zones", {
        "name": domain,
        "masterIp": config["master_ip"],
    })
    if result and result.get("_status"):
        status = result["_status"]
        error = result.get("error", "Unknown error")
        if status == 409:
            logger.info("    Already exists, skipping.")
        else:
            logger.error("    Error (%s): %s", status, error)
        return False
    logger.info("    Done.")
    return True


def find_zone_by_name(config, domain):
    result = api_request(config, "GET", f"/api/zones/by-name/{domain}")
    if result and not result.get("_status"):
        return result
    return None


def remove_zone(config, domain):
    domain = domain.lower().rstrip(".")
    zone = find_zone_by_name(config, domain)
    if not zone:
        logger.info("[-] Zone %s not found on secondary DNS.", domain)
        return False
    logger.info("[-] Removing zone: %s", domain)
    result = api_request(config, "DELETE", f"/api/zones/{zone['id']}")
    if result and result.get("_status"):
        logger.error("    Error: %s", result.get("error", "Unknown"))
        return False
    logger.info("    Done.")
    return True


def get_cyberpanel_domains():
    domains = []

    # Method 1: CyberPanel CLI
    try:
        result = subprocess.run(
            ["cyberpanel", "listWebsitesJson"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if isinstance(data, list):
                for site in data:
                    name = site.get("domain") or site.get("domainName")
                    if name:
                        domains.append(name.lower().rstrip("."))
                return domains
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass

    # Method 2: CyberPanel SQLite database
    try:
        result = subprocess.run(
            ["sqlite3", "/usr/local/CyberCP/database.sqlite3",
             "SELECT domain FROM websiteFunctions_websites;"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                if line.strip():
                    domains.append(line.strip().lower().rstrip("."))
            return domains
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return domains


def sync(config):
    local_domains = set(get_cyberpanel_domains())
    remote_zones = list_zones(config)
    remote_domains = {z["name"].rstrip("."): z for z in remote_zones}

    logger.info("Local domains: %d, Remote zones: %d", len(local_domains), len(remote_domains))

    added = 0
    for domain in sorted(local_domains - set(remote_domains.keys())):
        if add_zone(config, domain):
            added += 1

    removed = 0
    for domain in sorted(set(remote_domains.keys()) - local_domains):
        if remove_zone(config, domain):
            removed += 1

    logger.info("Sync complete: +%d added, -%d removed", added, removed)


def cmd_list(config):
    zones = list_zones(config)
    if not zones:
        print("No zones found.")
        return
    print(f"{'Name':<40} {'Status':<10} {'Master IP':<18} {'Last Sync'}")
    print("-" * 90)
    for z in zones:
        print(f"{z['name']:<40} {z.get('status','?'):<10} {z.get('masterIp','?'):<18} {z.get('lastSync','never')}")


# --- Django signal handlers (used when loaded as CyberPanel plugin) ---

def _extract_domain(request, response=None):
    """Extract domain name from CyberPanel request/response."""
    keys = ("domainName", "domain", "websiteName", "zoneDomain", "selectedZone")

    # 1. Try request.body (JSON) — CyberPanel uses json.loads(request.body) in views
    if hasattr(request, "body") and request.body:
        try:
            data = json.loads(request.body)
            for k in keys:
                v = data.get(k)
                if v:
                    return v
        except (json.JSONDecodeError, AttributeError, ValueError):
            pass

    # 2. Try POST form data
    if hasattr(request, "POST"):
        for k in keys:
            v = request.POST.get(k)
            if v:
                return v

    # 3. Try GET params
    if hasattr(request, "GET"):
        for k in keys:
            v = request.GET.get(k)
            if v:
                return v

    # 4. Try response (coreResult) — may be HttpResponse with JSON body
    if response and hasattr(response, "content"):
        try:
            data = json.loads(response.content)
            for k in keys:
                v = data.get(k) if isinstance(data, dict) else None
                if v:
                    return v
        except (json.JSONDecodeError, AttributeError, ValueError):
            pass

    return ""


def _set_zone_master(domain):
    """Change zone type from NATIVE to MASTER so AXFR works."""
    try:
        from django.db import connection
        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE domains SET type='MASTER' WHERE name=%s AND type='NATIVE'",
                [domain]
            )
            if cursor.rowcount > 0:
                logger.info("Zone %s: type changed NATIVE -> MASTER", domain)
    except Exception as e:
        logger.warning("Could not update zone type for %s: %s", domain, e)


def on_zone_created(sender, **kwargs):
    """Signal receiver for DNS zone creation."""
    try:
        request = kwargs.get("request")
        response = kwargs.get("response")
        if not request:
            return 200
        domain = _extract_domain(request, response)
        if not domain:
            return 200
        logger.info("Zone created: %s", domain)
        _set_zone_master(domain)
        config = load_config()
        if config:
            add_zone(config, domain)
    except Exception as e:
        logger.error("Signal handler error (create): %s", e)
    return 200


def _domain_has_website(domain):
    """Check if domain belongs to an existing website in CyberPanel."""
    try:
        from websiteFunctions.models import Websites
        return Websites.objects.filter(domain=domain).exists()
    except Exception:
        return False


def on_website_deleted(sender, **kwargs):
    """Website deletion — always remove from secondary DNS."""
    try:
        request = kwargs.get("request")
        response = kwargs.get("response")
        if not request:
            return 200
        domain = _extract_domain(request, response)
        if not domain:
            return 200
        logger.info("Website deleted: %s", domain)
        config = load_config()
        if config:
            remove_zone(config, domain)
    except Exception as e:
        logger.error("Signal handler error (website delete): %s", e)
    return 200


def on_dns_zone_deleted(sender, **kwargs):
    """DNS zone deletion — only remove if domain has no website."""
    try:
        request = kwargs.get("request")
        response = kwargs.get("response")
        if not request:
            return 200
        domain = _extract_domain(request, response)
        if not domain:
            return 200
        if _domain_has_website(domain):
            logger.info("DNS zone deleted but website exists for %s — keeping on secondary", domain)
            return 200
        logger.info("DNS zone deleted: %s", domain)
        config = load_config()
        if config:
            remove_zone(config, domain)
    except Exception as e:
        logger.error("Signal handler error (dns zone delete): %s", e)
    return 200


_signals_registered = False

def register_signals():
    """Connect to CyberPanel signals — both website and DNS zone hooks."""
    global _signals_registered
    if _signals_registered:
        return
    hooks = []
    try:
        from websiteFunctions.signals import postWebsiteCreation, postWebsiteDeletion
        postWebsiteCreation.connect(on_zone_created, dispatch_uid="seconddns_website_create")
        postWebsiteDeletion.connect(on_website_deleted, dispatch_uid="seconddns_website_delete")
        hooks.append("website")
    except ImportError:
        pass
    try:
        from dns.signals import postZoneCreation, postSubmitZoneDeletion
        postZoneCreation.connect(on_zone_created, dispatch_uid="seconddns_dns_create")
        postSubmitZoneDeletion.connect(on_dns_zone_deleted, dispatch_uid="seconddns_dns_delete")
        hooks.append("dns zone")
    except ImportError:
        pass
    if hooks:
        _signals_registered = True
        logger.info("SecondDNS signals registered (%s hooks).", " + ".join(hooks))
    else:
        logger.warning("CyberPanel signals not available.")


SIGNAL_BLOCK = """
# SecondDNS integration — register domain create/delete signals
try:
    from plogical.seconddns_plugin import register_signals, setup_logging
    setup_logging()
    register_signals()
except Exception as e:
    import logging
    logging.getLogger("seconddns").error("Failed to register signals: %s", e)
"""

SIGNAL_MARKER = "seconddns_plugin"
CYBERPANEL_DIR = "/usr/local/CyberCP"


def _clean_signal_blocks(filepath):
    """Remove all SecondDNS signal blocks from a file."""
    import re
    if not os.path.isfile(filepath):
        return
    with open(filepath, encoding="utf-8") as f:
        content = f.read()
    if SIGNAL_MARKER not in content:
        return
    cleaned = re.sub(
        r'\n*# SecondDNS integration[^\n]*\ntry:\n\s+from plogical\.seconddns_plugin.*?except[^\n]*\n\s+import logging\n\s+logging\.getLogger.*?\n',
        '', content, flags=re.DOTALL)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(cleaned)
    logger.info("Cleaned old signal blocks from %s", filepath)


def ensure_signals():
    """Ensure exactly one signal registration block exists in wsgi.py.
    Safe to run repeatedly — cleans duplicates, adds if missing.
    Called by systemd after lscpd restart to survive CyberPanel updates."""
    wsgi = os.path.join(CYBERPANEL_DIR, "CyberCP", "wsgi.py")
    init = os.path.join(CYBERPANEL_DIR, "CyberCP", "__init__.py")
    ready = os.path.join(CYBERPANEL_DIR, "CyberCP", "ready.py")

    # Clean all locations
    for f in [wsgi, init, ready]:
        _clean_signal_blocks(f)

    # Add to wsgi.py (preferred target)
    target = wsgi
    if not os.path.isfile(target):
        target = init if os.path.isfile(init) else ready
    if not os.path.isfile(target):
        logger.error("No suitable CyberPanel entry point found")
        print("[!] No wsgi.py, __init__.py, or ready.py found")
        return

    with open(target, "a", encoding="utf-8") as f:
        f.write(SIGNAL_BLOCK)
    logger.info("Signal block added to %s", target)
    print(f"[+] Signals ensured in {target}")


# --- CLI ---

def main():
    setup_logging()

    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    config = load_config()
    if not config:
        sys.exit(1)

    if cmd == "add" and len(sys.argv) >= 3:
        add_zone(config, sys.argv[2])
    elif cmd == "remove" and len(sys.argv) >= 3:
        remove_zone(config, sys.argv[2])
    elif cmd == "sync":
        sync(config)
    elif cmd == "list":
        cmd_list(config)
    elif cmd == "ensure-signals":
        ensure_signals()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
