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

Each command: open RFCOMM channel 8, send BMAP, read response, close (~200-300ms).
Both devices can send commands at any time -- SPP is single-connection, so if both try
simultaneously one waits, but in practice commands are too brief to collide.

## Components

### macOS (`macos/`)
- `macos/BoseControl/` -- SwiftUI menu bar app (replaces Hammerspoon/Raycast/bosed)
- `macos/build.sh` -- Build script
- `macos/com.jamesdowzard.bose-control.plist` -- LaunchAgent

### Android (`android/`)
- `android/` -- Jetpack Compose app (package: `au.com.jd.bose`)
- Foreground service, home screen widget, Quick Settings tile
- A2DP auto-accept, boot receiver

### Shared
- `BoseRFCOMM.swift` -- Direct RFCOMM BMAP protocol (IOBluetooth, on-demand)
- `BoseCtl.swift` -- CLI using BoseRFCOMM directly

## Build

```bash
# bose-ctl (CLI)
swiftc -O BoseRFCOMM.swift BoseCtl.swift -framework IOBluetooth -o ~/bin/bose-ctl

# Mac app
cd macos && ./build.sh
```

## Device Map

| Name | MAC | Notes |
|------|-----|-------|
| mac | BC:D0:74:11:DB:27 | MacBook |
| phone | A8:76:50:D3:B1:1B | Samsung S21 |
| ipad | F4:81:C4:B5:FA:AB | Currently needs re-pairing |
| iphone | F8:4D:89:C4:B6:ED | |
| tv | 14:C1:4E:B7:CB:68 | Chromecast |

## BMAP Function IDs (Block 0x04 — DeviceManagement)

| Function | ID | Notes |
|----------|-----|-------|
| Connect | **0x01** | Payload: `00` + 6-byte MAC = 7 bytes. Also routes audio. |
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
| 0x06 | SET | Simple set (name, multipoint, volume). **Does NOT work for EQ** |
| 0x07 | ACK | Acknowledgement |

### All Settable Commands (RFCOMM, verified)

| Setting | Block,Func | Operator | Bytes | Notes |
|---------|-----------|----------|-------|-------|
| ANC mode | 1F,03 | START | `1F,03,05,02,{mode},01` | 0=quiet 1=aware 2=custom1 3=custom2 |
| Volume | 05,05 | SET | `05,05,06,01,{level}` | 0-31 |
| Device name | 01,02 | SET | `01,02,06,{len},00,{utf8}` | max 30 chars |
| Multipoint | 01,0A | SET | `01,0A,06,01,{07/00}` | 07=on, 00=off |
| Connect device | 04,01 | START | `04,01,05,07,00,{MAC}` | Also routes audio |
| Disconnect | 04,02 | START | `04,02,05,06,{MAC}` | |
| Media control | 05,03 | START | `05,03,05,01,{action}` | 01=play 02=pause 03=next 04=prev |
| **EQ band** | 01,07 | **SET_GET** | `01,07,02,02,{value},{band}` | band: 0=bass 1=mid 2=treble, value: signed -10 to +10 |
| **StandbyTimer** | 01,04 | **SET_GET** | `01,04,02,01,{minutes}` | 0=never, or minutes (1 byte if <=255) |

### ActiveDevice (04,09) is UNRELIABLE

`04,09` always returns the querying device's own MAC, not the actual audio source.
Do NOT use it for determining which device is streaming. Instead:
- `05,01` (getConnectedDevices) = audio-connected devices → show as "active" (green)
- `04,05` (getDeviceInfo per device) = ACL-connected → show as "connected" (orange)

## Rules

- **NEVER unpair/toggle BT/pairing mode without explicit user approval** — broke pairings on 2026-03-16
- **Verify state changes with the user**, not just the protocol response
- **Bose Music app must be disabled** — fights for RFCOMM: `adb shell pm disable-user com.bose.bosemusic`
- 2-device multipoint limit
- getDeviceInfo status byte unreliable — use getConnectedDevices() as ground truth
- Single RFCOMM attempt per command — no retry loops
- Drain 300ms of initial data after RFCOMM connect (Bose firmware quirk)
- Use pymobiledevice3 for iPad BT operations
