#!/bin/bash
# PostToolUse hook: seats the simulator on the canvas the first time a session
# touches one, beside the terminal that ran the command. Silent otherwise.
#
# Register it in the project's .claude/settings.json:
#
#   { "hooks": { "PostToolUse": [ { "matcher": "Bash",
#       "hooks": [ { "type": "command",
#                    "command": "$CLAUDE_PROJECT_DIR/scripts/mobile/hooks/seat-simulator.sh" } ] } ] } }
#
# Two non-obvious details there. The matcher is the literal string "Bash" — not
# a regex, not "*" — and that is what gives the hook the Bash `tool_input` shape
# it parses below. And $CLAUDE_PROJECT_DIR is a HOOK-TIME substitution, not a
# shell variable (it is unset inside a Bash tool call), which is what lets the
# wiring survive the project folder moving.
#
# It runs after EVERY shell command, so it has to be cheap: a case match and one
# file read decide it, and the slow part — sim-node.sh, which boots, streams and
# seats — is backgrounded. The session carries on while the node appears.
#
# Doing nothing is the common answer. It stays silent outside nodeterm, on
# commands with nothing to do with a simulator, and once this terminal already
# has a simulator node roped to it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_NODE="$HERE/../sim-node.sh"

# What counts as "using a simulator" in THIS project. Override it from the
# environment or edit it — the default covers simctl and this bundle's own
# scripts, but a project whose agents type `make run` needs that listed here or
# the hook never fires. The bundle this grew out of hardcoded four capital-S
# script paths that did not exist in it, so the hook exited at the first gate and
# printed nothing at all, forever.
SEAT_TRIGGERS="${SEAT_TRIGGERS:-simctl boot|simctl launch|simctl install|sim-capture.sh|scripts/mobile/run|scripts/mobile/test}"

# Outside nodeterm there is no canvas to seat anything on, and no rope to draw.
[ -n "${NODETERM_CANVAS_CONTROL:-}" ] || exit 0
[ -n "${NODETERM_NODE_ID:-}" ] || exit 0
[ -x "$SIM_NODE" ] || exit 0

PAYLOAD="$(cat)"
COMMAND="$(printf '%s' "$PAYLOAD" | /usr/bin/python3 -c '
import json, sys

try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except (ValueError, AttributeError):
    pass
')"

# sim-node.sh itself is deliberately NOT a trigger, or the hook chases its tail.
case "$COMMAND" in
  *sim-node.sh*) exit 0 ;;
esac
printf '%s' "$COMMAND" | grep -qE "$SEAT_TRIGGERS" || exit 0

# One at a time. The test below reads the canvas FILE, which nodeterm can be
# minutes behind on when nobody is looking at the window, so a seat already in
# flight is invisible to it and every command would start another.
pgrep -f "sim-node.sh" >/dev/null 2>&1 && exit 0

# Already seated for this terminal? The rope is what "connected to this
# terminal" means, so it is also the test for whether there is anything to do.
CANVAS="$(PROJECT_ROOT="" bash -c "source '$HERE/../lib/mobile-env.sh' >/dev/null 2>&1; printf '%s' \"\$CANVAS_JSON\"" 2>/dev/null)"
SEATED="$(NODE_ID="$NODETERM_NODE_ID" PROJECT_JSON="$CANVAS" /usr/bin/python3 -c '
import json, os

try:
    with open(os.environ["PROJECT_JSON"], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit

node_id = os.environ["NODE_ID"]
views = {
    n["id"]
    for n in doc.get("nodes", [])
    if n.get("kind") == "web" and (n.get("title") or "").endswith(" — simulator")
}
for rope in doc.get("ropes", []):
    if rope.get("source") == node_id and rope.get("target") in views:
        print("yes")
        break
')"
[ -n "$SEATED" ] && exit 0

# Whichever device the command itself named, so a CLAIMED device is not swapped
# for the project default halfway through a session. A bare udid argument counts
# too, not just SIM_UDID=.
UDID="$(printf '%s' "$COMMAND" | grep -o -E '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)"

nohup "$SIM_NODE" ${UDID:+"$UDID"} >"${TMPDIR:-/tmp/}seat-simulator.log" 2>&1 &

echo "Seating the simulator on the canvas beside this terminal — it will appear in a few seconds (sim-node.sh, backgrounded)."
