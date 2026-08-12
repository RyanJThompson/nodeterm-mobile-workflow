#!/bin/bash
# Installs this workflow into a mobile project.
#
#   ./install.sh /path/to/your/project          # copy in, merge settings
#   ./install.sh /path/to/your/project --dry-run
#   ./install.sh /path/to/your/project --no-hook   # skip the auto-seat hook
#
# What it puts where:
#
#   <project>/scripts/mobile/                 the scripts (lib/, hooks/)
#   <project>/.claude/skills/                 mobile-orchestrator, simulator-node,
#                                             nodeterm-canvas
#   <project>/.claude/commands/sim-teardown.md
#   <project>/.claude/settings.json           permissions merged in, hook added
#   <project>/.mobile-workflow.conf           from the example, IF absent
#
# It never overwrites `.mobile-workflow.conf` — that file is the project's
# policy and yours to edit. Everything else is machinery and IS overwritten, so
# re-running this is how you take an update.
#
# It does NOT: install simbroker, register the MCP server, create simulators, or
# write your CLAUDE.md. Those need decisions or credentials this script does not
# have — it prints exactly what is left, in order, at the end.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
shift || true

DRY=""
HOOK="yes"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY="yes" ;;
    --no-hook) HOOK="" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "usage: ./install.sh /path/to/your/project [--dry-run] [--no-hook]" >&2
  exit 2
fi
if [ ! -d "$TARGET" ]; then
  echo "not a directory: $TARGET" >&2
  exit 2
fi
TARGET="$(cd "$TARGET" && pwd)"

say() { printf '  %s\n' "$*"; }
run() { if [ -n "$DRY" ]; then say "would: $*"; else "$@"; fi; }

echo "Installing the nodeterm mobile workflow into $TARGET"
[ -n "$DRY" ] && echo "(dry run — nothing will be written)"

# ── scripts ───────────────────────────────────────────────────────────────────
say "scripts/mobile/"
run mkdir -p "$TARGET/scripts/mobile/lib" "$TARGET/scripts/mobile/hooks"
for f in sim-node.sh sim-doctor.sh sim-capture.sh sim-bootstrap.sh; do
  run cp "$HERE/scripts/$f" "$TARGET/scripts/mobile/$f"
  run chmod +x "$TARGET/scripts/mobile/$f"
done
run cp "$HERE/scripts/lib/mobile-env.sh" "$TARGET/scripts/mobile/lib/mobile-env.sh"
run cp "$HERE/scripts/hooks/seat-simulator.sh" "$TARGET/scripts/mobile/hooks/seat-simulator.sh"
run chmod +x "$TARGET/scripts/mobile/hooks/seat-simulator.sh"

# ── skills and commands ───────────────────────────────────────────────────────
say ".claude/skills/ and .claude/commands/"
run mkdir -p "$TARGET/.claude/skills" "$TARGET/.claude/commands"
for skill in mobile-orchestrator simulator-node nodeterm-canvas; do
  run rm -rf "$TARGET/.claude/skills/$skill"
  run cp -R "$HERE/skills/$skill" "$TARGET/.claude/skills/$skill"
done
run cp "$HERE/commands/sim-teardown.md" "$TARGET/.claude/commands/sim-teardown.md"

# ── config ────────────────────────────────────────────────────────────────────
if [ -f "$TARGET/.mobile-workflow.conf" ]; then
  say ".mobile-workflow.conf exists — left alone"
  CONF_IS_NEW=""
else
  say ".mobile-workflow.conf  (from the example — EDIT IT)"
  run cp "$HERE/mobile-workflow.conf.example" "$TARGET/.mobile-workflow.conf"
  CONF_IS_NEW="yes"
fi

