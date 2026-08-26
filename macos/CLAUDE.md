# Bose — macOS surface (Bose.app, profiles)

<!-- Split out of the root CLAUDE.md on 2026-08-27: it was 52 KB, ~6x the 8 KB fleet cap.
     This file loads when Claude reads a file in this directory. -->

The windowed control app and the profile presets. Protocol/wire detail lives in
`protocol/CLAUDE.md`; the CLI that this app shells out to is `cli/CLAUDE.md`.

## No resident poller
There is intentionally **no LaunchAgent and nothing that polls** (a resident 10 s
poll timer was the original audio-dropout cause — #69-era). The Mac control surface
is three thin front-ends that shell out to the `cli/` binary (`~/bin/bose`), so
nothing runs in the background and the Mac only touches the headphones on an
explicit user action.


## Bose.app

A windowed SwiftUI app: settings panel, draggable device sidebar, EQ. Full detail —
panels, theme, cached-first reads, the staleness banner — is in **`docs/macos-app.md`**.

**The two traps, kept here because they are how this app breaks:**

- **It is a thin front-end that shells `bose`.** No RFCOMM, no IOBluetooth, no protocol
  code — reads via `bose info --json`, writes via the verbs. Keep it that way; that is what
  stops the app reintroducing a transport or poll bug.
- **Any guard that reads `deviceStates` must also check `reachable`.** The painted state is
  last-known, not live. Both HIGH findings in this app were that mistake — a skip-if-active
  guard made the Mac row un-tappable exactly when it was needed, and `assertedActiveDevice`
  was never cleared on disconnect so the row just disconnected repainted as active.

## Profiles
- `profiles.json` (repo root) -- presets ({ANC mode, noise level, EQ, multipoint, volume} **+ optional `pair: [primary, secondary]`**) applied by `bose profile`; versioned + hand-editable, ships flight/office/music/**tv** (tv = pair audikast+phone, the one-tap watch-TV setup). A profile's `pair` applies FIRST via the same evict→held→active composite as `bose pair`, then any settings; a pair-only profile skips the settings session (`hasDeviceSettings`). The Mac app shows a **PROFILES chips row** (top of the left panel; list via `bose profile --json`, a pure file read). A profile's `noiseLevel` is applied via the `anc-level` (1F,06) RMW and ONLY takes effect on the adjustable custom modes (4/5, `cncMutable`) — named modes set the mode only (a level over quiet/aware/spatial is a no-op; the old 1F,0A depth write disabled ANC, #83). flight = {quiet, multipoint off}. Runtime JSON (not codegen'd TOML) because `profile save` writes it; loader resolves `$BOSE_PROFILES` → repo path → `~/.config/bose/`. Pure logic in `cli/Profiles.swift`, live apply in `cli/Composites.swift` (`applyProfile`).

## Build notes
- The Swift core that does the actual RFCOMM work lives in `cli/` (see below). The macOS app target (`macos/BoseControl/`) is pure SwiftUI/Foundation and does NO RFCOMM — it shells `bose`, so the two never drift and the app can't reintroduce a transport/poll bug.
- **`macos/build.sh` compiles ONLY the four SwiftUI files** — `BoseDeviceMap`/`Headphone` are NOT linked into the app. Any device or protocol constant the UI needs is therefore **mirrored locally** in `ContentView.swift` (the device labels, and `DeviceButton.priority` which seeds the sidebar's default rank). Real drift risk: **adding or re-prioritising a device in `devices.toml` needs a matching edit there**, or the sidebar's rank badges silently misstate the eviction order the CLI will actually use. Display-only — the CLI owns real victim selection and a saved `priority.json` overrides it — but the badges lie until it's updated.

