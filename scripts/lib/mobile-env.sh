#!/bin/bash
# Shared machinery for the nodeterm mobile workflow scripts.
#
# This file is the part that does NOT change between projects. Everything a
# project gets to decide lives in `.mobile-workflow.conf` at the project root —
# see mobile-workflow.conf.example. Keep that separation: the moment a device
# name or a bundle id appears in here, the next project to copy this has to edit
# machinery instead of policy.
#
# Sourced, never executed:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/mobile-env.sh"
#
# What it gives you:
#
#   PROJECT_ROOT      the project the caller is working in
#   CANVAS_JSON       the nodeterm canvas file to write (worktree-aware)
#   DEVELOPER_DIR     exported, so xcrun agrees with the rest of the toolchain
#   sim_udid          resolve + vet a simulator udid (the runtime guard)
#   sim_name          the device name for a udid
#   sim_is_booted     read-only boot check that does not boot anything

set -euo pipefail

# ── Where are we ──────────────────────────────────────────────────────────────
#
# Walk up for the config file first, then for a repo. Deriving the root from the
# script's own location is the last resort and not the first, because these
# scripts get installed at different depths in different projects — the bundle
# this grew out of hardcoded `dirname/../..` and broke the moment anyone moved
# it one level.

_walk_up_for() {
  local needle="$1" dir="${2:-$PWD}"
  while [ "$dir" != "/" ]; do
    if [ -e "$dir/$needle" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$(_walk_up_for .mobile-workflow.conf 2>/dev/null || true)"
fi
if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "${PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export PROJECT_ROOT

# ── Project policy ────────────────────────────────────────────────────────────

MOBILE_WORKFLOW_CONF="${MOBILE_WORKFLOW_CONF:-$PROJECT_ROOT/.mobile-workflow.conf}"
if [ -f "$MOBILE_WORKFLOW_CONF" ]; then
  # shellcheck source=/dev/null
  source "$MOBILE_WORKFLOW_CONF"
fi

# ── Toolchain ─────────────────────────────────────────────────────────────────
#
# Honour an explicit DEVELOPER_DIR, then whatever `xcode-select -p` says, and
# only then guess. A machine running an Xcode beta as its only install is the
# case that breaks naive scripts: `xcode-select -p` is the authority, and asking
# it is what lets the same file work on a machine with a stock Xcode.

if [ -z "${DEVELOPER_DIR:-}" ]; then
  DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
fi
if [ -z "$DEVELOPER_DIR" ] || [ ! -d "$DEVELOPER_DIR" ]; then
  for candidate in \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer; do
    [ -d "$candidate" ] && DEVELOPER_DIR="$candidate" && break
  done
fi
export DEVELOPER_DIR

# ── Defaults ──────────────────────────────────────────────────────────────────
#
# Every one of these is overridable from the conf file or the environment, and
# the environment wins — `SIM_NODE_H=820 scripts/mobile/sim-node.sh` is a
# supported one-run override.

# Empty means "any runtime". Set it in the conf file the moment the project has
# a runtime it actually depends on: the broker matches its pool on device NAME
# alone and has no runtime filter, so if a guard does not live here it lives
# nowhere. See docs/LIMITS.md.
export SIM_RUNTIME_MATCH="${SIM_RUNTIME_MATCH:-}"

# The device used when nobody passes a udid. Right for one session, wrong the
# moment there are two — which is what the broker is for.
export SIM_NAME="${SIM_NAME:-}"

# Canvas node shape, in points. Height alone decides how large the device
# renders: the picture is fitted inside the node, so width past the
# aspect-derived minimum buys black bars and nothing else. 686 tall, less ~68
# for nodeterm's title bar and serve-sim's button row, fits the tallest iPhone
# in a pool without cropping.
export SIM_NODE_W="${SIM_NODE_W:-352}"
export SIM_NODE_H="${SIM_NODE_H:-686}"
export SIM_NODE_GAP="${SIM_NODE_GAP:-100}"

export SHOT_DIR="${SHOT_DIR:-$PROJECT_ROOT/.build/shots}"
export BUNDLE_ID="${BUNDLE_ID:-}"

# Declared unconditionally so `${#SIM_POOL[@]}` is safe under `set -u` in every
# consumer, whether or not the conf file mentions it.
if ! declare -p SIM_POOL >/dev/null 2>&1; then
  SIM_POOL=()
fi

# ── nodeterm ──────────────────────────────────────────────────────────────────

export NODETERM_SHIM="${NODETERM_SHIM:-$HOME/Library/Application Support/node-terminal/canvas-control/nodeterm.sh}"

# Which canvas file to write.
#
# `.nodeterm/` sits beside the MAIN checkout, so a session inside a git worktree
# that looks for `$PROJECT_ROOT/.nodeterm` finds nothing — and the bundle this
# grew out of simply gave up there, spent 90 seconds polling a file that would
# never exist, and left the node at nodeterm's default 720x520. Ask git for the
# common dir instead: from a worktree that resolves to the main checkout's
# `.git`, whose parent is the canvas root.
_canvas_json() {
  local common main
  if [ -f "$PROJECT_ROOT/.nodeterm/project.json" ]; then
    printf '%s\n' "$PROJECT_ROOT/.nodeterm/project.json"
    return 0
  fi
  common="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    main="$(dirname "$common")"
    if [ -f "$main/.nodeterm/project.json" ]; then
      printf '%s\n' "$main/.nodeterm/project.json"
      return 0
    fi
  fi
  # The default project — a nodeterm window opened on no project at all.
  printf '%s\n' "$HOME/.nodeterm/project.json"
}
export CANVAS_JSON="${CANVAS_JSON:-$(_canvas_json)}"

# ── Devices ───────────────────────────────────────────────────────────────────

# Resolve the simulator to drive, refusing one on the wrong runtime rather than
# quietly building against it.
#
# Precedence: SIM_UDID (how a broker claim gets in) beats SIM_NAME beats
# failure. The runtime check applies to a CLAIMED udid exactly as it does to a
# name — that is the whole point. simbroker matches its pool on the device name
# and has no runtime filter, so a pool that has drifted onto a beta runtime is
# caught here, at the door, instead of an hour later.
sim_udid() {
  xcrun simctl list devices -j \
    | SIM_NAME="${SIM_NAME:-}" SIM_RUNTIME_MATCH="${SIM_RUNTIME_MATCH:-}" \
      SIM_UDID="${SIM_UDID:-}" /usr/bin/python3 -c '
import json, os, sys

name = os.environ["SIM_NAME"]
match = os.environ["SIM_RUNTIME_MATCH"]
wanted = os.environ["SIM_UDID"].strip()
devices = json.load(sys.stdin)["devices"]

if wanted:
    for runtime, entries in devices.items():
        for device in entries:
            if device["udid"].lower() != wanted.lower():
                continue
            if match and match not in runtime:
                raise SystemExit(
                    f"Simulator {wanted} is on {runtime}, not a {match} runtime.\n"
                    "Claim a device from the simbroker pool, or relax "
                    "SIM_RUNTIME_MATCH in .mobile-workflow.conf."
                )
            if not device["isAvailable"]:
                raise SystemExit(f"Simulator {wanted} is not available.")
            print(device["udid"])
            raise SystemExit
    raise SystemExit(f"No simulator with udid {wanted}.")

if not name:
    raise SystemExit(
        "No device named. Claim one with the claim_simulator MCP tool and pass "
        "the udid, or set SIM_NAME in .mobile-workflow.conf for single-session "
        "work."
    )

for runtime, entries in devices.items():
    if match and match not in runtime:
        continue
    for device in entries:
        if device["name"] == name and device["isAvailable"]:
            print(device["udid"])
            raise SystemExit

raise SystemExit(
    f"No available simulator named {name!r}"
    + (f" on a {match} runtime" if match else "")
    + ".\nRun scripts/mobile/sim-bootstrap.sh to create the pool."
)
'
}

sim_name() {
  xcrun simctl list devices -j | UDID="$1" /usr/bin/python3 -c '
import json, os, sys

udid = os.environ["UDID"]
for entries in json.load(sys.stdin)["devices"].values():
    for device in entries:
        if device["udid"] == udid:
            print(device["name"])
            raise SystemExit
print("Simulator")
'
}

# Read-only. `simctl bootstatus <udid> -b` is NOT a question — the -b boots the
# device if it is down, so reaching for it to ask whether something is booted
# answers by making it true. Every status check must come through here.
sim_is_booted() {
  xcrun simctl list devices | grep -- "$1" | grep -q "(Booted)"
}
