#!/bin/bash
# Launches the app in a known state and screenshots it. The EVIDENCE channel.
#
#   scripts/mobile/sim-capture.sh <name> [launch args...]
#   SIM_UDID=<claimed-udid> scripts/mobile/sim-capture.sh after-fix -myFlag value
#
# This is not the same job as the canvas node, and confusing the two wastes a
# lot of time. The node is for WATCHING — an animation, a drag, a transition,
# anything a still frame cannot show. This is for CHECKING YOUR OWN WORK: a
# launch argument puts the app in the state you want in one step and hands you a
# PNG to read back with the Read tool, where tapping through the UI is slow and
# may not land where you think.
#
# IT DOES NOT INSTALL. It terminates and relaunches whatever build is already on
# the device, so after a code change you must install the new build first — or
# the PNG shows the previous binary, which looks exactly like a fix that did not
# work. The pinned status bar means even a before/after diff shows nothing.
#
# Environment knobs, for review axes launch arguments cannot reach:
#
#   CONTENT_SIZE=accessibility-extra-large   Dynamic Type. `xcrun simctl help ui`
#                 lists them; the useful ends are `extra-small` and
#                 `accessibility-extra-extra-extra-large`.
#   INCREASE_CONTRAST=enabled                Increase Contrast.
#   SETTLE=5                                 Seconds to wait after launch.
#   SHOT_DIR=/tmp/shots                      Where PNGs land.
#   NORMALISE_STATUS_BAR=0                   Leave the real clock/battery alone.
#
# The status bar is pinned to 9:41 / full battery / full bars by default, so two
# shots of the same screen differ only where the APP differs. Without that, the
# drifting clock defeats every before/after comparison you will want to make.

source "$(dirname "${BASH_SOURCE[0]}")/lib/mobile-env.sh"

if [ -z "$BUNDLE_ID" ]; then
  echo "BUNDLE_ID is not set in $MOBILE_WORKFLOW_CONF" >&2
  exit 1
fi

NAME="${1:-shot}"
shift || true

OUT_DIR="$SHOT_DIR"
mkdir -p "$OUT_DIR"

UDID="$(sim_udid)"

if [ "${NORMALISE_STATUS_BAR:-1}" != "0" ]; then
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100 >/dev/null 2>&1 || true
fi

# Accessibility axes are applied BEFORE launch, so the app picks them up at
# start-up rather than mid-session.
if [ -n "${CONTENT_SIZE:-}" ]; then
  xcrun simctl ui "$UDID" content_size "$CONTENT_SIZE" >/dev/null 2>&1 \
    || echo "warning: could not set content_size=$CONTENT_SIZE" >&2
fi

if [ -n "${INCREASE_CONTRAST:-}" ]; then
  xcrun simctl ui "$UDID" increase_contrast "$INCREASE_CONTRAST" >/dev/null 2>&1 \
    || echo "warning: could not set increase_contrast=$INCREASE_CONTRAST" >&2
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null
# Generous by default: a cold launch on a freshly installed runtime can still be
# showing the launch screen after a couple of seconds, which silently yields a
# blank screenshot that looks like a bug in the app.
sleep "${SETTLE:-3}"
xcrun simctl io "$UDID" screenshot --type=png "$OUT_DIR/$NAME.png" >/dev/null 2>&1
echo "$OUT_DIR/$NAME.png"
