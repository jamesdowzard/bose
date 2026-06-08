# Windowed macOS app — restore + re-wire onto the v2 core

**Date:** 2026-06-08
**Branch:** `feature/restore-windowed-mac-app`
**Issue context:** follows the v2 rebuild (#70) that deleted the v1 windowed app in favour of Raycast + Hammerspoon. James wants a clickable window back.

## Problem

The Mac control surface is currently Raycast script-commands + Hammerspoon hotkeys
over `bose-ctl`. There is no app window where you can see current state and toggle
ANC mode / volume / EQ / routing by clicking. James wants that window.

The v1 windowed SwiftUI app *existed* (the "landscape frosted-dark" redesign,
#69) but #70 deleted its source — keeping only a stale compiled `.app` built on the
pre-codegen v1 protocol (the one with the wire bugs since fixed in #78–#82). The
source is recoverable from git at `f0b71d7`.

The reason #70 killed the app was **polling**: the old `BoseManager` ran a 10 s
`Timer` that hit the headphones over RFCOMM and contended with the active A2DP
link — the audio-dropout root cause. The dropout was caused by *polling*, not by
*having a window*.

## Design

**Restore the UI, replace the data layer. Make the app a third thin front-end over
`bose-ctl`** — exactly like Raycast and Hammerspoon already are (CLAUDE.md:
"thin front-ends that shell out to the `cli/` binary"). The app contains **no
RFCOMM, no IOBluetooth, no protocol code** — it spawns `bose-ctl` for every read
and write. Consequences:

- It structurally *cannot* reintroduce a transport/polling bug — it never holds a
  channel.
- It inherits every CLI fix automatically (including the open #83 flight fix when
  it lands).
- The app target is pure SwiftUI + Foundation. Trivial to build and sign.

### Components

1. **`bose-ctl info --json` (new read mode)** — `cli/main.swift`. Reuses the
   existing `getAllState()` composite (one RFCOMM session) for config + active
   device, plus `getDeviceStates()` for the idle (○) device state, and emits one
   JSON object: `connected`, `deviceName`, `firmware`, `batteryLevel`,
   `batteryCharging`, `ancMode` (int 0–3), `volume`, `volumeMax`,
   `eq{bass,mid,treble}`, `multipoint` (bool), `ancDepth` (cncLevel 0–10),
   `onHead` (bool|null), `devices{name: active|connected|offline}`. On
   unreachable: `{"connected": false}`, exit 0. No protocol/spec change — pure
   formatting over existing composites.

2. **`BoseManager` (rewritten)** — `macos/BoseControl/BoseManager.swift`. Drops
   `BoseRFCOMM`, `pollTimer`, `startPolling`, auto-reconnect, IOBluetooth. Keeps
   the same `@Published` surface ContentView binds to. Runs `bose-ctl` via
   `Process` on a serial background queue:
   - `refreshState()` → `info --json` → decode → publish on main.
   - setters (`setAncMode`/`setVolume`/`setEQ`/`setMultipoint`/`setCncLevel`/
     `connectDevice`/`applyProfile`) → run the matching verb, optimistic local
     update, then `refreshState()`.
   - **No timer.** Reads happen on: window open, window regaining focus, after a
     write, and manual ⌘R.
   - Binary resolution: `$BOSE_CTL` → `~/bin/bose-ctl` → repo `cli/build/bose-ctl`.

3. **`ContentView` (restored + extended)** — restored as-is (frosted two-panel:
   battery, ANC buttons, volume, on-head, device grid, EQ presets + sliders).
   Adds: **ANC depth slider** (0–10), **multipoint toggle**, and in-window
   keyboard shortcuts ⌘1/2/3/4 (ANC modes), ⌘↑/⌘↓ (volume), ⌘R (refresh), ⌘M
   (connect Mac, already present).

4. **`BoseApp` / `AppDelegate`** — `startPolling()` → `refreshState()`; add a
   `NSApplication.didBecomeActiveNotification` observer that re-reads on focus.
   Window chrome unchanged.

5. **`macos/build.sh` (rewritten)** — compiles the 4 SwiftUI files only (no
   `BoseRFCOMM`, no IOBluetooth/CoreBluetooth frameworks), bundles `Info.plist`,
   Developer-ID signs (per `/mac`), `--install` copies to `/Applications`. **No
   LaunchAgent** — the app is user-launched and event-driven.

### Coexistence

Raycast commands and Hammerspoon hotkeys (Opt+B/N/J) are untouched and keep
working — all four surfaces shell the same `bose-ctl`. Global hotkeys stay in
Hammerspoon; the app only owns in-window keys.

## Known limitation — #83

The multipoint toggle and a custom ANC depth exercise the `ancDepth`/CNC-RMW path
that is currently buggy on hardware (#83 — after a custom depth write ANC reads
`off`, and multipoint-off doesn't stick on fw 8.2.20). The window faithfully
*surfaces* that behaviour; it does not fix it. ANC mode, volume, EQ, routing, and
the office/music profiles work clean. The #83 fix is a separate hardware-gated
loop and lands in the CLI — the app inherits it for free.

## Out of scope (YAGNI)

No menu-bar icon, no battery/auto-off polling, no auto-reconnect, no LaunchAgent,
no device-name editing in the window (CLI-only). Just the window.

## Testing

- `cd protocol && make check` — golden byte tests + no-drift (the `--json` change
  touches only `main.swift`, not the spec, so this must stay green).
- `bash cli/build.sh` — CLI compiles with the new read mode; `bose-ctl info --json`
  emits valid JSON (hardware: real values; no hardware: `{"connected":false}`).
- `bash macos/build.sh` — app compiles, bundle is well-formed, launch-smoke (window
  appears, shows disconnected state without headphones).
- Hardware smoke (James, headphones worn): open window → state reads correctly →
  click ANC/volume/EQ/route → device reflects it. Flight/multipoint show the known
  #83 behaviour.
