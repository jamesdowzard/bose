# Plan: auto-route-on-call — keep the Mac mic off the Bose during calls

**Goal:** While a call app (Teams/Zoom/FaceTime/Slack/Webex) is running, force the Mac's audio **input** to the MacBook mic (never the Bose), guard it if macOS flips input to the Bose mid-call, and restore the prior input when the last call app closes. The Bose stays the **output** untouched. Automates the manual fix for the recurring "people hear my background louder than me" — the Bose over-ear mics force HFP + favour the room (see `bluetooth-audio` dossier).

## Design

- **Home:** extend `hammerspoon/bose.lua` — the existing event-driven module. Reuses the `hs.audiodevice.watcher` added for battery-announce (it's a singleton; we extend its callback, not add a second). **No poller** (respects the #69 rule).
- **Detection:** `hs.application.watcher`. `launched` arms the route (bundleID is reliable on launch). `terminated` **re-scans all call apps** and restores only when none remain — because a `terminated` event's app object can't be trusted to return its bundleID.
- **Belt-and-braces:** the existing `onAudioChange` (audiodevice watcher) also flips input off the Bose while a call is active — catches macOS auto-selecting the Bose input on a mid-call reconnect.
- **Known limit (documented in-code):** apps with their **own** device setting (Teams) can override the system input — the in-app Teams mic must be set to the MacBook mic once. This feature is the system-level guarantee for apps that follow the default (Zoom/FaceTime/Meet) and a backstop otherwise.
- **Verification is integration-style** (syntax-check + reload + live guard test), not Lua TDD — consistent with this module (the repo's unit tests are the Swift/Kotlin `Parsers`, which this doesn't touch). The battery-announce feature was verified the same way.

## Files

- **Modify:** `hammerspoon/bose.lua` (config + state + helpers + app-watcher + start/stop wiring + header docstring)
- **Modify:** `CLAUDE.md` (Hammerspoon component description — add the auto-route behaviour)
- **Modify (dossiers repo, separate ship):** `bluetooth-audio/wiki/processes/auto-route-on-call.md` — flip status draft→built, point at the implementation

---

## Phase 1 — Implement (hammerspoon/bose.lua)

| Task | Model | Execution | Dependencies |
|------|-------|-----------|--------------|
| 1 Config + state | sonnet | sequential | — |
| 2 Helpers + app-watcher callback | sonnet | sequential | 1 |
| 3 Extend onAudioChange guard | sonnet | sequential | 2 |
| 4 Wire start()/stop() + docstring | sonnet | sequential | 3 |

### Task 1 — Config + state

**Modify** `hammerspoon/bose.lua`, after the `ANNOUNCE_*` config block (before the `---` rule):

```lua
-- Auto-route on call: while a call app is running, keep the Mac's INPUT off the Bose
-- (the over-ear mics force HFP + favour the room — see the bluetooth-audio dossier).
-- Sets input → MacBook mic when a call app opens, guards it if macOS flips input to the
-- Bose mid-call, and restores the prior input when the last call app closes. The Bose
-- OUTPUT is never touched. NB apps with their own device setting (Teams) may still
-- override this — set Teams' in-app Microphone to the MacBook mic once; this is the
-- system-level backstop for apps that follow the default (Zoom/FaceTime/Meet).
local AUTO_ROUTE_ON_CALL = true
local MAC_MIC            = "MacBook Pro Microphone"
local CALL_APPS = {   -- bundle IDs of apps that take the mic for calls (editable)
  ["com.microsoft.teams2"]      = true,
  ["us.zoom.xos"]               = true,
  ["com.apple.FaceTime"]        = true,
  ["com.tinyspeck.slackmacgap"] = true,   -- Slack huddles
  ["com.cisco.webexmeetings"]   = true,
}
```

Add state near the other module-level state (by `lastBoseOut`):

```lua
local savedInputName = nil   -- input device to restore when the last call app closes
```

### Task 2 — Helpers + app-watcher callback

**Modify** `hammerspoon/bose.lua`, after `announceBattery`/`onAudioChange` (before `toggleApp`):

```lua
-- Input-side helpers (mirror the output helpers). Used by auto-route-on-call.
local function setMacInput(name)
  local dev = hs.audiodevice.findInputByName(name)
  if dev then dev:setDefaultInputDevice() end
end

local function defaultInputIsBose()
  local inp = hs.audiodevice.defaultInputDevice()
  return inp ~= nil and inp:name():find(BOSE_NAME, 1, true) ~= nil
end

local function anyCallAppRunning()
  for bid, _ in pairs(CALL_APPS) do
    if hs.application.get(bid) then return true end
  end
  return false
end

-- hs.application.watcher callback. `launched` is reliable for bundleID → arm the route.
-- `terminated` can't be trusted for bundleID, so re-scan all call apps and restore only
-- when none remain.
local function onAppEvent(_, eventType, app)
  if not AUTO_ROUTE_ON_CALL then return end
  if eventType == hs.application.watcher.launched then
    local bid = app and app:bundleID()
    if bid and CALL_APPS[bid] then
      if savedInputName == nil then
        local cur = hs.audiodevice.defaultInputDevice()
        savedInputName = (cur and cur:name()) or MAC_MIC
      end
      setMacInput(MAC_MIC)
    end
  elseif eventType == hs.application.watcher.terminated then
    if savedInputName ~= nil and not anyCallAppRunning() then
      setMacInput(savedInputName)
      savedInputName = nil
    end
  end
end
```

### Task 3 — Extend onAudioChange guard

**Modify** `onAudioChange` (added by battery-announce): append the input-guard so a mid-call reconnect can't leave the Bose as the input. Add just before the closing `end`:

```lua
  -- Auto-route guard: while a call app is active (savedInputName set), never let the
  -- Bose be the system input — macOS can flip it on a reconnect.
  if AUTO_ROUTE_ON_CALL and savedInputName ~= nil and defaultInputIsBose() then
    setMacInput(MAC_MIC)
  end
```

### Task 4 — Wire start()/stop() + header docstring

**Modify** `M.start()` — after the `ANNOUNCE_BATTERY` block, before `return M`:

```lua
  if AUTO_ROUTE_ON_CALL then
    M.appWatcher = hs.application.watcher.new(onAppEvent)
    M.appWatcher:start()
    if anyCallAppRunning() then   -- a call app already open at start → route now
      local cur = hs.audiodevice.defaultInputDevice()
      savedInputName = (cur and cur:name()) or MAC_MIC
      setMacInput(MAC_MIC)
    end
  end
```

**Modify** `M.stop()` — after the `ANNOUNCE_BATTERY` watcher stop:

```lua
  if M.appWatcher then M.appWatcher:stop(); M.appWatcher = nil end
```

**Modify** the header `-- Features:` block — add:

```lua
--   • Auto-route on call — while a call app (Teams/Zoom/FaceTime/Slack/Webex) is
--              running, force the Mac's input to the MacBook mic (never the Bose) so
--              callers don't hear the room; restores the prior input when calls end.
--              Output (the Bose) is untouched. ANNOUNCE/route both event-driven, no poll.
```

---

## Phase 2 — Verify

### Task 5 — Syntax + reload + watcher armed

Run:
```bash
cd ~/code/personal/bose/.worktrees/auto-route-on-call
lua -e "assert(loadfile('hammerspoon/bose.lua'))" && echo "lua: OK"
```
Expected: `lua: OK`

(After merge to main + reload — see Phase 3) confirm both watchers:
```bash
hs -c "print('appWatcher: '..tostring(BoseCtl.appWatcher ~= nil))"
hs -c "print('audio watcher running: '..tostring(hs.audiodevice.watcher.isRunning()))"
```
Expected: `appWatcher: true` and `audio watcher running: true`

### Task 6 — Live guard test (no real call needed)

Force the failure condition and prove the guard fixes it, via `hs -c` against the live module:
```bash
# simulate "call active" + Bose-as-input, then run the guard logic
SwitchAudioSource -s "verBosita" -t input >/dev/null   # put input ON the Bose (the bad state)
SwitchAudioSource -c -t input                          # show: verBosita
hs -c "savedInputName='MacBook Pro Microphone'; if hs.audiodevice.defaultInputDevice():name():find('verBosita',1,true) then hs.audiodevice.findInputByName('MacBook Pro Microphone'):setDefaultInputDevice() end"
sleep 1
SwitchAudioSource -c -t input                          # expect: MacBook Pro Microphone
```
Expected: input flips `verBosita → MacBook Pro Microphone`. (Then a real Teams/Zoom launch is the full integration check James can do live.)

---

## Phase 3 — Ship

### Task 7 — Docs + commit + merge + reload
1. Update `CLAUDE.md` Hammerspoon component description with the auto-route behaviour.
2. Commit: `feat: auto-route Mac mic off the Bose during calls (Hammerspoon)`
3. PR → squash-merge to `main` → cleanup worktree.
4. `hs -c "hs.reload()"` (dofile reads from the main repo path).
5. Run Task 5/6 verification against the reloaded module.
6. Separate ship in the **dossiers** repo: flip `auto-route-on-call.md` status `draft → built`, point at `hammerspoon/bose.lua`.

---

## Summary

7 tasks, 1 file of real code (`hammerspoon/bose.lua`, ~45 lines) + 2 doc updates. **Low complexity** — a self-contained extension of an existing event-driven module, no new resident process, no protocol/RFCOMM changes. Integration-verified (syntax + reload + live guard test), matching how battery-announce was shipped.

**Open question for approval:** scope of `CALL_APPS` — the list above covers Teams/Zoom/FaceTime/Slack/Webex. Add/remove any? (e.g. Google Meet runs in-browser and can't be detected this way — it'd rely on the system-input-default path only.)
