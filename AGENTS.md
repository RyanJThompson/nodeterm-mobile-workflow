# For the agent installing this

You have been pointed at this repository and asked to add it to a mobile
project. This file is the runbook. Work through it in order — later steps
assume earlier ones.

**Read [docs/WORKFLOW.md](docs/WORKFLOW.md) first, in full.** It is not
background reading. Several constraints in it are counter-intuitive enough that
guessing produces something that looks right and silently does not work, and you
will be asked to explain choices that only make sense once you have read it.

## Is this the right thing to install?

Yes, if the project is an **iOS app** built with Xcode, and the user wants any
of: several agents working at once, a live simulator beside the terminal, or a
disciplined way to stop agents fighting over devices.

No, if: the project is not iOS (see [docs/LIMITS.md](docs/LIMITS.md) — Android
can be *claimed* but not mirrored), the machine is not macOS, or the user is not
running nodeterm. Say so plainly rather than installing something inert.

You can install it for a **single-agent** project too — the broker still stops a
second session from colliding with the first, and the mirror is worth having on
its own. Do not oversell the orchestration half if there is only ever one agent.

## 1. Install

```bash
git clone https://github.com/RyanJThompson/nodeterm-mobile-workflow
./nodeterm-mobile-workflow/install.sh /path/to/the/project
```

`--dry-run` shows what it would touch. `--no-hook` skips the auto-seat hook.

It copies scripts, skills and a command into the project, merges a permissions
allowlist into `.claude/settings.json` (keeping what is already there), and
creates `.mobile-workflow.conf` **only if absent** — that file is the project's
policy and is never overwritten, so re-running the installer is how an update is
taken.

Read its closing output. Everything it could not do for you is listed there, in
order.

## 2. Fill in `.mobile-workflow.conf`

This is the only file the project should need to edit, and the values are not
guesses — read them out of the repository:

| Value | Where it comes from |
|---|---|
| `BUNDLE_ID` | the Xcode project's `PRODUCT_BUNDLE_IDENTIFIER`, or `Info.plist` |
| `SIM_RUNTIME_MATCH` | the deployment target, reconciled against `xcrun simctl list runtimes` — pin the runtime the project actually supports, not the newest installed |
| `SIM_NAME` / `SIM_POOL` | purpose-named devices prefixed with the project name |

**Why purpose-named devices matters more than it looks.** simbroker matches pool
membership on the device *name*, exactly, with no OS filter. A pool of stock
names will eventually hand an agent a device on a beta runtime, and nothing
downstream notices, because the udid is valid and the device boots.
`SIM_RUNTIME_MATCH` is the second gate, enforced by `sim_udid()` on claimed
udids too.

Show the user the finished file and explain each choice. These are decisions,
not defaults.

## 3. simbroker

```bash
simbroker doctor          # already installed?
go install github.com/RyanJThompson/simbroker/cmd/simbroker@latest
claude mcp add simbroker --scope user -- simbroker mcp
```

The MCP registration invokes the bare command `simbroker`, so a launch context
without its directory on `PATH` silently loses the server. Check
`"$(go env GOPATH)/bin"` is on `PATH`.

## 4. Create the pool

```bash
cd /path/to/the/project && scripts/mobile/sim-bootstrap.sh
```

Creates any missing devices from `SIM_POOL` on one runtime, and prints the
`~/.simbroker/config.json` block to merge. Set `capacity.ios` to what the Mac
can really take — three booted simulators is the usual ceiling, and that number
is also the hard cap on how many agents can work in parallel.

Nothing else in the workflow creates devices, and a pool naming devices that do
not exist fails every claim.

## 5. Tell future agents

Append [docs/CLAUDE.snippet.md](docs/CLAUDE.snippet.md) to the project's
`CLAUDE.md`, filling in the project-specific build, run and test commands at the
bottom.

**Every one of those commands must accept `SIM_UDID`.** If they do not — if the
project's `run.sh` hardcodes a device or takes whatever is booted — parallel
agents will all build onto one device and the entire installation is decorative.
Fixing that is part of this job, not a follow-up. If you cannot fix it, say so
explicitly rather than reporting success.

This step is the one most likely to be skipped and the one that matters most:
skills are read at session start, but `CLAUDE.md` is in front of an agent the
whole time.

## 6. Restart, then check

The simbroker MCP server reads its config once at start-up; Claude Code reads
skills and settings at start-up. Nothing you wrote in steps 3–5 reaches the
running session.

```bash
scripts/mobile/sim-doctor.sh
```

Exit status is the number of failures. Do not report success until it is green,
and do not describe a `warn` as green.

## 7. Prove it works

Claim a device with the `claim_simulator` MCP tool, seat it, take a screenshot:

```bash
scripts/mobile/sim-node.sh <udid>
SIM_UDID=<udid> scripts/mobile/sim-capture.sh smoke
```

Read the PNG back. A green doctor with no picture is not a working install.

## What to report

- The finished `.mobile-workflow.conf`, with each value justified.
- The `sim-doctor.sh` output, verbatim.
- Anything you could not do, named — especially build scripts that do not accept
  `SIM_UDID`, a `capacity` you guessed, or a runtime you had to pick between.
- The reminder to restart, if you have not already been restarted.

Do not claim the parallel workflow works until at least one device has been
claimed, seated and screenshotted.
