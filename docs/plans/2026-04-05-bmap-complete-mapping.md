# BMAP Complete Function Mapping (from Bose Music APK decompilation)

**Date:** 2026-04-05
**Source:** Decompiled `com.bose.bosemusic` v25.3.x APK via jadx

## Key Findings

1. **EQ SET uses SET_GET operator (0x02), not SET (0x06)**. This is why EQ appeared to need BLE GATT — we were sending the wrong operator. EQ SET works fine over RFCOMM.

2. **BLE GATT is NOT needed** for EQ, immersion, or auto-off. All settings are accessible over RFCOMM with the correct operator and function ID.

3. **Some function IDs we had were wrong.** Auto-off is func 0x04 (StandbyTimer), not 0x0B. What we thought was 0x0B might be a different setting.

## Operators (byte 2 of BMAP packet)

| Value | Name | Direction | Notes |
|-------|------|-----------|-------|
| 0x00 | SET | Host→Device | Direct set, used for ANC mode, volume, etc |
| 0x01 | GET | Host→Device | Query current value |
| 0x02 | SET_GET | Host→Device | Set value and get response back. **Required for EQ and StandbyTimer** |
| 0x03 | STATUS | Device→Host | Response / notification |
| 0x04 | ERROR | Device→Host | Error response |
| 0x05 | START | Host→Device | Used for connect/disconnect/media |
| 0x06 | RESULT | Device→Host | Result of START operation |
| 0x07 | PROCESSING | Device→Host | In-progress indicator |

## Function Blocks

| Block | ID | Description |
|-------|----|-------------|
| ProductInfo | 0x00 | Device identification, firmware, serial |
| Settings | 0x01 | Product name, voice prompts, EQ, ANC, multipoint, etc |
| Status | 0x02 | Battery, in-ear, charging, buttons |
| FirmwareUpdate | 0x03 | OTA update protocol |
| DeviceManagement | 0x04 | Connect/disconnect/pair/list devices |
| AudioManagement | 0x05 | Source, volume, media control, codec, spatial audio |
| CallManagement | 0x06 | Phone call handling |
| Control | 0x07 | Power, chirp, factory reset |
| Debug | 0x08 | Debug/diagnostics |
| Notification | 0x09 | Event subscriptions |
| HearingAssistance | 0x0C | Hearing aid EQ/WDRC/noise reduction |
| DataCollection | 0x0D | Usage data/crash logs |
| HeartRate | 0x0E | Heart rate sensor (Bose Sport) |
| Vpa | 0x10 | Voice assistant (Alexa/Google) |
| Wifi | 0x11 | WiFi config (Bose speakers) |
| Authentication | 0x12 | ECDSA auth, product identity |
| Cloud | 0x14 | Cloud sync/updates |
| AugmentedReality | 0x15 | AR streaming |
| AudioModes | 0x1F | ANC mode switching (Quiet/Aware/Custom) |

## Settings Block (0x01) — Complete Function List

| Func ID | Name | GET | SET | Operator for SET | Notes |
|---------|------|-----|-----|-----------------|-------|
| 0x00 | FblockInfo | Y | N | — | |
| 0x01 | GetAll | Y | N | — | |
| 0x02 | ProductName | Y | Y | SET (0x06) | UTF-8 name, max 30 chars |
| 0x03 | VoicePrompts | Y | Y | SET_GET (0x02) | Language config |
| 0x04 | StandbyTimer | Y | Y | SET_GET (0x02) | **Auto-off. Payload: {minutes} (1 byte if <=255, 2 bytes BE if >255)** |
| 0x05 | Cnc | Y | ? | — | ANC config (older devices) |
| 0x06 | Anr | Y | ? | — | ANR mode (older devices) |
| 0x07 | RangeControl | Y | Y | SET_GET (0x02) | **EQ. Payload: {level, bandId}. bandId: 0=bass, 1=mid, 2=treble. Level: -10 to +10 signed byte** |
| 0x08 | Alerts | Y | ? | — | |
| 0x09 | Buttons | Y | Y | SET_GET? | Button mapping |
| 0x0A | Multipoint | Y | Y | SET (0x06) | 0x07=on, 0x00=off |
| 0x0B | Sidetone | Y | ? | — | Sidetone level |
| 0x0C | SetupComplete | Y | ? | — | |
| 0x0D | ConversationMode | Y | ? | — | |
| 0x0E | CncPersistence | Y | ? | — | |
| 0x0F | CncPresets | Y | ? | — | |
| 0x10 | OnHeadDetection | Y | Y | SET_GET? | Wear detection settings |
| 0x13 | LedBrightness | Y | ? | — | |
| 0x14 | MotionInactivityAutoOff | Y | Y | SET_GET (0x02) | Motion-based auto-off |
| 0x16 | FlipToOff | Y | ? | — | |
| 0x18 | AutoPlayPause | Y | Y | SET_GET? | |
| 0x1A | TeamsButtonMode | Y | ? | — | |
| 0x1B | AutoAnswer | Y | ? | — | |
| 0x1C | VolumeControl | Y | ? | — | |
| 0x1D | AutoAwareMode | Y | ? | — | |
| 0x1E | SourceBargeIn | Y | ? | — | |
| 0x20 | AutoVolumeLevel | Y | ? | — | |
| 0x21 | Grouping | Y | ? | — | |
| 0x22 | DisableCaptouch | Y | ? | — | |

