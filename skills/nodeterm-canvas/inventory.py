#!/usr/bin/env python3
"""What is open on the nodeterm canvas, and which of it is still alive.

Three sources, because no one of them is enough. `nodeterm.sh list` is the only
authority on what EXISTS, and it answers with id, kind and title and nothing
else. Size, URL and ropes live in the project's own canvas file. Whether a web
node still SHOWS anything is a question only the thing behind the URL can
answer — a stream whose server has been killed leaves a node that looks exactly
like a working one: same title, same size, same place. That is why counting
nodes is not the same as counting devices, and why DEAD is worth printing.

Liveness for a simulator mirror is checked by looking for a JPEG start-of-image
marker in the stream body, not merely by seeing whether the port answers. A
serve-sim page whose device has gone will still return 200 for the page.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

SHIM = os.path.expanduser(
    "~/Library/Application Support/node-terminal/canvas-control/nodeterm.sh"
)
ROW = re.compile(r"(\S+)\s+\[(\w+)\]\s*(.*)")
SOI = b"\xff\xd8\xff"


def canvas_nodes():
    """[(id, kind, title)] for the active project, newest last."""
    done = subprocess.run(
        ["sh", SHIM, "list"], capture_output=True, text=True, timeout=20
    )
    if done.returncode != 0:
        raise SystemExit((done.stderr or "nodeterm did not answer").strip())
    rows = []
    for line in done.stdout.splitlines():
        match = ROW.match(line.strip())
        if match:
            rows.append((match.group(1), match.group(2), match.group(3).strip()))
    return rows


def project_file():
    """The canvas file for whichever project this directory is in, or None.

    Worktree-aware: `.nodeterm/` lives beside the MAIN checkout, so a session
    inside a git worktree finds nothing by walking up and has to ask git where
    the common dir is. Falls back to the default project.
    """
    here = os.path.abspath(os.getcwd())
    while True:
        candidate = os.path.join(here, ".nodeterm", "project.json")
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(here)
        if parent == here:
            break
        here = parent

    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    except OSError:
        common = ""
    if common:
        candidate = os.path.join(os.path.dirname(common), ".nodeterm", "project.json")
        if os.path.exists(candidate):
            return candidate

    fallback = os.path.expanduser("~/.nodeterm/project.json")
    return fallback if os.path.exists(fallback) else None


def details():
    """id -> the fields only the canvas file carries."""
    path = project_file()
    if not path:
        return {}, {}, None
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return {}, {}, path
    by_id = {node.get("id"): node for node in doc.get("nodes", [])}
    roped = {}
    for rope in doc.get("ropes", []):
        roped.setdefault(rope.get("target"), []).append(rope.get("source"))
    return by_id, roped, path


FIRST = 16384  # enough for a JPEG start-of-image if this is a stream at all
CAP = 524288  # serve-sim's page is ~420 KB and names the udid two thirds in


def fetch(url, timeout=3):
    """The head of the body, or None if nothing answered.

    Read in two bites. A stream announces itself in the first few kilobytes, so
    stop there rather than pulling half a megabyte off an endless MJPEG feed;
    an HTML page has to be read much further, because serve-sim's bundle does
    not mention the device until ~140 KB in and a short read reports a live
    stream as dead.

    Reading a stream always ends in a timeout eventually, so a timeout after
    bytes have arrived is a success here — judge by what came back, not by how
    the read ended.
    """
    if not url:
        return None
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            head = response.read(FIRST)
            if SOI in head or len(head) < FIRST:
                return head
            try:
                return head + response.read(CAP - FIRST)
            except Exception:
                return head
    except urllib.error.HTTPError:
        return b""  # something is serving, just not this
    except Exception:
        return None


def liveness(url):
    """'live' / 'DEAD' / 'page only' for a web node.

    'live' means a JPEG start-of-image marker actually arrived. Nothing weaker
    will do: a serve-sim page keeps returning 200 long after its device has
    gone, which is exactly the failure this is here to catch.
    """
    body = fetch(url)
    if body is None:
        return "DEAD"
    if SOI in body:
        return "live"

    # An HTML page. serve-sim builds its stream URL client-side, but the udid
    # appears literally in the bundle as /helper/<udid>/…, so the stream can be
    # reconstructed. Try any .mjpeg path the page mentions first, for servers
    # that are not serve-sim.
    text = body.decode("utf-8", "replace")
    base = url.rstrip("/")
    candidates = [
        f"{base}/helper/{udid}/stream.mjpeg"
        for udid in dict.fromkeys(re.findall(r"/helper/([0-9A-Fa-f-]{36})/", text))
    ]
    # Absolute paths only — the bundle also contains fragments like
    # "3101/helper/…/stream.mjpeg" that would join into nonsense.
    candidates += [
        base + path for path in dict.fromkeys(re.findall(r"/[\w./-]*\.mjpeg", text))
    ]

    for probe in list(dict.fromkeys(candidates))[:6]:
        frame = fetch(probe)
        if frame and SOI in frame:
            return "live"

    return "page only"


def booted():
    done = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "booted", "-j"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if done.returncode != 0:
        return []
    try:
        groups = json.loads(done.stdout)["devices"].values()
    except (ValueError, KeyError):
        return []
    return [device["name"] for entries in groups for device in entries]


def main():
    if not os.environ.get("NODETERM_CANVAS_CONTROL") or not os.path.exists(SHIM):
        raise SystemExit("Not a nodeterm session — there is no canvas to look at.")

    nodes = canvas_nodes()
    by_id, roped, path = details()

    kinds = {}
    for _, kind, _ in nodes:
        kinds[kind] = kinds.get(kind, 0) + 1
    print(
        ", ".join(
            f"{count} {kind}{'' if count == 1 else 's'}"
            for kind, count in sorted(kinds.items())
        )
    )
    if not path:
        print("(no canvas file found — sizes, URLs and ropes are unavailable)")
    print()

    here = os.environ.get("NODETERM_NODE_ID", "")
    for node_id, kind, title in nodes:
        node = by_id.get(node_id, {})
        size = node.get("size") or {}
        shape = (
            f'{round(size["width"])}x{round(size["height"])}'
            if size.get("width") and size.get("height")
            else ""
        )
        url = node.get("url", "")
        mark = f"  {liveness(url)}" if kind == "web" and url else ""
        mine = "  ← this terminal" if node_id == here else ""
        ties = [t for t in roped.get(node_id, []) if t != node_id]
        rope = f"  roped to {', '.join(ties)}" if ties and kind != "terminal" else ""
        print(f"{node_id:20} {kind:9} {shape:9} {title}{mine}")
        if url or rope:
            print(f"{'':20} {url}{mark}{rope}")

    up = booted()
    print()
    print("booted simulators: " + (", ".join(sorted(up)) if up else "none"))


if __name__ == "__main__":
    main()
