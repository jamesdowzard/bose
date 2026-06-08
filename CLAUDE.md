# Bose QC Ultra 2 Controller

**Headphones MAC:** E4:58:BC:C0:2F:72 (name: "verBosita")
**Protocol:** BMAP over RFCOMM via SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`)
**Note:** deca-fade UUID is Apple iAP2, NOT BMAP — don't use it

## Architecture (Independent Control)

Both Mac and phone control headphones independently via on-demand RFCOMM.
No persistent connections. No coordination. No Tailscale dependency.

```
Mac:   bose-ctl (CLI)                     → IOBluetooth RFCOMM → Headphones
Mac:   Raycast / Hammerspoon / Bose Control.app  ─shell→ bose-ctl → Headphones
Phone: BoseControl (Android/Compose)      → Android RFCOMM     → Headphones
```

Each command: open RFCOMM (SDP-resolved channel), send BMAP, read response, close (~200-300ms).
Both devices can send commands at any time -- SPP is single-connection, so if both try
simultaneously one waits, but in practice commands are too brief to collide.

## Components

### macOS — no resident poller; on-demand surfaces over `bose-ctl`
There is intentionally **no LaunchAgent and nothing that polls** (a resident 10 s
poll timer was the original audio-dropout cause — #69-era). The Mac control surface
is three thin front-ends that shell out to the `cli/` binary (`~/bin/bose-ctl`), so
nothing runs in the background and the Mac only touches the headphones on an
explicit user action.
- `macos/BoseControl/` -- **Bose Control.app**: a windowed SwiftUI app (frosted-dark
  two-panel: battery/ANC mode/volume/multipoint/on-head + device grid + EQ). No depth
  slider — ANC is mode-based and a raw depth disables it (#83); modes only.
  It is a **thin front-end that shells `bose-ctl`** — NO RFCOMM, NO IOBluetooth, NO
  protocol code — reading via `bose-ctl info --json` and writing via the verbs. It is
  **user-launched and event-driven**: reads on window-open, on app-focus, after each
  write, and on ⌘R — never on a timer. Build `bash macos/build.sh [--install]`
  (Developer-ID signed → `/Applications`; no LaunchAgent). In-window keys: ⌘1/2/3/4
  ANC modes, ⌘↑/⌘↓ volume, ⌘R refresh, ⌘M connect Mac. Global hotkeys stay in
  Hammerspoon. The `--json` read seam lives in `cli/main.swift` (`cmdInfoJSON`, pure
  formatting over `getAllState` + `getDeviceStates`). It surfaces — but does not fix —
  the #83 flight/ancDepth behaviour; that fix lands in the CLI and the app inherits it.
- `raycast/bose-connect.sh` / `bose-disconnect.sh` -- Raycast script commands with a device dropdown → `bose-ctl connect|disconnect <device>`
- `raycast/bose-status.sh` / `bose-full-status.sh` -- `bose-ctl status` / `bose-ctl info`
- `raycast/bose-anc-depth.sh` / `bose-profile.sh` -- `bose-ctl anc-depth [0-10]` / `bose-ctl profile [name]` (text arg)
- `profiles.json` (repo root) -- settings presets ({ANC mode, depth, EQ, multipoint, volume}) applied by `bose-ctl profile`; versioned + hand-editable, ships flight/office/music. ANC depth is applied ONLY for custom1/custom2 modes (named modes set mode only — depth over quiet/aware disables ANC, #83). flight = {quiet, multipoint off}. Runtime JSON (not codegen'd TOML) because `profile save` writes it; loader resolves `$BOSE_PROFILES` → repo path → `~/.config/bose/`. Pure logic in `cli/Profiles.swift`, live apply in `cli/Composites.swift` (`applyProfile`).
- `hammerspoon/bose.lua` -- Hammerspoon module, all **event-driven** (no timers): **Opt+B toggles Mac ↔ phone** (+ one-shot low-battery warn piggybacked on the press), **Opt+N cycles ANC** (quiet→aware→custom1), **Opt+J connects the headphones to this Mac** (unconditional, no toggle direction-guessing; `CONNECT_TARGET` retargets it), and a call-app **launch** watcher (Teams/Zoom/Meet → ANC aware). Returns a table with `.start()`/`.stop()`. Wired in `init.lua` via `BoseCtl = dofile(os.getenv("HOME").."/code/personal/bose/hammerspoon/bose.lua"); BoseCtl.start()`. Edits apply on Hammerspoon reload.
- The Swift core that does the actual RFCOMM work lives in `cli/` (see below). The macOS app target (`macos/BoseControl/`) is pure SwiftUI/Foundation and does NO RFCOMM — it shells `bose-ctl`, so the two never drift and the app can't reintroduce a transport/poll bug.

### Android (`android/`) — regenerated protocol on the kept architecture
- `android/` -- Jetpack Compose app (package: `au.com.jd.bose`)
- Protocol wire layer is GENERATED: `app/src/generated/java/au/com/jd/bose/BMAP.generated.kt` (from `bmap.toml`) + `Devices.generated.kt` (device map / headphone MAC from `devices.toml`). Refresh with `cd protocol && make gen` then `cd android && ./gradlew copyGeneratedProtocol` (the committed copies are the build inputs — do-not-edit banner)
- `Transport.kt` -- RFCOMM transport (per-command open/drain-300ms/close, `ReentrantLock`, cold-start). Sends the `IntArray` frames the generated builders produce
- `Composites.kt` -- live-channel composites (connectDevice poll-confirm, cnc_level RMW, connected_devices list, getAllState) — same escape-hatch split as macOS
- `Parsers.kt` -- pure, hardware-free response parsers (JVM-unit-tested in `app/src/test/`, against the same captured bytes as macOS `Parsers.swift`)
- `BoseProtocol.kt` -- thin command facade: builds non-composite frames via generated `BMAP.*`, decodes responses. NO hand-written frame builders
- `A2dpReflection.kt` -- the ONE isolated home for the hidden-API `BluetoothA2dp.connect()` reflection (phone-only insurance; don't expand)
- `BoseService` -- foreground service (RFCOMM commands; phone-only A2DP nudge; notification media controls play/pause/next/prev)
- `BoseWidgetProvider` -- home screen widget (button set derives from `BoseDeviceMap.widgetDevices` — tv is macOS-only, never a widget button)
- `BoseTileService` -- Quick Settings tile (shows active source)
- `DevicePickerActivity` -- dialog launched from QS tile
- `BootReceiver` -- auto-start service on boot
- Companion device registered for background FGS privileges

### CLI (`cli/`) — regenerated on the shared layer
- `cli/main.swift` -- `bose-ctl` command surface (status/battery/anc/devices/connect/disconnect/swap/volume/multipoint/play-pause-next-prev/eq/raw). **No inline byte parsing** — every command routes through the generated `BMAP.*` builders. `connect`/`swap` poll-confirm via `getConnectedDevices` (ACK is never success); volume uses the generated SET_GET builder.
- `cli/Transport.swift` -- IOBluetooth RFCOMM transport (per-command open/drain-300ms/close, cold-start warm-up, serial queue).
- `cli/Composites.swift` -- live-channel composites (cncLevel RMW, connectedDevices list, getAllState single-session).
- `cli/Parsers.swift` -- pure, hardware-free response parsers; `cli/Tests/main.swift` + `cli/run-tests.sh` are the standalone unit tests (same captured-byte corpus as Android `Parsers.kt`).
- `cli/build.sh` -- compiles the generated Swift + `cli/{Transport,Parsers,Composites}.swift` + `cli/main.swift` → `cli/build/bose-ctl`. Does NOT install over `~/bin/bose-ctl`.
- The Swift core here and the Kotlin app share one protocol source (`protocol/spec/` → `generated/`), so they can't drift on wire encoding.

### Protocol (`protocol/`) — the single source of truth
- `protocol/spec/bmap.toml` -- **canonical machine-readable BMAP spec.** Every command, operator, and enum lives here with `verified_bytes` golden captures. The command tables further down in this file are the human-readable mirror — **edit `bmap.toml` and regenerate; never hand-edit `generated/`.**
- `protocol/spec/devices.toml` -- headphone MAC + device map (the one home for those literals).
- `protocol/codegen/` + `protocol/generate.py` -- Python (uv) emitters → `protocol/generated/{BMAP,Devices}.generated.{swift,kt}`. `make gen` regenerates; `make check` proves the committed generated files are in sync + runs the golden byte tests.

## Build & Deploy

```bash
# Protocol layer (regenerate Swift + Kotlin from the spec; run golden tests)
cd protocol && make gen      # or `make check` to also verify no drift + run tests

