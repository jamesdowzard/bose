# BMAP command reference — tables

<!-- Reference detail moved out of the sibling CLAUDE.md on 2026-08-27 to keep it under the
     8 KB fleet cap. The CLAUDE.md keeps the rules and traps; this holds the tables. -->

`protocol/spec/bmap.toml` is canonical; everything here mirrors it. Edit the TOML and
regenerate — never hand-edit `generated/`, and never edit these tables alone.

## BMAP Function IDs (Block 0x04 — DeviceManagement)

| Function | ID | Notes |
|----------|-----|-------|
| Connect | **0x01** | Payload: `00` + 6-byte MAC = 7 bytes. Pages offline devices + routes audio. |
| Disconnect | **0x02** | Payload: 6-byte MAC |
| RemoveDevice | 0x03 | NEVER use — removes from paired list |
| ListDevices | **0x04** | GET `04,04,01,00` → the headphones' OWN paired table: `04,04,03,<len>,<capacity=0x10>,{6-byte MAC}*`. **Ground truth for "is this device even paired?"** — `devices.toml` is a host-side map and drifts from it. `parsePairedDevices` (hand-written, variable-length) + `preflightPaired` in the connect path. |
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
| ANC mode | 1F,03 | START | `1F,03,05,02,{mode},01` | slots: 0=quiet 1=aware 2=immersion 3=cinema (fixed) 4=custom1 5=custom2 (adjustable); reads 255 = OFF (genuinely disabled — confirmed audibly #83). 255 is REACHABLE: writing a raw CNC depth (1F,0A) over a named mode knocks 1F,03 to 255. ANC here is mode-based; depth is the same axis. **255 also turns up in the wild with no 1F,0A write from us** (the `anc-depth` command that did it was removed) — seen 2026-06-20 and again 2026-08-31; cause still unknown. **Do not read a 255 as a bad read:** `bose anc` has no cache path (`transport.oneShot`, hard-fails "not reachable" rather than printing a mode), so a printed `off` was genuinely read off the device. Recover with any `bose anc <mode>`. |
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
| ~~ANC depth~~ | ~~1F,0A~~ | — | — | **DO NOT USE.** `1F,0A` (AudioModesSettingsConfig) is GLOBAL live-tuning; writing it over an active mode DETACHES the mode → 1F,03 reads 255 = ANC OFF (#83, confirmed audibly). The old `anc-depth` command used this — removed. Use `anc-level` (1F,06) instead. |

**Not supported / write-locked on QC Ultra 2 (all re-verified live 2026-06-20, fw 8.2.20 — don't re-investigate):**
- **StandbyTimer SET (01,04)**, **MotionAutoOff (01,14)**, **OnHeadDetection SET (01,10)**, **CncPresets (01,0F)**: reply **FuncNotSupp** (error op 0x04, code 4) to a GET. Dead.
- **Global Immersive/Spatial Audio (05,0F SpatialAudioMode, 05,10 SpatialAudioStatus)**: FuncNotSupp. The dedicated AudioManagement spatial functions don't exist here — spatial is per-mode only (see AudioModes 1F,06 below).
- **VoicePrompts (01,03)**: GET works (`01 03 03 07 41 00 00 81 02 00 00` → enabled=0, lang=UsEnglish), but `isTogglable` (config bit7) = 0 and the enable SET_GET is **silently ignored** (response byte unchanged, cold + warm). Read-only on this firmware.
- **Volume-strip shortcut (01,09)** — *not* "the action button"; see the naming note under AudioModes below: GET works (`01 09 03 07 80 09 13 …` → button id 0x80, eventType 0x09, **already SpatialAudioMode (0x13)**; only Vpa/Disabled/SpotifyGoMode/SpatialAudioMode assignable), but the SET_GET (op 0x02) **and** plain SET (op 0x06) both return **No response** and leave state unchanged, cold + warm. Write-locked — Bose's app likely uses a privileged channel we don't replicate.
- **Sidetone**: no settable opcode (the 01,0B the generic BMAP enum labels "Sidetone" is the read-only **auto-off timer** here — returns `01 0b 03 03 01 02 0f`).
- Auto-off timer (01,0B) is read-only over RFCOMM — distinct from StandbyTimer (01,04).

### Which physical control is which (naming note, settled 2026-08-31)

Three control inputs, **all on the right earcup**. The repo used to call `01,09` "the
action button" / "the over-ear button", which merged two controls that do different
things — and that merge is what made a mode change look like a tool bug.

| Control | Where | Gesture | Wire |
|---|---|---|---|
| **Multi-function button** | back of the right earcup | **press and hold → cycles the favourited listening modes** (spoken aloud). Press/double/triple = play-pause / skip / back. | Mode changes land as `1F,03`; the presses themselves are **AVRCP media keys**, never a BMAP event. Favourites = `1F,08`. |
| **Volume strip** (capacitive) | back edge of the right earcup | swipe = volume; **press and hold = the configurable shortcut** (Immersive Audio / Spotify Tap / voice assistant) | **`01,09`** — this is the one `01,09` reassigns. Write-locked on this fw; reads `0x13` SpatialAudioMode. |
| Bluetooth/power | bottom of the right earcup | power, pairing, device cycling | — |

The assignable mask on `01,09` ({Vpa, Disabled, SpotifyGoMode, SpatialAudioMode}) maps
exactly onto Bose's documented *shortcut* options, which is the independent confirmation
that `01,09` is the strip and not the button.

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
- `bose spatial [off|still|motion]` does the same 1F,06 RMW on the **active** mode's spatial byte (Immersive Audio), refusing if the mode's `spatialMutable` (payload[41] bit2) is false. Verified live 2026-06-20: custom slots 4/5 have spatialMutable=1; Immersion carries spatial=2 (Motion), Cinema spatial=1 (Still). Build = `buildModeConfigSet(_, newSpatial:)`; session RMW = `setActiveModeSpatial` (Composites). `ModeConfig.spatialMutable` is the bit2 read. Surfaced in the macOS app AND the Android app (`MainActivity.kt` SettingsSection → `BoseViewModel.setSpatial` → `Composites.setActiveModeSpatial`) as an Off/Still/Motion segmented control that greys out on fixed modes, like the Level slider. The Hammerspoon Opt+I hotkey that cycled off→still→motion is **disabled** as of 2026-06-20 (commented out in `bose.lua` `start()`).
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

| Capability | Block,Func | `bose` | Hammerspoon | Android |
|------------|-----------|-----------|-------------|---------|
| ANC mode | 1F,03 | ✅ `anc` | — (Opt+N disabled 2026-06-20) | ✅ mode selector |
| Noise level (CNC) | **1F,06** | ✅ `anc-level` (custom modes) | — | ✅ slider (1F,06 RMW, custom modes only) |
| Immersive Audio (spatial) | **1F,06** | ✅ `spatial` (custom modes) | — (Opt+I disabled 2026-06-20) | ✅ Off/Still/Motion selector (custom modes only) |
| Device name | 01,02 | ✅ `name` | — | ✅ rename |
| EQ band | 01,07 | ✅ `eq` | — | ✅ 3-band |
| Multipoint | 01,0A | ✅ `multipoint` | — | ✅ toggle |
| Auto-pause | **01,18** | ✅ `auto-pause` | — | ✅ toggle |
| Auto-answer | **01,1B** | ✅ `auto-answer` | — | ✅ toggle |
| Favorites | **1F,08** | ✅ `favorites` | — | — (parser only, no UI) |
| Connect device | 04,01 | ✅ `connect`/`swap` | Opt+B opens app (Opt+⇧B/Opt+J disabled 2026-06-20) | ✅ widget/tile/picker |
| Paired-device list | **04,04** | 👁 preflight in `connect`/`swap`/`pair` | — | 👁 preflight in both connect paths (service `switchDevice` + in-app `BoseViewModel`) |
| ~~CNC depth~~ | ~~1F,0A~~ | 👁 read-only GET inside `getAllState` — **NEVER write (#83)** | — | — |
| Multipoint pair / priority | host-side (priority.json) | ✅ `pair` / `priority` | — | — (compiled `Eviction.kt` only) |
| Disconnect device | 04,02 | ✅ `disconnect` | — | — |
| Device info (ACL) | 04,05 | 👁 `devices` (○ state) | — | 👁 widget colour |
| Connected devices | 05,01 | 👁 `devices`/`status`/`info` | — | 👁 widget/tile active |
| Media control | 05,03 | ✅ `play`/`pause`/`next`/`prev` | — | ✅ notification controls |
| Audio codec | 05,04 | 👁 `info` | — | 👁 state |
| Volume | 05,05 | ✅ `volume` | — | ✅ slider |
| Firmware | 00,05 | 👁 `status`/`info` | — | 👁 state |
| Battery | 02,02 | 👁 `battery`/`status`/`info` | 👁 (battery announce on becoming Mac output) | 👁 widget overlay |

### Off-spec diagnostic GETs (issued directly in `getAllState`, not in `bmap.toml`)

| Capability | Block,Func | `bose` | Android |
|------------|-----------|-----------|---------|
| Serial number | 00,07 | 👁 `info` | 👁 state |
| Product name | 00,0F | 👁 `info` | 👁 state |
| Platform | 12,0D | 👁 `info` | 👁 state |
| Codename | 12,0C | 👁 `info` | 👁 state |
| Auto-off timer | 01,0B | 👁 `info` (read-only) | 👁 state |

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
applies {ANC mode, noise level, EQ, multipoint, volume} in one session (CLI;
drivable from macOS Focus via a Shortcut, see README).

**Notable gaps (intentional):** Hammerspoon binds **only Opt+B (open app)** as of
2026-06-20 — the other four (Opt+⇧B toggle, Opt+N ANC cycle, Opt+I Immersive Audio
cycle, Opt+J connect → Mac) are commented out in `start()` (James uses the Bose app for
those; the binds remain in-file for a one-line re-enable). Still all event-driven, no
timers.

**The Raycast surface is gone (2026-07-20).** `raycast/` and its ten deployed script
commands were removed — the Mac surface is now **Bose.app + Hammerspoon Opt+B + the
`bose` CLI**, the same consolidation the disabled hotkeys already reflected. Do NOT
re-add it: it was a fourth thin wrapper over the same CLI, its argument handling was a
standing bug source (a blank optional arg reached the CLI as `""` and made
`bose-auto-pause`/`bose-auto-answer` silently WRITE OFF on what the placeholder called a
read), and a stale `bose-toggle.sh` had survived deployed-but-untracked since April,
doing raw `blueutil --connect/--disconnect` around the whole eviction/priority layer.
Anything Raycast did is a `bose` verb or a click in the app.

The macOS surface has **no resident process** — every reading is on-demand, never polled.

