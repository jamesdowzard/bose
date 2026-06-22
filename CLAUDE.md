# Bose QC Ultra 2 Controller

**Headphones MAC:** E4:58:BC:C0:2F:72 (name: "verBosita")
**Protocol:** BMAP over RFCOMM via SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`)
**Note:** deca-fade UUID is Apple iAP2, NOT BMAP — don't use it

## Architecture (Independent Control)

Both Mac and phone control headphones independently via on-demand RFCOMM.
No persistent connections. No coordination. No Tailscale dependency.

```
Mac:   bose (CLI)                     → IOBluetooth RFCOMM → Headphones
Mac:   Raycast / Hammerspoon / Bose.app  ─shell→ bose → Headphones
Phone: BoseControl (Android/Compose)      → Android RFCOMM     → Headphones
```

Each command: open RFCOMM (SDP-resolved channel), send BMAP, read response, close (~200-300ms).
Both devices can send commands at any time -- SPP is single-connection, so if both try
simultaneously one waits, but in practice commands are too brief to collide.

## Components

### macOS — no resident poller; on-demand surfaces over `bose`
There is intentionally **no LaunchAgent and nothing that polls** (a resident 10 s
poll timer was the original audio-dropout cause — #69-era). The Mac control surface
is three thin front-ends that shell out to the `cli/` binary (`~/bin/bose`), so
nothing runs in the background and the Mac only touches the headphones on an
explicit user action.
- `macos/BoseControl/` -- **Bose.app**: a windowed SwiftUI app (warm-paper light
  two-panel: battery/ANC mode/Immersive Audio (spatial Off/Still/Motion)/volume/multipoint + auto-pause/auto-answer toggles
  (01,18 / 01,1B) + a favourites display (1F,08, read-only) + device grid + EQ). The light
  theme (burnt-orange `#AF3A03` accent on warm paper, from the Midterm `paper-hc` palette)
  is shared with the Android app; macOS colours live in `ContentView.swift`, Android in
  `MainActivity.kt` (`BoseAccent`/`BoseConnected`/…). Six ANC
  mode buttons (Quiet/Aware/Immersion/Cinema/C1/C2 = slots 0-5; the C1/C2 buttons show
  the custom slots' stored on-device names when set, e.g. "Spatial", and can be **renamed
  in place via right-click → Rename…** — `mode-name --slot`, active mode untouched) + a **noise-level
  slider** driven by `anc-level` (1F,06) — NOT a raw depth (1F,0A disables ANC, #83).
  The slider is enabled only on the adjustable custom slots (4/5, firmware `cncMutable`)
  and greys out with a "level is fixed" hint on Quiet/Aware/Immersion/Cinema.
  It is a **thin front-end that shells `bose`** — NO RFCOMM, NO IOBluetooth, NO
  protocol code — reading via `bose info --json` and writing via the verbs. It is
  **user-launched and event-driven**: reads on window-open, on app-focus, after each
  write, and on ⌘R — never on a timer. Build `bash macos/build.sh [--install]`
  (Developer-ID signed → `/Applications`; no LaunchAgent). In-window keys: ⌘1-6
  ANC modes (slots 0-5), ⌘↑/⌘↓ volume, ⌘R refresh, ⌘M connect Mac. Global hotkeys stay in
  Hammerspoon. The `--json` read seam lives in `cli/main.swift` (`cmdInfoJSON`, pure
  formatting over `getAllStateWithDevices` — bulk state + the device grid's active sink
  AND idle ACL probes in ONE warm session, so neither is lost to the cold-second-session
  quirk a separate `getDeviceStates` call hit, #132). It surfaces — but does not fix —
  the #83 flight/ancDepth behaviour; that fix lands in the CLI and the app inherits it.
- `raycast/bose-connect.sh` / `bose-disconnect.sh` -- Raycast script commands with a device dropdown → `bose connect|disconnect <device>`
- `raycast/bose-status.sh` / `bose-full-status.sh` -- `bose status` / `bose info`
- `raycast/bose-anc-level.sh` / `bose-profile.sh` -- `bose anc-level [0-10]` (active mode's noise level, custom modes only) / `bose profile [name]` (text arg)
- `raycast/bose-spatial.sh` -- `bose spatial [off|still|motion]` (active mode's Immersive Audio, custom modes only). Dropdown arg incl. a blank "Read current"; the script uses `${1:+"$1"}` so a blank omits the arg entirely (a literal `""` makes the CLI reject it) — the robust pattern the older bare-`"$1"` commands lack.
- `raycast/bose-auto-pause.sh` / `bose-auto-answer.sh` -- `bose auto-pause [on|off]` / `bose auto-answer [on|off]` (blank arg = read); `bose-favorites.sh` -- `bose favorites` (display-only)
- `profiles.json` (repo root) -- settings presets ({ANC mode, noise level, EQ, multipoint, volume}) applied by `bose profile`; versioned + hand-editable, ships flight/office/music. A profile's `noiseLevel` is applied via the `anc-level` (1F,06) RMW and ONLY takes effect on the adjustable custom modes (4/5, `cncMutable`) — named modes set the mode only (a level over quiet/aware/spatial is a no-op; the old 1F,0A depth write disabled ANC, #83). flight = {quiet, multipoint off}. Runtime JSON (not codegen'd TOML) because `profile save` writes it; loader resolves `$BOSE_PROFILES` → repo path → `~/.config/bose/`. Pure logic in `cli/Profiles.swift`, live apply in `cli/Composites.swift` (`applyProfile`).
- `hammerspoon/bose.lua` -- Hammerspoon module, all **event-driven** (no timers). **Only Opt+B is bound now** (2026-06-20): **Opt+B shows/hides the Bose app** (the windowed control surface — press once to open/focus, again to hide; switch devices/ANC/EQ from its tiles). The other four hotkeys are **commented out in `start()`** — James drives everything else from the Bose app (Opt+I was cycling spatial audio unexpectedly). Their binds + `_MODS`/`_KEY` defaults remain in the file, so re-enabling any is a one-line uncomment + reload: **Opt+⇧B toggles Mac ↔ phone** (+ one-shot low-battery warn piggybacked on the press), **Opt+N cycles ANC** (quiet→aware→immersion), **Opt+I cycles Immersive Audio** (off→still→motion; custom modes only — shows a hint on a fixed named mode), **Opt+J connects the headphones to this Mac** (unconditional, no toggle direction-guessing; `CONNECT_TARGET` retargets it). Plus two **OS-event** behaviours (no hotkey, no poll — driven by `hs.audiodevice`/`hs.application` watchers): **battery announce** — `say`s the battery through the headphones when they become the Mac output (a stand-in for the power-on announcement Bose removed in fw 8.2.20; `ANNOUNCE_BATTERY`), and **auto-route on call** — a call app (Teams/Zoom/FaceTime/Slack/Webex) launching routes the Mac's *input* to the MacBook mic, and the audiodevice guard never lets the Bose be the system input (its over-ear mics make callers hear the room); input **stays** on the MacBook mic after calls — no restore, because `hs.application.watcher` doesn't reliably deliver `terminated` (verified 2026-06-20) and the MacBook mic is the right default. `AUTO_ROUTE_ON_CALL` + `CALL_APPS`. NB Teams can override the system input with its own setting — set its in-app mic once. Returns a table with `.start()`/`.stop()`. Wired in `init.lua` via `BoseCtl = dofile(os.getenv("HOME").."/code/personal/bose/hammerspoon/bose.lua"); BoseCtl.start()`. Edits apply on Hammerspoon reload.
- The Swift core that does the actual RFCOMM work lives in `cli/` (see below). The macOS app target (`macos/BoseControl/`) is pure SwiftUI/Foundation and does NO RFCOMM — it shells `bose`, so the two never drift and the app can't reintroduce a transport/poll bug.

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
- `cli/main.swift` -- `bose` command surface (status/battery/anc/anc-level/spatial/mode-name/devices/connect/disconnect/swap/volume/multipoint/auto-pause/auto-answer/favorites/play-pause-next-prev/eq/raw). `mode-name [--slot 4|5] [name]` renames a custom mode via the 1F,06 RMW (name field, SET payload [3..34]) — custom slots only (`userConfigurable`; presets are locked, firmware ignores the write). Without `--slot` it targets the ACTIVE mode (`setActiveModeName`); with `--slot 4`/`5` it renames C1/C2 **in place without changing the active mode** (`setModeName`, used by the Mac app's right-click rename). Both share `renameModeSlot`. The name persists on-device and shows in the Bose app too. `info --json` emits `custom1Name`/`custom2Name` (slot 4/5 stored names) AND the active mode config (modeName/noiseLevel/spatial/adjustable) — all read in the SAME warm session as the bulk state, folded into `getAllStateWithDevices` (a separate `readModeInfo` call ran as a cold SECOND session and reliably came back empty, blanking the slider/spatial/C1-C2 names, #134). The Mac app labels the C1/C2 buttons with the names (falling back to "C1"/"C2" when unset = "None") and renames them via right-click → Rename… → `mode-name --slot`. The Android app does the same display on its mode selector — `Composites.readCustomModeNames()` (slots 4/5) → `BoseViewModel` `custom1Name`/`custom2Name` → `AncSection` label. (Display only on Android; renaming is Mac/CLI via `mode-name`.) **No inline byte parsing** — every command routes through the generated `BMAP.*` builders. `connect`/`swap` poll-confirm via `getConnectedDevices` (ACK is never success); volume uses the generated SET_GET builder.
- `cli/Transport.swift` -- IOBluetooth RFCOMM transport (per-command open/drain-300ms/close, cold-start warm-up, serial queue).
- `cli/Composites.swift` -- live-channel composites (cncLevel RMW, connectedDevices list, getAllState single-session).
- `cli/Parsers.swift` -- pure, hardware-free response parsers; `cli/Tests/main.swift` + `cli/run-tests.sh` are the standalone unit tests (same captured-byte corpus as Android `Parsers.kt`).
- `cli/build.sh` -- compiles the generated Swift + `cli/{Transport,Parsers,Composites}.swift` + `cli/main.swift` → `cli/build/bose`. Does NOT install over `~/bin/bose`.
- The Swift core here and the Kotlin app share one protocol source (`protocol/spec/` → `generated/`), so they can't drift on wire encoding.

### Protocol (`protocol/`) — the single source of truth
- `protocol/spec/bmap.toml` -- **canonical machine-readable BMAP spec.** Every command, operator, and enum lives here with `verified_bytes` golden captures. The command tables further down in this file are the human-readable mirror — **edit `bmap.toml` and regenerate; never hand-edit `generated/`.**
- `protocol/spec/devices.toml` -- headphone MAC + device map (the one home for those literals).
- `protocol/codegen/` + `protocol/generate.py` -- Python (uv) emitters → `protocol/generated/{BMAP,Devices}.generated.{swift,kt}`. `make gen` regenerates; `make check` proves the committed generated files are in sync + runs the golden byte tests.

## Build & Deploy

```bash
# Protocol layer (regenerate Swift + Kotlin from the spec; run golden tests)
cd protocol && make gen      # or `make check` to also verify no drift + run tests

# bose (CLI) → cli/build/bose, then install + the macOS front-ends
bash cli/build.sh
cp cli/build/bose ~/bin/bose                       # the engine
cp raycast/*.sh ~/.config/raycast/script-commands/         # Raycast commands
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

**State colors** (warm-paper card, shared with the #98 app retheme):
- Burnt-orange chip (#AF3A03) = active (audio routed here)
- Blue chip (#1B4A82) = connected but not active
- Muted paper chip (#E6DCC6 fill / #6E6A5E text) = offline/not connected

The widget is a paper **card** (`@drawable/widget_card_bg`: #FCFAF4 fill, #E6DCC6
hairline border, rounded) sitting on the home-screen wallpaper. Active/connected
are solid filled chips so they read on any wallpaper. Constants live in
`BoseWidgetProvider.kt` (independent of the app's Compose palette in `MainActivity.kt`).

Battery percentage shown as overlay text — own on-paper thresholds: warm-red
(#A82E2E) ≤15, burnt-orange (#AF3A03) ≤30, secondary grey (#6E6A5E) otherwise.

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
| appletv | 48:E1:5C:5D:33:B6 | macOS + S21 in-app | Katrina's Apple TV 4K (label "Katrina's Apple TV"; `widget=false` → no home-screen widget) |
| quest | 78:C4:FA:C8:5C:3D | yes | Meta Quest 3 |

A device's optional `label` (devices.toml) is the friendly display name shared by the Mac app + S21 in-app tile; absent → fall back to the key.

**Connection priority** (`priority` in devices.toml; 1 = highest):
`1 mac → 2 phone → 3 appletv → 4 ipad → 5 quest → 6 tv → 7 iphone`.
The headset holds 2 devices (multipoint) and the firmware only evicts by its own LRU
(`ConnectionPriority 0x10` is FuncNotSupp — see `docs/reverse-engineering.md`). So the
CLI's `connect`/`swap` enforce the hierarchy in software: when both slots are full and
the target isn't already connected, it **disconnects the lowest-priority of the two held
devices first**, then pages the target — and **restores the evicted device if the target
fails to connect** (`evictLowestPriorityIfFull` / `restoreEvicted` in `cli/main.swift`).
Mac app / Raycast / Hammerspoon inherit this (they shell `bose`). **Android now replicates
it too**: pure victim selection in `android/.../Eviction.kt` (`evictionVictim`, JVM-unit-
tested), held-state read via `Composites.getDeviceStates`, wired into `BoseService.switchDevice`
(evict-then-page, restore on failure). Android can't run the Mac's host-side blueutil step, so
it only sends the BMAP disconnect/connect — correct from the phone's side.

**Cycle order** (bose): `mac → quest → ipad → iphone → tv → appletv → phone`

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

> **Decompile archive + findings:** `docs/reverse-engineering.md` — the Bose Music
> v13.0.7 APK + full jadx source are archived on S3; that doc holds the BMAP frame
> format, the DeviceManagement (0x04) function-ID table, and proven/dead-end notes
> (e.g. `ConnectionPriority 0x10` is FuncNotSupp on the QC Ultra 2 — no firmware
> device-priority hierarchy). Grep it before re-decompiling.

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
| ANC mode | 1F,03 | START | `1F,03,05,02,{mode},01` | slots: 0=quiet 1=aware 2=immersion 3=cinema (fixed) 4=custom1 5=custom2 (adjustable); reads 255 = OFF (genuinely disabled — confirmed audibly #83). 255 is REACHABLE: writing a raw CNC depth (1F,0A) over a named mode knocks 1F,03 to 255. ANC here is mode-based; depth is the same axis. |
| Volume | 05,05 | SET_GET | `05,05,02,01,{level}` | 0-31 |
| Device name | 01,02 | SET | `01,02,06,{len},00,{utf8}` | max 30 UTF-8 bytes |
| Multipoint | 01,0A | SET_GET | `01,0A,02,01,{07/00}` | SET 07=on/00=off. RESPONSE is a bitfield — bit 0 = enable; fw 8.2.20: on→0x07, off→0x06 (slot bits persist). Parse `& 0x01`, NOT `!= 0` (that misread 0x06 as on, #83). |
| **Auto-pause** | **01,18** | **SET_GET** | `01,18,02,01,{00/01}` | Pause when headphones are removed. Single bool byte; RESP echoes STATUS (`& 0x01`). Verified live (no-op SET_GET) + app builder. The *setting toggle* — distinct from the live wear STATE (02,09, FuncNotSupp on over-ears). |
| **Auto-answer** | **01,1B** | **SET_GET** | `01,1B,02,01,{00/01}` | Answer a call when headphones are donned. Single bool byte; RESP echoes STATUS. Verified live + app builder. |
| **Favorites** | **1F,08** | **SET_GET** | `1F,08,02,{len},{count},{reversed bitmask…}` | Which mode slots are favourited. Payload = count byte + `ceil(count/8)`-byte REVERSED-order bitmask (low modes in the LAST byte). Live: `1F 08 02 03 0b 00 07` = count 11, modes 0/1/2. GET is a generated builder; the SET_GET bitmask + decode are hand-written (`buildFavoritesSetGet`/`parseFavorites`, Swift+Kotlin). |
| Connect device | 04,01 | START | `04,01,05,07,00,{MAC}` | Also routes audio |
| Disconnect | 04,02 | START | `04,02,05,06,{MAC}` | |
| Media control | 05,03 | START | `05,03,05,01,{action}` | 01=play 02=pause 03=next 04=prev |
| **EQ band** | 01,07 | **SET_GET** | `01,07,02,02,{value},{band}` | band: 0=bass 1=mid 2=treble, value: signed -10 to +10 |
| **Noise level** | **1F,06** | **SET_GET** | per-mode read-modify-write (see below) | 0 = max cancel … 10 = transparency. The CORRECT level command (`bose anc-level`). Reads a mode's config, changes only the level, forces `ancToggle=1`, writes back — ANC stays anchored to the mode. Only on `cncMutable` modes (custom slots); Quiet/Aware/spatial modes are fixed. |
| **Immersive Audio (spatial)** | **1F,06** | **SET_GET** | per-mode RMW, spatial byte (resp [44] / SET [37]) | 0 = off, 1 = Still (fixed-to-room), 2 = Motion (head-tracking). The CORRECT spatial command (`bose spatial off\|still\|motion`). Same 1F,06 RMW as noise level — changes only the spatial byte. Settable ONLY on `spatialMutable` modes (custom slots 4/5, payload[41] bit2); named modes carry it fixed (Immersion = Motion, Cinema = Still). The global 05,0F path is FuncNotSupp. |
| ~~ANC depth~~ | ~~1F,0A~~ | — | — | **DO NOT USE.** `1F,0A` (AudioModesSettingsConfig) is GLOBAL live-tuning; writing it over an active mode DETACHES the mode → 1F,03 reads 255 = ANC OFF (#83, confirmed audibly). The old `anc-depth` command + Raycast used this — removed. Use `anc-level` (1F,06) instead. |

**Not supported / write-locked on QC Ultra 2 (all re-verified live 2026-06-20, fw 8.2.20 — don't re-investigate):**
- **StandbyTimer SET (01,04)**, **MotionAutoOff (01,14)**, **OnHeadDetection SET (01,10)**, **CncPresets (01,0F)**: reply **FuncNotSupp** (error op 0x04, code 4) to a GET. Dead.
- **Global Immersive/Spatial Audio (05,0F SpatialAudioMode, 05,10 SpatialAudioStatus)**: FuncNotSupp. The dedicated AudioManagement spatial functions don't exist here — spatial is per-mode only (see AudioModes 1F,06 below).
- **VoicePrompts (01,03)**: GET works (`01 03 03 07 41 00 00 81 02 00 00` → enabled=0, lang=UsEnglish), but `isTogglable` (config bit7) = 0 and the enable SET_GET is **silently ignored** (response byte unchanged, cold + warm). Read-only on this firmware.
- **Buttons / action-button mode (01,09)**: GET works (`01 09 03 07 80 09 13 …` → button id 0x80, eventType 0x09, **already SpatialAudioMode (0x13)**; only Vpa/Disabled/SpotifyGoMode/SpatialAudioMode assignable), but the SET_GET (op 0x02) **and** plain SET (op 0x06) both return **No response** and leave state unchanged, cold + warm. Write-locked — Bose's app likely uses a privileged channel we don't replicate.
- **Sidetone**: no settable opcode (the 01,0B the generic BMAP enum labels "Sidetone" is the read-only **auto-off timer** here — returns `01 0b 03 03 01 02 0f`).
- Auto-off timer (01,0B) is read-only over RFCOMM — distinct from StandbyTimer (01,04).

### AudioModes (block 0x1F) — ANC is MODE-based (reverse-engineered from the Bose app, confirmed live fw 8.2.20)

Block `0x1F` is **AudioModes**, not "ANC". The headphone has a list of **mode slots**
(by index): on verBosita — 0 Quiet, 1 Aware, 2 Immersion, 3 Cinema, 4/5 empty user
slots ("None"). Each mode carries a CNC noise level + autoCNC + spatial + windBlock +
ancToggle. **Level semantics: 0 = max cancellation (Quiet end), 10 = full transparency
(Aware end)** — NOT "cancellation strength 0..10".

| Func | Name | Use |
|------|------|-----|
| 1F,03 | AudioModesCurrentMode | select/activate a mode by **slot index** (START). Our `anc` command: 6 named (quiet/aware/immersion/cinema/custom1/custom2) + `anc <0-5>` for any slot. custom1/custom2 = slots 4/5 (the adjustable ones). Reads 255 = "no mode" = ANC off. |
| 1F,06 | **AudioModesModeConfig** | read/define a mode (index, prompt, name[32], …, cncLevel, …, ancToggle). The CORRECT level command — RMW it. **GET only answers inside a warm bulk session** (prime with a 02,02 read first). |
| 1F,0A | AudioModesSettingsConfig | GLOBAL live tuning. **Footgun** — detaches the active mode → 255/off (#83). Never use. |

- **1F,06 GET** request `1F 06 01 01 {index}`. RESPONSE `1F 06 03 30 {48-byte payload}`; offsets (payload = frame[4:]): `[0]`index, `[1..2]`prompt, `[3]`userConfigurable, `[6..37]`32-byte name, `[41]`mutability bitfield (**bit0 = cncMutable** = level editable; bit4 = ancToggleMutable), `[42]`cncLevel, `[43]`autoCNC, `[44]`spatial, `[46]`windBlock, `[47]`ancToggle.
- **1F,06 SET_GET** (DIFFERENT layout) `1F 06 02 28 {payload}`: `[0]`index, `[1..2]`prompt, `[3..34]`32-byte name, `[35]`cncLevel, `[36]`autoCNC, `[37]`spatial, `[38]`windBlock, `[39]`ancToggle.
- `bose anc-level [0-10]` does the GET→change-level→SET_GET RMW on the **active** mode, forcing `ancToggle=1`, and refuses if the mode's `cncMutable` is false (so it can never disable ANC). Pure parse/build = `parseModeConfig`/`buildModeConfigSet` (Parsers); session RMW = `setActiveModeLevel` (Composites).
- `bose spatial [off|still|motion]` does the same 1F,06 RMW on the **active** mode's spatial byte (Immersive Audio), refusing if the mode's `spatialMutable` (payload[41] bit2) is false. Verified live 2026-06-20: custom slots 4/5 have spatialMutable=1; Immersion carries spatial=2 (Motion), Cinema spatial=1 (Still). Build = `buildModeConfigSet(_, newSpatial:)`; session RMW = `setActiveModeSpatial` (Composites). `ModeConfig.spatialMutable` is the bit2 read. Surfaced in the macOS app AND the Android app (`MainActivity.kt` SettingsSection → `BoseViewModel.setSpatial` → `Composites.setActiveModeSpatial`) as an Off/Still/Motion segmented control that greys out on fixed modes, like the Level slider. Also a Raycast command (`bose-spatial.sh`); the Hammerspoon Opt+I hotkey that cycled off→still→motion is **disabled** as of 2026-06-20 (commented out in `bose.lua` `start()`).
- Implementation derived from decompiling `com.bose.bosemusic` (`AudioModesModeConfigResponse`, `FBlockAudioModesKt`); see `docs/plans/2026-06-08-cnc-mode-config-proper.md`.

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

| Capability | Block,Func | `bose` | Raycast | Hammerspoon | Android |
|------------|-----------|-----------|---------|-------------|---------|
| ANC mode | 1F,03 | ✅ `anc` | 👁 (in status) | — (Opt+N disabled 2026-06-20) | ✅ mode selector |
| Noise level (CNC) | **1F,06** | ✅ `anc-level` (custom modes) | ✅ `bose-anc-level` | — | ✅ slider (1F,06 RMW, custom modes only) |
| Immersive Audio (spatial) | **1F,06** | ✅ `spatial` (custom modes) | ✅ `bose-spatial` | — (Opt+I disabled 2026-06-20) | ✅ Off/Still/Motion selector (custom modes only) |
| Device name | 01,02 | ✅ `name` | — | — | ✅ rename |
| EQ band | 01,07 | ✅ `eq` | 👁 (in status) | — | ✅ 3-band |
| Multipoint | 01,0A | ✅ `multipoint` | — | — | ✅ toggle |
| Auto-pause | **01,18** | ✅ `auto-pause` | ✅ `bose-auto-pause` | — | — (parser only, no UI) |
| Auto-answer | **01,1B** | ✅ `auto-answer` | ✅ `bose-auto-answer` | — | — |
| Favorites | **1F,08** | ✅ `favorites` | 👁 `bose-favorites` | — | — (parser only, no UI) |
| Connect device | 04,01 | ✅ `connect`/`swap` | ✅ `bose-connect` | Opt+B opens app (Opt+⇧B/Opt+J disabled 2026-06-20) | ✅ widget/tile/picker |
| Disconnect device | 04,02 | ✅ `disconnect` | ✅ `bose-disconnect` | 👁 (toggle path) | — |
| Device info (ACL) | 04,05 | 👁 `devices` (○ state) | — | — | 👁 widget colour |
| Connected devices | 05,01 | 👁 `devices`/`status`/`info` | 👁 (in status) | 👁 toggle-direction | 👁 widget/tile active |
| Media control | 05,03 | ✅ `play`/`pause`/`next`/`prev` | — | — | ✅ notification controls |
| Audio codec | 05,04 | 👁 `info` | 👁 (full status) | — | 👁 state |
| Volume | 05,05 | ✅ `volume` | 👁 (in status) | — | ✅ slider |
| Firmware | 00,05 | 👁 `status`/`info` | 👁 (status) | — | 👁 state |
| Battery | 02,02 | 👁 `battery`/`status`/`info` | 👁 (status) | — | 👁 widget overlay |

### Off-spec diagnostic GETs (issued directly in `getAllState`, not in `bmap.toml`)

| Capability | Block,Func | `bose` | Raycast | Android |
|------------|-----------|-----------|---------|---------|
| Serial number | 00,07 | 👁 `info` | 👁 (full status) | 👁 state |
| Product name | 00,0F | 👁 `info` | 👁 (full status) | 👁 state |
| Platform | 12,0D | 👁 `info` | 👁 (full status) | 👁 state |
| Codename | 12,0C | 👁 `info` | 👁 (full status) | 👁 state |
| Auto-off timer | 01,0B | 👁 `info` (read-only) | 👁 (full status) | 👁 state |

> **No on-head / live wear state — not exposed on the QC Ultra 2 (verified, do not re-add).**
> The real wear function is **`StatusInEar` = block `0x02` / func `0x09`** (a plain GET;
> response decodes `payload[0]` bit0 = left bud, bit1 = right bud). It's an **earbuds**
> feature — the over-ear headphones answer **`FuncNotSupp`** (error op `0x04`, code `4`)
> to `02,09`. The live wear STATE (which bud is in the ear) is never published over BMAP
> on the over-ears — auto-pause is handled on-device (sensor → AVRCP pause to the active
> sink). The on/off *setting* for that feature IS published, though: it's `01,18`
> AutoPlayPause (mapped above), distinct from the unpublished wear state. The old
> `08,07 == 0x04` "on-head" read was a synthetic-fixture
> guess — `08,07` isn't the wear function and its byte is noise (flips 0x03/0x04 off-head).
> Confirmed by decompiling the Bose Music app (v13.0.7, `com.bose.bmap.messages…StatusInEar`)
> + the device's own `FuncNotSupp` reply. Removed from app/CLI/Android (#104-era cleanup).

**Profiles** compose several of these capabilities at once — a `bose profile`
applies {ANC mode, noise level, EQ, multipoint, volume} in one session (CLI +
`bose-profile.sh` Raycast; drivable from macOS Focus via a Shortcut, see README).

**Notable gaps (intentional):** Hammerspoon binds **only Opt+B (open app)** as of
2026-06-20 — the other four (Opt+⇧B toggle, Opt+N ANC cycle, Opt+I Immersive Audio
cycle, Opt+J connect → Mac) are commented out in `start()` (James uses the Bose app for
those; the binds remain in-file for a one-line re-enable). Still all event-driven, no
timers. Raycast covers the common dropdowns plus full-status / anc-level /
spatial / profile; deeper config
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
