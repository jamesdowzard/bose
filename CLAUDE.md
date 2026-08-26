# Bose QC Ultra 2 Controller

**Headphones MAC:** E4:58:BC:C0:2F:72 (name: "verBosita")
**Protocol:** BMAP over RFCOMM via SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`)
**Note:** deca-fade UUID is Apple iAP2, NOT BMAP — don't use it

## Architecture (Independent Control)

Both Mac and phone control headphones independently via on-demand RFCOMM.
No persistent connections. No coordination. No Tailscale dependency.

```
Mac:   bose (CLI)                     → IOBluetooth RFCOMM → Headphones
Mac:   Hammerspoon / Bose.app             ─shell→ bose → Headphones
Phone: BoseControl (Android/Compose)      → Android RFCOMM     → Headphones
```

Each command: open RFCOMM (SDP-resolved channel), send BMAP, read response, close (~200-300ms).
Both devices can send commands at any time -- SPP is single-connection, so if both try
simultaneously one waits, but in practice commands are too brief to collide.


## Components — detail lives next to the code

Each surface documents itself in its own directory, so the detail loads when you actually
open that code rather than on every session in this repo.

| Surface | Read |
|---|---|
| Bose.app + profiles | `macos/CLAUDE.md` |
| Hammerspoon module | `hammerspoon/CLAUDE.md` |
| `bose` CLI (the engine — all RFCOMM) | `cli/CLAUDE.md` |
| Android app, widget, service | `android/CLAUDE.md` |
| BMAP wire format + command tables | `protocol/CLAUDE.md` |
| Device map, priority, connect semantics | `docs/device-map.md` |
| Reverse-engineering notes, firmware | `docs/reverse-engineering.md`, `docs/firmware-delivery.md` |

The Swift core (`cli/`) and the Android app share one generated protocol layer
(`protocol/spec/` → `generated/`), so the clients cannot drift on wire encoding.

## Build & Deploy

```bash
# Protocol layer (regenerate Swift + Kotlin from the spec; run golden tests)
cd protocol && make gen      # or `make check` to also verify no drift + run tests

# bose (CLI) → cli/build/bose, then install + the macOS front-ends
bash cli/build.sh
cp cli/build/bose ~/bin/bose                       # the engine
# hammerspoon/bose.lua is dofile'd from this repo path by init.lua — no copy needed

# Bose.app (windowed) → Developer-ID signed, installed to /Applications
bash macos/build.sh --install                              # needs ~/bin/bose present

# Android app (deploy to S21 via ADB)
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The Swift core (`cli/{Transport,Parsers,Composites}.swift` + generated Swift) and the
Android Kotlin app share one protocol source (`protocol/spec/` → `generated/`), so the
clients cannot drift on wire encoding or transport behaviour.

Note: `android/local.properties` needs `sdk.dir=/Users/jamesdowzard/Library/Android/sdk`.
This file is gitignored. Worktrees need it copied manually.


## Rules

- **NEVER unpair/toggle BT/pairing mode without explicit user approval** — broke pairings on 2026-03-16
- **NEVER proactively connect HFP** — SCO blocks A2DP streaming
- **NEVER auto-reconnect A2DP** — an RFCOMM/ACL probe to decide fights user device switches (#61-#64). Reconnection is user-initiated only. A Hammerspoon walk-back auto-reconnect (channel-free `blueutil` + last-active-mac flag) was tried and **removed 2026-07-13 for being too aggressive** (#139) — do not reintroduce it.
- **NEVER treat ACK as success for connectDevice** — poll getConnectedDevices instead
- **Bose Music app must be disabled** — fights for RFCOMM: `adb shell pm disable-user com.bose.bosemusic`
- 2-device multipoint limit
- getDeviceInfo status byte unreliable — use getConnectedDevices() as ground truth
- Single RFCOMM attempt per command — no retry loops
- Drain 300ms of initial data after RFCOMM connect (Bose firmware quirk)
- Use pymobiledevice3 for iPad BT operations
- minSdk 31 (Android 12) — no pre-O version checks needed


## Structure

```
bose/
├── android/
├── cli/
├── docs/
├── hammerspoon/
├── macos/
└── protocol/
```
