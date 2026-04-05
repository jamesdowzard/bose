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

## Transport: RFCOMM vs BLE GATT (verified 2026-04-05)

The QC Ultra 2 uses TWO Bluetooth transports. Most settings can be READ over
RFCOMM, but some can only be WRITTEN over BLE GATT. This is a firmware design
choice — not a bug.

### RFCOMM (Bluetooth Classic SPP) — what we use now

On-demand connections via `withRFCOMM`/`withConnection`. Opens socket, sends
BMAP bytes, reads response, closes. ~200-300ms per session.

**GET works for everything** — all blocks/functions below return valid data over RFCOMM.

**SET works for these (ACK/RESP confirmed):**

| Setting | Block,Func | SET bytes | Notes |
|---------|-----------|-----------|-------|
| ANC mode | 1F,03 | `1F,03,05,02,{mode},01` | 0=quiet 1=aware 2=custom1 3=custom2 |
| Volume | 05,05 | `05,05,06,01,{level}` | 0-31 |
| Device name | 01,02 | `01,02,06,{len},00,{utf8}` | max 30 chars |
| Multipoint | 01,0A | `01,0A,06,01,{07/00}` | 07=on, 00=off |
| Connect device | 04,01 | `04,01,05,07,00,{MAC}` | Also routes audio |
| Disconnect | 04,02 | `04,02,05,06,{MAC}` | |
| Media control | 05,03 | `05,03,05,01,{action}` | 01=play 02=pause 03=next 04=prev |

**SET returns ERROR (0x04) — requires BLE GATT instead:**

| Setting | Block,Func | Error response | Notes |
|---------|-----------|----------------|-------|
| EQ (bass/mid/treble) | 01,07 | `00,00,04,01,05,10,00,04,01,03` | 3-band, range -10 to +10 |
| Immersion level | 01,09 | `01,09,04,01,05` | Custom ANC depth |
| Auto-off timer | 01,0B | `01,0B,04,01,05` | Minutes until auto-off |

### BLE GATT — not yet implemented

GATT services discovered on headphones (BLE scan 2026-04-05):

| Service UUID | Type | Notes |
|-------------|------|-------|
| FEBE | Bose proprietary | No characteristics enumerated |
| FE2C | Bose proprietary | No characteristics enumerated |
| Battery | Standard + Bose | Contains FE2C12XX writable chars |

Writable characteristics found under Battery service:

| Characteristic UUID | Properties |
|--------------------|-----------|
| D417C028-9818-4354-99D1-2AC09D074591 | Read, Write, WriteNoResp, Notify |
| C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8 | Read, Write, WriteNoResp, Notify |
| FE2C1234-8366-4814-8EB0-01DE32100BEA | Write, Indicate |
| FE2C1235-8366-4814-8EB0-01DE32100BEA | Write, Indicate |
| FE2C1236-8366-4814-8EB0-01DE32100BEA | Write |
| FE2C1237-8366-4814-8EB0-01DE32100BEA | Write, Indicate |
| FE2C1238-8366-4814-8EB0-01DE32100BEA | Read, Write, Notify |

The FE2C12XX Write+Indicate characteristics are likely BMAP-over-BLE command
channels (write command, receive response via indication). Not yet tested.

To implement: CoreBluetooth (Mac), BluetoothGatt (Android). Write BMAP EQ/immersion
SET bytes to the writable characteristics and check which one responds.

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
