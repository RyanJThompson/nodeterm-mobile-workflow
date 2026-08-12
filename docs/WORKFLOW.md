# The workflow

The authoritative guide. If you are an AI agent operating this setup, read this
file top to bottom before doing anything — several of the constraints below are
counter-intuitive enough that guessing produces something that looks right and
silently does not work.

---

## 0. The shape of the problem

You want several coding agents working on one mobile app at once, each able to
*see* and *drive* the app, without them colliding.

Three facts set the whole design:

1. **A nodeterm node can be a terminal, an editor, or a web view — never a
   native macOS window.** So a device on the canvas is always the same trick:
   serve the device's screen over local HTTP, then open that URL as a web node.
   Everything in `sim-node.sh` is plumbing around that one idea.

2. **Simulators are RAM, and RAM is the ceiling.** About three booted simulators
   is all a Mac takes before it crawls. That number — not the number of agents
   you would like — is the real width of your fan-out.

3. **Two agents on one device is the failure mode.** They background each
   other's app, install over each other's build, and each sees a mirror that
   goes black for reasons neither can explain. Allocation has to be brokered.

### Who owns what

| Concern | Owner |
|---|---|
| Which device may I use, and is it free | **simbroker** — machine-global, project-agnostic |
| Sessions, worktrees, canvas, orchestration | **nodeterm** |
| Streaming a simulator's screen | **serve-sim** (via `npx`) |
| Build / install / launch *your* app | **your project** — irreducibly app-specific |
| Gluing those together for agents | **this repo** |

simbroker deliberately does not build anything, and this repo deliberately does
not build your app either. Keep that line: the moment a device name or a scheme
appears in `scripts/mobile/lib/mobile-env.sh`, the next project to adopt this has
to edit machinery instead of policy.

---

## 1. One session

The single-agent path, which is also the inner loop of every station in §2.

### Claim a device

Use the **`claim_simulator` MCP tool**, not the CLI.

Not for the reason you would guess. Inside an agent session every Bash call is
its own short-lived shell, so `simbroker claim --pid $$` produces a claim whose
holder process is dead by the next tool call — and the broker reclaims a
dead-pid claim immediately. A pid-less CLI claim is governed by TTL instead,
which is a number you have to guess up front. The MCP server claims with its own
long-lived pid, heartbeats at TTL/3, and releases when the session ends, so the
claim lives exactly as long as you do.

(From a *long-running script*, `--pid $$` is correct and better — a claim whose
holder is alive is never reclaimed regardless of TTL. Pair it with
`trap 'simbroker release "$CLAIM"' EXIT`. The injunction is about claiming from
inside an agent tool call. `list`, `devices`, `doctor` and `release` are fine
from anywhere.)

### Seat it

```bash
scripts/mobile/sim-node.sh <claimed-udid>
```

Boots the device if it is down, reuses a stream and a node that already exist
for that device, waits for a real JPEG frame before reporting success, and
prints the URL and node id. The node arrives roped to your terminal and shaped
like a phone.

Outside nodeterm it prints the URL and stops. That is the correct behaviour, not
a degradation — the stream is useful either way; only the seating needs a canvas.

### Drive it

The canvas node is for **watching**: animation, drag, transition, anything a
still frame cannot show. It shows serve-sim's own page, which brings Apple's
real DeviceKit chrome and the tool row — the arrow is the accessibility overlay
(it outlines every element on screen), the globe is WebKit DevTools, plus
screenshot, rotate, Home, Text Size and simulator actions. Tap and drag land at
stream latency.

`sim-capture.sh` is the **evidence** channel: a launch flag puts the app in a
known state in one step and hands you a PNG to read back, where tapping through
the UI is slow and may not land where you think. Two shots of the same screen
differ only where the app differs, because the status bar is pinned to 9:41.

Pass the same udid to everything:

```bash
SIM_UDID=<udid> scripts/mobile/sim-capture.sh after-fix -myLaunchFlag value
```

Building on the device you were granted and screenshotting a different one is a
confusing hour.

### Put it away

