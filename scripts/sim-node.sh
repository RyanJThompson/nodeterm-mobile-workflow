#!/bin/bash
# Puts a live, touchable simulator on the nodeterm canvas, beside this terminal.
#
#   scripts/mobile/sim-node.sh <udid>          # a simbroker-claimed device
#   scripts/mobile/sim-node.sh                 # the project default (SIM_NAME)
#   SIM_UDID=<udid> scripts/mobile/sim-node.sh # the same, by environment
#   scripts/mobile/sim-node.sh --close [udid]  # take that view back down
#
# Streams the device with serve-sim and seats the URL it prints as a web node.
# Outside nodeterm it prints the URL and stops — the stream is useful either
# way; only the seating needs a canvas.
#
# CLAIMING IS DELIBERATELY NOT DONE HERE. A claim wants to live exactly as long
# as the session holding it, and the simbroker MCP server renews and releases
# one automatically where a script would have to guess a TTL up front. So the
# caller claims, and passes the udid in. With no udid this falls back to the
# project default, which is right for a single session and wrong the moment
# there are two.

# Read before mobile-env.sh states its defaults, so a size passed on the command
# line can be told apart from the configured one.
ASKED_W="${SIM_NODE_W:-}"
ASKED_H="${SIM_NODE_H:-}"

source "$(dirname "${BASH_SOURCE[0]}")/lib/mobile-env.sh"

SHIM="$NODETERM_SHIM"
PROJECT_JSON="$CANVAS_JSON"

CLOSING=""
if [ "${1:-}" = "--close" ]; then
  CLOSING="yes"
  shift
fi

# An explicit argument beats SIM_UDID, which beats the default device. sim_udid
# vets whichever it is, so a device on the wrong runtime is refused here rather
# than mirrored happily for an hour before anyone notices.
if [ -n "${1:-}" ]; then
  SIM_UDID="$1"
fi
export SIM_UDID="${SIM_UDID:-}"
UDID="$(sim_udid)"
NAME="$(sim_name "$UDID")"
TITLE="$NAME — simulator"

# ── Taking it down ────────────────────────────────────────────────────────────
#
# The node goes two ways, in this order:
#
#   1. By editing the canvas file, which is silent. `close` asks the user to
#      confirm every time and takes one confirmation at a time, and that gate is
#      worth keeping where it guards a terminal with a live session in it.
#   2. Through the control API, when the file is not ours to write.
#
# Either route refuses to remove anything that is not a *web* node carrying this
# device's own title. The worst a bug here can do is take away a picture that
# one command puts back.
close_via_file() {
  PROJECT_JSON="$PROJECT_JSON" TITLE="$TITLE" /usr/bin/python3 -c '
import json, os, sys
from datetime import datetime, timezone

path = os.environ["PROJECT_JSON"]
title = os.environ["TITLE"]
try:
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit("no canvas file at " + path)
if doc.get("version") != 1 or not isinstance(doc.get("rev"), int):
    sys.exit("project.json is not the shape this knows how to edit")

doomed = [
    node["id"]
    for node in doc.get("nodes", [])
    if node.get("kind") == "web" and (node.get("title") or "") == title
]
if not doomed:
    print("no node for it on the canvas")
    raise SystemExit

doc["nodes"] = [n for n in doc["nodes"] if n.get("id") not in doomed]
doc["ropes"] = [
    r for r in doc.get("ropes", [])
    if r.get("source") not in doomed and r.get("target") not in doomed
]
doc["bridges"] = [
    b for b in doc.get("bridges", [])
    if b.get("source") not in doomed and b.get("target") not in doomed
]
doc["rev"] += 1
doc["savedAt"] = (
    datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
)
tmp = path + ".sim-node.tmp"
with open(tmp, "w", encoding="utf-8") as out:
    json.dump(doc, out, indent=2)
os.replace(tmp, path)
print("closed " + ", ".join(doomed))
'
}

# Web nodes carrying this device's title, read back off the control API. Used
# both to find what to close and to check afterwards whether it went.
web_nodes_named() {
  [ -e "$SHIM" ] || return 1
  sh "$SHIM" list 2>/dev/null | TITLE="$TITLE" /usr/bin/python3 -c '
import os, sys

title = os.environ["TITLE"]
for line in sys.stdin:
    parts = line.rstrip("\n").split(" ", 2)
    if len(parts) == 3 and parts[1] == "[web]" and parts[2] == title:
        print(parts[0])
'
}

