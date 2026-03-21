# Bose QC Ultra 2 Controller

**Headphones MAC:** E4:58:BC:C0:2F:72 (name: "verBosita")
**Protocol:** BMAP over RFCOMM via SPP UUID (`00001101-0000-1000-8000-00805f9b34fb`)
**Note:** deca-fade UUID is Apple iAP2, NOT BMAP — don't use it

## Architecture (Phone-Centric)

Phone is the sole RFCOMM owner. Mac daemon relays over Tailscale.
bosed maintains persistent subscribe channel — phone pushes bt_connect/bt_disconnect to control Mac BT.

```
bose-ctl / Hammerspoon (Mac)
  → bosed (/tmp/bosed.sock) — daemon-only, no direct RFCOMM
    → Phone BoseService (Tailscale 100.97.121.67:8899)
      → Bose headphones (RFCOMM via SPP)
```

## Components

- `BoseCtl.swift` — CLI (daemon-only, no RFCOMM fallback)
- `BoseDaemon.swift` — Smart relay with subscribe channel for push commands
- `hammerspoon/bose.lua` — ⌥B floating webview bar
- LaunchAgent: `~/Library/LaunchAgents/com.jamesdowzard.bosed.plist`

Android controller: `~/code/personal/s21/app-automation` (package: au.com.jd.automation)

## Device Map

| Name | MAC | Notes |
|------|-----|-------|
| mac | BC:D0:74:11:DB:27 | MacBook |
| phone | A8:76:50:D3:B1:1B | Samsung S21 (RFCOMM owner) |
| ipad | F4:81:C4:B5:FA:AB | Currently needs re-pairing |
| iphone | F8:4D:89:C4:B6:ED | |
| tv | 14:C1:4E:B7:CB:68 | Chromecast |

## Correct BMAP Function IDs (Block 0x04 — DeviceManagement)

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

## TCP Commands (port 8899)

status, connect, disconnect, swap, battery, devices, anc, pair, reconnect, pause, resume, raw

## Rules

- **NEVER unpair/toggle BT/pairing mode without explicit user approval** — broke pairings on 2026-03-16
- **Verify state changes with the user**, not just the protocol response
- **Never disconnect the phone** — it's the RFCOMM controller
- **Bose Music app must be disabled** — fights for RFCOMM: `adb shell pm disable-user com.bose.bosemusic`
- 2-device multipoint limit
- getDeviceInfo status byte unreliable — use getConnectedDevices() as ground truth
- Use pymobiledevice3 for iPad BT operations
