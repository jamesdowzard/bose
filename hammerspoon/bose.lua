-- bose.lua — Hammerspoon control for the Bose QC Ultra (on-demand, never polled).
--
-- Everything here is EVENT-DRIVEN: a keypress or an OS event triggers one async
-- `bose` call (the on-demand RFCOMM CLI). Nothing runs on a timer — a resident
-- poller was the original audio-dropout cause, so this module must never introduce one.
--
-- Features:
--   • Opt+B  — show/hide the Bose app, the windowed control surface (press once
--              to open/focus, again to hide). Switch devices/ANC/EQ from its tiles.
--   • Opt+⇧B — no-look toggle of audio between Mac and phone (direction from Mac's
--              output device). The former Opt+B; kept as a fallback to the app. On the
--              way, reads battery and warns if low (piggybacks the keypress; no poll).
--   • Opt+N  — cycle ANC mode quiet → aware → custom1.
--   • Opt+J  — unconditionally bring the headphones to THIS Mac (connect + route
--              audio here). Unlike Opt+⇧B, never guesses direction from the current
--              output device — it always connects the Mac.
--   • Battery announce — when the Bose become the Mac's audio output (auto on
--              power-on, Opt+J, or the toggle), speak the battery level through them.
--              An event-driven replacement for the power-on announcement Bose removed
--              in fw 8.2.20. Driven by hs.audiodevice change events — no poller.
--              Set ANNOUNCE_BATTERY=false to disable.
--   • Auto-route on call — while a call app (Teams/Zoom/FaceTime/Slack/Webex) runs,
--              force the Mac's INPUT to the MacBook mic (never the Bose, whose over-ear
--              mics make callers hear the room); restore the prior input when calls end.
--              Output (the Bose) is untouched. Event-driven (hs.application.watcher +
--              the audiodevice watcher), no poll. Set AUTO_ROUTE_ON_CALL=false to disable.
--
-- Wiring (init.lua dofiles this from the repo path; reload Hammerspoon to apply edits):
--     BoseCtl = dofile(os.getenv("HOME").."/code/personal/bose/hammerspoon/bose.lua")
--     BoseCtl.start()

local M = {}

-- Config ---------------------------------------------------------------------
local CTL          = os.getenv("HOME") .. "/bin/bose"
local BOSE_NAME    = "verBosita"             -- macOS output-device name when on the Mac
local MAC_SPEAKERS = "MacBook Pro Speakers"  -- Mac audio falls back here after "→ phone"

-- Open the windowed app (Opt+B): the primary control surface now that its device
-- tiles do live connect/switch with a pending → connected state.
local OPEN_MODS    = { "alt" }
local OPEN_KEY     = "b"
-- Match by bundle ID, not display name: the .app's CFBundleName is "Bose" (not
-- "Bose Control"), so hs.application.get("Bose Control") returns nil and the toggle
-- could never find the running app to hide it. The bundle ID is unambiguous.
local APP_BUNDLE_ID = "com.jamesdowzard.bose-control"

-- No-look Mac↔phone toggle, moved to Opt+⇧B (was Opt+B). Kept as a fallback to the app.
local HOTKEY_MODS  = { "alt", "shift" }
local HOTKEY_KEY   = "b"
local TO_MAC       = "mac"                    -- the two favourites the toggle flips between
local TO_PHONE     = "phone"

-- ANC cycle (Opt+N). Rebind freely — these are personal-config defaults.
local ANC_MODS     = { "alt" }
local ANC_KEY      = "n"
local ANC_CYCLE    = { "quiet", "aware", "immersion" }