# ── settings ──────────────────────────────────────────────────────────────────
#
# Merged, not overwritten: a project's settings.json usually has permissions
# that matter. Existing allow entries are kept, ours are appended if absent, and
# an existing PostToolUse hook list gains one entry rather than being replaced.
say ".claude/settings.json  (merged)"
if [ -z "$DRY" ]; then
  SNIPPET="$HERE/settings/claude-settings.snippet.json" \
  TARGET_SETTINGS="$TARGET/.claude/settings.json" \
  WANT_HOOK="$HOOK" \
  /usr/bin/python3 - <<'PY'
import json, os

snippet_path = os.environ["SNIPPET"]
target_path = os.environ["TARGET_SETTINGS"]
want_hook = bool(os.environ["WANT_HOOK"])

with open(snippet_path, encoding="utf-8") as handle:
    snippet = json.load(handle)
snippet = {k: v for k, v in snippet.items() if not k.startswith("//")}

try:
    with open(target_path, encoding="utf-8") as handle:
        target = json.load(handle)
except (OSError, ValueError):
    target = {}

added = []

allow = target.setdefault("permissions", {}).setdefault("allow", [])
for entry in snippet["permissions"]["allow"]:
    if entry not in allow:
        allow.append(entry)
        added.append(entry)

if want_hook:
    hook_cmd = snippet["hooks"]["PostToolUse"][0]["hooks"][0]["command"]
    post = target.setdefault("hooks", {}).setdefault("PostToolUse", [])
    bash_entry = next((e for e in post if e.get("matcher") == "Bash"), None)
    if bash_entry is None:
        post.append(snippet["hooks"]["PostToolUse"][0])
        added.append("PostToolUse hook (new Bash matcher)")
    else:
        hooks = bash_entry.setdefault("hooks", [])
        if not any(h.get("command") == hook_cmd for h in hooks):
            hooks.append({"type": "command", "command": hook_cmd})
            added.append("PostToolUse hook (appended to existing Bash matcher)")

os.makedirs(os.path.dirname(target_path), exist_ok=True)
tmp = target_path + ".install.tmp"
with open(tmp, "w", encoding="utf-8") as out:
    json.dump(target, out, indent=2)
    out.write("\n")
os.replace(tmp, target_path)

print("    %d new entr%s" % (len(added), "y" if len(added) == 1 else "ies"))
for entry in added:
    print("      + " + entry)
PY
fi

# ── gitignore ─────────────────────────────────────────────────────────────────
if [ -f "$TARGET/.gitignore" ] && ! grep -q '^\.build/' "$TARGET/.gitignore" 2>/dev/null; then
  say "adding .build/ to .gitignore  (screenshots land there)"
  [ -z "$DRY" ] && printf '\n# nodeterm mobile workflow\n.build/\n' >> "$TARGET/.gitignore"
fi

# ── what is left ──────────────────────────────────────────────────────────────
cat <<EOF

Installed. What is left, in order — none of it can be done for you:

 1. EDIT $TARGET/.mobile-workflow.conf
    BUNDLE_ID, SIM_NAME, SIM_POOL and SIM_RUNTIME_MATCH are project decisions.
EOF
[ -n "$CONF_IS_NEW" ] || echo "    (yours was left alone — check it still matches this version)"
cat <<EOF

 2. INSTALL simbroker, if it is not already:
        go install github.com/RyanJThompson/simbroker/cmd/simbroker@latest
    and put "\$(go env GOPATH)/bin" on PATH.

 3. REGISTER the MCP server, once per machine:
        claude mcp add simbroker --scope user -- simbroker mcp

 4. CREATE the pool devices and write the broker config:
        cd $TARGET && scripts/mobile/sim-bootstrap.sh
    It prints the ~/.simbroker/config.json block to merge.

 5. TELL FUTURE AGENTS. Paste docs/CLAUDE.snippet.md into $TARGET/CLAUDE.md.
    Without it an agent will pick a device instead of claiming one, and the
    whole thing quietly stops working the moment there are two sessions.

 6. RESTART your agent session. The simbroker MCP server reads its config ONCE
    at start-up, and Claude Code reads skills and settings at start-up too.

 7. CHECK IT:
        cd $TARGET && scripts/mobile/sim-doctor.sh
EOF
