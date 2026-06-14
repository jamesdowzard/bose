# Bose Rename + "Katrina's Apple TV" Button — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the controller from `bose-ctl`/"Bose Control.app" to just **Bose**, then add a **"Katrina's Apple TV"** device that routes the headphones to the Apple TV headphone-side, surfaced on the Mac app, the S21 in-app UI, and the CLI/Raycast.

**Architecture:** Keep the existing design unchanged — one `protocol/spec/*.toml` → Python codegen → shared Swift + Kotlin wire layers; macOS front-ends shell out to one on-demand CLI; Android embeds its own transport. We only (A) unify the *name*, and (B) add one device through the single-source device map, plus an optional `label` field so the friendly name is shared across clients.

**Tech Stack:** Python codegen (uv/pytest), Swift (`swiftc`, IOBluetooth), SwiftUI (macOS app), Kotlin/Jetpack Compose (Android), Raycast/Hammerspoon shell front-ends.

**Branching:** Two branches.
- **Branch 1 `feature/rename-to-bose`** — Part A. Not gated on anything; ship now.
- **Branch 2 `feature/appletv-device-button`** — Part B. Gated on capturing the Apple TV's Bluetooth MAC (Phase 0). Branch off `main` *after* Branch 1 merges.

---

## Pre-flight facts (verified this session)

- `bose` is **free** as a command (`which bose` → not found).
- Live `bose-ctl` references (token-exact, safe to global-replace): `cli/build.sh`, `cli/main.swift`, `cli/Profiles.swift`, `macos/BoseControl/BoseManager.swift`, `raycast/*.sh` (6), `hammerspoon/bose.lua`, plus docs. The env var `BOSE_CTL` (uppercase) and source dir `BoseControl` do **not** contain the token `bose-ctl`, so they are untouched.
- App bundle: `macos/build.sh` `APP_NAME="Bose Control"` → produces `/Applications/Bose Control.app`.
- `connect_device` BMAP frame: `04 01 05 07 00 {MAC}` (START op). Pages ANY bonded MAC — works for the Apple TV because the headphones were already paired to it. Golden test harness in `protocol/tests/test_golden.py` auto-covers any new `verified_bytes` entry.
- macOS device grid is **hardcoded** (`ContentView.swift:31-38`). Android in-app tiles are **dynamic** (iterate `BoseDeviceMap` via `state.deviceStates`, ignore the `widget` flag). Android home-screen widget is hardcoded — **out of scope** (set `widget = false` for appletv, matching Chromecast `tv`).

---

# PART A — Rename to "Bose"  (Branch 1: `feature/rename-to-bose`)

Execution: **inline, sequential** — coupled shared files + sequential builds. Mechanical; no subagents.

## Task A1: Replace `bose-ctl` → `bose` in all live source

**Files (modify):**
- `cli/build.sh:21` — `BIN="$BUILD_DIR/bose-ctl"` → `BIN="$BUILD_DIR/bose"` (+ comment lines 2,11,12,23)
- `cli/main.swift` — help block (530-548), usage strings (283,293,301,311,480,558), header/comments (1,41,124)
- `cli/Profiles.swift:154` — comment
- `macos/BoseControl/BoseManager.swift:80,81,83` — resolver paths `~/bin/bose-ctl`, `cli/build/bose-ctl` → `bose` (keep env var name `BOSE_CTL`; comments 3,5,46,68,72,90,188,230 cosmetic)
- `raycast/bose-connect.sh`, `bose-disconnect.sh`, `bose-status.sh`, `bose-full-status.sh`, `bose-anc-level.sh`, `bose-profile.sh` — `$HOME/bin/bose-ctl` → `$HOME/bin/bose`
- `hammerspoon/bose.lua:25` — `CTL = ...HOME.."/bin/bose-ctl"` → `/bin/bose` (+ comments 4,71,76)

**Step 1 — apply the replace (token-exact):**
```bash
cd ~/code/personal/bose/.worktrees/rename-to-bose
grep -rl 'bose-ctl' cli raycast hammerspoon macos --include='*.swift' --include='*.sh' --include='*.lua' \
  | while read f; do LC_ALL=C sed -i '' 's/bose-ctl/bose/g' "$f"; done
```