# THE SHIM REPLY IS NOT TO BE BELIEVED. `close` prints "Could not reach nodeterm
# (control endpoint unreachable)" on closes that had already landed, because the
# HTTP request gives up while the confirmation dialog is still on screen. A
# timeout is not a refusal, and re-firing merely queues another dialog in the
# user's face. So: fire once per node, then POLL `list` until it is gone.
#
# The window is readable rather than folklore — NODETERM_PERM_WAIT_SECS is
# exported into the session (and is 0 when approvals are off), so read it rather
# than hardcoding the 45 it usually holds.
close_via_shim() {
  local ids id waited budget
  ids="$(web_nodes_named)" || { echo "no canvas control to ask" >&2; return 1; }
  if [ -z "$ids" ]; then
    echo "no node for it on the canvas"
    return 0
  fi
  budget=$(( ${NODETERM_PERM_WAIT_SECS:-45} + 30 ))
  for id in $ids; do
    sh "$SHIM" close --node "$id" >/dev/null 2>&1 || true
    waited=0
    while [ "$waited" -lt "$budget" ]; do
      web_nodes_named 2>/dev/null | grep -qx "$id" || break
      sleep 2
      waited=$(( waited + 2 ))
    done
  done
  [ -n "$(web_nodes_named 2>/dev/null)" ] && return 1
  echo "closed $(printf '%s\n' "$ids" | tr '\n' ' ')"
}

if [ -n "$CLOSING" ]; then
  close_via_file || close_via_shim || echo "the node is still on the canvas" >&2

  npx --yes serve-sim@latest --kill "$UDID" >/dev/null 2>&1 && echo "stream killed"

  # Asked, not assumed — and asked with `simctl list`, never `bootstatus -b`.
  # "still booted" is precisely the claim somebody reads before deciding whether
  # they still have to shut something down.
  if sim_is_booted "$UDID"; then
    echo "$NAME is still booted"
  else
    echo "$NAME is shut down"
  fi
  exit 0
fi

# ── Bringing it up ────────────────────────────────────────────────────────────

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID"

# Reuse a stream this device already has rather than restarting it: another
# session may be watching, and --kill is the one operation here that reaches
# outside this script's own work.
URL="$(npx --yes serve-sim@latest --list "$UDID" 2>/dev/null | /usr/bin/python3 -c '
import json, sys

try:
    state = json.loads(sys.stdin.read() or "{}")
except ValueError:
    raise SystemExit
if state.get("running") and state.get("url"):
    print(state["url"])
')"

if [ -z "$URL" ]; then
  URL="$(npx --yes serve-sim@latest --detach --quiet "$UDID" | /usr/bin/python3 -c '
import json, sys
print(json.load(sys.stdin)["url"])
')"
fi

# A PAGE THAT LOADS IS NOT A STREAM THAT RENDERS. A JPEG start-of-image marker
# in the body is the only proof, and two things make the obvious implementations
# wrong: reading an endless stream always ends in a timeout, so curl's exit code
# says nothing (and `pipefail`, set above, would fail the check on it); and BSD
# grep REJECTS those bytes under a UTF-8 locale with "illegal byte sequence"
# rather than simply not matching. Hence curl --range … || true, and python.
PROBE="$(mktemp)"
trap 'rm -f "$PROBE"' EXIT

FRAMED=""
for _ in 1 2 3 4 5 6 7 8; do
  curl -s --max-time 3 --range 0-200000 \
    "$URL/helper/$UDID/stream.mjpeg" -o "$PROBE" 2>/dev/null || true
  if /usr/bin/python3 -c '
import sys

with open(sys.argv[1], "rb") as probe:
    sys.exit(0 if b"\xff\xd8\xff" in probe.read() else 1)
' "$PROBE"; then
    FRAMED="yes"
    break
  fi
  sleep 1
done

if [ -z "$FRAMED" ]; then
  echo "serve-sim is up at $URL but delivered no frame for $NAME ($UDID)." >&2
  echo "Check the device is booted, then retry; --kill only that udid if wedged." >&2
  exit 1
fi

echo "$NAME  $UDID"
echo "$URL"
echo "stream $URL/helper/$UDID/stream.mjpeg"

# Outside nodeterm the URL is the whole answer.
if [ -z "${NODETERM_CANVAS_CONTROL:-}" ] || [ ! -f "$SHIM" ]; then
  exit 0
fi

WANT_W="${ASKED_W:-$SIM_NODE_W}"
WANT_H="${ASKED_H:-$SIM_NODE_H}"