-- Connect hotkey (Opt+J): always bring the headphones to THIS Mac, no toggle
-- guessing. `connect mac` does the A2DP bring-up + BMAP route + poll-confirm.
-- Change CONNECT_TARGET to route the key at a different device (must be a name
-- in devices.toml's device map, e.g. "mac"/"quest"/"ipad").
local CONNECT_MODS   = { "alt" }
local CONNECT_KEY    = "j"
local CONNECT_TARGET = "mac"

-- Low-battery warning threshold (%), checked on each toggle (no separate poll).
local LOW_BATTERY  = 20

-- Speak the battery level when the headphones become this Mac's audio output — an
-- event-driven stand-in for the power-on battery announcement Bose removed in fw
-- 8.2.20 (see docs/related-projects.md: the native announcement can't be restored —
-- firmware-locked; the `01,09` button BatteryLevel action isn't supported on the
-- over-ears; `01,03` voice-prompts can't be safely toggled). This fires on the rising
-- edge of "Bose is the default output" (auto on power-on, or via Opt+J / the toggle),
-- reads battery ONCE, and `say`s it through the headphones. Still no poller — driven
-- purely by hs.audiodevice change events.
local ANNOUNCE_BATTERY   = true
local ANNOUNCE_DELAY     = 1.8   -- s: let the A2DP route + RFCOMM settle before read/speak
local ANNOUNCE_COOLDOWN  = 10    -- s: ignore output flaps within this window

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
-------------------------------------------------------------------------------

local function boseIsMacOutput()
  local out = hs.audiodevice.defaultOutputDevice()
  return out ~= nil and out:name():find(BOSE_NAME, 1, true) ~= nil
end

local function setMacOutput(name)
  local dev = hs.audiodevice.findOutputByName(name)
  if dev then dev:setDefaultOutputDevice() end
end

-- Input-side helpers (mirror the output helpers above). Used by auto-route-on-call.
local function setMacInput(name)
  local dev = hs.audiodevice.findInputByName(name)
  if dev then dev:setDefaultInputDevice() end
end

local function defaultInputIsBose()
  local inp = hs.audiodevice.defaultInputDevice()
  return inp ~= nil and inp:name():find(BOSE_NAME, 1, true) ~= nil
end

-- Fire-and-forget bose (exit code only).
local function ctl(args, done)
  hs.task.new(CTL, function(code) if done then done(code == 0) end end, args):start()
end

-- bose with stdout captured (for reads like battery / anc).
local function ctlRead(args, done)
  hs.task.new(CTL, function(code, stdout) done(code == 0, stdout or "") end, args):start()
end

-- One on-demand battery read; warn if low. Triggered by the toggle keypress, so it's
-- a single brief RFCOMM open on an explicit action — not a background poll.
local function warnIfLowBattery()
  ctlRead({ "battery" }, function(ok, out)
    local pct = tonumber(out:match("(%d+)%%"))
    if ok and pct and pct <= LOW_BATTERY then
      hs.alert.show("🪫  Bose battery " .. pct .. "%")
    end
  end)
end

-- Speak battery when the Bose become the Mac's output (rising edge), via the
-- hs.audiodevice change watcher — event-driven, no timer/poll. The `say` plays
-- through the current default output, which is the Bose we just detected.
local lastBoseOut    = false
local lastAnnounce   = -math.huge
local savedInputName = nil   -- input device to restore when the last call app closes

local function announceBattery()
  ctlRead({ "battery" }, function(ok, out)
    local pct = out:match("(%d+)%%") or out:match("(%d+)")
    if ok and pct then
      hs.task.new("/usr/bin/say", nil, { "Bose, battery " .. pct .. " percent" }):start()
    end
  end)
end

-- Fired by hs.audiodevice.watcher on any audio-hardware/default-device change. We
-- re-evaluate "is the Bose the Mac output" and announce only on the false→true edge,
-- with a cooldown so a flapping route can't double-speak.
local function onAudioChange()
  local nowOut = boseIsMacOutput()
  if nowOut and not lastBoseOut then
    local t = hs.timer.secondsSinceEpoch()
    if (t - lastAnnounce) >= ANNOUNCE_COOLDOWN then
      lastAnnounce = t
      hs.timer.doAfter(ANNOUNCE_DELAY, announceBattery)
    end
  end
  lastBoseOut = nowOut
  -- Auto-route guard: while a call app is active (savedInputName set), never let the
  -- Bose be the system input — macOS can flip it on a mid-call reconnect.
  if AUTO_ROUTE_ON_CALL and savedInputName ~= nil and defaultInputIsBose() then
    setMacInput(MAC_MIC)
  end
end

-- True if any configured call app is currently running (by bundle ID).
local function anyCallAppRunning()
  for bid, _ in pairs(CALL_APPS) do
    if hs.application.get(bid) then return true end
  end
  return false
end

-- hs.application.watcher callback. `launched` is reliable for bundleID → arm the route
-- (remember the prior input, switch to the Mac mic). `terminated` can't be trusted for
-- bundleID, so re-scan all call apps and restore only when none remain.
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

-- Show/hide toggle for the windowed control app: press once to open/focus it, press
-- again (while it's frontmost) to hide it. Not running → launch it; running but behind
-- → bring it forward; running + frontmost → hide. So Opt+B both summons and dismisses.
local function toggleApp()
  local app = hs.application.get(APP_BUNDLE_ID)
  if app and app:isFrontmost() then
    app:hide()
  else
    hs.application.launchOrFocusByBundleID(APP_BUNDLE_ID)
  end
end

local function toggle()
  hs.alert.closeAll()
  if boseIsMacOutput() then
    -- Audio is on the Mac → push it to the phone.
    hs.alert.show("🎧  Bose → phone")
    ctl({ "connect", TO_PHONE })
    -- Take the Mac off the Bose so the next press flips back correctly.
    hs.timer.doAfter(1.0, function() setMacOutput(MAC_SPEAKERS) end)
  else
    -- Audio is elsewhere → bring the headphones to the Mac.
    hs.alert.show("🎧  Bose → Mac")
    ctl({ "connect", TO_MAC }, function(ok)
      if ok then
        hs.timer.doAfter(2.0, function() setMacOutput(BOSE_NAME) end)
      end
    end)
  end
  -- After the link settles, do a one-shot low-battery check (no polling).
  hs.timer.doAfter(2.5, warnIfLowBattery)
end

-- Unconditionally bring the headphones to this Mac (no toggle direction-guessing).
-- `connect <target>` does the A2DP bring-up + BMAP route + poll-confirm; on success
-- route the Mac's audio to the Bose so it shows Connected and audio lands here.
local function connectHere()
  hs.alert.closeAll()
  hs.alert.show("🎧  Bose → Mac")
  ctl({ "connect", CONNECT_TARGET }, function(ok)
    if ok then
      hs.timer.doAfter(2.0, function() setMacOutput(BOSE_NAME) end)
    else
      hs.alert.show("🎧  connect failed")
    end
  end)
end

-- Read current ANC, then set the next mode in the cycle.
local function cycleAnc()
  ctlRead({ "anc" }, function(_, out)
    local cur = out:match("ANC:%s*(%w+)")
    local nextMode = ANC_CYCLE[1]
    for i, m in ipairs(ANC_CYCLE) do
      if m == cur then nextMode = ANC_CYCLE[(i % #ANC_CYCLE) + 1]; break end
    end
    ctl({ "anc", nextMode }, function(ok)
      if ok then hs.alert.show("🎧  ANC → " .. nextMode) end
    end)
  end)
end

function M.start()
  M.openHotkey = hs.hotkey.bind(OPEN_MODS, OPEN_KEY, toggleApp)
  M.hotkey = hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, toggle)
  M.ancHotkey = hs.hotkey.bind(ANC_MODS, ANC_KEY, cycleAnc)
  M.connectHotkey = hs.hotkey.bind(CONNECT_MODS, CONNECT_KEY, connectHere)
  if ANNOUNCE_BATTERY then
    lastBoseOut = boseIsMacOutput()   -- seed so (re)starting doesn't announce
    hs.audiodevice.watcher.setCallback(onAudioChange)
    hs.audiodevice.watcher.start()
  end
  if AUTO_ROUTE_ON_CALL then
    M.appWatcher = hs.application.watcher.new(onAppEvent)
    M.appWatcher:start()
    if anyCallAppRunning() then   -- a call app already open at start → route now
      local cur = hs.audiodevice.defaultInputDevice()
      savedInputName = (cur and cur:name()) or MAC_MIC
      setMacInput(MAC_MIC)
    end
  end
  return M
end

function M.stop()
  if M.openHotkey then M.openHotkey:delete(); M.openHotkey = nil end
  if M.hotkey then M.hotkey:delete(); M.hotkey = nil end
  if M.ancHotkey then M.ancHotkey:delete(); M.ancHotkey = nil end
  if M.connectHotkey then M.connectHotkey:delete(); M.connectHotkey = nil end
  if ANNOUNCE_BATTERY then hs.audiodevice.watcher.stop() end
  if M.appWatcher then M.appWatcher:stop(); M.appWatcher = nil end
end

return M
