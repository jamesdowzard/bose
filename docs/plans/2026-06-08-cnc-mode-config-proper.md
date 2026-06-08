# Proper ANC noise-level control via AudioModesModeConfig (1F,06)

**Date:** 2026-06-08
**Context:** #83 found that our `1F,0A` CNC write disables ANC (mode → 255). The official
Bose Music app uses a different command. Reverse-engineered from the decompiled app
(`com.bose.bosemusic`) and **confirmed live on fw 8.2.20** via a `cnc-debug` probe.

## The model (confirmed)

Block `0x1F` is **AudioModes**, not "ANC". Functions:
- `1F,03` **AudioModesCurrentMode** — select/activate a mode by **slot index** (START op, payload `{index, playVoicePrompt}`). This is our existing "anc mode" command; the 0/1/2/3 we send ARE slot indices.
- `1F,06` **AudioModesModeConfig** — read/define a mode's full config (name + CNC level + autoCNC + spatial + windblock + ancToggle). **This is the slider command.**
- `1F,0A` **AudioModesSettingsConfig** — global live-tuning. Pushing this over an active mode DETACHES the mode → `1F,03` reads 255 = genuinely OFF. **This is what we wrongly used (#83).**
- `1F,07` AudioModesUserIndices — which slots are user-editable (no response in our probe; not needed — mode list comes from 1F,06).

**Mode slots on this unit (verBosita, fw 8.2.20), from the live 1F,06 probe:**
| idx | name | cncLevel | ancToggle |
|----|------|----------|-----------|
| 0 | Quiet | 0 | on |
| 1 | Aware | 10 | on |
| 2 | Immersion | (custom) | on |
| 3 | Cinema | (custom) | on |
| 4 | None | — | — |
| 5 | None | — | — |

**Level semantics (KEY):** `cncLevel` 0 = **max cancellation** (Quiet), 10 = **full transparency** (Aware). The "depth 0..10" we assumed was inverted — it's a Quiet↔Aware continuum, not "cancellation strength 0..10".

## Wire formats (confirmed live + decompiled)

### 1F,06 GET (read a mode config) — works only inside a WARM bulk session
Request: `1F 06 01 01 {index}` (op GET=01, len 01, payload = modeIndex).
**Response** `1F 06 03 30 {48-byte payload}`. Payload offsets (payload = frame[4:]):
- `[0]` modeIndex
- `[1..2]` prompt (b1, b2) — voice-prompt id (Quiet=…01, Aware=…02)
- `[3..5]` flags (icon/spatial-ish; preserve)
- `[6..37]` 32-byte UTF-8 name, null-padded
- `[41]` mutability bitfield
- `[42]` **cncLevel**
- `[43]` autoCNC
- `[44]` spatial
- `[46]` windBlock
- `[47]` **ancToggle** (1 = ANC enabled)

### 1F,06 SET_GET (write a mode config) — DIFFERENT layout from the response
Per `FBlockAudioModesKt.createAudioModesConfigSetGetPayload`: op SET_GET=02, payload:
- `[0]` modeIndex
- `[1..2]` prompt.b1, prompt.b2
- `[3..34]` 32-byte name
- `[35]` cncLevel
- `[36]` autoCNC
- `[37]` spatial
- `[38]` windBlock
- `[39]` ancToggle
(trailing spatial/windBlock/ancToggle are conditionally appended when supported; this unit supports all.)

### 1F,03 activate
`1F 03 05 02 {index} {playVoicePrompt}` (op START=05). We already send this.

## The fix
Replace the `1F,0A` write with a `1F,06` **read-modify-write against a mode slot**:
1. `1F,06` GET {index} → parse {prompt, name, cncLevel, autoCNC, spatial, windBlock}.
2. `1F,06` SET_GET with the SET layout, changing **only cncLevel**, forcing **ancToggle=1**, preserving everything else.
3. `1F,03` activate {index} if not current.

All in one warm session.

## SAFETY (delicate — can corrupt a mode's name/config)
The SET and GET layouts differ; a wrong byte could rename/break a mode. Therefore:
- **Round-trip test FIRST:** read a mode, rebuild the SET payload from the parsed values WITHOUT changing the level, write it back, re-read, and assert the config is byte-identical. Only after a clean round-trip do we expose a real level change.
- Modes are recoverable via the Bose Music app, but avoid the churn.

## Exposure plan
- `bose-ctl anc-level <mode> <0-10>` (rename from the removed `anc-depth`; mode = quiet/aware/immersion/cinema by name or index). 0 = max ANC … 10 = transparency — label it that way (not "depth").
- Restore the app control as a slider tied to the ACTIVE mode (or hidden for Quiet/Aware which are fixed endpoints — TBD).
- Android: same `1F,06` RMW — follow-up.
- Profiles: a profile can set a mode's level via the same RMW (no longer the `1F,0A` footgun).

## Status
Protocol confirmed live. Next: implement GET-parse + round-trip safety test, verify on hardware (ANC stays on at a mid level — audible check), then expose `anc-level` + restore the app slider.