```bash
scripts/mobile/sim-node.sh --close <udid>   # node + stream; device left booted
/sim-teardown                               # that, plus the claim and the device
```

MCP claims release themselves when the session ends, so teardown is about giving
a device back *early* — which matters, because a held device is a station that
cannot start.

**What comes back is the slot, not the device.** A simulator someone booted stays
`Booted` until `xcrun simctl shutdown`, and nothing in the broker does that for
you — which is why `/sim-teardown` lists the device separately from the claim. A
session that simply ends leaves a booted simulator behind. That is usually fine
(the next claimant is handed the same warm device), and it is worth reclaiming
when the RAM is wanted for something other than the next station.

---

## 2. Many sessions: the orchestrator

One session plans and delegates. Each **station** is one worktree + one Claude
session + one claimed simulator.

### Decide the width first

```
stations = min( genuinely independent workstreams , simbroker iOS capacity )
```

```bash
simbroker list      # capacity per class, and what is already held
simbroker doctor    # resolved capacity, pool size, what is claimable
```

Open five stations against a capacity of three and two of them sit blocked on
`claim_simulator`, having already burned a worktree and a session. Queue the
surplus with `--after` instead.

But `--after` sequences the *work*, not the *devices*. "Idle" is a turn boundary
(§2, *Collect*) while an MCP claim lives until the session **ends** (§1) — so an
armed station wakes into exactly the pool that was there before, and a queued
station behind three live ones still blocks. Collecting from an upstream and
closing it, or having it call `release_simulator`, is what actually frees the
slot the queued station is waiting for.

Then check the split is real. For every "and then" in the plan: **does the next
step read the previous step's output?** If not, there is no dependency and both
are stations. If it does, open the downstream station with
`--after <upstream-id>` — it launches itself when the upstream goes idle, and
arrives already context-linked to it. Never poll for that in your own session.

Split by **subsystem, not by file**. Two agents in one file is a merge conflict
wearing a plan's clothes.

### Open the stations

```bash
SHIM="$HOME/Library/Application Support/node-terminal/canvas-control/nodeterm.sh"

sh "$SHIM" open-worktree --branch fix-timer-drift        # → prints a groupId
sh "$SHIM" open-agent --agent claude --group <groupId> --prompt "<brief>"
```

Members opened `--group` land in grid slots inside the frame and inherit the
worktree as their cwd. Afterwards:

```bash
sh "$SHIM" arrange --nodes <groupId>,<groupId>,<groupId> --layout row
sh "$SHIM" rename --node <groupId> --title "Timer drift"
```

`arrange` and `align` need every id to share one container, so pass the **group**
ids, not the children.

### The station brief

An agent that is not told to claim will pick a device, and picking is the thing
the pool exists to stop. Say it explicitly, every time:

```text
<What to build or fix, concretely and self-contained. Assume the station has
read none of the orchestrator's conversation.>

Before you build, run or drive the app:
  1. Claim your own device with the claim_simulator MCP tool. Do not pick one,
     and do not use a device you were not granted.
  2. Seat it beside you:  scripts/mobile/sim-node.sh <that udid>
  3. Pass that udid to every build/run/test/screenshot command:
     SIM_UDID=<udid> scripts/mobile/sim-capture.sh <name>

You are in a git worktree on your own branch. Commit there. Do not merge, do not
touch other branches, and do not close anyone else's canvas node.

Finish with a short summary: what changed, which files, what you verified and
how, and anything the other stations need to know.
```

The last line is not politeness. You will read it back in the next step, and a
station that ends with "done!" leaves you nothing to reconcile.

### Collect — this is the job

Every station you opened is context-linked to you.

```bash
CTX="$HOME/Library/Application Support/node-terminal/context-links/context.sh"
sh "$CTX" list
sh "$CTX" summary --node <station-id> -n 40
sh "$CTX" transcript --node <station-id>
```

Read each one as it goes idle, then reconcile the streams against each other,
name the conflicts and the leftovers, and report **one** synthesis. A station
you never read is a station whose work you cannot vouch for — say so rather than
assuming it went fine.

Note what "idle" means: the end of a *turn*, not proof the whole job is done.
That is right for a station given one self-contained brief, and wrong if you
expected a conversation first.

