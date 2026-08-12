#!/bin/bash
# Creates the project's purpose-named simulators, and prints the simbroker
# config that has to agree with them.
#
#   scripts/mobile/sim-bootstrap.sh            # create anything missing
#   scripts/mobile/sim-bootstrap.sh --print    # just show the simbroker block
#
# Nothing else in this workflow creates devices, and simbroker deliberately does
# not: it allocates from a pool it is told about, and a pool naming devices that
# do not exist fails every claim. This is that missing step.
#
# WHY PURPOSE-NAMED DEVICES. simbroker matches pool membership on the device
# NAME, exactly, with no OS filter. A stock name like "iPhone 17 Pro" can exist
# on two runtimes at once, so a pool of stock names eventually hands an agent a
# device on a runtime the project does not support — and nothing downstream
# notices, because the udid is valid and the device boots. Naming them after the
# project keeps the pool pinned by construction.

source "$(dirname "${BASH_SOURCE[0]}")/lib/mobile-env.sh"

PRINT_ONLY=""
[ "${1:-}" = "--print" ] && PRINT_ONLY="yes"

if [ "${#SIM_POOL[@]}" -eq 0 ]; then
  echo "SIM_POOL is empty in $MOBILE_WORKFLOW_CONF — nothing to create." >&2
  exit 1
fi

# The concrete runtime SIM_RUNTIME_MATCH resolves to, picked once so that every
# device in the pool lands on the SAME runtime. Choosing per-device would let a
# point release split the pool.
RUNTIME="$(xcrun simctl list runtimes -j | MATCH="${SIM_RUNTIME_MATCH:-}" /usr/bin/python3 -c '
import json, os, sys

match = os.environ["MATCH"]
runtimes = [
    r for r in json.load(sys.stdin)["runtimes"]
    if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")
    and (not match or match in r["identifier"])
]
if not runtimes:
    raise SystemExit(
        "No available iOS runtime" + (f" matching {match}" if match else "") + ".\n"
        "xcrun simctl list runtimes — install one through Xcode, or relax "
        "SIM_RUNTIME_MATCH."
    )
# Newest matching runtime, so a pool pinned to iOS-26 follows 26.0 -> 26.1.
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".") if p.isdigit()])
print(runtimes[-1]["identifier"])
')"

echo "Runtime: $RUNTIME"

if [ -z "$PRINT_ONLY" ]; then
  for entry in "${SIM_POOL[@]}"; do
    name="${entry%%:*}"
    devtype="${entry#*:}"
    if [ "$name" = "$devtype" ]; then
      echo "  $name: no device type given (want 'name:com.apple.CoreSimulator.SimDeviceType.X')" >&2
      continue
    fi
    existing="$(xcrun simctl list devices -j | NAME="$name" RUNTIME="$RUNTIME" /usr/bin/python3 -c '
import json, os, sys

name, runtime = os.environ["NAME"], os.environ["RUNTIME"]
for rt, entries in json.load(sys.stdin)["devices"].items():
    if rt != runtime:
        continue
    for device in entries:
        if device["name"] == name:
            print(device["udid"])
            raise SystemExit
')"
    if [ -n "$existing" ]; then
      echo "  $name  exists  $existing"
    else
      udid="$(xcrun simctl create "$name" "$devtype" "$RUNTIME")"
      echo "  $name  created $udid"
    fi
  done
fi

cat <<'BANNER'

── ~/.simbroker/config.json ────────────────────────────────────────────────────
Merge the models.ios list below into your config. capacity is the machine's RAM
ceiling, not a wish: three booted simulators is about all a Mac takes, and that
number is also the hard ceiling on how many agents you can fan out at once.

BANNER

printf '%s\n' "${SIM_POOL[@]}" | cut -d: -f1 | /usr/bin/python3 -c '
import json, sys

names = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps({
    "capacity": {"ios": min(3, len(names)), "android": 1},
    "models": {"ios": names},
    "default_ttl_seconds": 1800,
}, indent=2))
'

cat <<'AFTER'

Then: simbroker devices     — every name above must show as IN POOL
      simbroker doctor      — resolved capacity and pool size

AND RESTART YOUR AGENT SESSION. The MCP server reads that config ONCE, at
start-up. Editing it does not reach a running server: claim_simulator keeps
handing out the old pool, while the CLI shows the new one, and the two disagree
until the session restarts. `simbroker doctor` can show you it is stale; nothing
can fix it in place.
AFTER
