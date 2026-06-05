# Bose Control v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild the Bose QC Ultra 2 controller around a single TOML protocol spec + Python codegen that emits the Swift and Kotlin wire layers, then rebuild the macOS app (event-driven menu-bar, no dropout poll), regenerate the Android protocol, and regenerate the CLI.

**Architecture:** One `protocol/spec/bmap.toml` is the source of truth for every BMAP command, operator, and enum; `protocol/spec/devices.toml` holds the headphone MAC + device map. `generate.py` (uv/Python) emits `BMAP.generated.swift` and `BMAP.generated.kt`, both verified by pytest golden tests against captured byte sequences. Platform transport (IOBluetooth / `BluetoothSocket`) and ~3 composite commands stay hand-written but call generated primitives.

**Tech Stack:** Python 3.12 + uv + tomllib + pytest (codegen & tests); Swift + IOBluetooth + SwiftUI `MenuBarExtra` (macOS); Kotlin + Jetpack Compose + foreground service (Android).

**Reference:** `docs/plans/2026-06-05-bose-control-v2-design.md` (approved design), repo `CLAUDE.md` (BMAP command tables + verified byte captures — the golden-test corpus).

---

## Phase 1 — Protocol spec + codegen (foundation)

Self-contained. Proven against captures before any app consumes it. Build the codegen test-first: the generator is itself driven by golden-byte assertions.

### Task 1.1: Scaffold the protocol package

**Files:**
- Create: `protocol/pyproject.toml`
- Create: `protocol/codegen/__init__.py`
- Create: `protocol/tests/__init__.py`

**Step 1:** Create `protocol/pyproject.toml`:

```toml
[project]
name = "bose-protocol-codegen"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = []

[dependency-groups]
dev = ["pytest>=8"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

**Step 2:** Create the two empty `__init__.py` files.

**Step 3:** Verify the env: `cd protocol && uv sync` → expect a created `.venv`.

**Step 4: Commit**
```bash
git add protocol/pyproject.toml protocol/codegen/__init__.py protocol/tests/__init__.py
git commit -m "chore: scaffold protocol codegen package"
```

### Task 1.2: Spec loader + frame model (TDD)

The smallest unit: parse a single command spec and build a BMAP frame `[block, function, operator, length, ...payload]`.

**Files:**
- Create: `protocol/codegen/model.py`
- Test: `protocol/tests/test_frame.py`

**Step 1: Write the failing test** (`tests/test_frame.py`):

```python
from codegen.model import build_frame, Operator

def test_frame_anc_set_quiet():
    # ANC set quiet: block=1F func=03 op=START(05) len=02 payload=[mode=0, 01]
    frame = build_frame(block=0x1F, function=0x03, operator=Operator.START,
                        payload=[0x00, 0x01])
    assert frame == [0x1F, 0x03, 0x05, 0x02, 0x00, 0x01]

def test_frame_get_zero_payload():
    frame = build_frame(block=0x1F, function=0x03, operator=Operator.GET, payload=[])
    assert frame == [0x1F, 0x03, 0x01, 0x00]
```

**Step 2:** Run `cd protocol && uv run pytest tests/test_frame.py -v` → FAIL (no module).

**Step 3: Minimal implementation** (`codegen/model.py`):

```python
from enum import IntEnum

class Operator(IntEnum):
    GET = 0x01
    SET_GET = 0x02
    RESP = 0x03
    ERROR = 0x04
    START = 0x05
    SET = 0x06
    ACK = 0x07

def build_frame(block: int, function: int, operator: Operator, payload: list[int]) -> list[int]:
    return [block, function, int(operator), len(payload), *payload]