### Verify what matters

```bash
sh "$SHIM" verify --node <station-id>
```

Opens a review panel — one reviewer per lens, each armed behind the station and
linked to it, plus a judge merging their findings. Use it instead of asking a
station "are you sure?": you cannot independently check work you helped plan.
Reviewers are told not to change files, because they share one checkout and
finding is a separate job from fixing.

### Hand back

The **user** merges, from the group's chip. Never merge for them. Release a
finished station with `close-worktree --group <id>` (default `unbind` keeps the
directory; `--mode remove` asks before deleting).

---

## 3. What is different because it is mobile

Generic parallel-agent advice misses these.

**Each worktree gets its own DerivedData for free — and that is a cost, not a
gift.** Xcode keys the default DerivedData directory on the project's absolute
path, so three worktrees mean three build directories: three cold builds and
three times the disk. Nothing corrupts. The case that *does* bite is a project
pinning an absolute `-derivedDataPath`: then three stations share one directory
and serialise on its lock, and the parallelism you paid for evaporates. If your
build scripts pin it, make the path relative to the checkout.

**The same bundle id on three different devices is fine.** On the *same* device
it is the collision — one install replaces another, and `simctl launch` starts
whichever landed last. One device per station is what makes the bundle id a
non-issue, which is most of why the broker is here.

**serve-sim's ports are assigned, not fixed.** Its per-device helper takes the
first free port from **3100** upward, one per device, so three concurrent
streams reach 3102 and which device is on which port changes between sessions.
Never hardcode a port; `sim-node.sh` discovers the URL at runtime with
`serve-sim --list <udid>`, and so should anything else.

**Never run a bare `serve-sim --kill`.** It takes down every other session's
mirror. Always `--kill <udid>`.

**The broker matches its pool on the device NAME, exactly, with no runtime
filter.** A stock name like "iPhone 17 Pro" can exist on two runtimes at once,
so a pool of stock names eventually hands a station a device on a beta runtime
nobody meant to support — and nothing downstream notices, because the udid is
valid and the device boots. Two defences, and you want both: purpose-named
devices (`sim-bootstrap.sh` creates them), and `SIM_RUNTIME_MATCH` in
`.mobile-workflow.conf`, which `sim_udid()` enforces on **claimed** udids too.
That guard has to live in the consumer, because the broker has nowhere to put it.

---

## 4. Worktrees: what breaks, and what to do

A station in a git worktree is isolated from the shared checkout, and two things
follow.

**`.nodeterm/` lives beside the main checkout, not the worktree.** The naive
lookup finds nothing, and the bundle this grew out of simply gave up there —
polling a file that would never exist for 90 seconds, then leaving the node at
nodeterm's default 720×520 landscape box for a portrait phone. `mobile-env.sh`
asks git for the common dir instead, so `CANVAS_JSON` resolves to the main
checkout's canvas file from inside a worktree. That fixes sizing and seating.

**Claude Code refuses shell commands it cannot prove stay inside the worktree.**
This is compiled in, not configurable. Practically: a *single, simple*
invocation is fine —

```bash
scripts/mobile/sim-node.sh <udid>
```

— and a compound one (`&&`, `;`, redirects) may be refused. Keep station
commands simple. If one is refused, run the steps by hand rather than trying to
outsmart the guard.

---

## 5. Canvas mechanics that will cost you an hour each

Full reference in [NODETERM.md](NODETERM.md). The four that matter most:

1. **There is no resize verb, and `show-web` ignores size arguments.** Node sizes
   are hardcoded constants in the renderer; every new web node is 720×520. The
   only way to size one is to edit `<project>/.nodeterm/project.json`, which the
   running app picks up and keeps across its own saves. Write atomically, bump
   `rev`, rewrite `savedAt`, and batch every change into one write — each write
   costs a canvas reload.

2. **The control API's reply is not to be believed.** `close` prints "Could not
   reach nodeterm (control endpoint unreachable)" on closes that already landed,
   because the HTTP request gives up while the confirmation dialog is still on
   screen. A timeout is **not** a refusal, and re-firing merely queues another
   dialog in the user's face. Fire once, then poll `list`.

