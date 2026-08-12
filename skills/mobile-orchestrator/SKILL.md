---
name: mobile-orchestrator
description: Run several Claude Code sessions in parallel on this mobile app, each on its own git worktree and its own simulator claimed from the simbroker pool, arranged on the nodeterm canvas. Use when asked to parallelise, fan out, split work across agents, work on several features or bugs at once, or when one task is large enough that independent workstreams would finish sooner than one session grinding through them.
---

# Orchestrating parallel mobile agents

You are the orchestrator. You plan the work, open one station per workstream,
and — the half most orchestrators skip — **collect and reconcile what they
produced**. You do not do the workstreams yourself.

The unit is a **station**: one git worktree + one Claude session + one claimed
simulator. Nothing is shared between stations except the repo's history, which
is the point — two agents building the same scheme into the same DerivedData, or
installing the same bundle id onto the same device, is the failure this
prevents.

## 0. Work out how wide you can actually go

**Read this before deciding anything.** Fan-out width is not your choice alone:

```
stations = min( genuinely independent workstreams , simbroker iOS capacity )
```

```bash
simbroker list          # capacity per class, and what is already held
simbroker doctor        # resolved capacity, pool size, what is claimable
```

Capacity defaults to **3** and reflects the machine's RAM, not ambition — about
three booted simulators is all a Mac takes before it thrashes. Open five
stations against a capacity of three and two of them will sit blocked on
`claim_simulator`, having already burned a worktree and a session. **If the work
splits into more streams than there is capacity for, queue the surplus behind
the first stations with `--after` rather than opening them all at once.**

Then check the split is real. For every "and then" in your plan, ask: **does the
next step read the previous step's output?** If not, the dependency is imagined
and both are stations. If it does, the dependency is real — open the downstream
station with `--after <upstream-id>` and it launches itself when the upstream
goes idle. Never poll for that in your own session.

Split by **subsystem, not by file**. Two agents in the same file is a merge
conflict wearing a plan's clothes.

## 1. Open a station per workstream

```bash
SHIM="$HOME/Library/Application Support/node-terminal/canvas-control/nodeterm.sh"

sh "$SHIM" open-worktree --branch fix-timer-drift
# → note the groupId it prints

sh "$SHIM" open-agent --agent claude --group <groupId> --prompt "<the brief>"
```

The worktree gives the station its own branch and checkout; the group frame
binds them, so an agent opened `--group <groupId>` starts in the worktree
automatically. Successive worktree frames fan out side by side; tidy them
afterwards with `arrange --nodes <groupId,groupId,…> --layout row` and `rename`
each frame by subject.

### The station brief

Every station must claim its own device. Say so explicitly — an agent that is
not told will pick a device, and picking is exactly what the pool exists to
stop. Use this shape:

```text
<What to build or fix, concretely, self-contained. Assume the station has read
none of this conversation.>

Before you build, run or drive the app:
  1. Claim your own device with the claim_simulator MCP tool. Do not pick one,
     and do not use a device you were not granted.
  2. Seat it on the canvas beside you:  scripts/mobile/sim-node.sh <that udid>
  3. Pass that udid to every build/run/test/screenshot command:
     SIM_UDID=<udid> scripts/mobile/sim-capture.sh <name>

You are in a git worktree on your own branch. Commit there. Do not merge, do not
touch other branches, and do not close anyone else's canvas node.

When you are done, finish with a short summary: what changed, which files, what
you verified and how, and anything you hit that the other stations need to know.
```

That last line matters more than it looks: you will read it back in step 3, and
a station that ends with "done!" gives you nothing to reconcile.

## 2. While they run

- Their status badges show working / waiting / blocked. That is your progress
  view — do not interrupt a station to ask how it is going.
- Keep the board honest if the project uses one: `board` for the columns,
  `assign --node <id> --column "In Progress"` as each station starts and
  `--column Done` as it finishes.
- If a station goes **blocked**, read it before acting — a blocked station is
  usually asking for a decision only you have.
- **Do not claim a device for yourself** unless you are genuinely going to drive
  one. Every device you hold is a station that cannot start.

## 3. Collect — this is the job

Every station you opened is context-linked to you. When one goes idle, read what
it actually did:

```bash
CTX="$HOME/Library/Application Support/node-terminal/context-links/context.sh"
sh "$CTX" list
sh "$CTX" summary --node <station-id> -n 40
sh "$CTX" transcript --node <station-id>     # when the summary is not enough
```

Then do the part only you can do: reconcile the streams against each other, name
the conflicts and the leftovers, and report **one** synthesis. A station you
never read is a station whose work you cannot vouch for — say that plainly
rather than assuming it went fine.

## 4. Verify what matters

For anything touching money, auth, data migration, a public API — or a UI change
someone will ship:

```bash
sh "$SHIM" verify --node <station-id>
```

That opens a review panel: one reviewer per lens, each armed behind the station
and linked to it, plus a judge that merges their findings. Use it instead of
asking the station "are you sure?" — you cannot independently check work you
helped plan, and several independent looks catch what one pass cannot. Fold the
verdict into your synthesis and say which findings you accepted and which you
dismissed, and why.

## 5. Hand back

- **The user merges**, from the group's chip on the canvas. Never merge for them.
- Release a finished station: `close-worktree --group <id>` (default `unbind`
  keeps the directory; `--mode remove` asks the user before deleting it).
- Devices come back on their own: an MCP claim is released when the session that
  made it ends. Nothing to do unless a station finished early and its device is
  wanted now — then have it call `release_simulator`, or run
  `simbroker release <claim_id>`.
- Simulator views do **not** go on their own. `scripts/mobile/sim-node.sh
  --close <udid>` removes one silently; `/sim-teardown` does the whole lot for
  one station.

## What goes wrong

| Symptom | Cause |
|---|---|
| A station hangs on `claim_simulator` | Capacity is full. Do not loop; release something or queue with `--after`. |
| A station is handed a device on the wrong OS | The broker matches its pool on device NAME with no runtime filter. `SIM_RUNTIME_MATCH` in `.mobile-workflow.conf` is the guard, and `sim-doctor.sh` is how you find out. |
| `claim_simulator` keeps returning a stale pool | The MCP server reads `~/.simbroker/config.json` **once, at start-up**. Only restarting the session fixes it. |
| A station's mirror is 720×520 landscape | It ran from a worktree and could not write the canvas file, or nodeterm had not saved the node yet. Re-run `sim-node.sh` — it repairs both. |
| Stations serialise on the build instead of running in parallel | The project pins an absolute `-derivedDataPath`, so three worktrees share one build directory and its lock. Make that path relative to the checkout. |
| A view looks fine but shows nothing | The stream died; the node survives it. `inventory.py` prints `DEAD` for those. Re-run `sim-node.sh`, do not open a second node. |

Related: the **simulator-node** skill (one device on the canvas) and the
**nodeterm-canvas** skill (what is open, and what is dead).