```

**Step 4:** Run the test → PASS.

**Step 5: Commit**
```bash
git add protocol/codegen/model.py protocol/tests/test_frame.py
git commit -m "feat: BMAP frame builder + operator enum"
```

### Task 1.3: Payload encoder DSL (TDD)

Spec payloads are written like `["mode:u8", "0x01"]`. Parse those tokens into byte-producing encoders given named args.

**Files:**
- Modify: `protocol/codegen/model.py`
- Test: `protocol/tests/test_payload.py`

**Step 1: Failing test**:

```python
from codegen.model import encode_payload

def test_literal_and_arg():
    out = encode_payload(["mode:u8", "0x01"], {"mode": 0})
    assert out == [0x00, 0x01]

def test_signed_arg():
    out = encode_payload(["value:i8", "band:u8"], {"value": -3, "band": 1})
    assert out == [0xFD, 0x01]  # -3 as two's complement byte

def test_mac_arg():
    out = encode_payload(["00", "mac:mac"], {"mac": "E4:58:BC:C0:2F:72"})
    assert out == [0x00, 0xE4, 0x58, 0xBC, 0xC0, 0x2F, 0x72]
```

**Step 2:** Run → FAIL.

**Step 3: Implement** `encode_payload` in `model.py`:

```python
def _mac_bytes(s: str) -> list[int]:
    return [int(b, 16) for b in s.replace("-", ":").split(":")]

def encode_payload(tokens: list[str], args: dict) -> list[int]:
    out: list[int] = []
    for tok in tokens:
        if ":" in tok:                       # named arg "name:type"
            name, typ = tok.split(":")
            val = args[name]
            if typ == "u8":
                out.append(val & 0xFF)
            elif typ == "i8":
                out.append(val & 0xFF)        # two's complement in a byte
            elif typ == "mac":
                out.extend(_mac_bytes(val))
            else:
                raise ValueError(f"unknown type {typ}")
        else:                                 # hex literal "0x01" / "00"
            out.append(int(tok, 16))
    return out
```

**Step 4:** Run → PASS.

**Step 5: Commit**
```bash
git add protocol/codegen/model.py protocol/tests/test_payload.py
git commit -m "feat: payload encoder DSL (u8/i8/mac + hex literals)"
```

### Task 1.4: Author `bmap.toml` from CLAUDE.md (data, golden-locked)

Transcribe every command in the `CLAUDE.md` tables into the spec, with `verified_bytes` wherever the doc gives a concrete capture. This is the single source of truth.

**Files:**
- Create: `protocol/spec/bmap.toml`
- Create: `protocol/spec/devices.toml`
- Test: `protocol/tests/test_golden.py`

**Step 1:** Author `spec/bmap.toml`. One section per command. Include at minimum (from `CLAUDE.md`): `anc_mode` (1F,03), `volume` (05,05, **SET_GET** — fixes the v1 bug), `device_name` (01,02), `multipoint` (01,0A), `connect_device` (04,01), `disconnect_device` (04,02), `media_control` (05,03), `eq_band` (01,07), `cnc_level` (1F,0A, composite), `connected_devices` (05,01, composite), `battery` (02,02), `audio_codec` (05,04), `firmware` (00,05). Enums: `AncMode`, `EqBand`, `MediaAction`. Mark composites `composite = true`. Add `verified_bytes` for ANC, EQ, volume, connect, media (the doc gives exact byte rows).

**Step 2:** Author `spec/devices.toml`:

```toml
headphone_mac = "E4:58:BC:C0:2F:72"
headphone_name = "verBosita"
cycle_order = ["mac", "quest", "ipad", "iphone", "tv", "phone"]

[devices.phone]   ; mac, widget, notes per CLAUDE.md device map
mac = "A8:76:50:D3:B1:1B"
widget = true
[devices.mac]
mac = "BC:D0:74:11:DB:27"
widget = true
# ... ipad, iphone, tv (widget=false), quest
```

**Step 3: Golden test** (`tests/test_golden.py`) — generic over the spec:

```python
import tomllib, pathlib
from codegen.model import build_frame, encode_payload, Operator

