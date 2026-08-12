---
description: Tear down this session's simulator — canvas node, stream, broker claim, and the device itself.
argument-hint: "[udid]  (optional — otherwise worked out from this terminal's node)"
allowed-tools: Bash(echo:*), Bash(simbroker list:*), Bash(simbroker release:*), Bash(xcrun simctl list:*), Bash(xcrun simctl shutdown:*), Bash(scripts/mobile/sim-node.sh:*), Bash(/usr/bin/python3 .claude/skills/nodeterm-canvas/inventory.py)
---

## What is up right now

This terminal: !`echo "${NODETERM_NODE_ID:-not in nodeterm}"`

Canvas: !`/usr/bin/python3 .claude/skills/nodeterm-canvas/inventory.py 2>&1 || true`

Pool: !`simbroker list --json 2>&1 || true`

Booted: !`xcrun simctl list devices booted 2>&1 || echo none`

## Do this

Tear down the simulator **this session** has been using.

A device may be named as an argument, and here it is: `$1` — but that is usually
empty, and empty is the ordinary case. When it is, work the device out from the
canvas above: the web node titled `<device> — simulator` that is **roped to this
terminal**, whose id is printed at the top. The rope is the record of which
session opened which view, so it is the answer rather than a guess.

**Never tear down a device roped to a different terminal.** Another session is
working on it, and the pool exists precisely so that does not happen. If the
rope does not name one device unambiguously, say what you found and stop.

Then, in order:

1. `scripts/mobile/sim-node.sh --close <udid>` — the node and the stream. It
   needs no confirmation dialog and does not touch the device.
2. Release the claim: find the entry in the pool JSON whose `udid` matches and
   run `simbroker release <its claim_id>`. If nothing holds it, say so rather
   than inventing a claim id. (A claim made through the MCP tool is released
   automatically when this session ends, so this step is only about giving the
   device back *early*.)
3. `xcrun simctl shutdown <udid>` — but **only** if nothing else still wants it:
   no other node on the canvas names that device, and no other claim is left on
   it. If something does, leave it booted and say what.

Report it in a couple of lines: what was closed, what was released, whether the
device went down, and anything you deliberately left alone. Don't re-list the
canvas.
