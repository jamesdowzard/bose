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

## Other Commands

- Battery: `02,02,01,00` → level 0-100, charging flag
- ANC: `1F,03` — GET/SET modes (Quiet=0, Aware=1, Custom=2,3)
- Firmware: `00,05,01,00`
- Product name: `00,0F,01,00`

## Rules

- **NEVER unpair/toggle BT/pairing mode without explicit user approval** — broke pairings on 2026-03-16
- **Verify state changes with the user**, not just the protocol response
- **Bose Music app must be disabled** — fights for RFCOMM: `adb shell pm disable-user com.bose.bosemusic`
- 2-device multipoint limit
- getDeviceInfo status byte unreliable — use getConnectedDevices() as ground truth
- Single RFCOMM attempt per command — no retry loops
- Drain 300ms of initial data after RFCOMM connect (Bose firmware quirk)
- Use pymobiledevice3 for iPad BT operations
