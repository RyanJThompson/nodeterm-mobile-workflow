# What this does not do

Written so nobody spends an afternoon rediscovering a wall. Everything here is
either measured on a real machine or read out of the source it describes.

## Platform

**macOS only, and iOS simulators only.** The mirror is `serve-sim`, which drives
CoreSimulator. Nothing in here has a Linux or Windows path, and there is no
intention to add one — the thing being brokered is a Mac's RAM.

**Xcode is required**, but Simulator.app is not — and that is a feature. `simctl`
works headlessly, which is the whole reason this toolchain runs on a machine with
a trimmed Xcode install and no `Contents/Developer/Applications` directory at
all. A native window could not be seated on the canvas anyway.

## Android

simbroker **does** broker Android emulators — a separate class with its own
capacity, because an emulator is a full VM and costs far more RAM than a
simulator. `claim_simulator(class: "android")` returns an **AVD name** where iOS
returns a UDID, and you boot it with `emulator @<name>` (a heavyweight ~30–60 s
cold start).

**What is missing here is the canvas half.** Nothing in this repo mirrors an
Android emulator onto a nodeterm node. The shape of a solution is obvious enough
— an emulator's screen over HTTP, opened as a web node, exactly as with
serve-sim — but nothing on the machine this was captured from verifies it, and a
plausible-looking path that has never been run is worse than an honest gap in a
repo whose whole value is being trustworthy.

So: **claim Android devices through the broker, then drive them with `adb`
yourself.** The orchestration half of this repo — stations, worktrees, briefs,
collection, capacity math — applies unchanged. Only the mirror does not.

## Physical iPhones

Also not shipped here, and the constraints are sharp enough to be worth stating
so nobody starts down the road expecting the simulator experience.

A physical device streams through **WebDriverAgent's MJPEG server** rather than
serve-sim: a userspace tunnel, port forwards on 8100 (control) and 9100 (video),
WDA itself, then a small server that puts video and control on one local page.
It works. What you should know before building it:

- **USB only.** `go-ios` talks to usbmuxd and cannot see a Wi-Fi-paired device,
  even when `xcrun devicectl` reports it connected over `localNetwork`.
- **The phone must be unlocked** during launch, or WDA fails with `Timed out
  while enabling automation mode`.
- **Free-team signing certificates expire after 7 days.** A paid Apple Developer
  membership moves that to a year, which is the real reason to buy one here.
- **WDA dies when the XCUITest session ends** and has no supervisor. Bringing it
  back is a ~20 s job you will do often.
- **~33 fps is a hard ceiling**, and it is XCTest's screenshot rate, not
  bandwidth or JPEG encoding. Measured at three configurations — quality 20 /
  scale 50, quality 10 / scale 33, and quality 40 / scale 100 — the results were
  33.3, 34.0 and 33.4 fps. **Lowering quality and resolution buys nothing, so
  always run at full resolution.** (Default WDA MJPEG is ~10 fps; the session
  settings `{"mjpegServerFramerate": 60, "mjpegServerScreenshotQuality": 40,
  "mjpegScalingFactor": 100}` are what raise it to 33.)
- **Do not waste time on the AVFoundation/QuickTime route on macOS 26.** The
  classic trick — set `kCMIOHardwarePropertyAllowScreenCaptureDevices` and the
  iPhone appears as a capture device — is dead. The property sets successfully
  (status 0) but no screen device appears; enumerating CoreMediaIO directly
  returns only cameras; and `/System/Library/CoreMediaIO/Plug-Ins/DAL` no longer
  exists. `xcrun devicectl device capture screen-record` exists, but the phone
  reports the capability as unsupported.
- **A native live window does still exist**: `open "devices://device/open?id=<uuid>"`
  launches Apple's Device Hub at full framerate. Getting it onto the canvas would
  mean capturing it with ScreenCaptureKit (needs Screen Recording permission) and
  re-serving it — viable, but it splits video and control across two sources.
- **If you use `mobile-mcp` against a real device, it must run in legacy mode**
  (`MOBILEMCP_LEGACY_ROBOT=1`). Version 1.0 and later route real iOS devices
  through a bundled `mobilecli` that insists on installing its own on-device
  agent with bundle id `com.mobilenext.devicekit-iosUITests.xctrunner`;
  re-signing that needs a provisioning profile matching that id, and Apple will
  not register `com.mobilenext.*` to another team. A wildcard App ID (`TEAMID.*`)
  would work but needs a **paid** membership. Legacy mode bypasses mobilecli and
  talks to appium WDA on 8100, which signs fine under a free personal team.

Pick a preview port **outside 3100–3149** if you build this: serve-sim's helpers
take the first free port from 3100 upward, one per device, so three concurrent
simulator streams reach 3102 and will collide with a naively chosen default.

## Version coupling

This repo reads and writes nodeterm's own canvas file and depends on the
control-API verb list. Both are internals.

- The verb list and node-size constants in [NODETERM.md](NODETERM.md) were read
  out of **nodeterm 0.2.43**. Probing for an unknown verb costs nothing and
  creates nothing, so re-verify rather than assuming.
- `serve-sim` is fetched with `npx --yes serve-sim@latest` and pinned to
  nothing. **0.1.45 or later** is required: before that, its touches did not
  reach the device, and the node was a picture you could not tap.
- Every canvas write here is defensive — it checks `version` and `rev`, refuses
  anything it does not recognise, and leaves the node alone rather than guessing.
  A default-sized simulator is a small disappointment; a mangled canvas is not.

## Things that are deliberately not automated

- **Creating simulators** happens only in `sim-bootstrap.sh`, and only for names
  you listed. Nothing here invents devices.
- **Merging** is the user's, from the group's chip on the canvas. An orchestrator
  that merges for you is an orchestrator you cannot review.
- **`serve-sim --kill` unscoped** is left out of the permissions allowlist on
  purpose. An allowlist entry cannot tell a scoped kill from an unscoped one, and
  an unscoped one takes down every session's mirror.
- **`simctl erase`** is likewise absent: it destroys another agent's device state.
