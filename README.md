# nodeterm-mobile-workflow

**Parallel AI coding agents for an iOS project — each on its own git worktree,
its own claimed simulator, and its own live mirror on the canvas.**

One agent orchestrates. Several work. Nobody collides.

```
┌───────────────────────────────────────────────────────────────────────┐
│  nodeterm canvas                                                      │
│                                                                       │
│   ┌──────────────┐                                                    │
│   │ orchestrator │  plans · opens stations · collects · reconciles    │
│   └──────┬───────┘                                                    │
│          ├──────────────────┬──────────────────┐                      │
│   ┌──────▼──────┐   ┌───────▼─────┐   ┌────────▼────┐                 │
│   │ worktree A  │   │ worktree B  │   │ worktree C  │   git branches  │
│   │ claude      │   │ claude      │   │ claude      │   sessions      │
│   │ ┌─────────┐ │   │ ┌─────────┐ │   │ ┌─────────┐ │                 │
│   │ │ iPhone  │ │   │ │ iPhone  │ │   │ │ iPhone  │ │   live, tappable│
│   │ │ mirror  │ │   │ │ mirror  │ │   │ │ mirror  │ │   ~29 fps       │
│   │ └─────────┘ │   │ └─────────┘ │   │ └─────────┘ │                 │
│   └─────────────┘   └─────────────┘   └─────────────┘                 │
└──────────┬──────────────────┬──────────────────┬──────────────────────┘
           │ claim_simulator  │                  │
           ▼                  ▼                  ▼
        ┌────────────────────────────────────────────┐
        │ simbroker — one device each, RAM-capped    │
        └────────────────────────────────────────────┘
```

Without the broker, three agents pick the same simulator, install over each
other's build, and each sees a mirror that goes black for reasons none of them
can explain. The whole repo exists to make that impossible and then to make the
rest of it pleasant.

## Add it to your project

Paste this into Claude Code from inside your iOS project. It is written to be
executed, not read.

```text
Set up the nodeterm mobile workflow in this project, so that several AI agents
can work here in parallel — each with its own git worktree, its own simulator
claimed from a shared pool, and its own live mirror on the nodeterm canvas.

The workflow lives at https://github.com/RyanJThompson/nodeterm-mobile-workflow
It depends on simbroker (https://github.com/RyanJThompson/simbroker), which
allocates devices; building and launching this app stays in this project.

Do all of this, then tell me what you changed and what still needs my input:

1. Clone the workflow somewhere outside this project and run its installer:
       git clone https://github.com/RyanJThompson/nodeterm-mobile-workflow
       ./nodeterm-mobile-workflow/install.sh <this project's path>
   Read its output — it lists what it could not do for me.

2. Read nodeterm-mobile-workflow/docs/WORKFLOW.md top to bottom before going
   further. Several constraints in it are counter-intuitive enough that guessing
   produces something that looks right and silently does not work.

3. Fill in .mobile-workflow.conf from what you can see in this repo: BUNDLE_ID
   from the Xcode project, SIM_RUNTIME_MATCH from the deployment target and the
   runtimes actually installed, and a SIM_POOL of purpose-named devices prefixed
   with this project's name. Show me the file and explain each choice.

4. Install simbroker if it is missing, and register its MCP server once for this
   machine:
       go install github.com/RyanJThompson/simbroker/cmd/simbroker@latest
       claude mcp add simbroker --scope user -- simbroker mcp
   If that install 404s at sum.golang.org, the module is not publicly readable
   from here: do not retry it, read AGENTS.md section 3 and tell me which of the
   two routes there applies.

5. Run scripts/mobile/sim-bootstrap.sh to create the pool devices, and merge the
   ~/.simbroker/config.json block it prints. Set capacity.ios to what this Mac
   can really take — three booted simulators is the usual ceiling.

6. Append docs/CLAUDE.snippet.md to this project's CLAUDE.md, with the
   project-specific build, run and test commands filled in. Every one of them
   must accept SIM_UDID, or parallel agents will all build onto one device.

7. Tell me to restart my session, then run scripts/mobile/sim-doctor.sh and show
   me the output. Fix anything that is not green.
```

Or by hand: `./install.sh /path/to/project`, then follow the seven steps it
prints. [AGENTS.md](AGENTS.md) is the same runbook written for an agent.

## Requirements

| | |
|---|---|
| macOS with Xcode | or the Command Line Tools plus one iOS runtime |
| [nodeterm](https://nodeterm.app) | the canvas; this reads and writes its project file |
| [simbroker](https://github.com/RyanJThompson/simbroker) | device allocation, registered as an MCP server |
| Node | for `npx`; `serve-sim` 0.1.45+ is fetched on demand |
| Claude Code | or any agent that reads `CLAUDE.md` and MCP tools |

Everything is macOS- and iOS-simulator-shaped. Android emulators can be claimed
but not mirrored; physical iPhones need a different path entirely. Both are
documented honestly in [docs/LIMITS.md](docs/LIMITS.md).

## What you get

```
install.sh                          copy in, merge settings, print what is left
mobile-workflow.conf.example        the ONLY file a project should need to edit

docs/
  WORKFLOW.md                       the authoritative guide — read this
  NODETERM.md                       canvas control API: verbs, sizing, gotchas
  CLAUDE.snippet.md                 the block to paste into your CLAUDE.md
  LIMITS.md                         Android, physical devices, version coupling

scripts/                            → <project>/scripts/mobile/
  sim-node.sh                       seat a claimed simulator on the canvas
  sim-doctor.sh                     check every link in the chain
  sim-bootstrap.sh                  create the pool devices + broker config
  sim-capture.sh                    launch in a known state, screenshot it
  lib/mobile-env.sh                 machinery: paths, runtime guard, canvas file
  hooks/seat-simulator.sh           optional: auto-seat on first simulator use

skills/                             → <project>/.claude/skills/
  mobile-orchestrator/              plan, fan out, collect, verify, hand back
  simulator-node/                   one device on the canvas
  nodeterm-canvas/                  what is open, and what is secretly dead

commands/sim-teardown.md            → <project>/.claude/commands/
settings/claude-settings.snippet.json  permissions + the auto-seat hook
```

## The three things most likely to bite you

**The broker matches its pool on the device NAME, exactly, with no runtime
filter.** A stock name like "iPhone 17 Pro" can exist on two runtimes at once,
so a pool of stock names eventually hands an agent a device on a runtime nobody
meant to support — and nothing downstream notices, because the udid is valid and
the device boots. Use purpose-named devices *and* set `SIM_RUNTIME_MATCH`.

**The simbroker MCP server reads its config once, at start-up.** Editing
`~/.simbroker/config.json` does not reach a running session: `claim_simulator`
keeps handing out the old pool while the CLI shows the new one, and the two
disagree until you restart. `simbroker doctor` can show you it is stale. Nothing
can fix it in place.

**A page that loads is not a stream that renders.** A killed stream leaves a
canvas node that reads as perfectly healthy — same title, same size, same place.
Counting nodes is not counting devices. `inventory.py` prints `DEAD` for those;
the fix is to re-run `sim-node.sh`, which re-points the existing node.

Ten more, with their causes, are in
[WORKFLOW.md §6](docs/WORKFLOW.md#6-when-something-is-wrong).

## Provenance

Captured from a working setup on macOS 26 / Xcode 27 beta, where it is in daily
use, and then de-hardcoded: project constants moved to one config file, paths
resolved at runtime instead of assumed, worktree support fixed rather than
documented as broken, and the liveness checks made to test what they claim to
test. What is still specific to that machine is called out where it appears.

## License

MIT — see [LICENSE](LICENSE).
