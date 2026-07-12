# Multipoint pair picker — design (as built)

**Date:** 2026-07-13 · **Status:** implemented

## Problem

The QC Ultra 2 holds **exactly 2** multipoint devices, and the firmware has **no
device-priority hierarchy** (`ConnectionPriority 0x10` = FuncNotSupp) — it evicts by its
own LRU. The CLI already enforces a *compiled* priority (`devices.toml`) in software on a
full-multipoint connect, but James had no way to pick, at runtime, **which two devices are
the pair** (and which is primary/active vs secondary/held), nor to reorder eviction
priority without editing the spec + rebuilding.

## Decision

**Approach A — the CLI owns all logic; the app is a thin front-end.** A runtime order file
(`~/.config/bose/priority.json`) overrides the compiled priorities. Reordering the device
grid in the app persists that order and connects the top-2 as the pair.

- **Behaviour (chosen):** reorder → *persist* the order **and** *connect the pair now*
  (evict others, secondary held, primary active). Top-2 unchanged → persist only, no re-page.
- **UI (chosen):** reorder the **whole device grid** — index 0 = Primary (active), 1 =
  Secondary (held), rest = eviction order. Drag tiles, or right-click → Make Primary /
  Make Secondary / Disconnect. Primary/Secondary shown as a small "1"/"2" badge.

## Components

### CLI (`cli/`)
- **`Priority.swift`** (pure, Foundation-only, unit-tested): `PriorityOrder` load/save
  (`priority.json`, `$BOSE_STATE_DIR` override) + `effectiveRank(name, order, compiledPriority)` —
  listed device ranks by index; unlisted sorts after all listed, then by compiled priority
  (graceful degradation to devices.toml when the file is absent/partial).
- **`main.swift`**:
  - `evictLowestPriorityIfFull` now picks the victim by `effectiveRank` (runtime order wins,
    compiled fallback).
  - `bose priority [--set n… | --clear]` — show/set/clear the runtime order.
  - `bose pair <primary> <secondary>` — composite: evict all non-pair held devices → connect
    secondary (held) → connect primary (active), reporting the honest outcome. Reuses the
    verified `confirmConnect` poll (ACK ≠ success).

### App (`macos/BoseControl/`)
- **`BoseManager`**: `loadPriorityOrder`, `setPriority` (writes via `bose priority --set`),
  `disconnectDevice`, `applyPair` (shells `bose pair`, spins the primary tile).
- **`ContentView`**: device grid is drag-reorderable (`DeviceDropDelegate`); "1"/"2" role
  badges; right-click context menu (Make Primary / Make Secondary / Disconnect). On reorder:
  persist + `applyPair` iff the top-2 changed.

## Deliberately NOT built

- **No resident "kick the Audikast" watcher.** A background poller that disconnects an
  aggressive re-pager is exactly the banned anti-pattern (#61–#69 audio dropouts). The picker
  is user-initiated; an aggressive transmitter is defeated by powering it off, not software.
- Firmware priority push (impossible — FuncNotSupp).

## Honest limits

The firmware has no priority lock, so `pair` can still lose the slot to an instant re-pager
(e.g. the Avantree Audikast) or a sleeping target. It reports the real outcome; the order
persists regardless of whether the live connect landed.

## Testing

Pure unit tests (`cli/Tests`, hardware-free): `effectiveRank` (listed/unlisted/empty),
victim selection (compiled default vs runtime override flip), `priority.json` round-trip +
clear. All pass. Live `bose pair` intentionally not exercised in CI (mutates real BT links).