SPEC = tomllib.loads((pathlib.Path(__file__).parent.parent / "spec/bmap.toml").read_text())

def _bytes(s): return [int(x, 16) for x in s.split()]

def test_every_verified_capture_matches():
    checked = 0
    for name, cmd in SPEC["commands"].items():
        for label, expected_hex in cmd.get("verified_bytes", {}).items():
            # label like "set_quiet" -> action "set", variant args resolved in spec
            action, *_ = label.split("_", 1)
            block, func = cmd["block"], cmd["function"]
            spec_action = cmd[action]
            op = Operator[spec_action["operator"]]
            args = cmd.get("test_args", {}).get(label, {})
            frame = build_frame(block, func, op, encode_payload(spec_action.get("payload", []), args))
            assert frame == _bytes(expected_hex), f"{name}.{label}"
            checked += 1
    assert checked > 0
```

**Step 4:** Run `uv run pytest tests/test_golden.py -v` → PASS (iterate the TOML until every capture matches).

**Step 5: Commit**
```bash
git add protocol/spec/ protocol/tests/test_golden.py
git commit -m "feat: bmap.toml + devices.toml spec, golden byte tests green"
```

### Task 1.5: Swift emitter (TDD against a snapshot)

**Files:**
- Create: `protocol/codegen/emit_swift.py`
- Test: `protocol/tests/test_emit_swift.py`

**Step 1: Failing test** — assert the emitter produces a builder for a known command and the enum:

```python
from codegen.emit_swift import emit_swift
import tomllib, pathlib
SPEC = tomllib.loads((pathlib.Path(__file__).parent.parent/"spec/bmap.toml").read_text())

def test_emits_anc_enum_and_builder():
    src = emit_swift(SPEC)
    assert "enum AncMode: UInt8" in src
    assert "case quiet = 0" in src
    assert "static func setAncMode(" in src
    assert "[0x1F, 0x03, 0x05," in src  # frame prefix present
