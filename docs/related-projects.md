# Related Projects — BMAP/Firmware Cross-Reference & Gap Analysis

Survey of every public project doing what this repo does (Bose BMAP control / firmware RE),
cross-validated against our own `protocol/spec/bmap.toml` and `reverse-engineering.md`.
Compiled 2026-06-20 from a 6-way parallel read of the projects below. Goal: fold in
anything useful, and flag where our map may be wrong or incomplete.

**Headline:** four independent implementations now agree on the BMAP framing, operators,
and the QC Ultra 2 (`0x4082`/wolverine) command map — strong cross-validation. The biggest
*new* finds for us: (1) the **auth boundary** (why `SETGET` works where `SET` doesn't),
(2) a real **gap set** of commands we don't yet map, and (3) **two concrete leads** at the
lost power-on battery announcement.

---

## The landscape

| Project | Lang | Device target | Stars | Value to us |
|---|---|---|---|---|
| **[aaronsb/bosectl](https://github.com/aaronsb/bosectl)** | Py/Rust/C++ | **QC Ultra 2 `0x4082`** (fw 8.2.20) | 18 | **Closest peer.** Best protocol notes (`NOTES.md`), the auth-boundary model, live-CNC quirks. |
| **[cmqui/boss](https://github.com/cmqui/boss)** | Rust + Swift | **QC Ultra 2 `0x4082`** | 0 | **Goldmine.** Stream framer, bootstrap, verified-write + capability-from-bitset patterns. BLE-first but models RFCOMM. |
| **[docentYT/Bose-QuietComfort-Ultra-Protocol](https://github.com/docentYT/Bose-QuietComfort-Ultra-Protocol)** | PDF/Typst | **QC Ultra HP** (fw 1.6.7) | 0 | Only doc that's *actually the Ultra HP*; exact bytes incl. the **battery-on-power voice-prompt byte**. |
| **[myNameArnav/libreqc](https://github.com/myNameArnav/libreqc)** | Kotlin | QC HP "prince" `0x4075` | 0 | Hardware-verified writes, error-code table, flag-byte decoders. |
| **[ll0s0ll/NoQCNoLife](https://github.com/ll0s0ll/NoQCNoLife)** | **Swift** | QC35 | 6 | **Only native-Swift `IOBluetooth` RFCOMM reference** — lifecycle to copy. |
| **[mishamyrt/bose-nc](https://github.com/mishamyrt/bose-nc)** | Rust+ObjC | QC Ultra **gen-1 `0x4066`** | 0 | macOS IOBluetooth shim; `qc_ultra.rs` wire spec (gen-1). |
| **[Denton-L/based-connect](https://github.com/Denton-L/based-connect)** | C | QC35 / SoundLink | 278 | The canonical *old*-BMAP byte reference; device-management block. |
| **[sim642/openbose](https://github.com/sim642/openbose)** | Python | QC35 II | 26 | Cleanest structural model of the (early) BMAP frame; BLE advert decoder. |
| **[avicoder/Bose-headphones-firmware](https://github.com/avicoder/Bose-headphones-firmware)** | — | QC35 II | 9 | Old CSR firmware RE (see `firmware-delivery.md`). |
| **[tchebb/bose-dfu](https://github.com/tchebb/bose-dfu)** · **[bosefirmware/ced](https://github.com/bosefirmware/ced)** | Rust/— | many (not Ultra) | 461 | DFU tool + firmware archive (see `firmware-delivery.md`). |
| prototux/python-bmap | — | — | 0 | **Empty stub — ignore.** |

The "Bose Connect" lineage (openbose/based-connect) reverse-engineered **early BMAP** — same
`[block][function][op-nibble][len]` frame, older function IDs. Treat its bytes as the ancestor:
structure carries over, specific IDs need re-verifying on wolverine.

---

## Cross-validated protocol facts (now confirmed by 4+ implementations)

**Frame:** `[byte0 functionBlock][byte1 function][byte2 packed][byte3 payloadLen][payload…]`
- `byte2 = (deviceId<<6) | (port<<4) | (operator & 0x0F)` — **mask `0x0F` to read the operator**; high nibble is deviceId/port (both 0 in all real traffic).
- **No checksum, no STX, no escaping.** Length is the single `byte3`. Multiple frames coalesce on one read → slice by `4 + payload[3]`, keep the partial remainder (the `BmapFrameStreamDecoder` loop — ideal for RFCOMM).

**Operators:** `0 SET · 1 GET · 2 SETGET · 3 STATUS · 4 ERROR · 5 START · 6 RESULT · 7 PROCESSING`.
- `GET`→`STATUS`; `SETGET` writes **and returns** a `STATUS` echo; `START`→`PROCESSING`…`STATUS`*…`RESULT`.
- No sequence IDs — responses correlate purely on `(block, function)`. Serialise one in-flight request per (block,function).

**Error codes** (payload byte 0 of an `ERROR` response) — *we should add this table; we don't have it*:
`1 Length · 2 Chksum · 3 FblockNotSupp · 4 FuncNotSupp · 5 OpNotSupp(=auth) · 6 InvalidData · 7 DataUnavail · 8 Runtime · 9 Timeout · 0A InvalidState · 0C Busy · 14 InsecureTransport · FF FblockSpecific`.

### ⭐ The auth boundary (the single most useful strategic insight)
On wolverine, BMAP commands split by operator:
- **`GET` (1) is open on every block** — all reads are unauthenticated.
- **`SET` (0) and `START` (5) are cloud-ECDH-gated on most blocks** → return **error `5` (OpNotSupp)**. The auth is a P-384 challenge/response via `nadc.data.api.bose.io` (block `0x12`), which none of these projects implement — they route *around* it.
- **`SETGET` (2) is left UNAUTHENTICATED on Settings (block `0x01`) and AudioModes (block `0x1F`)** — this is the whole leverage. Writes that look like they should need auth go through `SETGET` on those two blocks.
- Some functions also reject over plain SPP/unsecure links with error **`0x14` InsecureTransport**.

This explains our own operator choices (EQ/multipoint/volume need `SET_GET`; anc_mode/connect use `START`). Worth documenting *why* in our spec, not just *that*.

---

## Device generations (don't cross-wire the bytes)

| PID | Codename | Product | Platform | Notes |
|---|---|---|---|---|
| **`0x4082`** | **wolverine** | **QC Ultra 2 HP** | **OTG-QCC-384** | **Our device.** bosectl + boss target this. |
| `0x4066` | lonestarr | QC Ultra HP **gen-1** | — | `bose-nc/qc_ultra.rs` targets THIS — gen-1 bytes, verify before reuse. |
| `0x4062` | edith | QC Ultra **Earbuds** | — | Shares the `qc_ultra2` config in bosectl. |
| `0x4024` | goodyear | NC 700 | — | FB `01`/FN `05` NC, sends each set ×2. |
| `0x400C` | (wolfcastle) | QC35/45-class | — | 4-level NC `[01,06,02,01,wire]`. |
| `0x4075` | prince | QC Headphones (non-Ultra) | — | libreqc's target. |

Variant byte (wolverine) = colour: `1` Black · `2` WhiteSmoke · `3` DriftwoodSand · `4` MidnightViolet · `5` DesertGold.

---

## Gap analysis — commands others map that our `bmap.toml` does NOT

Our spec has: `anc_mode 1F,03 · cnc_level 1F,0A · device_name 01,02 · eq_band 01,07 · multipoint 01,0A · connect/disconnect 04,01/02 · device_info 04,05 · media_control 05,03 · audio_codec 05,04 · volume 05,05 · firmware 00,05 · battery 02,02`. Missing (all worth adding, bytes from the sources):

| Command | Block,Func | Op | Payload | Source |
|---|---|---|---|---|
| **Voice prompts** ⭐ | `01,03` | SETGET | `(enabled<<5)\|langId` (wolverine) **OR** richer on older fw incl. **battery-on-power byte** | bosectl / docentYT |
| **Button remap** ⭐ | `01,09` | SETGET | `[btnId, event, actionMode]` — **actionMode 3 = announce BatteryLevel** | bosectl |
| **Sidetone / mic-monitor** | `01,0B` | SETGET | `[persist=1, level 0–3]` (off/low/med/high) | bosectl / docentYT |
| **Auto-off / standby** | `01,04` | SETGET | minutes `{0,5,20,40,60,180; a0,05=24h LE}` | docentYT | ⚠️ we found `01,04` **SET unsupported** on wolverine (CLAUDE.md); docentYT's is older fw. Verify before trusting. |
| **Auto-pause off-head** | `01,18` | SETGET | `[0/1]` | bosectl / docentYT |
| **Auto-answer on-head** | `01,1B` | SETGET | `[0/1]` | bosectl / docentYT |
| ~~Settings register (live CNC) `1F,0A`~~ | — | — | **CONFLICT — see callout below. Do NOT adopt as a write path.** | bosectl / boss |
| **Favorites** | `1F,08` | SETGET | `[count, bitmask…]` (reversed byte order) | bosectl / boss |
| **Remember-last-mode** | `1F,05` | SETGET | `[0/1]` | docentYT |
| **Supported prompt names** | `1F,0B` | GET | bitmask → mode names | boss |
| **Power off** | `07,04` | START | `0`=off, `1`=on | bosectl |
| **Pairing mode** | `04,08` | START | `01`=enter, `00`=exit | bosectl / based-connect |
| **Multipoint routing (switch active)** | `04,12` | START | `[0x82, mac0..5]` | bosectl |
| **Source query (BT/aux)** | `05,01` | GET | type 0/1/2 + MAC | docentYT / boss |
| **Now-playing metadata** | `05,06` | START | title/artist ASCII frames | docentYT |
| **Spatial standalone** | `05,0F` | SETGET | `[0 off/1 still/2 motion]` | docentYT |
| **Spatial calibration** | `05,11` | START | head-forward calibrate | docentYT |

Plus **bootstrap reads** we should ensure we issue: BMAP version `00,01`, product-id+variant `00,03` (`[0..1]` BE = `0x4082`, `[2]` = colour), all-fblocks bitset `00,02`.

### ⚠️ Conflicts with our verified findings — do NOT blindly adopt

1. **`1F,0A` (AudioModesSettingsConfig) as a "live CNC register."** bosectl and boss both treat `1F,0A` SETGET `[cnc, autoCNC, spatial, wind, anc]` as the canonical instant-apply ANC control "the Bose app uses." **But our #83 finding is that writing `1F,0A` over an active mode DETACHES the mode → `1F,03` reads 255 = ANC OFF** — we removed our `anc-depth` command for exactly this and use the `1F,06` mode-config RMW instead. **Possible reconciliation worth a careful test (not a change):** their 5-byte payload sets byte `[4] = anc_toggle`; our #83 footgun may have been writing `1F,0A` *without* holding `anc=1`. It's plausible the app-style write `[cnc,autoCNC,spatial,wind,1]` is safe where a bare depth write was not. **If** you ever revisit this, test on a custom slot with `anc=1` and watch `1F,03` — but our shipped path (`1F,06` RMW) is correct and proven; `1F,0A` stays a footgun until disproven.
2. **`deca-fade` discovery UUID** — see macOS note #8; it's Apple iAP2, our CLAUDE.md already says don't use it.
3. **`01,04` auto-off SET** — we found it unsupported on wolverine; peer docs are older firmware.

Where peers and our captures agree (framing, operators, `SETGET`-is-the-write-path, EQ `01,07`, multipoint `01,0A`, battery `02,02`, mode switch `1F,03` START, the inverted CNC scale, `1F,06` mode-config offsets), that's strong cross-validation. Where they disagree with a `verified_bytes`/#-issue finding of ours, **ours wins** until a fresh on-device capture says otherwise.

---

## ⭐ Leads on the lost power-on battery announcement

Two BMAP-side angles at the v8.2.20 feature removal (background: `bluetooth-audio` dossier):

1. **Voice-prompts byte (`01,03`).** docentYT (QC Ultra HP, fw **1.6.7**) decodes the voice-prompts
   payload with a **trailing byte = "battery level announced at power-on"**, set via
   `01 03 02 02 <flags|5bit-lang> <00/01 battery-on-power>`. **But** bosectl (wolverine, fw **8.2.20**)
   sees `01,03` as a *single* byte `(enabled<<5)|langId` — no battery-on-power field. **Hypothesis:**
   the battery-on-power toggle existed in earlier firmware and was **removed/relocated in 8.2.20**
   (consistent with the documented feature removal). **Action:** probe `GET 01,03` on the actual
   device and inspect the payload length/bytes — if the battery-on-power byte still exists, a `SETGET`
   may restore it; if the payload is the single-byte form, it's confirmed gone from firmware.

2. **Button action mode (`01,09`).** bosectl's `ActionButtonMode` enum includes **`3 = BatteryLevel`**
   (the button *speaks the battery* on press). If `SETGET 01,09 [btnId, event, 0x03]` is accepted, the
   physical button can be made to announce battery on demand — a partial replacement for the lost
   auto-announce. **Action:** try remapping a shortcut to mode 3 and test.

Either way, the host-side fallback (Mac reads `battery 02,02` and speaks it on connect) remains the
guaranteed path — see the `bluetooth-audio` dossier's auto-route notes.

---

## macOS / Swift adoption notes (for this repo's `macos/` + `cli/`)

From **NoQCNoLife** (native Swift `IOBluetooth`) and **boss** (Rust+Swift):
1. **Query the SPP channel from the `0x1101` SDP record — never hardcode it.** `getRFCOMMChannelID(&id)` then `openRFCOMMChannelSync`. (Observed channels: wolverine = **2**, QC35 = 8 — so hardcoding breaks across devices.)
2. **Match the device via the PnP/DI SDP record (UUID `0x1200`, attrs `0x0201` vendor / `0x0202` product), Bose vendor `0x009E`.** More robust than name-matching. `system_profiler -json SPBluetoothDataType` is a no-IOBluetooth discovery fallback.
3. **Handshake gotcha (we already note a 300ms drain):** the device sends **nothing until you GET BMAP version first** — send `00,01` immediately on channel-open-complete, treat the version reply as "link live." NoQCNoLife's comment is explicit about this.
4. **Persistent channel + delegate callbacks** (NoQCNoLife), not open/close-per-command (bose-nc's CLI compromise adds ~2s latency and misses unsolicited STATUS).
5. **Poll as authoritative; treat notifications as a fast-path bonus.** boss found hardware-button mode changes were *not* reliably pushed — block `0x09` Notification subscriptions are an open gap in *every* project, ours included.
6. **Verified writes:** SETGET then re-GET to confirm; retry on recoverable errors (`0x09 Timeout`, `0x0C Busy`, `0x14 InsecureTransport`) with ~750ms–1s backoff; return "inconclusive" rather than throwing.
7. **Capability-from-bitset:** resolve features from the `00,02` all-fblocks bitset, don't compile-in a fixed list.
8. **Discovery** — for our RFCOMM path the **SPP UUID `00001101-…` is the channel** (resolve the channel ID from its SDP record). ⚠️ **Do NOT adopt bosectl's discovery UUID `00000000-deca-fade-deca-deafdecacaff`** — we already verified that is **Apple iAP2, not BMAP** (CLAUDE.md "deca-fade UUID is Apple iAP2 … don't use it"). bosectl matching on it is a divergence from our ground truth, not a lead. (boss uses BLE service `0000FEBE-…`, irrelevant to our RFCOMM transport.)
9. **The action button is NOT a BMAP event** — it's emitted as AVRCP **media keys**. To act on a press, use a macOS `CGEventTap` on the media keys (separate Accessibility-gated subsystem); BMAP only lets you *reassign* the button (`01,09`). Don't hunt for a press-notification over RFCOMM.

(Battery on macOS: boss-qt's idea of re-publishing battery to the OS via the BlueZ `BatteryProvider1` D-Bus API → the macOS analog is feeding a status-bar item / IOKit. "Surface battery to the host OS, not just our own UI" is the lesson.)

---

## Device quirks worth recording in our spec

- **CNC scale is inverted:** `0` = max ANC, `10` = most ambient/transparent. Easy to ship backwards.
- **CNC is inaudible unless `anc=on AND wind=off`** — Wind Block bypasses the CNC DSP, so CNC 0 vs 10 sound identical with wind on. A "broken slider" trap.
- **`autoCNC=1` is firmware-rejected** (Runtime error `8`) — only manual CNC.
- **Mode-config presets 0–3 are write-locked** (Runtime `8`); only custom slots 5–10 accept `1F,06` SETGET.
- **Current-mode GET returns `0xFF`** when in a non-standard state (e.g. Quiet + immersive) → substitute last-known index.
- **Mode-config CNC offset:** in the 47-byte `1F,06` GET, **CNC = payload byte 42**, autoCNC = 43, mutability bitfield = 41, name = 6..37. (libreqc explicitly warns against reading CNC from byte 41.)

---

## Firmware RE — state of the art (confirms `firmware-delivery.md`)

The public ecosystem solved firmware only on the **old CSR BlueCore** generation (QC35 II era) — and even there only the `.dfu` half, never the companion `_signed.xuv` images. The moment Bose moved to **Qualcomm QCC + cloud-gated, signed, monolithic encrypted blobs** (NC700 → QC Ultra), the firmware path went dark. **Nobody public has decrypted a `_encrypted_prod_*.bin`, forged a signature, or beaten the ECDH cloud gate.** Specifics worth knowing:

- **`tchebb/bose-dfu`** is the serious flasher: USB **DFU 1.1 tunnelled over HID feature reports** (report IDs 1/2/3; enter-DFU magic `[0xb0,0x07]`; `tap` commands `pl`/`sn`/`vr` for model/serial/version). It verifies the 16-byte DFU suffix + CRC32 + VID/PID before flashing. **NC700 is explicitly blocklisted** (`0x40fc`) — it doesn't speak HID-DFU at all; QCC devices are out of scope.
- **Device read-back is deliberately unexposed** — Bose's upload returns a non-identical, non-re-flashable image. Confirms our "can't dump a clean image off the device."
- **`avicoder/Bose-headphones-firmware`** is **just a mirror** of the QC35 II `.dfu`/`.xuv` (single "upload" commit, README = "use binwalk"). No RE, no patching.
- **`iclemens/bose` (NC700)** got furthest on a cloud-gated device: a Wireshark dissector for the QCC OTAU transport — but their own README says the **encrypted blob is sent to the device as-is**; they mapped the transport, never the crypto.
- **The "cloud bypass"** (bose-dfu #15) is a **DevTools Network Override** that edits the *reported version* down so btu.bose.com re-serves firmware — it defeats only the **version check**, never the signing/auth. The binary is still Bose-supplied and Bose-signed.

Net: our wolverine firmware (QCC384, `USE_CLOUD`, signed) is behind the same intact wall `bosectl` explicitly refuses to touch. The runtime BMAP control surface is the whole game; firmware is sealed. Full detail: `firmware-delivery.md`.

## Cross-reference

- `firmware-delivery.md` — the firmware side (cloud-gated wolverine, CSR-dfu2 format, why no OTA).
- `reverse-engineering.md` — our own BMAP capture record (the byte source of truth for this repo).
- `bluetooth-audio` dossier (`~/code/personal/dossiers/bluetooth-audio/`) — the wider call-quality / firmware-removal context and the battery-announce-on-connect feature idea.

> **Open gap (2026-06-20):** the gap-table bytes above are transcribed from peer projects (mostly
> wolverine, some gen-1/prince/older-fw). Before adding any to `bmap.toml`, **verify each against the
> actual headset** — generation and firmware (8.2.20+) shift specific IDs/payloads. Treat this doc as a
> prioritised lead list, not verified captures.
