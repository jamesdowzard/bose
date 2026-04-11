# Bose QC Ultra 2 Controller

**Headphones MAC:** E4:58:BC:C0:2F:72 (name: "verBosita")
**Protocol:** BMAP over RFCOMM via SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`)
**Note:** deca-fade UUID is Apple iAP2, NOT BMAP — don't use it

## Architecture (Independent Control)

Both Mac and phone control headphones independently via on-demand RFCOMM.
No persistent connections. No coordination. No Tailscale dependency.

```
Mac:   BoseControl.app (SwiftUI menu bar) → IOBluetooth RFCOMM → Headphones
Mac:   bose-ctl (CLI)                     → IOBluetooth RFCOMM → Headphones
Phone: BoseControl (Android/Compose)      → Android RFCOMM     → Headphones
```

Each command: open RFCOMM (SDP-resolved channel), send BMAP, read response, close (~200-300ms).
Both devices can send commands at any time -- SPP is single-connection, so if both try
simultaneously one waits, but in practice commands are too brief to collide.

## Components

### macOS (`macos/`)
- `macos/BoseControl/` -- SwiftUI menu bar app (replaces Hammerspoon/Raycast/bosed)
- `macos/build.sh` -- Build script
- `macos/com.jamesdowzard.bose-control.plist` -- LaunchAgent

### Android (`android/`)
- `android/` -- Jetpack Compose app (package: `au.com.jd.bose`)
- `BoseService` -- foreground service (RFCOMM commands, A2DP auto-accept)
- `BoseWidgetProvider` -- home screen widget (5 device buttons)
- `BoseTileService` -- Quick Settings tile (shows active source)
- `DevicePickerActivity` -- dialog launched from QS tile
- `BootReceiver` -- auto-start service on boot
- Companion device registered for background FGS privileges

### Shared
- `BoseRFCOMM.swift` -- Direct RFCOMM BMAP protocol (IOBluetooth, on-demand)
- `BoseCtl.swift` -- CLI using BoseRFCOMM directly

## Build & Deploy

```bash
# bose-ctl (CLI)
swiftc -O BoseRFCOMM.swift BoseCtl.swift -framework IOBluetooth -o ~/bin/bose-ctl

# Mac app
cd macos && ./build.sh

# Android app (deploy to S21 via ADB)
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

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
| ANC mode | 1F,03 | START | `1F,03,05,02,{mode},01` | 0=quiet 1=aware 2=custom1 3=custom2 |
| Volume | 05,05 | SET_GET | `05,05,02,01,{level}` | 0-31 |
| Device name | 01,02 | SET | `01,02,06,{len},00,{utf8}` | max 30 UTF-8 bytes |
| Multipoint | 01,0A | SET_GET | `01,0A,02,01,{07/00}` | 07=on, 00=off |
| Connect device | 04,01 | START | `04,01,05,07,00,{MAC}` | Also routes audio |
| Disconnect | 04,02 | START | `04,02,05,06,{MAC}` | |
| Media control | 05,03 | START | `05,03,05,01,{action}` | 01=play 02=pause 03=next 04=prev |
| **EQ band** | 01,07 | **SET_GET** | `01,07,02,02,{value},{band}` | band: 0=bass 1=mid 2=treble, value: signed -10 to +10 |
| **ANC depth** | 1F,0A | **SET_GET** | `1F,0A,02,05,{level},{autoCNC},{spatial},{windBlock},{ancToggle}` | level 0-10. Read current first, change level, preserve others. |

**Not supported on QC Ultra 2:** StandbyTimer SET (01,04), MotionAutoOff (01,14), OnHeadDetection SET (01,10).
Auto-off timer (01,0B) is read-only over RFCOMM — distinct from StandbyTimer (01,04).

### BMAP Function IDs (Block 0x05 — Audio)

| Function | ID | Notes |
|----------|-----|-------|
| ConnectedDevices | **0x01** | GET returns audio-active device MACs (ground truth) |
| MediaControl | 0x03 | START: 01=play 02=pause 03=next 04=prev |
| AudioCodec | 0x04 | GET returns codec ID + bitrate |
| Volume | **0x05** | GET/SET_GET: current + max level (0-31) |

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
