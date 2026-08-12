---
name: simulator-node
description: Put a live, touchable iOS simulator on the nodeterm canvas beside this terminal, on a device claimed from the simbroker pool. Use when asked to show, open, watch or mirror the simulator, to see the app running rather than a screenshot of it, or when several sessions are working at once and each needs its own device.
---

# A simulator on the canvas

A nodeterm node can be a terminal, an editor or a **web view** — never a native
macOS window. So a device on the canvas is always the same trick: serve the
screen over local HTTP, open that URL as a web node. `scripts/mobile/sim-node.sh`
does it with `serve-sim`: about 29 fps, and it takes touch.

## The process

**1. Claim a device** with the `claim_simulator` MCP tool — **not** the CLI.

Inside an agent session every Bash call is its own short-lived shell, so
`simbroker claim --pid $$` produces a claim whose holder process is dead by the
next tool call, and the broker reclaims a dead-pid claim immediately. The MCP
server claims with its own long-lived pid, heartbeats, and releases when the
session ends — so the claim lives exactly as long as you do. (From a
*long-running script*, `--pid $$` with `trap 'simbroker release "$CLAIM"' EXIT`
is correct. The injunction is about claiming from a tool call.)

Claim **one** device, and only when this session genuinely needs its own. Three
sessions sharing one device is precisely what the pool exists to prevent; the
symptom is a mirror going black when another session backgrounds the app.

**2. Seat it**, passing the udid the claim handed back:

```bash
scripts/mobile/sim-node.sh <claimed-udid>
```

It boots the device if it is down, reuses a stream and a node that already exist
for that device rather than duplicating either, waits for a real JPEG frame
before reporting success, and prints the URL and the node id. The node arrives
**roped to this terminal** and shaped like a phone rather than nodeterm's
default 720×520 box.

With no argument it falls back to the project default (`SIM_NAME`), which is
right for one session working alone and wrong the moment there are two.

**3. Pass the same udid to everything else.** Building on the device you were
granted and screenshotting a different one is a confusing hour:

```bash
SIM_UDID=<udid> scripts/mobile/sim-capture.sh after-fix
```

## What the node is for

**Watching and driving by hand** — an animation, a drag, a transition, anything
a still frame cannot show. The page is serve-sim's own, which brings Apple's
real DeviceKit chrome around the screen and its tool row: the **arrow** is the
accessibility overlay (it outlines every element on screen), the **globe** is
WebKit DevTools, plus screenshot, rotate, Home, Text Size and simulator actions.
Tap, drag and the hardware buttons all land at stream latency.

It is **not the evidence channel**. Checking your own work is
`scripts/mobile/sim-capture.sh` with launch flags, read back with the Read tool:
a launch flag puts the app in a known state in one step, where tapping through
the UI is slow and may not land where you think.

## Sizing

`SIM_NODE_W` / `SIM_NODE_H` in `.mobile-workflow.conf`, and only that. Passing
either on the command line outranks the file for one run.

A node is reshaped **only while it still measures exactly 720×520** — the size
nodeterm gives every new web node. Any other size was chosen by dragging, and
that node belongs to the user: leave its size *and* its position alone.

**Height alone decides how large the device renders.** The picture is fitted
inside the node, so raising the width buys black bars and nothing else.

## Housekeeping

```bash
scripts/mobile/sim-node.sh --close <udid>   # node + stream down, device left booted
npx --yes serve-sim@latest --list           # what is streaming
```

`--close` needs no confirmation dialog, because it edits the canvas file
directly and refuses to remove anything that is not a **web** node with this
device's title. `/sim-teardown` does that *and* releases the claim and shuts the
device down.

Never run a bare `npx serve-sim --kill` — it takes down every other session's
mirror. Always scope it: `--kill <udid>`.

**A page that loads is not a stream that renders.** A killed stream leaves a node
that reads as perfectly healthy — same title, same size, same place. The
**nodeterm-canvas** skill prints `DEAD` for those. The fix is to run
`sim-node.sh` again, which re-points the existing node; do not open a second.
