#!/usr/bin/env python3
"""Compile the Python embedded inside the shell scripts.

A lot of the real logic here lives in `python3 -c '…'` blocks and `<<'PY'`
heredocs — every canvas edit, every JSON probe, the runtime guard. `bash -n`
does not look inside them, so a typo there survives every check and fails at
run time, on a user's machine, halfway through seating a device.

Single-quoted blocks cannot contain a single quote (the shell would end them
there), so the naive regex is also the correct one.
"""

import ast
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INLINE = re.compile(r"python3\s+-c\s+'([^']*)'", re.S)
HEREDOC = re.compile(r"<<\s*'(\w+)'\n(.*?)\n\1\b", re.S)

files = []
for pattern in ("install.sh", "scripts/*.sh", "scripts/lib/*.sh", "scripts/hooks/*.sh"):
    files.extend(glob.glob(os.path.join(ROOT, pattern)))

checked = 0
bad = 0
for path in sorted(files):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    blocks = [(m.start(), m.group(1)) for m in INLINE.finditer(text)]
    for match in HEREDOC.finditer(text):
        body = match.group(2)
        # Only the heredocs that are actually Python — the others are banners.
        if re.search(r"^\s*(import|from)\s", body, re.M):
            blocks.append((match.start(), body))

    for offset, source in blocks:
        line = text.count("\n", 0, offset) + 1
        checked += 1
        try:
            ast.parse(source)
        except SyntaxError as error:
            bad += 1
            rel = os.path.relpath(path, ROOT)
            print(f"{rel}:{line}: embedded python: {error}")

print(f"{checked} embedded python block(s) checked, {bad} bad")
sys.exit(1 if bad else 0)