# Four things, in ONE write, because each write costs a canvas reload:
#
#   - roped to this terminal, if not roped already;
#   - seated under that terminal, centred, SIM_NODE_GAP below — nodeterm drops a
#     new web node over the terminal that asked for it and no verb places a node
#     anywhere (`move` reparents, `arrange`/`align` would shift the terminal
#     too), so position lives only in this file;
#   - re-pointed at the stream, because a node's URL is fixed at creation while
#     serve-sim hands out the first free port from 3100 upward, so which device
#     is on a given port changes between sessions;
#   - and sized, but ONLY while it still measures exactly the 720x520 nodeterm
#     gives every new web node. Any other size was chosen by dragging, and a
#     node shaped by hand is the user's — which is why that same test governs
#     the seating, and why a node dragged somewhere is left there. A node seated
#     but not yet reshaped is still at that default, so the rule repairs itself
#     on the next run without needing to detect the failure.
#
# Anything unexpected about the file leaves the node alone: a default-sized
# simulator is a small disappointment where a mangled canvas is not.
shape() {
  PROJECT_JSON="$PROJECT_JSON" NODE="$1" TERM_NODE="${NODETERM_NODE_ID:-}" \
    WANT_URL="$URL" WANT_W="${2:-}" WANT_H="${3:-}" GAP="$SIM_NODE_GAP" \
    /usr/bin/python3 -c '
import json, os, sys, time
from datetime import datetime, timezone

path = os.environ["PROJECT_JSON"]
node_id = os.environ["NODE"]
terminal = os.environ["TERM_NODE"]
gap = float(os.environ["GAP"])
width, height = os.environ["WANT_W"], os.environ["WANT_H"]
want = {"width": int(width), "height": int(height)} if width and height else None


def read():
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


# The node is only on disk once nodeterm has saved. That is usually a couple of
# seconds, but a window nobody is looking at can sit on the change for minutes —
# so this waits far longer than it ever normally needs to. Giving up early is
# what leaves a node at the 720x520 nodeterm gave it.
deadline = time.monotonic() + 90
while True:
    doc = read()
    if doc and any(n.get("id") == node_id for n in doc.get("nodes", [])):
        break
    if time.monotonic() > deadline:
        sys.exit("nodeterm has not written the node to " + path)
    time.sleep(0.4)

# An external change lands silently on a clean canvas and raises a conflict bar
# on a dirty one, and the save that just happened is what clears the flag.
time.sleep(0.5)
doc = read()
if not doc or doc.get("version") != 1 or not isinstance(doc.get("rev"), int):
    sys.exit("project.json is not the shape this knows how to edit")

changed = []
for node in doc.get("nodes", []):
    if node.get("id") != node_id:
        continue
    born = {"width": 720, "height": 520}
    untouched = node.get("size", born) == born
    if want and untouched and node.get("size") != want:
        node["size"] = want
        changed.append("{width}x{height}".format(**want))
    # Read after the resize, so the width being centred is the one the node is
    # about to have and not the 720 it was born at. A frame is the one thing
    # that could make two sets of coordinates mean different things, so a
    # terminal and a view in different containers are left alone.
    opener = next((n for n in doc["nodes"] if n.get("id") == terminal), None)
    if untouched and opener is not None and opener.get("group") == node.get("group"):
        here, room = opener.get("position") or {}, opener.get("size") or {}
        mine = node.get("size") or born
        if {"x", "y"} <= set(here) and {"width", "height"} <= set(room):
            seat = {
                "x": here["x"] + (room["width"] - mine["width"]) / 2,
                "y": here["y"] + room["height"] + gap,
            }
            if node.get("position") != seat:
                node["position"] = seat
                changed.append("seated below the terminal")
    if node.get("url") != os.environ["WANT_URL"]:
        node["url"] = os.environ["WANT_URL"]
        changed.append("pointed at " + os.environ["WANT_URL"])
    break
else:
    sys.exit("the node is no longer on the canvas")

if terminal:
    ropes = doc.setdefault("ropes", [])
    rope = "ctrl-%s-%s" % (terminal, node_id)
    if not any(r.get("id") == rope for r in ropes):
        ropes.append({"id": rope, "source": terminal, "target": node_id})
        changed.append("roped to this terminal")

if not changed:
    raise SystemExit

doc["rev"] += 1
doc["savedAt"] = (
    datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
)
tmp = path + ".sim-node.tmp"
with open(tmp, "w", encoding="utf-8") as out:
    json.dump(doc, out, indent=2)
os.replace(tmp, path)
print(", ".join(changed))
' || echo "the node kept the size nodeterm gave it" >&2
}

# Re-running should REUSE the node, not litter the canvas with copies of the
# same device. The title carries the device name for exactly this lookup — and
# the title rather than the URL, because a node's URL is fixed at creation while
# serve-sim reallocates helper ports per session, so URL matching goes stale and
# orphans nodes, or worse leaves a node quietly showing a different device.
EXISTING="$(sh "$SHIM" list 2>/dev/null | TITLE="$TITLE" /usr/bin/python3 -c '
import os, re, sys

title = os.environ["TITLE"]
for line in sys.stdin:
    match = re.match(r"(\S+)\s+\[web\]\s+(.*)", line.strip())
    if match and match.group(2).strip() == title:
        print(match.group(1))
        raise SystemExit
')"

if [ -n "$EXISTING" ]; then
  echo "already on the canvas as $EXISTING"
  shape "$EXISTING" "$WANT_W" "$WANT_H"
  exit 0
fi

# show-web ropes the new node to this terminal on its own and drops it over that
# terminal; where it lands is settled in the one write above rather than with an
# `align` here, which would only move it twice and reload the canvas for the
# privilege. A node this narrow also gets a bare stream for free: serve-sim's
# device and tools panels only open themselves above about 800px.
NODE="$(sh "$SHIM" show-web --url "$URL" 2>&1 | awk '{print $NF}')"
sh "$SHIM" rename --node "$NODE" --title "$TITLE" >/dev/null 2>&1
echo "seated on the canvas as $NODE"
shape "$NODE" "$WANT_W" "$WANT_H"