**Step 2 — verify no live token remains (expect only docs/historical):**
```bash
grep -rn 'bose-ctl' cli raycast hammerspoon macos --include='*.swift' --include='*.sh' --include='*.lua'
```
Expected: **no output**.

**Step 3 — confirm the env var + source dir survived:**
```bash
grep -n 'BOSE_CTL' macos/BoseControl/BoseManager.swift   # expect line 75 intact
```
Expected: the `BOSE_CTL` env lookup line still present.

**Step 4 — commit:**
```bash
git add cli raycast hammerspoon macos
git commit -m "refactor: rename bose-ctl invocations to bose"
```

## Task A2: Rebuild + install the `bose` CLI

**Step 1 — build:**
```bash
cd ~/code/personal/bose/.worktrees/rename-to-bose
NO_REGEN= bash cli/build.sh
```
Expected: `Building bose (CLI)...` → produces `cli/build/bose`.

**Step 2 — install + retire the old binary (keep a compat symlink for one cycle):**
```bash
cp cli/build/bose ~/bin/bose
ln -sf ~/bin/bose ~/bin/bose-ctl    # back-compat shim; remove after a week
chmod +x ~/bin/bose
```

**Step 3 — VERIFY against hardware (headphones must be bonded to the Mac):**
```bash
~/bin/bose status
```
Expected: real status (connection/battery/ANC/volume) — exit 0. (If "headphones not reachable", that's a BT-reach issue, not a rename failure.)

**Step 4 — commit:** nothing to commit (build artifact); proceed.

## Task A3: Rename the app bundle → `Bose.app`

**Files (modify):** `macos/build.sh`

**Step 1 — edit:**
- `macos/build.sh:18` — `APP_NAME="Bose Control"` → `APP_NAME="Bose"`
- `macos/build.sh:65` — hardcoded `"$HOME/.Trash/Bose Control.app.$(date +%s)"` → `"$HOME/.Trash/$APP_NAME.app.$(date +%s)"`
- (comment line 2 cosmetic)

**Step 2 — build + install:**
```bash
bash macos/build.sh --install
```
Expected: `Installed: /Applications/Bose.app`.

**Step 3 — retire the old bundle (one-time):**
```bash
[ -d "/Applications/Bose Control.app" ] && mv "/Applications/Bose Control.app" ~/.Trash/"Bose Control.app.$(date +%s)"
```

**Step 4 — VERIFY launch + connect:**
```bash
open -a "Bose" ; sleep 2
osascript -e 'tell application "System Events" to (name of processes) contains "Bose"'
```
Expected: `true`. (Then visually: window opens, device tiles populate, a tile tap connects — uses `~/bin/bose`.)

**Step 5 — commit:**
```bash
git add macos/build.sh
git commit -m "refactor: rename app bundle to Bose.app"
```

## Task A4: Update docs

**Files (modify):** `README.md`, `CLAUDE.md` — replace `bose-ctl` → `bose`, "Bose Control.app" → "Bose.app". Leave `docs/plans/*` historical files untouched.

**Step 1:**
```bash
LC_ALL=C sed -i '' 's/bose-ctl/bose/g; s/Bose Control\.app/Bose.app/g' README.md CLAUDE.md
```
**Step 2 — sanity check the device/usage tables still read correctly** (manual skim).
**Step 3 — commit:**
```bash
git add README.md CLAUDE.md
git commit -m "docs: bose-ctl -> bose, Bose Control.app -> Bose.app"
```

## Task A5: Regression gate + ship

**Step 1 — protocol tests unaffected (run anyway):**
```bash
cd protocol && make test
```
Expected: all pass.

**Step 2 — re-copy Raycast scripts to the live dir (they shell `~/bin/bose`):**
```bash
cp raycast/*.sh ~/.config/raycast/script-commands/
```

**Step 3 — ship:** `/f:ship` (PR + merge to main + cleanup). After merge, the live Hammerspoon `dofile` (reads the **main** repo path) picks up `~/bin/bose`; reload Hammerspoon (`hs.reload()`), Opt+B still works.

**Summary Part A:** 5 tasks, sequential, **Low** complexity (mechanical rename + 2 rebuilds). Risk: anything outside the repo referencing `bose-ctl` — mitigated by the `~/bin/bose-ctl` compat symlink for one cycle.

---

# PART B — "Katrina's Apple TV" button  (Branch 2: `feature/appletv-device-button`)

> Branch off `main` AFTER Part A merges, so it inherits the `bose` name.

## Phase 0 (GATE): Capture the Apple TV's Bluetooth MAC

The headphones must be connected to the Apple TV once so we can read its MAC; this also delivers the immediate goal (golf audio in the Bose). **Do NOT invent the MAC** (repo rule).

**Step 1 — connect headphones → Apple TV** (James's action, one-time): Apple TV → Settings → Remotes and Devices → Bluetooth → `verBosita`. (Or Control Center audio output if it now lists them.)

**Step 2 — read the active MAC from the headphones** (Mac bonded to headphones):
```bash
~/bin/bose raw "05 01 01 00"   # connected_devices GET; response = header + 6-byte MAC chunks
```
Parse the response: the 6-byte entry that is neither the headphone MAC (`E4:58:BC:C0:2F:72`) nor any known device in `devices.toml` is the **Apple TV**. Record as `APPLETV_MAC` (colon-hex).

**Fallback:** Apple TV → Settings → General → About → Bluetooth shows the address; read it off once.

**Verification:** `APPLETV_MAC` is a valid 6-octet address, distinct from all existing `[devices.*]` MACs.

## Phase B1: Add an optional `label` field to the device schema

**Files:**
- Modify: `protocol/codegen/emit_devices.py`
- Modify: `protocol/tests/test_emit_devices.py`, `protocol/tests/test_emit_devices_kotlin.py`
- Generated (via `make gen`): `protocol/generated/Devices.generated.{swift,kt}`

**Step 1 — failing test (Kotlin emitter carries `label`):**
```python
# test_emit_devices_kotlin.py
def test_device_struct_has_optional_label():
    src = emit_devices_kotlin(SPEC)
    assert "val label: String?" in src          # struct field
```
Run: `cd protocol && uv run pytest tests/test_emit_devices_kotlin.py::test_device_struct_has_optional_label -q` → **FAIL**.

**Step 2 — implement in `emit_devices.py`:** add `label: String?` (Swift) / `val label: String?` (Kotlin) to the `BoseDevice` struct emission; read `dev.get("label")` from each `[devices.*]` table; emit `label: "X"` / `label = "X"` when present else `nil` / `null`. Keep `mac`/`widget` unchanged.

**Step 3 — regen + tests pass:**
```bash
cd protocol && make gen && uv run pytest tests/test_emit_devices_kotlin.py tests/test_emit_devices.py -q
```
Expected: PASS. Also `make check` (drift + full suite) green.

**Step 4 — commit:**
```bash
git add protocol/codegen/emit_devices.py protocol/tests/test_emit_devices*.py protocol/generated
git commit -m "feat: optional label field in device schema codegen"
```

## Phase B2: Add the `appletv` device + golden connect test

**Files:** `protocol/spec/devices.toml`, `protocol/spec/bmap.toml`

**Step 1 — failing golden test:** add to `bmap.toml` under `[commands.connect_device]` (substitute real MAC, e.g. `AA BB CC DD EE FF`):
```toml
[commands.connect_device.verified_bytes]
connect_mac = "04 01 05 07 00 BC D0 74 11 DB 27"
connect_appletv = "04 01 05 07 00 AA BB CC DD EE FF"
[commands.connect_device.test_args]
connect_mac = { mac = "BC:D0:74:11:DB:27" }
connect_appletv = { mac = "AA:BB:CC:DD:EE:FF" }
```
Run: `cd protocol && uv run pytest tests/test_golden.py -q` → **PASS only if** the device exists; first add the toml above, the test auto-covers it.

**Step 2 — add the device to `devices.toml`:**
```toml
[devices.appletv]
mac = "AA:BB:CC:DD:EE:FF"          # real APPLETV_MAC from Phase 0
label = "Katrina's Apple TV"
widget = false                      # in-app + Mac only; no home-screen widget
notes = "Lounge Room Apple TV 4K (gen 3)"
```
Add `"appletv"` to `cycle_order` (e.g. after `tv`).

**Step 3 — regen + full suite:**
```bash
cd protocol && make gen && make test
```
Expected: PASS, incl. `connect_appletv` golden + committed-generated-in-sync.

**Step 4 — rebuild + install `bose`, smoke-test the connect:**
```bash
bash cli/build.sh && cp cli/build/bose ~/bin/bose
~/bin/bose connect appletv
```
Expected: routes audio to the Apple TV (headphones reachable + Apple TV bonded). VERIFY: audio actually moves to the Bose.

**Step 5 — commit:**
```bash
git add protocol/spec/devices.toml protocol/spec/bmap.toml protocol/generated
git commit -m "feat: add Katrina's Apple TV device to the map"
```

## Phase B3: macOS app tile

**Files:** `macos/BoseControl/ContentView.swift`, `macos/BoseControl/BoseManager.swift`

**Step 1 — add the tile** at `ContentView.swift:31-38` `deviceButtons`:
```swift
DeviceButton(id: "appletv", label: "Katrina's Apple TV", symbol: "appletv"),
```

**Step 2 — long label fits:** at the tile label modifier (`ContentView.swift:300-304`) allow two lines: `.lineLimit(2)` (keep `.minimumScaleFactor(0.8)`).

**Step 3 — seed state** `BoseManager.swift:39-42`: add `"appletv": "offline",`.

**Step 4 — build + install + verify:**
```bash
bash macos/build.sh --install
```
VERIFY: new tile labelled "Katrina's Apple TV" renders; tapping it runs `bose connect appletv` and routes audio.

**Step 5 — commit:**
```bash
git add macos/BoseControl/ContentView.swift macos/BoseControl/BoseManager.swift
git commit -m "feat: Apple TV tile in the Mac app"
```

## Phase B4: Android in-app tile (label + 7-tile wrap)

**Files:** `android/app/src/main/java/au/com/jd/bose/MainActivity.kt` (+ refreshed `Devices.generated.kt`)

**Step 1 — use the friendly label** at `MainActivity.kt:554-556`:
```kotlin
Text(
    text = BoseDeviceMap.byName[name]?.label ?: name,
    fontSize = 12.sp,
```

**Step 2 — wrap the row for 7 tiles** at `DevicesSection` (`MainActivity.kt:528-531`): change the single non-wrapping `Row { ... }` to `FlowRow(maxItemsInEachRow = 4) { ... }` (import `androidx.compose.foundation.layout.FlowRow`) so 7 tiles wrap to two rows on the S21.

**Step 3 — refresh generated map + build:**
```bash
cd protocol && make gen
cd ../android && ./gradlew copyGeneratedProtocol && ./gradlew assembleDebug
```
Expected: `Devices.generated.kt` now carries `appletv` + `label`; APK builds at `app/build/outputs/apk/debug/app-debug.apk`.

**Step 4 — deploy + verify on the S21:**
```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
VERIFY: "Katrina's Apple TV" tile shows; tap → `Composites.connectDevice(appletv MAC)` routes audio. (Headphones bonded to the S21 for the command path.)

**Step 5 — commit:**
```bash
git add android/app/src/main/java/au/com/jd/bose/MainActivity.kt android/app/src/generated/java/au/com/jd/bose/Devices.generated.kt
git commit -m "feat: Apple TV tile on the S21 in-app UI"
```

## Phase B5: Raycast dropdown

**Files:** `raycast/bose-connect.sh`

**Step 1 — add to the `@raycast.argument1` dropdown data:** append `{"title":"Apple TV","value":"appletv"}`.
**Step 2 — recopy:** `cp raycast/bose-connect.sh ~/.config/raycast/script-commands/`
**Step 3 — commit:**
```bash
git add raycast/bose-connect.sh
git commit -m "feat: Apple TV in Raycast connect dropdown"
```

## Phase B6: Ship

`/f:ship` Branch 2.

**Summary Part B:** Phase 0 gate (MAC) + 6 phases, sequential (shared device map feeds all). **Medium** complexity (codegen schema change + 3 client rebuilds + device deploy).

---

## Verification gate (every task)

Run the stated command fresh, read the output + exit code, confirm it proves the claim before marking done. No "should work". Hardware steps (`bose status`, `bose connect appletv`, tile taps) require the headphones bonded to the relevant device.

## Overall

| Part | Branch | Gated? | Tasks | Complexity |
|------|--------|--------|-------|------------|
| A — rename to Bose | `feature/rename-to-bose` | no — ship now | 5 | Low |
| B — Apple TV button | `feature/appletv-device-button` | yes — Apple TV MAC (Phase 0) | 6 (+gate) | Medium |
