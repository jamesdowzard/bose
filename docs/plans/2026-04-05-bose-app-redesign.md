# Bose Controller App Redesign

**Goal:** Two native apps (Android + macOS) that fully replace the Bose Music app for the QC Ultra 2. Both control headphones independently via BMAP over RFCOMM. No coordination between devices needed.

**Date:** 2026-04-05

---

## How It Works

Every interaction follows two layers:

1. **BMAP** (headphones firmware) — send bytes over RFCOMM to control settings, switch devices, query state
2. **A2DP** (device OS) — each device manages its own audio routing to the headphones

When switching audio to a device:
- BMAP Connect tells headphones to page the target device
- The target device's OS auto-accepts A2DP from a paired device (macOS always, Android sometimes)
- As insurance, the target device's app also explicitly connects A2DP when it detects an incoming ACL connection

No TCP, no relay, no shared state. Each app talks directly to headphones.

---

## BMAP Protocol Map (Complete Scan — 2026-04-05)

Format: `[block, function, operator, length, ...payload]`
Operators: `0x01`=GET, `0x03`=RESP, `0x04`=ERR, `0x05`=START, `0x06`=SET, `0x07`=ACK

### Block 0x00 — System Info

| Func | Name | GET Bytes | Response | Settable |
|------|------|-----------|----------|----------|
| 0x00 | Block version | `00,00,01,00` | `1.1.0` | No |
| 0x01 | Protocol version | `00,01,01,00` | `1.2.0` | No |
| 0x02 | Hardware ID | `00,02,01,00` | `87cc23ff` | No |
| 0x03 | Capabilities | `00,03,01,00` | `408201` (flags) | No |
| 0x05 | Firmware version | `00,05,01,00` | `8.2.20+g34cf029` | No |
| 0x06 | Device MAC | `00,06,01,00` | `E4:58:BC:C0:2F:72` | No |
| 0x07 | Serial number | `00,07,01,00` | `085958M52497699AE` | No |
| 0x0C | Crypto token | `00,0c,01,00` | 16-byte UUID | No |
| 0x0F | Product name | `00,0f,01,00` | `Bose QC Ultra 2 HP` | No |
| 0x11 | MAC with prefix | `00,11,01,00` | `00` + 6-byte MAC | No |
| 0x17 | Unknown flag | `00,17,01,00` | `00` | ? |

### Block 0x01 — Settings

| Func | Name | GET Bytes | Response | Settable |
|------|------|-----------|----------|----------|
| 0x00 | Block version | `01,00,01,00` | `1.1.0` | No |
| 0x02 | Device name | `01,02,01,00` | `00` + UTF-8 name | Yes — `01,02,06,len,00,name_bytes` |
| 0x03 | Settings blob | `01,03,01,00` | `41000081020000` | ? |
| 0x05 | Voice prompt lang | `01,05,01,00` | `0b,00,03` | Yes |
| 0x07 | EQ (bass/mid/treble) | `01,07,01,00` | 12 bytes: 3x `f6,0a,XX,YY` | Yes — via BLE GATT on phone |
| 0x09 | Immersion level | `01,09,01,00` | 7 bytes | Yes |
| 0x0A | Multipoint | `01,0a,01,00` | `07`=on, `00`=off | Yes — `01,0a,02,01,{07/00}` |
| 0x0B | Auto-off timer | `01,0b,01,00` | `01,02,0f` | Yes |
| 0x0C | Unknown flag | `01,0c,01,00` | `00` | ? |
| 0x18 | Unknown flag | `01,18,01,00` | `01` | ? |
| 0x1B | Unknown flag | `01,1b,01,00` | `01` | ? |

### Block 0x02 — Battery

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x00 | Block version | `02,00,01,00` | `1.1.0` | |
| 0x02 | Battery status | `02,02,01,00` | byte4=level(0-100), byte7=charging | |
| 0x05 | Unknown | `02,05,01,00` | `00` | Battery mode? |
| 0x10 | Unknown flag | `02,10,01,00` | `01` | |
| 0x15 | Unknown flag | `02,15,01,00` | `01` | |

### Block 0x03 — Firmware/OTA

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x00 | Block version | `03,00,01,00` | `1.2.0` | |
| 0x01 | OTA available | `03,01,01,00` | `01` | |
| 0x04 | OTA version | `03,04,01,00` | `0.0.0` | No update pending |
| 0x06 | OTA state | `03,06,01,00` | `00,01` | |
| 0x07 | Unknown | `03,07,01,00` | `00` | |
| 0x0F | Unknown flag | `03,0f,01,00` | `01` | |
| 0x10 | Unknown flag | `03,10,01,00` | `00` | |

### Block 0x04 — Device Management

