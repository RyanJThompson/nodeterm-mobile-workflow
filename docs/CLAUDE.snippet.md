# The CLAUDE.md block

Paste this into your project's `CLAUDE.md`. Edit the bracketed parts.

This is the step that makes agents follow the workflow instead of improvising,
and it is the one most likely to be skipped. Skills are read when a session
starts; `CLAUDE.md` is what an agent has in front of it the whole time.

---

## Simulators — claim, never pick

This project runs on iOS simulators handed out by
[simbroker](https://github.com/RyanJThompson/simbroker), a machine-global broker
with a hard capacity (about three booted simulators is all a Mac takes). Several
agents may be working here at once.

**Before you build, run, test or drive the app on a device:**

1. **Claim one** with the `claim_simulator` MCP tool. Not the CLI — inside an
   agent session every Bash call is its own shell, so a `--pid $$` claim is dead
   by the next tool call and is reclaimed immediately. An MCP claim renews itself
   and is released when the session ends.
2. **Drive the exact udid you were granted, and nothing else.** Never pick, boot,
   reset or erase a device that was not granted to you — another agent is
   probably on it.
3. **Pass that udid to everything**, so the device you build on is the one you
   look at:
   ```bash
   SIM_UDID=<udid> scripts/mobile/sim-capture.sh <name>
   ```
4. **One device per concurrent task**, and do not hold one you are not using. A
   held device is another agent that cannot start.
5. If a claim fails with **capacity reached** or **no free device**, that class
   is full: release something you have finished with, wait briefly and retry, or
   tell the user. **Do not loop, and do not work around it by grabbing an
   unclaimed device.**

Teardown is normally automatic — MCP claims are released when the session ends.
Give a device back early with `release_simulator` when the work is genuinely
done. `/sim-teardown` does the whole lot: canvas node, stream, claim, device.

## Seeing the app

```bash
scripts/mobile/sim-node.sh <claimed-udid>
```

Puts a live, touchable mirror of that device on the nodeterm canvas beside this
terminal. Use it for **watching** — animation, drag, transition, anything a
still frame cannot show. Re-run it to repair a dead view; do **not** open a
second node for the same device.

Use `scripts/mobile/sim-capture.sh` for **checking your own work**: it launches
the app in a known state with launch flags, pins the status bar to 9:41 so two
shots differ only where the app differs, and writes a PNG to read back.

Never run a bare `npx serve-sim --kill` — it kills every other session's mirror.
Always scope it: `--kill <udid>`.

## Working in parallel

If asked to parallelise, fan out, or work on several things at once, use the
**mobile-orchestrator** skill. The short version: one worktree + one session +
one claimed device per workstream, and the number of stations is capped by
`simbroker doctor`'s capacity, not by how many workstreams you can think of.

## When something looks wrong

```bash
scripts/mobile/sim-doctor.sh
```

Run it before debugging anything. The failure modes here are silent — a stale
MCP server handing out an old pool, a pool name that fell out of the config, a
stream that died leaving a node that still looks healthy.

**[Project-specific: add your build/run/test commands here, and say that each
must take `SIM_UDID`.]**