## EQ SET Command (verified working over RFCOMM 2026-04-05)

Set one band at a time. Three calls for full EQ:

```
Bass:   01 07 02 02 {value} 00     value: signed byte -10 to +10
Mid:    01 07 02 02 {value} 01
Treble: 01 07 02 02 {value} 02
```

Response is the full 12-byte EQ state: `01 07 03 0C F6 0A {bass} 00 F6 0A {mid} 01 F6 0A {treble} 02`

## BLE GATT (for reference, NOT needed for our features)

- Service: FEBE (Bose proprietary)
- Write characteristic: D417C028 (unsecure) or C65B8F2F (secure/bonded)
- Response characteristic: C65B8F2F (notifications)
- Segmentation: prepend 0x00 byte for single-segment packets
- FE2C12XX characteristics are Google Fast Pair, NOT Bose BMAP

## AudioModes Block (0x1F) — ANC Mode Config (decoded from APK)

The Custom 1/2 ANC depth is configured via `AudioModesModeConfig` (1F,06).

### ModeConfig GET

`1F 06 01 01 {modeIndex}` — returns 48-byte response with full mode configuration.

Response payload (48 bytes):

| Offset | Field | Notes |
|--------|-------|-------|
| 0 | modeIndex | 0=quiet, 1=aware, 2=custom1, 3=custom2 |
| 1 | prompt.byte1 | Voice prompt identifier byte 1 |
| 2 | prompt.byte2 | Voice prompt identifier byte 2 |
| 3-5 | unknown | 3 bytes, often `00 00 01` |
| 6-37 | modeName | 32-byte null-terminated UTF-8 name (e.g. "Immersion") |
| 38-43 | padding/flags | 6 zero bytes |
| 44 | spatialAudioType | 0=disabled, 1=fixedToRoom, 2=fixedToHead |
| 45-46 | unknown | 00 00 |
| 47 | ancToggle | 0=disabled, 1=enabled |

Observed values:
- Mode 1 (Aware): name="Aware", prompt=00,02, spatial=2, ancToggle=1
- Mode 2 (Custom1): name="Immersion", prompt=00,22, spatial=2, ancToggle=1
- Mode 3 (Custom2): name="Cinema", prompt=00,24, spatial=1, ancToggle=1

### ModeConfig SET_GET (not yet verified — needs stable RFCOMM)

`1F 06 02 {len} {payload}` using SET_GET operator.

Payload from APK decompilation (`FBlockAudioModesKt.createAudioModesConfigSetGetPayload`):

```
Byte 0:     modeIndex (0-3)
Byte 1-2:   prompt (byte1, byte2)
Byte 3-34:  modeName (32 bytes, null-padded UTF-8)
Byte 35:    cncLevel (noise cancellation level — THE KEY FIELD)
Byte 36:    autoCNCEnabled (0 or 1)
Byte 37+:   optional: spatialAudioType, windBlockEnabled, ancToggleEnabled
```

**cncLevel at byte 35 is how Custom 1/2 ANC depth is controlled.**

Status: payload format decoded but SET not yet verified on headphones (connection
instability during testing at 40% battery). The response payload has 3 extra bytes
at offsets 3-5 that the SET payload doesn't include — the SET format is shorter.

### AudioModes SettingsConfig (1F,0A)

GET response: `1F 0A 03 05 00 00 00 00 01` — 5-byte payload. Purpose unclear.
May be related to auto-off timer on QC Ultra 2 (since StandbyTimer 0x04 is not supported).

## QC Ultra 2 Specific Quirks

| Official Name | Func ID | QC Ultra 2 Status |
|--------------|---------|-------------------|
| StandbyTimer | 0x04 | **Not supported** (error on GET and SET) |
| MotionInactivityAutoOff | 0x14 | **Not supported** (error) |
| OnHeadDetection | 0x10 | **Not supported** (error) |
| FlipToOff | 0x16 | **Not supported** (error) |
| Sidetone | 0x0B | Returns data: `01 02 0F` — **read-only**, all SET operators fail |
| AutoPlayPause | 0x18 | Returns data: `01` — may be settable |

Auto-off on QC Ultra 2 may only be configurable via the Bose Music app's AudioModes
settings flow, not via a standalone timer command.

## What we had wrong

| What | Wrong | Correct |
|------|-------|---------|
| EQ SET operator | 0x06 (SET) | 0x02 (SET_GET) |
| EQ SET payload | 12-byte full state | 2-byte per band: {level, bandId} |
| Auto-off function | 0x0B | 0x04 (StandbyTimer) |
| "Needs BLE GATT" | Assumed | False — just wrong operator |
| FE2C chars | Bose proprietary | Google Fast Pair |
