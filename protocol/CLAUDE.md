# Bose — BMAP protocol (the single source of truth)

<!-- Split out of the root CLAUDE.md on 2026-08-27: it was 52 KB, ~6x the 8 KB fleet cap.
     This file loads when Claude reads a file in this directory. -->

`spec/bmap.toml` is canonical; the tables below are its human-readable mirror. Edit the
TOML and regenerate — never hand-edit `generated/`.

### Protocol (`protocol/`) — the single source of truth
- `protocol/spec/bmap.toml` -- **canonical machine-readable BMAP spec** for every codegen'd builder, with `verified_bytes` golden captures. **ONE exception: `1F,06` AudioModesModeConfig is deliberately NOT here** — its GET (48-byte) and SET_GET (40-byte, different layout) payloads can't be expressed in the DSL, so the RMW behind `anc-level`/`spatial`/`mode-name` is hand-written per platform (`parseModeConfig`/`buildModeConfigSet`, Swift + Kotlin). That makes 1F,06 the one place the two clients **can** drift on wire encoding — `make check` cannot catch it. Change one side, change both, and keep the byte-test corpora in lockstep. The command tables further down in this file are the human-readable mirror — **edit `bmap.toml` and regenerate; never hand-edit `generated/`.**
- `protocol/spec/devices.toml` -- headphone MAC + device map (the one home for those literals).
- `protocol/codegen/` (entry point `codegen/generate.py`, run via `make gen` as `python -m codegen.generate`) -- Python (uv) emitters → `protocol/generated/{BMAP,Devices}.generated.{swift,kt}`. `make gen` regenerates; `make check` proves the committed generated files **and the Android copies under `android/app/src/generated/`** are in sync + runs the golden byte tests.



## Where the tables live

The full BMAP command/operator/function-ID tables, the AudioModes (1F) semantics, the
not-supported list and the capability→exposure map are in **`docs/bmap-reference.md`**.

## The two rules that matter here

- **Edit `spec/bmap.toml` and regenerate; never hand-edit `generated/`.** `make gen`
  regenerates, `make check` proves the committed Swift/Kotlin (and the Android copies under
  `android/app/src/generated/`) are in sync and runs the golden byte tests.
- **`1F,06` AudioModesModeConfig is deliberately NOT in the spec.** Its GET (48-byte) and
  SET_GET (40-byte) payloads have different layouts that the DSL can't express, so the RMW
  behind `anc-level`/`spatial`/`mode-name` is hand-written per platform. That makes it the
  **one place the Swift and Kotlin clients can drift**, and `make check` cannot catch it.
  Change one side, change both, and keep the byte-test corpora in lockstep.
