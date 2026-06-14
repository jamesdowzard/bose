# Reverse-Engineering Artifacts & BMAP Findings

The BMAP protocol in this repo was reverse-engineered from the **Bose Music** Android
app (`com.bose.bosemusic`) plus live captures off the headphones. This doc is the
durable record of the decompile: where the artifacts live, and the findings — so a
future session **greps here first** and only re-pulls the source from S3 if it needs to.

## Archived artifacts (S3)

Bucket `s3://james-dowzard-brain/archive/bose-reverse-engineering/` — AWS profile
`personal`, encrypted (`--sse AES256`):

| Object | Size | What |
|--------|------|------|
| `bosemusic-13.0.7-base.apk` | 68,606,716 B | Bose Music app **v13.0.7** — the source of truth (pulled from the S21) |
| `bosemusic-13.0.7-jadx-src.tgz` | 22,786,124 B | Full jadx decompile (`sources/`, ~22,010 files) — so we never have to re-decompile |

Re-fetch the decompiled source (no re-decompile needed):
```bash
aws s3 cp s3://james-dowzard-brain/archive/bose-reverse-engineering/bosemusic-13.0.7-jadx-src.tgz . --profile personal
tar xzf bosemusic-13.0.7-jadx-src.tgz   # -> sources/com/bose/bmap/...
```

Re-decompile from the APK (if you want a fresh/different jadx run):
```bash
aws s3 cp s3://james-dowzard-brain/archive/bose-reverse-engineering/bosemusic-13.0.7-base.apk . --profile personal
jadx -d jadx-out --no-debug-info bosemusic-13.0.7-base.apk
```

Pull a newer APK from a phone that has the app installed:
```bash
adb shell pm path com.bose.bosemusic         # find base.apk
adb pull "<…/base.apk>" bosemusic-<ver>-base.apk
```

## BMAP frame format

From `BmapPacket.toByteArray()` (`sources/com/bose/bmap/messages/packets/BmapPacket.java:173-183`):

```
[functionBlock] [function] [devPortOp] [length] [payload…]
```
- 4-byte header.
- `devPortOp` (byte 2) packs `operator | (deviceId << 6) | (port << 4)`. App-originated commands use deviceId=port=0, so **byte 2 == the bare operator**.

Operators (`BmapOperator.java`): `Set=0x00, Get=0x01, SetGet=0x02, Status=0x03, Error=0x04, Start=0x05, Result=0x06, Processing=0x07`.
(Note: in this build `SET=0x00` and `Result=0x06` — *not* the older "SET=0x06/ACK=0x07" naming in some notes.)

Function block `DeviceManagement = 0x04` (`BmapFunctionBlock.java:16`).

## DeviceManagement (block 0x04) — function IDs

From `sources/com/bose/bmap/messages/enums/spec/BmapFunction.java:514-533`:

| ID | Function | App-implemented? |
|----|----------|------------------|
| 0x00 | FblockInfo | yes |
| 0x01 | **Connect** | yes |
| 0x02 | Disconnect | yes |
| 0x03 | RemoveDevice | yes — **NEVER use (unpairs)** |
| 0x04 | **ListDevices** | yes |
| 0x05 | Info | yes |
| 0x06 | ExtendedInfo | yes |
| 0x07 | ClearDeviceList | yes |
| 0x08 | PairingMode | yes |
| 0x09 | AppAddress | yes |
| 0x0A–0x0F | PrepareP2p / P2pMode / Routing / P2pFeatures / Features / BoseProduct | mixed |
| **0x10** | **ConnectionPriority** | **enum-only — see below** |
| **0x11** | **UserCarouselSelect** | **enum-only — see below** |
| 0x12 | AvailableToConnect | yes |
| 0x13 | LeAudioCheck | yes |

## ConnectionPriority / UserCarouselSelect — DEAD END (verified 2026-06-14)

There is **no settable multipoint device-priority hierarchy** on the QC Ultra 2.

- `0x10 ConnectionPriority` and `0x11 UserCarouselSelect` exist **only as enum constants**
  in v13.0.7 — no packet builder, no response parser, no caller. The app never sends them
  (it connects via plain `Connect` 0x01 and lets the firmware evict).
- Probed live on `verBosita` (QC Ultra 2, fw 8.2.20):
  - GET `04 10 01 00` → `04 10 04 01 04` → op `0x04 Error`, code `0x04` = **FuncNotSupp**
  - GET `04 11 01 00` → `04 11 04 01 04` → **FuncNotSupp**
- **Conclusion:** the firmware doesn't implement either. Multipoint eviction is the
  firmware's internal **LRU** and cannot be reconfigured over BMAP. A *deterministic*
  device hierarchy must be implemented in **our own software** (the connect path /
  device map), not pushed to the headphones.

## ListDevices (0x04,0x04) — works (read-only)

- Request: `04 04 01 00`
- Response: `04 04 03 <len> <flagsByte> <N × 6-byte MAC>`. The parser
  (`DeviceManagementListDevicesResponse.java:62-72`) **drops `payload[0]`** and chunks the
  rest into 6-byte big-endian MACs.
- The leading byte is a **flags/state byte, not a count** — observed `0x11` then `0x18`
  across two reads with the *same* 6 devices. MAC order is firmware-defined (recency/pairing),
  **not** an app-assigned priority; `PairedDevice` has no rank field.
- Note: returns only BT-paired devices — the Chromecast `tv` (14:C1:4E:B7:CB:68) is absent.

## Connect / RemoveDevice — proven frames

- **Connect** (page + make active): `04 01 05 07 00 <6-byte MAC>` (op Start) —
  `DeviceManagementConnectStartPacket.create(mac)`. What the app actually uses; the
  firmware handles multipoint eviction.
- **RemoveDevice**: `04 03 05 06 <6-byte MAC>` (op Start) — **NEVER use** (unpairs the device).

## Method note

jadx output is huge (~19k classes); grep `sources/com/bose/bmap/` for `messages/packets`
(builders), `messages/responses` (parsers), `messages/enums/spec` (IDs). Builders
(`*StartPacket`/`*GetPacket`) prove request bytes; `BmapDeviceManagementResponseParser`
proves which responses the app parses (unhandled → `BmapNotImplementedResponse`).
