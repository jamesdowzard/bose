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
| `raycast/` | Raycast script commands (connect / disconnect / status / full-status / anc-level / profile) → `bose`. |
| `hammerspoon/` | `bose.lua` — Opt+B shows/hides the app, Opt+⇧B toggles Mac ↔ phone, Opt+N cycles ANC, call-app launch → ANC aware, low-battery warning on toggle. All event-driven. |
| `profiles.json` | Settings presets ({ANC mode, noise level, EQ, multipoint, volume}) applied via `bose profile`. Versioned + editable. |
| `android/` | Jetpack Compose app + foreground service (package `au.com.jd.bose`). |

The Mac has **no resident app** — Raycast + Hammerspoon shell out to `bose` on demand (a background poller was the original audio-dropout cause).

## Build

```bash
# bose (CLI) → cli/build/bose
bash cli/build.sh
cp cli/build/bose ~/bin/bose                      # the engine
cp raycast/*.sh ~/.config/raycast/script-commands/        # Raycast commands
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
bose anc [mode]           Get/set ANC (quiet/aware/custom1/custom2)
bose anc-level [0-10]     Get/set active mode noise level (0=max cancel … 10=transparent; custom modes only)
bose name [new name]      Get/set headphone name (max 30 UTF-8 bytes)
bose volume [0-31]        Get/set volume
bose multipoint [on|off]  Get/set multipoint
bose play|pause|next|prev Media transport
bose eq [bass mid treble] Get/set EQ (each -10 to +10)
bose profile [name]       Apply a preset (bare = list); save <name> / rm <name>
bose raw <hex>            Send raw BMAP bytes
```

## Profiles

A profile is a named bundle of settings — ANC mode, noise level, EQ, multipoint, volume —
applied in one RFCOMM session. They live in `profiles.json` (versioned, hand-editable);
ships with `flight`, `office`, `music`. A profile only sets the fields it defines.

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
- `Opt+B` — show/hide the Bose app (press once to open/focus, again to hide) — switch devices/ANC/EQ from its tiles.
- `Opt+⇧B` — toggle audio Mac ↔ phone (also warns if battery ≤ 20%, piggybacking the press).
- `Opt+N` — cycle ANC quiet → aware → immersion.
- `Opt+J` — bring the headphones to this Mac (always connects the Mac, no direction-guessing).
- Launching a call app (Teams / Zoom / Meet) switches ANC to aware. Edit `AWARE_ON_LAUNCH`
  / the chords at the top of `bose.lua` to taste.

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
