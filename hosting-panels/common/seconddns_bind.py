# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
"""BIND side of TSIG: key file, include and allow-transfer in the options block.

Only text edits; seconddns-tsig does the backup, named-checkconf, reload and rollback.
"""
import re

KEY_FILE_NAME = "seconddns-tsig.key"
MARK = "// seconddns-tsig"


def _code_mask(text, keep_strings=False):
    """Same length as text, with comments (and strings, unless keep_strings) blanked, so
    braces and keywords are only matched in real configuration."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = text.find('"', i + 1)
            j = n if j < 0 else j
            if not keep_strings:
                for k in range(i + 1, j):
                    out[k] = " "
            i = j + 1
        elif text.startswith("//", i) or c == "#":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if text[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def _options_span(text, mask):
    """(start, end) of the inside of the top-level options { ... } block, or None."""
    depth = 0
    for m in re.finditer(r"[{}]|\boptions\s*\{", mask):
        tok = m.group(0)
        if tok.startswith("options") and depth == 0:
            start = m.end()
            d = 1
            for k in range(start, len(mask)):
                if mask[k] == "{":
                    d += 1
                elif mask[k] == "}":
                    d -= 1
                    if d == 0:
                        return start, k
            return None
        depth += 1 if tok == "{" else -1 if tok == "}" else 0
    return None


def key_block(name, algorithm, secret):
    return f'key "{name}" {{\n    algorithm {algorithm};\n    secret "{secret}";\n}};\n'


def _edit_list(text, mask, a, b, add, drop, none_literal):
    """Edit the entries between a and b (the inside of a { ... } list): remove those in
    drop (and a none placeholder once something real is added), append those in add
    that are missing. Other entries and comments stay where they are."""
    body, body_mask = text[a:b], mask[a:b]
    values = _code_mask(text, keep_strings=True)[a:b]
    # entries end at ';' in real config; text in between (comments, spacing) is kept
    entries, pos = [], 0
    for i, ch in enumerate(body_mask):
        if ch == ";":
            entries.append((pos, i + 1, values[pos:i].strip()))
            pos = i + 1
    tail = body[pos:]
    gone = {d.strip('"') for d in drop}
    present = [v for _, _, v in entries if v.strip('"') not in gone]
    added = [x for x in add if x not in present]
    if len(present) + len(added) > 1:
        gone.add("none")
    kept = "".join(body[p:q] for p, q, v in entries if v.strip('"') not in gone)
    if not kept.strip() and not added:
        new = f" {none_literal}; "
    elif "\n" in body:
        # one entry per line: new ones go on their own lines, after a trailing comment
        indent = next((ln[:len(ln) - len(ln.lstrip())] for ln in body.splitlines() if ln.strip()), "    ")
        first, nl, rest = tail.partition("\n")
        new = kept + first + "".join(f"\n{indent}{x};" for x in added) + (nl + rest if nl else "\n")
    else:
        new = " " + " ".join(part for part in [kept.strip(), " ".join(f"{x};" for x in added)] if part) + " "
    return text[:a] + new + text[b:]


def edit_allow_transfer(text, add=(), drop=()):
    """allow-transfer in the options block, edited with _edit_list. Returns (new_text, error)."""
    mask = _code_mask(text)
    span = _options_span(text, mask)
    if not span:
        return text, "no options { } block"
    s, e = span
    m = re.search(r"\ballow-transfer\s*\{([^{}]*)\}\s*;", mask[s:e])
    if not m:
        if not add:
            return text, None
        return text[:e] + "    allow-transfer { " + "; ".join(add) + "; };\n" + text[e:], None
    return _edit_list(text, mask, s + m.start(1), s + m.end(1), add, drop, '"none"'), None


def key_entry(name):
    return f'key "{name}"'


def has_key_in_allow_transfer(text, key_name):
    mask = _code_mask(text)
    span = _options_span(text, mask)
    if not span:
        return False
    s, e = span
    m = re.search(r"\ballow-transfer\s*\{([^{}]*)\}\s*;", mask[s:e])
    return bool(m) and f'key "{key_name}"' in text[s + m.start(1):s + m.end(1)]


def include_line(key_file):
    return f'include "{key_file}"; {MARK}\n'


def add_include(text, key_file):
    if include_line(key_file).strip() in text:
        return text
    return text.rstrip("\n") + "\n" + include_line(key_file)


def remove_include(text, key_file):
    return "".join(l for l in text.splitlines(True) if l.strip() != include_line(key_file).strip())


def zone_level_transfers(text, ips):
    """allow-transfer statements outside the options block that name one of our IPs:
    zone-level entries (cPanel's WHM "Additional zone configuration") override options."""
    mask = _code_mask(text)
    span = _options_span(text, mask)
    found = 0
    for m in re.finditer(r"\ballow-transfer\s*\{([^{}]*)\}\s*;", mask):
        if span and span[0] <= m.start() < span[1]:
            continue
        body = _code_mask(text, keep_strings=True)[m.start(1):m.end(1)]
        if any(ip in [x.strip().strip('"') for x in body.split(";")] for ip in ips):
            found += 1
    return found


def allow_transfer_entries(text):
    """Entries of the options-level allow-transfer, as written (quotes kept), or []."""
    mask = _code_mask(text)
    span = _options_span(text, mask)
    if not span:
        return []
    s, e = span
    m = re.search(r"\ballow-transfer\s*\{([^{}]*)\}\s*;", mask[s:e])
    if not m:
        return []
    values = _code_mask(text, keep_strings=True)[s + m.start(1):s + m.end(1)]
    return [x.strip() for x in values.split(";") if x.strip()]


# --- Plesk: zones carry allow-transfer { common-allow-transfer; } ---------------------

PLESK_ACL = "common-allow-transfer"
PLESK_CUSTOM_MARK = "PLEASE ADD YOUR CUSTOM DIRECTIVES BELOW THIS LINE"


def _acl_body(text, mask):
    m = re.search(r"\bacl\s+" + re.escape(PLESK_ACL) + r"\s*\{([^{}]*)\}\s*;", mask)
    return (m.start(1), m.end(1)) if m else None


def edit_acl(text, add=(), drop=()):
    """acl common-allow-transfer, which Plesk includes in every zone. Returns (new_text, error)."""
    mask = _code_mask(text)
    span = _acl_body(text, mask)
    if not span:
        return text, f"no acl {PLESK_ACL} {{ }} block"
    return _edit_list(text, mask, span[0], span[1], add, drop, "none"), None


def acl_entries(text):
    mask = _code_mask(text)
    span = _acl_body(text, mask)
    if not span:
        return []
    values = _code_mask(text, keep_strings=True)[span[0]:span[1]]
    return [x.strip() for x in values.split(";") if x.strip()]


def add_include_custom(text, key_file):
    """The include goes into Plesk's custom directives block, which Plesk keeps when it
    rewrites named.conf. Returns (new_text, error)."""
    line = include_line(key_file)
    if line.strip() in text:
        return text, None
    out, done = [], False
    for ln in text.splitlines(True):
        out.append(ln)
        if not done and PLESK_CUSTOM_MARK in ln:
            out.append(line)
            done = True
    if not done:
        return text, f"no \"{PLESK_CUSTOM_MARK}\" line in named.conf"
    return "".join(out), None