# bose-ctl (CLI) → cli/build/bose-ctl, then install + the macOS front-ends
bash cli/build.sh
cp cli/build/bose-ctl ~/bin/bose-ctl                       # the engine
cp raycast/*.sh ~/.config/raycast/script-commands/         # Raycast commands
# hammerspoon/bose.lua is dofile'd from this repo path by init.lua — no copy needed

# Bose Control.app (windowed) → Developer-ID signed, installed to /Applications
bash macos/build.sh --install                              # needs ~/bin/bose-ctl present

# Android app (deploy to S21 via ADB)
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The Swift core (`cli/{Transport,Parsers,Composites}.swift` + generated Swift) and the
Android Kotlin app share one protocol source (`protocol/spec/` → `generated/`), so the
clients cannot drift on wire encoding or transport behaviour.

Note: `android/local.properties` needs `sdk.dir=/Users/jamesdowzard/Library/Android/sdk`.
This file is gitignored. Worktrees need it copied manually.

## Android Architecture

### Companion Device (Critical)

The app registers as a **companion device** for the Bose headphones via
`CompanionDeviceManager`. This is essential — without it, Android 12+ blocks
starting foreground services from the background, which breaks the widget.

**What it grants:**
- Background FGS starts (widget taps can start BoseService)
- Battery optimization exemption (service stays alive)
- Wake on BT connect/disconnect

**Setup:** Automatic on first app launch. User sees a one-time "Allow Bose to
access verBosita?" prompt. Association persists across app reinstalls.

**Manifest requirements:**
- `<uses-feature android:name="android.software.companion_device_setup" />`
- `REQUEST_COMPANION_RUN_IN_BACKGROUND`
- `REQUEST_COMPANION_USE_DATA_IN_BACKGROUND`
- `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND`
- `FOREGROUND_SERVICE_CONNECTED_DEVICE` (required for `connectedDevice` service type)

### Widget (5 buttons: phone, mac, ipad, iphone, quest)

Buttons use `PendingIntent.getForegroundService()` to send `ACTION_CONNECT_DEVICE`
directly to `BoseService`. No broadcast receiver in the click path.

**State colors:**
- Green (#00FF88) = active (audio routed here)
- Orange (#FF9500) = connected but not active
- Grey (#666666) = offline/not connected

Battery percentage shown as overlay text.

### BoseService (Foreground Service)

Single-threaded executor runs all RFCOMM operations off the main thread.
Key actions: `ACTION_CONNECT_DEVICE`, `ACTION_REFRESH`.

**On device switch to "phone":**
1. BMAP connectDevice(phone_mac) -- tells headphones to route audio to phone
2. ensureA2dp(boseDevice) -- phone-side A2DP connect (Samsung needs this)
3. 500ms wait for BT to settle
4. nudgeMediaPlayback() -- pause/play to force audio stream handover

**Skip-if-active:** Tapping an already-active device is a no-op (checks SharedPrefs).

### Key Lessons (Don't Repeat These Mistakes)

**HFP blocks A2DP:** Never proactively connect HFP (BluetoothHeadset profile).
SCO occupies the BT bandwidth and A2DP streaming fails with `sco_occupied:true`.
HFP connects automatically when a phone call arrives — let Android handle it.

**Media nudge is required:** After BT output changes, existing media playback
keeps streaming to the old sink. Must pause/play to force re-routing. Only
triggers if `AudioManager.isMusicActive` is true.

**Widget → BroadcastReceiver → startForegroundService crashes on Android 12+:**
`ForegroundServiceStartNotAllowedException`. Widget clicks must go directly to
the service via `PendingIntent.getForegroundService()`, not through a broadcast
receiver that tries to start the service.

**Companion device association API differs by Android version:**
- API 33+: `cdm.associate(request, executor, callback)` with
  `onAssociationCreated` / `onAssociationPending` / `onFailure`
- API 31-32: `cdm.associate(request, callback, handler)` with
  `onDeviceFound(IntentSender)` / `onFailure`
- Check existing: API 33+ uses `cdm.myAssociations`, older uses `cdm.associations`
- Requires `<uses-feature android:name="android.software.companion_device_setup" />`

**getActiveDevice (04,09) is unreliable:** Always returns the querying device's
own MAC. Use `getConnectedDevices` (05,01) for audio-active devices and
`getDeviceInfo` (04,05) per device for ACL connection state.

## Device Map

| Name | MAC | Widget | Notes |
|------|-----|--------|-------|
| phone | A8:76:50:D3:B1:1B | yes | Samsung S21 (local device) |
| mac | BC:D0:74:11:DB:27 | yes | MacBook |
| ipad | F4:81:C4:B5:FA:AB | yes | |
| iphone | F8:4D:89:C4:B6:ED | yes | |
| tv | 14:C1:4E:B7:CB:68 | macOS only | Chromecast |
| quest | 78:C4:FA:C8:5C:3D | yes | Meta Quest 3 |

**Cycle order** (bose-ctl): `mac → quest → ipad → iphone → tv → phone`

## BMAP Function IDs (Block 0x04 — DeviceManagement)

| Function | ID | Notes |
|----------|-----|-------|
| Connect | **0x01** | Payload: `00` + 6-byte MAC = 7 bytes. Pages offline devices + routes audio. |
| Disconnect | **0x02** | Payload: 6-byte MAC |
| RemoveDevice | 0x03 | NEVER use — removes from paired list |
| ListDevices | 0x04 | |
| Info | 0x05 | Status byte unreliable — cross-ref with getConnectedDevices |
| PairingMode | 0x08 | |
| ActiveDevice | 0x09 | Returns querying device, not necessarily streaming device |

## Transport & Operators (verified 2026-04-05, corrected via APK decompilation)

> **Source of truth:** the tables below are the human-readable mirror of
> `protocol/spec/bmap.toml`. To change a command/operator/enum, edit `bmap.toml`
> (with `verified_bytes` for any concrete capture), run `cd protocol && make gen`,
> and update these tables to match. Never hand-edit `protocol/generated/`.

**Everything works over RFCOMM.** BLE GATT is NOT needed for any setting.
The original "needs BLE GATT" assumption was wrong — we were using the wrong
BMAP operator (SET/0x06 instead of SET_GET/0x02).

### BMAP Operators

| Value | Name | When to use |
|-------|------|------------|
| 0x01 | GET | Query current value |
| 0x02 | SET_GET | **Set value AND get response. Required for EQ, StandbyTimer, buttons** |
| 0x03 | RESP | Response from device |
| 0x04 | ERROR | Error from device |
| 0x05 | START | Connect/disconnect/media commands |
| 0x06 | SET | Simple set (name only). **Does NOT work for EQ, volume, or multipoint** |
| 0x07 | ACK | Acknowledgement |

### All Settable Commands (RFCOMM, verified)

| Setting | Block,Func | Operator | Bytes | Notes |
|---------|-----------|----------|-------|-------|
| ANC mode | 1F,03 | START | `1F,03,05,02,{mode},01` | 0=quiet 1=aware 2=custom1 3=custom2; reads 255 = OFF (genuinely disabled — confirmed audibly #83). 255 is REACHABLE: writing a raw CNC depth (1F,0A) over a named mode knocks 1F,03 to 255. ANC here is mode-based; depth is the same axis. |
| Volume | 05,05 | SET_GET | `05,05,02,01,{level}` | 0-31 |
| Device name | 01,02 | SET | `01,02,06,{len},00,{utf8}` | max 30 UTF-8 bytes |
| Multipoint | 01,0A | SET_GET | `01,0A,02,01,{07/00}` | SET 07=on/00=off. RESPONSE is a bitfield — bit 0 = enable; fw 8.2.20: on→0x07, off→0x06 (slot bits persist). Parse `& 0x01`, NOT `!= 0` (that misread 0x06 as on, #83). |
| Connect device | 04,01 | START | `04,01,05,07,00,{MAC}` | Also routes audio |
| Disconnect | 04,02 | START | `04,02,05,06,{MAC}` | |
| Media control | 05,03 | START | `05,03,05,01,{action}` | 01=play 02=pause 03=next 04=prev |
| **EQ band** | 01,07 | **SET_GET** | `01,07,02,02,{value},{band}` | band: 0=bass 1=mid 2=treble, value: signed -10 to +10 |
| **ANC depth** | 1F,0A | **SET_GET** | `1F,0A,02,05,{level},{autoCNC},{spatial},{windBlock},{ancToggle}` | level 0-10. **SAME axis as ANC mode** — writing depth over a named mode (quiet/aware) sets 1F,03 to 255 = OFF (#83). Only meaningful inside a CUSTOM mode. Profiles + app set named-mode → mode only; never depth alongside quiet/aware. |

**Not supported on QC Ultra 2:** StandbyTimer SET (01,04), MotionAutoOff (01,14), OnHeadDetection SET (01,10).
Auto-off timer (01,0B) is read-only over RFCOMM — distinct from StandbyTimer (01,04).

### BMAP Function IDs (Block 0x05 — Audio)

| Function | ID | Notes |
|----------|-----|-------|
| ConnectedDevices | **0x01** | GET returns audio-active device MACs (ground truth) |
| MediaControl | 0x03 | START: 01=play 02=pause 03=next 04=prev |
| AudioCodec | 0x04 | GET returns codec ID + bitrate |
| Volume | **0x05** | GET/SET_GET: current + max level (0-31) |

## Capability → Exposure Map

Every BMAP capability and where each surface exposes it. Source: `bmap.toml`
commands + the off-spec diagnostic GETs that `getAllState`/`parseAllState` issue
directly (raw `[block,func,GET]`, not generated builders) + the Android control
surface. Keep this in sync when adding a verb or control.

**Legend:** ✅ get+set · 👁 read-only/display · — not exposed

### `bmap.toml` commands

| Capability | Block,Func | `bose-ctl` | Raycast | Hammerspoon | Android |
|------------|-----------|-----------|---------|-------------|---------|
| ANC mode | 1F,03 | ✅ `anc` | 👁 (in status) | ✅ Opt+N cycle + call-app hook | ✅ mode selector |
| ANC depth (CNC) | 1F,0A | ✅ `anc-depth` | ✅ `bose-anc-depth` | — | ✅ slider |
| Device name | 01,02 | ✅ `name` | — | — | ✅ rename |
| EQ band | 01,07 | ✅ `eq` | 👁 (in status) | — | ✅ 3-band |
| Multipoint | 01,0A | ✅ `multipoint` | — | — | ✅ toggle |
| Connect device | 04,01 | ✅ `connect`/`swap` | ✅ `bose-connect` | ✅ Opt+B toggle · Opt+J → Mac | ✅ widget/tile/picker |
| Disconnect device | 04,02 | ✅ `disconnect` | ✅ `bose-disconnect` | 👁 (toggle path) | — |
| Device info (ACL) | 04,05 | 👁 `devices` (○ state) | — | — | 👁 widget colour |
| Connected devices | 05,01 | 👁 `devices`/`status`/`info` | 👁 (in status) | 👁 toggle-direction | 👁 widget/tile active |
| Media control | 05,03 | ✅ `play`/`pause`/`next`/`prev` | — | — | ✅ notification controls |
| Audio codec | 05,04 | 👁 `info` | 👁 (full status) | — | 👁 state |
| Volume | 05,05 | ✅ `volume` | 👁 (in status) | — | ✅ slider |
| Firmware | 00,05 | 👁 `status`/`info` | 👁 (status) | — | 👁 state |
| Battery | 02,02 | 👁 `battery`/`status`/`info` | 👁 (status) | — | 👁 widget overlay |

### Off-spec diagnostic GETs (issued directly in `getAllState`, not in `bmap.toml`)

| Capability | Block,Func | `bose-ctl` | Raycast | Android |
|------------|-----------|-----------|---------|---------|
| Serial number | 00,07 | 👁 `info` | 👁 (full status) | 👁 state |
| Product name | 00,0F | 👁 `info` | 👁 (full status) | 👁 state |
| Platform | 12,0D | 👁 `info` | 👁 (full status) | 👁 state |
| Codename | 12,0C | 👁 `info` | 👁 (full status) | 👁 state |
| Auto-off timer | 01,0B | 👁 `info` (read-only) | 👁 (full status) | 👁 state |
| On-head / wear | 08,07 | 👁 `info` (yes/no; `unknown` if no RESP) | 👁 (full status) | 👁 state |

**Profiles** compose several of these capabilities at once — a `bose-ctl profile`
applies {ANC mode, ANC depth, EQ, multipoint, volume} in one session (CLI +
`bose-profile.sh` Raycast; drivable from macOS Focus via a Shortcut, see README).

**Notable gaps (intentional):** Hammerspoon now does Opt+B (toggle), Opt+N (ANC
cycle), Opt+J (connect → Mac), and a call-app launch hook — still all event-driven, no timers. Raycast
covers the common dropdowns plus full-status / anc-depth / profile; deeper config
(EQ/name/multipoint) is CLI- or Android-only by design. The macOS surface has
**no resident process** — every reading is on-demand, never polled.

## connectDevice Behaviour (verified 2026-04-11 via raw BMAP captures)

**connectDevice pages offline devices.** It doesn't just route audio between
already-connected devices — it tells the Bose to reach out and establish ACL+A2DP
with the target. For sleeping devices (iPad, iPhone) this can take up to ~15s.

**ACK does NOT mean success.** ACK (op=0x07) arrives in ~1s and means "command
received". The actual connection happens in the background. There is no reliable
RESULT frame for paged devices — the only way to confirm success is to poll
`getConnectedDevices` (05,01) until the target MAC appears in the audio-active list.

**No auto-reconnect from either platform.** Both Mac and Android had auto-reconnect
logic that fought user switches (#61-#64). Mac's BoseManager had a 30s reconnect
timer; Android's aclReceiver called ensureA2dp on every ACL reconnect. Both removed.
Reconnection is now user-initiated only.

**RFCOMM opens ACL.** Any RFCOMM connection (including state queries) establishes
ACL to the headphones. Bose firmware may interpret this as "device wants audio".
Don't probe/poll from a device that isn't supposed to be the active source.

## Rules

- **NEVER unpair/toggle BT/pairing mode without explicit user approval** — broke pairings on 2026-03-16
- **NEVER proactively connect HFP** — SCO blocks A2DP streaming
- **NEVER auto-reconnect A2DP** — fights user device switches (#61-#64)
- **NEVER treat ACK as success for connectDevice** — poll getConnectedDevices instead
- **Bose Music app must be disabled** — fights for RFCOMM: `adb shell pm disable-user com.bose.bosemusic`
- 2-device multipoint limit
- getDeviceInfo status byte unreliable — use getConnectedDevices() as ground truth
- Single RFCOMM attempt per command — no retry loops
- Drain 300ms of initial data after RFCOMM connect (Bose firmware quirk)
- Use pymobiledevice3 for iPad BT operations
- minSdk 31 (Android 12) — no pre-O version checks needed
