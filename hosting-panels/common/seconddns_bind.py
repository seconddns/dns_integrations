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


def edit_allow_transfer(text, add=(), drop=()):
    """allow-transfer in the options block: remove the entries in drop (and a "none"
    placeholder once something real is added), append the entries in add that are
    missing. Other entries and comments stay where they are. Returns (new_text, error)."""
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
    a, b = s + m.start(1), s + m.end(1)
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
        new = ' "none"; '
    elif "\n" in body:
        # one entry per line: new ones go on their own lines, after a trailing comment
        indent = next((ln[:len(ln) - len(ln.lstrip())] for ln in body.splitlines() if ln.strip()), "    ")
        first, nl, rest = tail.partition("\n")
        new = kept + first + "".join(f"\n{indent}{x};" for x in added) + (nl + rest if nl else "\n")
    else:
        new = " " + " ".join(part for part in [kept.strip(), " ".join(f"{x};" for x in added)] if part) + " "
    return text[:a] + new + text[b:], None


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
