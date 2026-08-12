---
name: nodeterm-canvas
description: See what is open on the nodeterm canvas — how many simulator views, which terminals, what each web node points at and whether it is still showing anything — and close the ones that are dead. Use when asked what is open, how many simulators are running, whether a view is live, or to tidy the canvas up.
---

# What is open on the canvas

```bash
/usr/bin/python3 .claude/skills/nodeterm-canvas/inventory.py
```

Every node with its kind, size, and — for a web node — its URL, whether anything
is still rendering there, and which terminals it is roped to. The terminal you
are running in is marked, and booted simulators are listed underneath so a view
can be matched to a device.

Three sources go into that, and no one of them would do. `nodeterm.sh list` is
the only authority on what **exists**, but answers with nothing but id, kind and
title. Size, URL and ropes live in the project's canvas file. And whether a
stream is **alive** is a question only the port can answer.

That third one is the reason this exists: **a killed stream leaves a node that
reads as working** — same title, same size, same place on the canvas — so
counting nodes is not counting devices. `inventory.py` looks for a JPEG
start-of-image marker in the body rather than settling for "the port answered",
because serve-sim's page keeps returning 200 after its device has gone.

## Closing one

A **simulator view** needs none of the machinery below:

```bash
scripts/mobile/sim-node.sh --close <udid>
```

That removes the node and the stream in about a second and asks nobody, because
it edits the canvas file directly and refuses to touch anything that is not a
web node. Prefer it.

For everything else, `close` asks the user **every time**, and only **one
confirmation can be pending** — the rest come straight back with "a confirmation
is already pending". The request also gives up while the dialog is still on
screen, so **a timeout is not a refusal** and re-firing merely queues another
dialog in the user's face. Fire one, wait for the node to leave the list, then
fire the next:

```bash
SHIM="$HOME/Library/Application Support/node-terminal/canvas-control/nodeterm.sh"
gone() { ! sh "$SHIM" list 2>/dev/null | grep -q "^$1 "; }
for n in <node-id> <node-id>; do
  sh "$SHIM" close --node "$n" 2>&1 || true
  for _ in $(seq 1 30); do gone "$n" && break; sleep 3; done
done
```

Say which nodes and why before firing anything: each one is a dialog in the
user's face, and a node whose stream is dead may still be one they want kept.

## Before opening another

`sim-node.sh` reuses the node for a device and re-points it at the current
stream, so the fix for a `DEAD` simulator view is to **run it again** — not to
open a second one. Five views for one booted device is what prompted this skill
existing. The same rule holds generally: re-point an existing node rather than
opening a second.
