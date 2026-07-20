# Bose QC Ultra 2 Controller

Independent control of Bose QC Ultra 2 headphones from macOS and Android over the
reverse-engineered BMAP-over-RFCOMM protocol. One TOML spec
(`protocol/spec/bmap.toml`) is the single source of truth; Python codegen emits the
Swift and Kotlin wire layers consumed by all three clients.

See `CLAUDE.md` for the protocol tables, device map, and hard-won lessons.

## Layout

| Path | What |
|------|------|
| `protocol/` | `bmap.toml` + `devices.toml` spec, Python codegen, golden byte tests. `make gen` regenerates `protocol/generated/{BMAP,Devices}.generated.{swift,kt}`. |
| `cli/` | `bose` CLI + the Swift core (`Transport`/`Parsers`/`Composites`) + generated Swift. The on-demand RFCOMM engine the Mac front-ends call. |
| `macos/` | **Bose.app** — windowed SwiftUI control surface (three-panel: settings / draggable device sidebar / EQ). Thin front-end that shells `bose`; cached-first reads (never pages when the Mac holds no slot), staleness banner with a Read-live button. `bash macos/build.sh --install`. |
| `hammerspoon/` | `bose.lua` — Opt+B shows/hides Bose.app (the only bound hotkey since 2026-06-20; the others are commented out in `start()`), plus event-driven battery announce + call-app mic routing. No timers. |
| `profiles.json` | Settings presets ({ANC mode, noise level, EQ, multipoint, volume}) applied via `bose profile`. Versioned + editable. |
| `android/` | Jetpack Compose app + foreground service (package `au.com.jd.bose`). |

The Mac has **no resident poller** — Bose.app is user-launched and event-driven, and Hammerspoon shells out to `bose` on demand (a background poll timer was the original audio-dropout cause). Reads with no ACL link are served from the timestamped state cache instead of paging the headphones (#148).

## Build

```bash
# bose (CLI) → cli/build/bose
bash cli/build.sh
cp cli/build/bose ~/bin/bose                      # the engine
# hammerspoon/bose.lua is dofile'd from this repo path by init.lua (Opt+B)

# Android app (deploy to S21 via ADB)
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The Swift core in `cli/` and the Android Kotlin app compile from the *same* generated
protocol, so the clients cannot drift on wire encoding or transport behaviour.

## CLI usage

```
bose status               Connection, battery, ANC, volume, EQ (one session)
bose info                 Full state: identity, power, all audio config, devices
bose battery              Battery level
bose devices              Known devices: ● active / ○ connected / · offline
bose connect <device>     Route audio to device (poll-confirmed)
bose disconnect <device>  Disconnect a device
bose swap <device>        Route audio to device (multipoint; keeps others)
bose anc [mode]           Get/set ANC (quiet/aware/immersion/cinema/custom1/custom2, or slot 0-5)
bose anc-level [0-10]     Get/set active mode noise level (0=max cancel … 10=transparent; custom modes only)
bose name [new name]      Get/set headphone name (max 30 UTF-8 bytes)
bose volume [0-31]        Get/set volume
bose multipoint [on|off]  Get/set multipoint
bose play|pause|next|prev Media transport
bose eq [bass mid treble] Get/set EQ (each -10 to +10)
bose spatial [off|still|motion]  Get/set Immersive Audio on the active mode (custom modes only)
bose mode-name [--slot 4|5] [name]  Rename a custom mode slot in place
bose pair <primary> <secondary>  Connect exactly that multipoint pair
bose priority [--set n… | --clear]  Show/set the runtime eviction order
bose auto-pause [on|off]  Get/set pause-on-removal (blank = read)
bose auto-answer [on|off] Get/set answer-on-donning (blank = read)
bose favorites            Show favourited mode slots (display-only)
bose presence [--json]    Passive BLE scan — is verBosita on and nearby? (sends nothing)
bose profile [name]       Apply a preset (bare = list); save <name> / rm <name>
bose raw <hex>            Send raw BMAP bytes
```

## Profiles

A profile is a named bundle of settings — ANC mode, noise level, EQ, multipoint, volume —
applied in one RFCOMM session, plus an optional `pair: [primary, secondary]` that reroutes the
multipoint slots **first**, before any settings. They live in `profiles.json` (versioned,
hand-editable); ships with `flight`, `office`, `music`, and `tv` (a pair-only profile). A
profile only sets the fields it defines.

```bash
bose profile                 # list
bose profile flight          # apply
bose profile save commute    # snapshot the current settings as "commute"
bose profile rm commute      # remove
```

Override the file location with `$BOSE_PROFILES`.

## Automation (event-driven — never polled)

The cardinal rule is **no background polling of the headphones**. These hooks fire on a
keypress or an OS event, then make one on-demand `bose` call.

**Hammerspoon** (`hammerspoon/bose.lua`, reload Hammerspoon after editing):
- `Opt+B` — show/hide the Bose app (press once to open/focus, again to hide) — switch devices/ANC/EQ from its tiles. **This is the only bound hotkey** as of 2026-06-20.
- `Opt+⇧B` (Mac ↔ phone), `Opt+N` (cycle ANC), `Opt+I` (cycle Immersive Audio), `Opt+J` (connect → Mac)
  remain in the file but are **commented out in `start()`** — everything else is driven from the
  Bose app. Re-enabling any is a one-line uncomment + reload.
- Two OS-event behaviours, no hotkey and no polling: the battery is **spoken** through the
  headphones when they become the Mac output (`ANNOUNCE_BATTERY`), and launching a call app
  (Teams/Zoom/FaceTime/Slack/Webex) routes the Mac's **input** to the MacBook mic — the Bose is
  never allowed to be the system input, since its over-ear mics make callers hear the room
  (`AUTO_ROUTE_ON_CALL` / `CALL_APPS`). Neither touches ANC.

**macOS Focus → Shortcuts** (drive profiles from Focus modes, zero polling):
1. Shortcuts app → new shortcut "Bose Office" → **Run Shell Script**: `~/bin/bose profile office`.
   (Repeat per profile: "Bose Flight" → `… profile flight`, etc.)
2. System Settings → Focus → pick a Focus (e.g. Work) → **Add Automation / Focus filter** →
   run the matching shortcut on activation.

Apple doesn't expose Focus automations to scripting, so step 2 is a one-time manual wire-up.

## Protocol

BMAP over RFCOMM via the SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`). Frame
layout `[block, function, operator, length, ...payload]`. The `deca-fade` UUID is
Apple iAP2, **not** BMAP — don't use it. Full command tables in `CLAUDE.md`.

## Licence

MIT
