# nodeterm canvas control — reference

Extracted from nodeterm 0.2.43 by unpacking `Contents/Resources/app.asar`, and
verified by probing. **Check against your version before relying on internals** —
the verb list and the hardcoded sizes are the parts most likely to move.

## The shim

```sh
sh "$HOME/Library/Application Support/node-terminal/canvas-control/nodeterm.sh" <verb> [--flag value ...]
```

It is a **generic passthrough**, not a fixed CLI: it turns `--flag value` pairs
into `--data-urlencode arg.flag=value` and POSTs to
`http://localhost/control/<verb>` over a unix socket (or
`127.0.0.1:$NODETERM_HOOK_PORT`), authenticated with `X-Nodeterm-Hook-Token`. So
any verb the app implements works whether or not it is documented, and unknown
verbs fail harmlessly with `unknown verb: <x>` — probing costs nothing and
creates nothing.

The live endpoint is re-read from `$NODETERM_HOOK_ENDPOINT` on every call, so a
session that outlived an app restart still reaches the current server.

## Environment

| Variable | Meaning |
|---|---|
| `NODETERM_CANVAS_CONTROL` | set when the canvas can be driven; the shim refuses without it |
| `NODETERM_NODE_ID` | the calling terminal's node id — sent as `nodeId` on every call |
| `NODETERM_HOOK_ENDPOINT` | file sourced for the live sock/port/token |
| `NODETERM_PERM_WAIT_SECS` | how long a confirmation dialog is waited on; **0** when approvals are off |

Scripts should branch on `NODETERM_CANVAS_CONTROL` and degrade gracefully —
print the URL — rather than failing.

## Verbs

The dispatcher's `switch (verb)` case labels, in source order:

```
list  open-terminal  open-claude  open-agent  show-image  show-video  show-web
open-browser  group  ungroup  move  arrange  align  link  verify  spawn-team
open-worktree  close-worktree  branch  rename  write  close  board  assign
```

That is **24** labels — the complete switch. Nine words that look verb-like in
the bundle are not verbs and return `unknown verb`: `merge`/`remove`/`unbind`
are `--mode` values of `close-worktree` (default `unbind`), and
`blocked`/`done`/`waiting`/`working`/`session` are agent-status event kinds.

Notably **absent**: any resize / size / set-size verb. Confirmed by probing.

Other notes:

- `show-web` also takes `--file <path>` and `--html "<markup>"`, so an arbitrary
  generated page becomes a canvas node with no server at all. Both are refused on
  an SSH project (only `--url` is universal); an explicit `--file` needs a
  `media.allow()` step that a generated `--html` does not.
- `open-browser --url` creates a different node **kind** (`browser`, 800×560),
  not a web node.
- `write` and `close` require the user to approve a dialog, and may be denied.
- `board` / `assign` are kanban metadata only and never move nodes.
- `--after <id,id>` opens a node **armed**: it does not start until every listed
  station goes idle, and arrives context-linked to each. Only agent nodes that
  report status can be waited on — waiting on a plain terminal is refused,
  because a plain terminal never reports finishing.

## Node sizes are hardcoded

From the renderer bundle:

```js
const GROUP_SIZE   = { width: 760, height: 540 };
const EDITOR_SIZE  = { width: 660, height: 460 };
const DIFF_SIZE    = { width: 860, height: 500 };
const VIDEO_SIZE   = { width: 640, height: 420 };
const WEB_SIZE     = { width: 720, height: 520 };
const BROWSER_SIZE = { width: 800, height: 560 };
```

`createWebNode` reads no setting and takes no argument. `settings.json`'s
`defaultNodeWidth` / `defaultNodeHeight` apply to **terminal nodes only** —
`terminalNodeSize()` is their sole reader. Every other kind is a constant, so a
fresh web node measures 720×520 regardless.

## project.json is writable from outside

`<project>/.nodeterm/project.json` — or `~/.nodeterm/project.json` for the
default project. **In a git worktree it is beside the MAIN checkout**; ask git
for `--git-common-dir` and take its parent.

Persisted node shape:

```json
{ "id": "web-…", "kind": "web", "title": "…",
  "size": { "width": 352, "height": 686 },
  "position": { "x": 1012, "y": 62 },
  "url": "http://127.0.0.1:3101" }
```

The running app **picks up external edits and keeps them across its own saves.**
Verified: wrote a size externally, forced a save with `rename`, and the external
value survived (rev advanced, title changed, size held). This is the only way to
size a node.

Rules when writing it:

1. **Wait for the node to appear.** After `show-web` it is not in the file yet —
   poll with a generous deadline (90 s at 0.4 s intervals), because a window
   nobody is looking at can sit on the change for minutes.
2. **Sleep ~0.5 s after the app's own save.** An external change lands silently
   on a clean canvas but raises a conflict bar on a dirty one, and the save that
   just happened is what clears the flag.
3. **Bump `rev` and rewrite `savedAt`** (ISO-8601 milliseconds, `Z`). That is
   what makes the app *adopt* the edit rather than merely tolerate it.
4. **Batch every change into one write, and write nothing if nothing changed** —
   each write costs a canvas reload. On removal, prune the id from `ropes` and
   `bridges` in the same write; rope ids are `"ctrl-<terminal>-<node>"`.
5. Write **atomically** — temp file in the same directory, then `os.replace`.
6. Match on `kind == "web"` **plus** a stable identifying field, and only ever
   remove **web** nodes this way. Terminals hold live sessions, and the
   confirmation gate on `close` is worth keeping for those.

**Which field is stable differs by device type.** For a simulator it is the
*title* (`"<device name> — simulator"`), because a node's URL is fixed at
creation while serve-sim reallocates helper ports per session — so URL matching
goes stale, orphans nodes, or worse leaves a node quietly showing a *different*
device. For anything on a pinned port, the URL is the narrower match.

## Gotchas

**Replies lie about failure, and the reason is a confirmation dialog.**

- `close` / `write` raise a dialog, and **only one confirmation can be pending**.
  Further calls return `a confirmation is already pending`.
- The HTTP request **gives up while the dialog stays on screen**. So a timeout is
  **not** a refusal, and re-firing merely queues another dialog. Read
  `NODETERM_PERM_WAIT_SECS` rather than hardcoding the 45 it usually holds — it
  is 0 when approvals are off or on a non-Claude agent node.
- The message is emitted by the shim on *any* transport failure, so it cannot
  distinguish a pending dialog from an app that quit, and it can appear for
  verbs other than close/write.

Fire once and poll:

```sh
gone() { ! sh "$SHIM" list 2>/dev/null | grep -q "^$1 "; }
for n in <node-id> <node-id>; do
  sh "$SHIM" close --node "$n" 2>&1 || true
  for _ in $(seq 1 30); do gone "$n" && break; sleep 3; done
done
```

**Grouping does not move nodes.** `group` only wraps loose top-level nodes and
silently skips any already inside a frame; use `move --nodes <ids> --group <id>`
for those. `show-web` has no group argument, so a new node lands at top level.

**`arrange` / `align` need one container.** Every id must share a parent — you
cannot mix framed and loose nodes, or nodes from two frames, in one call. Since
grouping preserves each node's scattered position, a fresh frame is usually too
wide: `arrange` its children to fix that.
