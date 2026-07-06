# Walk-Back Auto-Reconnect Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When James returns to his desk (input resumes after an idle gap) and the headphones have dropped off the Mac, automatically run `bose connect mac` — but only if the Mac was his last active source — with multipoint left on and no headphone polling.

**Architecture:** An event-driven `hs.eventtap` watcher in the already-resident `hammerspoon/bose.lua` detects "resumed activity after an idle gap." It gates on a channel-free `blueutil --is-connected` check (never opens RFCOMM to decide) and a `~/.config/bose/last-active-mac` flag written by the Swift CLI. If both say "disconnected + Mac was last source," it calls the existing `connectHere()`. The flag is set/cleared inside `cmdConnect`/`cmdSwap`/`cmdDisconnect` in `cli/main.swift`.

**Tech Stack:** Swift (Foundation-only for the flag), Lua (Hammerspoon `hs.eventtap`, `hs.task`), `blueutil`.

**Design doc:** `docs/plans/2026-07-06-walk-back-reconnect-design.md`

**Key constraints (from CLAUDE.md / #61-#62):**
- NEVER probe the headphones over RFCOMM to *decide* whether to reconnect — RFCOMM opens ACL and the firmware steals audio. Only open RFCOMM once we've already decided to connect.
- No new resident process / LaunchAgent / headphone poller. Reuse Hammerspoon.
- Multipoint stays on.

---

### Task 1: `last-active-mac` flag helpers (Swift, pure + testable)

**Files:**
- Modify: `cli/main.swift` (add flag helpers near the other free functions, ~line 33-52 area)
- Test: `cli/Tests/main.swift` (append checks)
- Check: `cli/Profiles.swift:80-90` for the config-dir idiom to mirror

**Step 1: Write the failing test**

Append to `cli/Tests/main.swift` (before the final exit):

```swift
// ── last-active-mac flag ─────────────────────────────────────────────────────────
// Uses $BOSE_STATE_DIR override so the test never touches real ~/.config/bose.
let tmpState = NSTemporaryDirectory() + "bose-test-state-\(getpid())"
setenv("BOSE_STATE_DIR", tmpState, 1)
let flagPath = tmpState + "/last-active-mac"

setLastActiveMac(true)
check(FileManager.default.fileExists(atPath: flagPath), "flag: set true creates the flag file")
check(lastActiveMacIsSet(), "flag: lastActiveMacIsSet true after set")

setLastActiveMac(false)
check(!FileManager.default.fileExists(atPath: flagPath), "flag: set false removes the flag file")
check(!lastActiveMacIsSet(), "flag: lastActiveMacIsSet false after clear")

try? FileManager.default.removeItem(atPath: tmpState)
```

**Step 2: Run test to verify it fails**

Run: `cd cli && ./run-tests.sh`
Expected: FAIL to compile — `setLastActiveMac` / `lastActiveMacIsSet` not defined.

> Note: `run-tests.sh` compiles `Parsers.swift` + `Profiles.swift` + generated BMAP. The flag helpers must live in a Foundation-only file that the test compiles. Put them in **`cli/Profiles.swift`** (already Foundation-only and already compiled by the test) rather than `main.swift` (which imports IOBluetooth and is NOT in the test target). Update the test-runner include list if needed — but Profiles.swift is already included, so no change.

**Step 3: Write minimal implementation**

Add to `cli/Profiles.swift` (Foundation-only — no IOBluetooth):

```swift
// MARK: - last-active-mac flag
//
// A presence flag: the file EXISTS iff the Mac was the last source we connected.
// Written by cmdConnect/cmdSwap/cmdDisconnect; read by the Hammerspoon walk-back
// watcher (which only auto-reconnects the Mac when this is set, so returning to the
// desk never yanks audio off the phone). Dir mirrors the profiles resolution:
// $BOSE_STATE_DIR override (for tests) → ~/.config/bose.
func boseStateDir() -> String {
    if let d = ProcessInfo.processInfo.environment["BOSE_STATE_DIR"], !d.isEmpty { return d }
    return FileManager.default.homeDirectoryForCurrentUser.path + "/.config/bose"
}

func lastActiveMacFlagPath() -> String { boseStateDir() + "/last-active-mac" }

func setLastActiveMac(_ active: Bool) {
    let path = lastActiveMacFlagPath()
    if active {
        try? FileManager.default.createDirectory(atPath: boseStateDir(),
                                                  withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
    } else {
        try? FileManager.default.removeItem(atPath: path)
    }
}

func lastActiveMacIsSet() -> Bool {
    FileManager.default.fileExists(atPath: lastActiveMacFlagPath())
}
```

**Step 4: Run test to verify it passes**

Run: `cd cli && ./run-tests.sh`
Expected: PASS — 4 new `ok - flag: ...` lines, exit 0.

**Step 5: Commit**

```bash
git add cli/Profiles.swift cli/Tests/main.swift
git commit -m "feat: last-active-mac flag helpers"
```

---

### Task 2: Wire the flag into connect/swap/disconnect (Swift)

**Files:**
- Modify: `cli/main.swift` — `cmdConnect` (`:444-463`), `cmdSwap` (`:468-486`), `cmdDisconnect` (find it)

**Step 1: Set/clear the flag on confirmed connect in `cmdConnect`**

In `cmdConnect`, in the `switch confirmConnect(mac)` block, both `.active` and `.idle` mean the device is now connected. Add flag maintenance:

```swift
    switch confirmConnect(mac) {
    case .active, .idle:
        setLastActiveMac(isMacDevice(mac))   // set iff we connected the Mac; clear on any other device
        if case .active = confirmConnect(mac) {} // (leave existing prints below unchanged)
    ...
    }
```

> IMPORTANT: do NOT call `confirmConnect` twice (it polls hardware ~16s). Instead capture the outcome once. Refactor the existing switch to:

```swift
    let outcome = confirmConnect(mac)
    if outcome == .active || outcome == .idle {
        setLastActiveMac(isMacDevice(mac))
    }
    switch outcome {
    case .active: print("Connected \(deviceName)")
    case .idle:   print("Connected \(deviceName) (idle — audio stayed on the active device; multipoint)")
    case .none:
        if let evicted = evicted { restoreEvicted(evicted, failedTarget: deviceName) }
        fail("connect \(deviceName) not confirmed within timeout")
    }
```

(`ConnectOutcome` needs `Equatable` — it's a plain enum with no associated values, so add `: Equatable` to its declaration at `cli/main.swift` `enum ConnectOutcome`.)

**Step 2: Same capture-once + flag in `cmdSwap`**

Apply the identical `let outcome = confirmConnect(mac)` + `setLastActiveMac(isMacDevice(mac))` refactor to `cmdSwap`.

**Step 3: Clear the flag on explicit Mac disconnect in `cmdDisconnect`**

In `cmdDisconnect`, after a successful disconnect of the Mac, clear the flag (an explicit Mac disconnect means "I don't want the Mac"):

```swift
    if isMacDevice(mac) { setLastActiveMac(false) }
```

**Step 4: Build the CLI and smoke-test the flag**

Run:
```bash
bash cli/build.sh && cp cli/build/bose ~/bin/bose
BOSE_STATE_DIR=/tmp/bose-smoke ~/bin/bose connect mac   # with headphones on
ls /tmp/bose-smoke/last-active-mac && echo "flag set OK"
```
Expected: after a Mac connect, the flag file exists. (If headphones are off, skip live check — the unit test already covers the helper.)

**Step 5: Run the unit tests + commit**

Run: `cd cli && ./run-tests.sh` (Expected: PASS)
```bash
git add cli/main.swift
git commit -m "feat: maintain last-active-mac flag on connect/swap/disconnect"
```

---

### Task 3: Pure walk-back decision function (Lua, testable without Hammerspoon)

**Files:**
- Create: `hammerspoon/reconnect_decision.lua`
- Test: `hammerspoon/reconnect_decision_test.lua`

**Step 1: Write the failing test**

Create `hammerspoon/reconnect_decision_test.lua`:

```lua
-- Run: lua hammerspoon/reconnect_decision_test.lua   (exits non-zero on failure)
local decide = require("reconnect_decision")

local function eq(got, want, msg)
  if got ~= want then error(string.format("FAIL %s: got %s want %s", msg, tostring(got), tostring(want)))
  else print("ok   - " .. msg) end
end

local IDLE = 150
-- gap below idle threshold → never reconnect (just a brief pause at the desk)
eq(decide(10,  IDLE, false, true),  false, "short gap → no")
-- long gap, but already connected → no (link never dropped)
eq(decide(300, IDLE, true,  true),  false, "connected → no")
-- long gap, disconnected, flag NOT set (was on phone) → no
eq(decide(300, IDLE, false, false), false, "flag unset → no")
-- long gap, disconnected, flag set → YES (the walk-back case)
eq(decide(300, IDLE, false, true),  true,  "walk-back → yes")
print("all passed")
```

**Step 2: Run to verify it fails**

Run: `cd hammerspoon && lua reconnect_decision_test.lua`
Expected: error — module `reconnect_decision` not found.

**Step 3: Write minimal implementation**

Create `hammerspoon/reconnect_decision.lua`:

```lua
-- Pure decision for the walk-back auto-reconnect (no hs.* deps, so it's unit-testable).
-- Reconnect the Mac iff: the user just returned after a real absence (gap >= idleGap),
-- the headphones are NOT currently connected to the Mac, and the Mac was the last
-- active source (flag set — so we never steal audio off the phone).
-- @param gap       number  seconds of inactivity that just ended
-- @param idleGap   number  threshold that counts as "walked away"
-- @param connected boolean blueutil --is-connected result (channel-free)
-- @param flagSet   boolean last-active-mac flag present
return function(gap, idleGap, connected, flagSet)
  return gap >= idleGap and not connected and flagSet
end
```

**Step 4: Run to verify it passes**

Run: `cd hammerspoon && lua reconnect_decision_test.lua`
Expected: 4 `ok -` lines + `all passed`, exit 0.

**Step 5: Commit**

```bash
git add hammerspoon/reconnect_decision.lua hammerspoon/reconnect_decision_test.lua
git commit -m "feat: pure walk-back reconnect decision + test"
```

---

### Task 4: Wire the walk-back watcher into bose.lua

**Files:**
- Modify: `hammerspoon/bose.lua` — config block (~:73), new watcher functions (near `connectHere` ~:244), `M.start` (:290), `M.stop` (:311)

**Step 1: Add config constants**

After the `CONNECT_*` block (`hammerspoon/bose.lua:75`), add:

```lua
-- ── Walk-back auto-reconnect ────────────────────────────────────────────────────
-- When input resumes after ≥ WALKBACK_IDLE_GAP seconds of inactivity (you left the
-- desk and came back) AND the headphones have dropped off the Mac AND the Mac was
-- your last active source (the ~/.config/bose/last-active-mac flag the CLI writes),
-- reconnect the Mac. Event-driven (hs.eventtap) — NO headphone polling, NO RFCOMM
-- probe to decide (uses blueutil --is-connected, which is channel-free). Multipoint
-- stays on. This is the deliberate, safe successor to the removed #61/#62 timer.
local WALKBACK_ENABLED    = true
local WALKBACK_IDLE_GAP   = 150   -- s of inactivity that counts as "walked away"
local WALKBACK_COOLDOWN   = 30    -- s: don't re-fire connect within this window
local HEADPHONE_MAC       = "E4:58:BC:C0:2F:72"
local BLUEUTIL            = "/opt/homebrew/bin/blueutil"
local FLAG_PATH           = os.getenv("HOME") .. "/.config/bose/last-active-mac"
```

**Step 2: Add the watcher functions** (after `connectHere`, ~`hammerspoon/bose.lua:255`)

```lua
-- Load the pure decision (co-located with this file).
local decideReconnect = dofile(hs.configdir and (os.getenv("HOME") .. "/code/personal/bose/hammerspoon/reconnect_decision.lua")
                               or "reconnect_decision.lua")

local walkbackLastActivity = hs.timer.secondsSinceEpoch()
local walkbackLastFire      = -math.huge

local function flagSet()
  local f = io.open(FLAG_PATH, "r")
  if f then f:close(); return true end
  return false
end

-- Async: query blueutil --is-connected (channel-free), then decide + maybe connect.
local function maybeReconnect(gap)
  hs.task.new(BLUEUTIL, function(code, stdout)
    local connected = (stdout or ""):match("1") ~= nil
    if decideReconnect(gap, WALKBACK_IDLE_GAP, connected, flagSet()) then
      walkbackLastFire = hs.timer.secondsSinceEpoch()
      connectHere()   -- reuse the existing gated connect + setMacOutput
    end
  end, { "--is-connected", HEADPHONE_MAC }):start()
end

-- Event-driven "resumed activity after a gap" detector. Discrete events only
-- (keyDown / mouse down / scroll) — NOT mouseMoved, to stay cheap.
local function onWalkbackActivity()
  local now = hs.timer.secondsSinceEpoch()
  local gap = now - walkbackLastActivity
  walkbackLastActivity = now
  if gap >= WALKBACK_IDLE_GAP and (now - walkbackLastFire) >= WALKBACK_COOLDOWN then
    maybeReconnect(gap)
  end
  return false   -- never swallow the event
end
```

> NOTE on the `dofile` path: match the repo's existing convention — `init.lua` already loads `bose.lua` by absolute repo path (`~/code/personal/bose/hammerspoon/bose.lua`). Use the same absolute path for `reconnect_decision.lua` so it resolves regardless of cwd. Simplify Step 2's first line to:
> ```lua
> local decideReconnect = dofile(os.getenv("HOME") .. "/code/personal/bose/hammerspoon/reconnect_decision.lua")
> ```

**Step 3: Start/stop the eventtap**

In `M.start()` (after the `AUTO_ROUTE_ON_CALL` block, before `return M`):

```lua
  if WALKBACK_ENABLED then
    M.walkbackTap = hs.eventtap.new(
      { hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,
        hs.eventtap.event.types.scrollWheel },
      onWalkbackActivity)
    M.walkbackTap:start()
  end
```

In `M.stop()`:

```lua
  if M.walkbackTap then M.walkbackTap:stop(); M.walkbackTap = nil end
```

**Step 4: Reload Hammerspoon and verify it loads clean**

Run: `hs -c "BoseCtl.stop(); BoseCtl.start(); print('walkback tap: ' .. tostring(BoseCtl.walkbackTap ~= nil))"`
Expected: prints `walkback tap: true`, no Lua errors in the Hammerspoon console.

> If `hs` CLI isn't on PATH: `open -g hammerspoon://` reload, then check the Hammerspoon console (Cmd-Alt-C style) for errors. Do NOT steal focus — use `hs -c` if available.

**Step 5: Commit**

```bash
git add hammerspoon/bose.lua
git commit -m "feat: walk-back auto-reconnect watcher (event-driven, gated)"
```

---

### Task 5: Manual acceptance test + docs

**Files:**
- Modify: `CLAUDE.md` (the macOS/Hammerspoon section + the "No auto-reconnect" note at `:404`)

**Step 1: Live acceptance test** (needs the headphones)

With multipoint on and the Mac as the active source:
1. Confirm the flag is set: `ls ~/.config/bose/last-active-mac` (run `bose connect mac` first if not).
2. Walk out of Bluetooth range until `blueutil --is-connected E4:58:BC:C0:2F:72` returns `0`.
3. Return, wait past the idle gap, touch the keyboard.
4. Expected: within a couple of seconds the Mac reconnects and audio routes to the headphones.
5. Negative test: `bose connect phone` (clears the flag), walk away/back → Mac does **NOT** grab audio.

Record the result (pass/fail + any timing) in the PR description.

**Step 2: Update CLAUDE.md**

Amend the "**No auto-reconnect from either platform**" note (`CLAUDE.md:404`) to carve out this event-driven, gated exception, and add a bullet under the Hammerspoon section describing `walkbackTap` + `WALKBACK_*` tunables + the `~/.config/bose/last-active-mac` flag + why it does NOT reintroduce #61/#62 (never probes RFCOMM to decide; gated on last-active-mac). Keep it factual and short.

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document walk-back auto-reconnect watcher + flag"
```

---

## Done criteria

- `cd cli && ./run-tests.sh` passes (incl. new flag tests).
- `cd hammerspoon && lua reconnect_decision_test.lua` passes.
- Hammerspoon loads with `walkbackTap` active, no console errors.
- Live: returning to the desk reconnects the Mac when it was last source; does nothing when it wasn't.
- CLAUDE.md documents the watcher, the flag, and why it's #61/#62-safe.
- Multipoint untouched; no LaunchAgent / resident poller added.
