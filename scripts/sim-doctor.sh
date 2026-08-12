#!/bin/bash
# Checks every link in the chain, and says which one is broken.
#
#   scripts/mobile/sim-doctor.sh
#
# Run this FIRST when anything looks wrong, and run it once after installing.
# The failure modes in this workflow are mostly silent — a stale MCP server
# handing out an old pool, a pool name that fell out of the config, a stream
# that died leaving a node that still looks perfectly healthy — so a green
# doctor is worth more than any single symptom.
#
# Exit status is the number of FAILs, so it composes: `sim-doctor.sh || echo bad`.

source "$(dirname "${BASH_SOURCE[0]}")/lib/mobile-env.sh"

FAILS=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$(( FAILS + 1 )); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "Project"
echo "  root        $PROJECT_ROOT"
if [ -f "$MOBILE_WORKFLOW_CONF" ]; then
  ok "config      $MOBILE_WORKFLOW_CONF"
else
  bad "no .mobile-workflow.conf at $PROJECT_ROOT — copy mobile-workflow.conf.example"
fi
echo "  runtime     ${SIM_RUNTIME_MATCH:-(any — see docs/LIMITS.md)}"
echo "  default sim ${SIM_NAME:-(none; every run must pass a claimed udid)}"

head_ "Toolchain"
if [ -d "$DEVELOPER_DIR" ]; then
  ok "DEVELOPER_DIR $DEVELOPER_DIR"
else
  bad "DEVELOPER_DIR is not a directory: ${DEVELOPER_DIR:-unset}"
fi
if xcrun simctl help >/dev/null 2>&1; then
  ok "xcrun simctl"
else
  bad "xcrun simctl does not run — install Xcode or the Command Line Tools"
fi
if command -v npx >/dev/null 2>&1; then
  ok "npx           $(command -v npx)"
else
  bad "npx not found — serve-sim is fetched with npx, so the mirror cannot start"
fi
if [ -x /usr/bin/python3 ]; then
  ok "python3       /usr/bin/python3"
else
  bad "/usr/bin/python3 missing — every canvas edit and JSON probe goes through it"
fi

head_ "simbroker"
if command -v simbroker >/dev/null 2>&1; then
  ok "binary        $(command -v simbroker)"
  if simbroker doctor >/dev/null 2>&1; then
    ok "simbroker doctor passes"
  else
    warn "simbroker doctor reports a problem — run it directly for the detail"
  fi
  BROKER_CONF="$HOME/.simbroker/config.json"
  if [ -f "$BROKER_CONF" ]; then
    ok "config        $BROKER_CONF"
  else
    warn "no $BROKER_CONF — with no models list, EVERY simulator on this machine is in the pool"
  fi
else
  bad "simbroker not on PATH — see https://github.com/RyanJThompson/simbroker"
fi

# Is the MCP server actually registered? A claim made from the CLI inside an
# agent tool call is reclaimed almost immediately (see docs/LIMITS.md), so the
# MCP route is not a nicety.
if command -v claude >/dev/null 2>&1; then
  if claude mcp list 2>/dev/null | grep -qi '^simbroker'; then
    ok "MCP server registered with Claude Code"
  else
    bad "simbroker MCP server not registered — claude mcp add simbroker --scope user -- simbroker mcp"
  fi
fi

head_ "Device pool"
if [ "${#SIM_POOL[@]}" -eq 0 ]; then
  warn "SIM_POOL is empty in .mobile-workflow.conf — nothing to check"
else
  DEVICES_JSON="$(xcrun simctl list devices -j 2>/dev/null || echo '{}')"
  for entry in "${SIM_POOL[@]}"; do
    name="${entry%%:*}"
    line="$(printf '%s' "$DEVICES_JSON" | NAME="$name" MATCH="${SIM_RUNTIME_MATCH:-}" /usr/bin/python3 -c '
import json, os, sys