| Func | Name | Bytes | Response | Notes |
|------|------|-------|----------|-------|
| 0x00 | Block version | `04,00,01,00` | `1.1.0` | |
| 0x01 | Connect | `04,01,05,07,00,{MAC}` | ACK + SET | Also routes audio |
| 0x02 | Disconnect | `04,02,05,06,{MAC}` | ACK | |
| 0x03 | Remove device | `04,03,05,06,{MAC}` | ACK | **NEVER USE** — unpairs |
| 0x04 | Paired devices | `04,04,01,00` | count + MAC array | 6 devices in scan |
| 0x05 | Device info | `04,05,01,06,{MAC}` | status + name | Status byte unreliable |
| 0x08 | Pairing mode | `04,08,01,00` | `00`=off | SET: `04,08,05,01,{00/01}` |
| 0x09 | Active device | `04,09,01,00` | 6-byte MAC | Returns querying device |
| 0x0E | Unknown flag | `04,0e,01,00` | `01` | |
| 0x12 | Unknown flag | `04,12,01,00` | `01` | |

### Block 0x05 — Audio

| Func | Name | Bytes | Response | Notes |
|------|------|-------|----------|-------|
| 0x00 | Block version | `05,00,01,00` | `1.1.0` | |
| 0x01 | Connected devices | `05,01,01,00` | count + MACs (with extra bytes) | Ground truth |
| 0x03 | Media state | `05,03,01,00` | `1f` (playing state) | Controls: `05,03,05,01,{01=play,02=pause,03=next,04=prev}` |
| 0x04 | Audio codec | `05,04,01,00` | `02,14,a3` | Codec ID + bitrate |
| 0x05 | Volume | `05,05,01,00` | `max,current` | SET: `05,05,02,01,{level}` (0-31) |
| 0x07 | Audio routing | `05,07,01,00` | 6 bytes | |
| 0x0D | Audio config | `05,0d,01,00` | 10 bytes | |
| 0x11 | DSP state | `05,11,01,00` | 102 bytes | Full DSP coefficients |

### Block 0x06 — Unknown (empty)

Only version response (1.1.0). No functions found.

### Block 0x07 — Sensors

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x00 | Block version | `07,00,01,00` | `1.1.0` | |
| 0x01 | Sensor reading | `07,01,01,00` | `08,73` | Temperature? Proximity? |
| 0x04 | Sensor flag | `07,04,01,00` | `01` | |

### Block 0x08 — Wear Detection

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x07 | Wear state | `08,07,01,00` | `04` | On-head detection |
| 0x08 | Wear config | `08,08,01,00` | 9 bytes: `23,01,00,00,01,00,00,00,00` | Auto-pause settings? |

### Block 0x09 — Usage Stats

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x00 | Block version | `09,00,01,00` | `1.1.0` | |
| 0x02 | Counters | `09,02,01,00` | `00,00,00,00` | Usage time? |

### Block 0x0D — Button Config

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x00 | Block version | `0d,00,01,00` | `1.1.0` | |
| 0x01 | Button mapping | `0d,01,01,00` | `ff,83` | Action assignment |
| 0x0D | Unknown | `0d,0d,01,00` | `00` | |
| 0x0E | Unknown | `0d,0e,01,00` | `02` | |

### Block 0x12 — Security/Identity

| Func | Name | GET Bytes | Response | Notes |
|------|------|-----------|----------|-------|
| 0x00 | Block version | `12,00,01,00` | `1.1.0` | |
| 0x01 | Security config | `12,01,01,00` | `03,39,08,3e,07` | |
| 0x09 | Public key | `12,09,01,00` | PEM-encoded ECDSA key | Authentication |
| 0x0B | Auth state | `12,0b,01,00` | `03` | |
| 0x0C | Codename | `12,0c,01,00` | `wolverine` | Internal codename |
| 0x0D | Platform | `12,0d,01,00` | `OTG-QCC-384` | Qualcomm QCC384 chip |

### Block 0x1F — Noise Control (from code, confirmed working)

| Func | Name | Bytes | Response | Notes |
|------|------|-------|----------|-------|
| 0x03 | ANC mode | `1f,03,01,00` | byte4: 0=quiet, 1=aware, 2=custom1, 3=custom2 | SET: `1f,03,05,02,{mode},01` |

---

## Architecture

### Shared Protocol

Both apps implement the same BMAP protocol. The byte-level code is identical — only the transport differs (IOBluetooth on Mac, BluetoothSocket on Android).

```
                         RFCOMM
  ┌──────────────┐  ──────────────►  ┌──────────────┐
  │  Mac App     │  ◄──────────────  │              │
  │  (SwiftUI)   │                   │  QC Ultra 2  │
  │  IOBluetooth │                   │  (BMAP)      │
  └──────────────┘                   │              │
                         RFCOMM      │              │
  ┌──────────────┐  ──────────────►  │              │
  │  Android App │  ◄──────────────  │              │
  │  (Compose)   │                   │              │
  │  BT Socket   │                   └──────────────┘
  └──────────────┘
```