```

**Step 2:** Run → FAIL.

**Step 3:** Implement `emit_swift(spec) -> str`: emit a `enum BMAPOperator`, each `enum <Name>: UInt8`, and an `enum BMAP { static func ... }` of builders/decoders for every non-composite command (skip `composite = true` — those are hand-written). Use the model's frame/payload logic to compute literal byte arrays where args are fixed, or emit functions that build them at runtime for arg'd commands.

**Step 4:** Run → PASS.

**Step 5: Commit**
```bash
git add protocol/codegen/emit_swift.py protocol/tests/test_emit_swift.py
git commit -m "feat: Swift emitter for generated BMAP layer"
```

### Task 1.6: Kotlin emitter (TDD, mirrors 1.5)

**Files:** Create `protocol/codegen/emit_kotlin.py`; Test `protocol/tests/test_emit_kotlin.py`.
Same structure as 1.5; emit `enum class AncMode(val v: Int)` and an `object BMAP { fun setAncMode(...) : IntArray ... }`. Assert enum + builder + frame prefix present. Commit `feat: Kotlin emitter for generated BMAP layer`.

### Task 1.7: `generate.py` driver + write generated files

**Files:**
- Create: `protocol/codegen/generate.py`
- Create (generated): `protocol/generated/BMAP.generated.swift`, `protocol/generated/BMAP.generated.kt`
- Test: `protocol/tests/test_generate.py`

**Step 1: Failing test** — running the generator writes both files and they're non-empty and start with a "DO NOT EDIT — generated from bmap.toml" banner.

**Step 2:** Implement `generate.py`: load spec, call both emitters, write files with the banner. Provide `uv run python -m codegen.generate`.

**Step 3:** Run it; assert files exist and contain the banner + a known symbol.

**Step 4:** Run full suite `uv run pytest -v` → all green.

**Step 5: Commit**
```bash
git add protocol/codegen/generate.py protocol/generated/ protocol/tests/test_generate.py
git commit -m "feat: codegen driver writes generated Swift + Kotlin"
```

### Task 1.8: Makefile/justfile + CI-equivalent check

Add `protocol/Makefile` with `gen` (regenerate) and `check` (regenerate then `git diff --exit-code generated/` to prove generated files are committed in sync) + `pytest`. Commit `chore: protocol make targets (gen, check)`.

---

## Phase 2 — macOS app (rebuilt, event-driven menu-bar)

> Detailed to task level when Phase 1 lands. Key shape below.

- **Task 2.1** — New SwiftUI target `BoseControl` using `MenuBarExtra`; `Info.plist` `LSUIElement = true`; remove the `WindowGroup`/Dock-window. Build script copies `protocol/generated/BMAP.generated.swift` into the target.
- **Task 2.2** — Port the transport from v1 `BoseRFCOMM.swift` into `Transport.swift`: `withRFCOMM` open/drain(300ms)/close, cold-start warm-up (error 913), **serial `DispatchQueue`** wrapping all sends. No held channel. Calls generated builders.
- **Task 2.3** — Composite commands `Composites.swift`: `cncLevel` read-modify-write, `connectedDevices` list parse, `getAllState` single-session. TDD the parsers against captured response bytes.
- **Task 2.4** — `connectDevice` confirmation: poll `connectedDevices` until target MAC appears (timeout ~16s); never ACK-as-success.
- **Task 2.5** — `BoseManager` (ObservableObject): **no timer**. `refresh()` only on menu-open + IOBluetooth `connect/disconnect` notifications. Surface all state.
- **Task 2.6** — Menu UI: device switch, ANC mode, CNC depth slider, volume, EQ presets+sliders, multipoint toggle, media transport, per-device disconnect, rename, info readout. Per-device "connecting…" + failure surfaced.
- **Task 2.7** — Global hotkey device cycle (`KeyboardShortcuts` or local monitor) using `devices.toml` cycle order.
- **Task 2.8** — LaunchAgent: keep `KeepAlive` but the resident process is now a silent menu-bar app that does NOT poll. Verify 30+ min no-dropout + phone app can connect while Mac idle. Retire/replace v1 `macos/BoseControl/*`.

## Phase 3 — Android (regenerate protocol, keep architecture)

- **Task 3.1** — Build step copies `BMAP.generated.kt` into `au.com.jd.bose`; delete hand-written `BoseProtocol.kt` wire details, keep transport + composites as a thin `Transport.kt` calling generated builders.
- **Task 3.2** — Unify device map from `devices.toml` (fix `tv` widget drift); single headphone MAC.
- **Task 3.3** — Add media controls to the notification (MediaSession) + optionally widget.
- **Task 3.4** — Isolate the hidden-API A2DP reflection into one clearly-marked `A2dpReflection.kt`; remove stale comments.
- **Task 3.5** — Verify FGS, companion device, widget, QS tile still work on device.

## Phase 4 — CLI + cleanup

- **Task 4.1** — `cli/` `bose-ctl` built from `protocol/generated/BMAP.generated.swift` + shared transport; collapse inline parsing onto generated methods.
- **Task 4.2** — Delete `probe-gatt.swift` and any other dead v1 files; de-stale references.
- **Task 4.3** — Update repo `CLAUDE.md`: document the spec/codegen as the source of truth; keep the BMAP knowledge but point edits at `bmap.toml`.
- **Task 4.4** — Final full-suite + live smoke; `/f:ship`.

---

## Conventions

- **TDD throughout** (superpowers:test-driven-development): failing test → minimal code → green → commit.
- **Frequent commits** — one per task step group as shown.
- **Generated files are committed** and never hand-edited (banner enforces; `make check` guards drift).
- **Golden tests are the contract** — any spec change must keep `verified_bytes` green; add a capture before locking an unverified command.
- **Headphone single-session rule** — no surface probes when it isn't the active source.