name = os.environ["NAME"]
match = os.environ["MATCH"]
try:
    devices = json.load(sys.stdin)["devices"]
except (ValueError, KeyError):
    raise SystemExit("no simctl output")

hits = [
    (runtime, d)
    for runtime, entries in devices.items()
    for d in entries
    if d["name"] == name
]
if not hits:
    print("MISSING")
    raise SystemExit
wrong = [r for r, d in hits if match and match not in r]
right = [(r, d) for r, d in hits if not match or match in r]
if not right:
    print("WRONGRUNTIME " + wrong[0].rsplit(".", 1)[-1])
    raise SystemExit
if len(hits) > 1:
    print("AMBIGUOUS %d copies, %d on the wrong runtime" % (len(hits), len(wrong)))
    raise SystemExit
runtime, device = right[0]
print("OK %s %s" % (runtime.rsplit(".", 1)[-1], "available" if device["isAvailable"] else "UNAVAILABLE"))
')"
    case "$line" in
      OK*available)      ok "$name  ${line#OK }" ;;
      OK*UNAVAILABLE)    bad "$name is not available (${line#OK })" ;;
      MISSING)           bad "$name does not exist — run scripts/mobile/sim-bootstrap.sh" ;;
      WRONGRUNTIME*)     bad "$name exists but on ${line#WRONGRUNTIME }, not $SIM_RUNTIME_MATCH" ;;
      AMBIGUOUS*)        bad "$name: ${line#AMBIGUOUS } — the broker matches on NAME alone and cannot tell them apart" ;;
      *)                 warn "$name: $line" ;;
    esac
  done

  # The two lists that have to agree, and the one place nothing checks for you.
  if [ -f "$HOME/.simbroker/config.json" ]; then
    MISSING="$(SIM_POOL_NAMES="$(printf '%s\n' "${SIM_POOL[@]}" | cut -d: -f1)" /usr/bin/python3 -c '
import json, os, sys

want = [n for n in os.environ["SIM_POOL_NAMES"].splitlines() if n]
try:
    with open(os.path.expanduser("~/.simbroker/config.json")) as handle:
        conf = json.load(handle)
except (OSError, ValueError):
    raise SystemExit
models = conf.get("models")
if models is None:
    print("__NOMODELS__")
    raise SystemExit
if isinstance(models, list):
    models = {"ios": models}
have = set(models.get("ios") or [])
for n in want:
    if n not in have:
        print(n)
')"
    case "$MISSING" in
      "")             ok "every pool device is in ~/.simbroker/config.json" ;;
      __NOMODELS__)   warn "~/.simbroker/config.json has no models list — every simulator on the machine is claimable, including ones on the wrong runtime" ;;
      *)              bad "not in ~/.simbroker/config.json models.ios: $(printf '%s\n' "$MISSING" | tr '\n' ' ')" ;;
    esac
  fi
fi

head_ "nodeterm"
if [ -n "${NODETERM_CANVAS_CONTROL:-}" ]; then
  ok "canvas control is available (this terminal: ${NODETERM_NODE_ID:-unknown})"
  if [ -f "$NODETERM_SHIM" ]; then
    ok "shim          $NODETERM_SHIM"
  else
    bad "shim missing at $NODETERM_SHIM"
  fi
  if [ -f "$CANVAS_JSON" ]; then
    ok "canvas file   $CANVAS_JSON"
  else
    bad "no canvas file at $CANVAS_JSON — nodes cannot be sized or seated, only created"
  fi
else
  warn "not a nodeterm session — sim-node.sh will print the URL instead of seating a node"
fi

head_ "Live devices"
BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -c "(Booted)" || true)"
echo "  booted        ${BOOTED:-0}"
if command -v simbroker >/dev/null 2>&1; then
  simbroker list 2>/dev/null | sed 's/^/  /' || true
fi

printf '\n'
if [ "$FAILS" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%d check(s) failed.\033[0m\n' "$FAILS"
fi
exit "$FAILS"
