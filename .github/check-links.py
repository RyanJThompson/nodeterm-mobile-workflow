#!/usr/bin/env python3
"""Every relative markdown link points at a file that exists.

Cheap, and it catches the failure this repo is most prone to: a doc that tells
an agent to read a file that was renamed. An agent following a dead link
improvises, which is exactly what the docs exist to prevent.
"""

import os
import re
import sys

LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

bad = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".github")]
    for name in filenames:
        if not name.endswith(".md"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for target in LINK.findall(text):
            if target.startswith(("http://", "https://", "#", "mailto:")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            resolved = os.path.normpath(os.path.join(dirpath, target))
            if not os.path.exists(resolved):
                bad.append(f"{os.path.relpath(path, ROOT)} -> {target}")

for entry in bad:
    print("broken link: " + entry)
sys.exit(1 if bad else 0)
