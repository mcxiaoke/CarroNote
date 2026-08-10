#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""i18n audit for safenotes (easy_localization, English-as-key, flat JSON).

Checks:
  1. Keys used via `'...'.tr()` in lib/ that are missing from a translation file.
  2. Keys present in a translation file but no longer referenced in code.
  3. Keys whose zh-CN value is byte-identical to the English key (untranslated).
  4. Key-set drift between en-US.json and zh-CN.json.

Usage:
    python scripts/i18n_audit.py                 # report only
    python scripts/i18n_audit.py --fill          # add missing keys to en-US/zh-CN
    python scripts/i18n_audit.py --locales all   # audit every locale file
"""

import argparse
import io
import json
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")
TRANS = os.path.join(ROOT, "assets", "translations")
PRIMARY = ["en-US", "zh-CN"]

# A Dart string literal (single or double quoted, no interpolation support needed
# because interpolated strings can't be static translation keys anyway).
_LIT = r"(?:'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")"
# One or more adjacent literals (Dart implicit concatenation) followed by `.tr(`.
_TR_CALL = re.compile(
    r"(?<![\w.$])((?:%s)(?:\s*(?:%s))*)\s*\.tr\(" % (_LIT, _LIT), re.S
)
_LIT_RE = re.compile(_LIT, re.S)

_UNESCAPE = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "'": "'",
    '"': '"',
    "\\": "\\",
    "$": "$",
}


def _unquote(chunk):
    """Join adjacent Dart literals into the effective runtime string."""
    out = []
    for part in _LIT_RE.findall(chunk):
        body = part[1:-1]
        i = 0
        while i < len(body):
            ch = body[i]
            if ch == "\\" and i + 1 < len(body):
                nxt = body[i + 1]
                out.append(_UNESCAPE.get(nxt, "\\" + nxt))
                i += 2
            else:
                out.append(ch)
                i += 1
    return "".join(out)


def scan_code():
    """Return {key: [file:line, ...]} for every literal `.tr()` call under lib/."""
    found = {}
    for root, _dirs, files in os.walk(LIB):
        for name in files:
            if not name.endswith(".dart"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            src = io.open(path, encoding="utf-8").read()
            for m in _TR_CALL.finditer(src):
                key = _unquote(m.group(1))
                line = src.count("\n", 0, m.start()) + 1
                found.setdefault(key, []).append("%s:%d" % (rel, line))
    return found


def load(locale):
    path = os.path.join(TRANS, locale + ".json")
    with io.open(path, encoding="utf-8") as fh:
        return json.load(fh)


def save(locale, data):
    path = os.path.join(TRANS, locale + ".json")
    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=4, sort_keys=False)
        fh.write("\n")


def all_locales():
    return sorted(
        f[:-5] for f in os.listdir(TRANS) if f.endswith(".json")
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fill", action="store_true",
                    help="write missing keys into en-US/zh-CN (value = key)")
    ap.add_argument("--locales", default="primary",
                    help="'primary' (en-US,zh-CN), 'all', or comma list")
    args = ap.parse_args()

    if args.locales == "primary":
        locales = PRIMARY
    elif args.locales == "all":
        locales = all_locales()
    else:
        locales = [x.strip() for x in args.locales.split(",") if x.strip()]

    code = scan_code()
    # Interpolated literals can never match a static key -- report separately.
    interpolated = {k: v for k, v in code.items() if "$" in k}
    code = {k: v for k, v in code.items() if "$" not in k}
    print("code: %d distinct .tr() keys under lib/" % len(code))

    exit_code = 0
    if interpolated:
        print("\n== interpolated .tr() keys (BROKEN, use namedArgs instead): %d"
              % len(interpolated))
        for k in sorted(interpolated):
            print("  INTERPOLATED %r  <- %s" % (k, interpolated[k][0]))
        exit_code = 1

    for loc in locales:
        data = load(loc)
        missing = [k for k in code if k not in data]
        unused = [k for k in data if k not in code]
        print("\n== %s: %d keys | missing %d | unreferenced %d"
              % (loc, len(data), len(missing), len(unused)))
        for k in sorted(missing):
            print("  MISSING %r  <- %s" % (k, code[k][0]))
            exit_code = 1
        for k in sorted(unused):
            print("  UNUSED  %r" % k)
        if loc == "zh-CN":
            same = [k for k, v in data.items() if v == k]
            if same:
                print("  -- %d zh-CN values identical to key (untranslated):"
                      % len(same))
                for k in sorted(same):
                    print("     UNTRANSLATED %r" % k)
                exit_code = 1

    # key-set drift between the two primary locales
    if set(PRIMARY) <= set(locales):
        en, zh = load("en-US"), load("zh-CN")
        only_en = sorted(set(en) - set(zh))
        only_zh = sorted(set(zh) - set(en))
        if only_en or only_zh:
            print("\n== drift en-US vs zh-CN")
            for k in only_en:
                print("  ONLY-EN %r" % k)
            for k in only_zh:
                print("  ONLY-ZH %r" % k)
            exit_code = 1
        else:
            print("\n== drift en-US vs zh-CN: none")

    if args.fill:
        for loc in PRIMARY:
            data = load(loc)
            added = [k for k in code if k not in data]
            if not added:
                continue
            for k in added:
                data[k] = k
            save(loc, data)
            print("\nfilled %d placeholder keys into %s.json" % (len(added), loc))
        exit_code = 0

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