No communication between Mac and Android. Both fully independent.

### Device Switching Flow

**"Switch to me"** (from either device):
1. Send BMAP Connect `04,01,05,07,00,{own_MAC}`
2. Connect own A2DP (insurance)

**"Switch to other device"** (from either device):
1. Send BMAP Connect `04,01,05,07,00,{other_MAC}`
2. Headphones page target device, target OS auto-accepts A2DP

**Android A2DP insurance:** BroadcastReceiver for `ACTION_ACL_CONNECTED` triggers `BluetoothA2dp.connect()` when headphones reconnect. This handles the case where headphones initiate but Samsung doesn't auto-accept.

---

## Android App

### Package & Identity
- Package: `au.com.jd.bose`
- Name: "Bose Control"
- Standalone app (not inside s21 automation)
- Min SDK 31 (Android 12 — BT permissions model)

### Components

**BoseProtocol.kt** — BMAP protocol (extracted from s21, identical bytes)
- On-demand RFCOMM via `withConnection { }` pattern
- All GET/SET commands from protocol map above
- Pure Kotlin, no Android UI dependencies

**BoseService.kt** — Foreground service
- Starts on boot, runs persistently
- Manages A2DP auto-accept (BroadcastReceiver for ACL events)
- No TCP server — no cross-device coordination needed
- Broadcasts state changes to UI + widget

**MainActivity.kt** — Full control UI (Jetpack Compose)
- **Dashboard card**: Battery, ANC mode, active device, firmware
- **Devices section**: 5 device buttons with state indicators (active/connected/offline)
- **ANC section**: Quiet / Aware / Custom1 / Custom2 toggle
- **EQ section**: Bass / Mid / Treble sliders (-10 to +10)
- **Volume section**: Slider (0-31)
- **Settings section**: Device name, multipoint toggle, auto-off timer, immersion level, wear detection
- **Info section**: Firmware, serial, platform (wolverine/QCC384), codec

**BoseWidget.kt** — Home screen widget
- 5 device buttons, tap to switch
- Shows active (green) / connected (orange) / offline (grey)
- Battery percentage overlay

### Permissions
```xml
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

---

## Mac App

### Identity
- Name: "Bose Control"
- Bundle ID: `com.jamesdowzard.bose-control`
- SwiftUI menu bar app
- Runs on startup via LaunchAgent (replaces bosed)
- Code-signed with Developer ID

### Components

**BoseRFCOMM.swift** — BMAP protocol (existing, enhanced with all commands from scan)
- All GET/SET from protocol map
- On-demand RFCOMM via `withRFCOMM { }` pattern

**BoseApp.swift** — Menu bar app
- Menu bar icon (headphones, shows battery level)
- Click → popover with full controls
- Keyboard shortcut `⌥B` → same popover (replaces Hammerspoon)

**Popover UI (SwiftUI)**
- **Header**: Battery, ANC quick toggle, device name
- **Devices**: 5 buttons with state (replaces Hammerspoon pill)
- **ANC**: Quiet / Aware / Custom segmented control
- **EQ**: Bass / Mid / Treble sliders
- **Volume**: Slider
- **Settings**: Expandable section (multipoint, auto-off, name, immersion)
- **Info**: Firmware, serial, codec

**Auto-reconnect** — built into the app (replaces bosed daemon)
- Polls blueutil every 3s for connection state
- 30-second reconnect window on disconnect

### Build
```bash
# Xcode project or SwiftPM
# Output: Bose Control.app → /Applications/
# LaunchAgent: com.jamesdowzard.bose-control.plist
```

---

## What Gets Removed

After both apps are working:

| Component | Action |
|-----------|--------|
| `BoseCtl.swift` | Keep as `bose-ctl` CLI (thin wrapper, useful for scripting) |
| `BoseDaemon.swift` | Removed — Mac app handles auto-reconnect |
| `hammerspoon/bose.lua` | Removed — Mac app handles `⌥B` shortcut |
| `raycast/bose-toggle.sh` | Removed — Mac app menu bar replaces it |
| `com.jamesdowzard.bosed.plist` | Removed — Mac app has its own LaunchAgent |
| `s21/app-automation/bose/*` | Removed — extracted to standalone Android app |
| TCP server (port 8899) | Removed — no cross-device coordination |
| Phone TCP client in BoseCtl.swift | Removed |

---

## Implementation Order

1. **Android app** — new repo, extract protocol, full UI, widget, A2DP auto-accept listener
2. **Mac app** — SwiftUI menu bar app, full protocol, `⌥B` shortcut, auto-reconnect
3. **Protocol exploration** — probe unknown SET commands (immersion, buttons, wear detection)
4. **Cleanup** — remove old code from s21, remove Hammerspoon/Raycast/bosed