3. **The 720×520 ownership test.** Reshape a node only while it still measures
   exactly 720×520. Any other size was chosen by dragging, and that node — size
   *and* position — belongs to the user. The rule self-repairs: a node seated
   but not yet reshaped is still at the default, so the next run fixes it.

4. **A page that loads is not a stream that renders.** A killed stream leaves a
   node that reads as perfectly healthy: same title, same size, same place. The
   only real liveness check is a JPEG start-of-image marker in the body, and two
   traps make the obvious implementations wrong — reading an endless stream
   always ends in a timeout, so curl's exit code says nothing; and BSD grep
   *rejects* those bytes under a UTF-8 locale rather than not matching, so the
   marker must be searched for in Python.

---

## 6. When something is wrong

**Run `scripts/mobile/sim-doctor.sh` first.** Almost every failure here is
silent, and the doctor checks the links in order.

| Symptom | Cause and fix |
|---|---|
| `claim_simulator` blocks or says capacity reached | The class is full. Release something finished, or queue with `--after`. Do not loop, and do not work around it by grabbing an unclaimed device. |
| `claim_simulator` keeps handing out an old pool | The MCP server reads `~/.simbroker/config.json` **once, at start-up**. The CLI re-reads every time, so `simbroker devices` shows the truth and the two disagree. Only restarting the agent session fixes it. |
| A station gets a device on the wrong OS | The pool matched on name. Purpose-name the devices and set `SIM_RUNTIME_MATCH`. |
| Mirror is a 720×520 landscape box | The canvas file was not writable or nodeterm had not saved the node yet. Re-run `sim-node.sh`. |
| Node looks fine, shows nothing | The stream died. `inventory.py` prints `DEAD`. Re-run `sim-node.sh` — it re-points the existing node. Do not open a second. |
| Everyone's mirror died at once | Somebody ran a bare `serve-sim --kill`. |
| `sim-node.sh` reports no frame | The device is not really booted, or the stream is wedged. `--kill <that udid>` and retry. |
| Nothing simulator-related is permitted | The permissions allowlist was not merged into `.claude/settings.json`, or the command was typed with a different path than the allowlist entry. Entries match the command as typed. |
| The auto-seat hook never fires | Its trigger list does not match how this project runs the app. Set `SEAT_TRIGGERS`, or delete the hook. |

---

## 7. Reproducing from scratch

1. **Xcode** (full, or the Command Line Tools plus at least one iOS runtime).
   `mobile-env.sh` asks `xcode-select -p`; set `DEVELOPER_DIR` in
   `.mobile-workflow.conf` only if this project needs a different Xcode than the
   machine default.
2. **Node**, for `npx` — `serve-sim` is fetched on demand and pinned to nothing.
   Say "0.1.45 or later": before that its touches did not reach the device.
3. **simbroker**: `go install github.com/RyanJThompson/simbroker/cmd/simbroker@latest`,
   then `claude mcp add simbroker --scope user -- simbroker mcp`. The
   registration invokes the bare command `simbroker`, so a launch context
   without its directory on `PATH` silently loses the MCP server.
4. **`./install.sh /path/to/project`**, then edit `.mobile-workflow.conf`.
5. **`scripts/mobile/sim-bootstrap.sh`** — creates the purpose-named devices and
   prints the `~/.simbroker/config.json` block. Nothing else creates devices, and
   a pool naming devices that do not exist fails every claim.
6. **Paste [CLAUDE.snippet.md](CLAUDE.snippet.md) into the project's
   `CLAUDE.md`.** This is the step that makes agents follow the workflow instead
   of improvising, and it is the one most likely to be skipped.
7. **Restart the agent session** — the broker's MCP server, the skills and the
   settings are all read at start-up.
8. **`scripts/mobile/sim-doctor.sh`** until it is green.

There is no Simulator.app in this picture at all, and it is not missed: `simctl`
is unaffected by its absence, which is why the whole toolchain works headlessly —
and a native window could not be seated on the canvas anyway.
