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
| `cli/` | `bose-ctl` CLI + the Swift core (`Transport`/`Parsers`/`Composites`) + generated Swift. The on-demand RFCOMM engine the Mac front-ends call. |
| `raycast/` | Raycast script commands (connect / disconnect / status) → `bose-ctl`. |
| `hammerspoon/` | `bose.lua` — Opt+B toggles Mac ↔ phone via `bose-ctl`. |
| `android/` | Jetpack Compose app + foreground service (package `au.com.jd.bose`). |

The Mac has **no resident app** — Raycast + Hammerspoon shell out to `bose-ctl` on demand (a background poller was the original audio-dropout cause).

## Build

```bash
# bose-ctl (CLI) → cli/build/bose-ctl
bash cli/build.sh
cp cli/build/bose-ctl ~/bin/bose-ctl                      # the engine
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
bose-ctl status               Connection, battery, ANC, volume, EQ (one session)
bose-ctl battery              Battery level
bose-ctl devices              Known devices with audio-active state
bose-ctl connect <device>     Route audio to device (poll-confirmed)
bose-ctl disconnect <device>  Disconnect a device
bose-ctl swap <device>        Route audio to device (multipoint; keeps others)
bose-ctl anc [mode]           Get/set ANC (quiet/aware/custom1/custom2)
bose-ctl volume [0-31]        Get/set volume
bose-ctl multipoint [on|off]  Get/set multipoint
bose-ctl play|pause|next|prev Media transport
bose-ctl eq [bass mid treble] Get/set EQ (each -10 to +10)
bose-ctl raw <hex>            Send raw BMAP bytes
```

## Protocol

BMAP over RFCOMM via the SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`). Frame
layout `[block, function, operator, length, ...payload]`. The `deca-fade` UUID is
Apple iAP2, **not** BMAP — don't use it. Full command tables in `CLAUDE.md`.

## Licence

MIT
