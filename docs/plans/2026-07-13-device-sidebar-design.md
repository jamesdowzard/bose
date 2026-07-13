# Device sidebar + Mac-as-plain-device — design (2026-07-13)

## Problem

Two issues with the Bose.app multipoint control:

1. The device picker was a 3-column `LazyVGrid` with drag-to-reorder. In a grid,
   "drag to set priority" reads ambiguously (up/down/left/right), and **every drag
   that changed the top-2 fired a live `pair` connect** (`applyOrder` → `applyPair`),
   so drags raced against connects — especially with the Avantree Audikast re-paging
   its slot aggressively. It "didn't work properly."
2. Connecting the **Mac** was unreliable. The CLI special-cased the Mac with a
   `blueutil --connect` (+1.5s sleep) A2DP dance on every connect/swap/pair/evict.

## Decisions (with James)

- **Layout:** a dedicated **3-column** window — Settings │ Devices sidebar │ EQ.
- **Drag semantics:** dragging **sets priority only** (persists `priority.json`, no
  radio activity). Connecting is an explicit **tap** on a device row. This decouples
  ranking from connecting and removes the drag-races-connect bug.
- **Mac:** strip **all** Mac special-casing — treat it exactly like any other device
  (plain BMAP connect/disconnect, no blueutil, no sleeps).

## Design

### Layout (`ContentView.swift`)
`connectedLayout` becomes a 3-panel `HStack`: `leftPanel` (260) │ divider │
`deviceSidebar` (220) │ divider │ `eqPanel` (flex). Window min-width 700→800.

### Device sidebar
- `deviceList`: a vertical `VStack` of `deviceRow`s in `deviceOrder`, each with
  `.onDrag`/`.onDrop` via the existing `DeviceDropDelegate` (axis-agnostic; vertical
  is unambiguous). `onCommit` = `applyOrder` = **`manager.setPriority` only**.
- `deviceRow`: `[rank badge] [icon] label … [state dot]`, ~38px tall. Badge = ①/②
  filled for the top-2 (pair preference), faint rank number below. Dot = live state
  (● active / ● held / ○ offline). Tap → `manager.connectDevice`. Right-click →
  Disconnect. The badge shows your **ranked preference**; the dot shows **reality** —
  they intentionally differ when the ranked device isn't the current sink.
- Removed: `deviceButton` (grid tile), `moveDevice` + the Make-Primary/Secondary menu
  (drag replaces them), `appliedTop2` state, the auto-`applyPair` on reorder.

### Mac-as-plain-device (`cli/main.swift`, `cli/Transport.swift`)
Removed every `isMacDevice(…) { runBlueutil(…) }` site across `cmdConnect`, `cmdSwap`,
`cmdDisconnect`, `cmdPair` (evict + page), `evictLowestPriorityIfFull`, `restoreEvicted`.
Deleted the now-dead `isMacDevice` and `runBlueutil` helpers.

## Testing / verification

- `cli/run-tests.sh` = 18 pass (priority/profile logic unchanged).
- App builds + Developer-ID signs; 3-column layout verified via AX screenshot.
- **Hardware, James to confirm:** that plain-BMAP `connect mac` reliably routes Mac
  audio without the blueutil link. The Audikast re-page race is radio timing — powering
  the transmitter off remains the durable lever.

## Out of scope
- No resident watcher / auto-reconnect (banned #61-#69; walk-back removed #139).
- No firmware priority push (`ConnectionPriority 0x10` is FuncNotSupp).
- Android app unchanged.
