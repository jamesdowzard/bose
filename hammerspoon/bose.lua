-- bose.lua — Hammerspoon control for the Bose QC Ultra (on-demand, never polled).
--
-- Everything here is EVENT-DRIVEN: a keypress or an OS event triggers one async
-- `bose-ctl` call (the on-demand RFCOMM CLI). Nothing runs on a timer — a resident
-- poller was the original audio-dropout cause, so this module must never introduce one.
--
-- Features:
--   • Opt+B  — toggle audio between Mac and phone (direction from Mac's output device).
--              On the way, reads battery and warns if low (piggybacks the keypress;
--              no separate poll loop).
--   • Opt+N  — cycle ANC mode quiet → aware → custom1.
--   • Opt+J  — unconditionally bring the headphones to THIS Mac (connect + route
--              audio here). Unlike Opt+B, never guesses direction from the current
--              output device — it always connects the Mac.
--   • App hook — when a call app LAUNCHES (Teams/Zoom/Meet), switch ANC to aware so
--                you can hear yourself. Fires once on launch, not on every focus.
--
-- Wiring (init.lua dofiles this from the repo path; reload Hammerspoon to apply edits):
--     BoseCtl = dofile(os.getenv("HOME").."/code/personal/bose/hammerspoon/bose.lua")
--     BoseCtl.start()

local M = {}

-- Config ---------------------------------------------------------------------
local CTL          = os.getenv("HOME") .. "/bin/bose-ctl"
local BOSE_NAME    = "verBosita"             -- macOS output-device name when on the Mac
local MAC_SPEAKERS = "MacBook Pro Speakers"  -- Mac audio falls back here after "→ phone"
local HOTKEY_MODS  = { "alt" }
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

-- Apps whose LAUNCH should switch ANC to aware (so you hear your own voice on calls).
-- Keys are hs.application names; adjust to taste.
local AWARE_ON_LAUNCH = {
  ["Microsoft Teams"]      = true,
  ["Microsoft Teams (work or school)"] = true,
  ["zoom.us"]              = true,
  ["Google Meet"]          = true,
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

-- Fire-and-forget bose-ctl (exit code only).
local function ctl(args, done)
  hs.task.new(CTL, function(code) if done then done(code == 0) end end, args):start()
end

-- bose-ctl with stdout captured (for reads like battery / anc).
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

-- App-launch watcher: switch ANC to aware when a call app starts.
local function onAppEvent(name, event)
  if event == hs.application.watcher.launched and name and AWARE_ON_LAUNCH[name] then
    ctl({ "anc", "aware" }, function(ok)
      if ok then hs.alert.show("🎧  " .. name .. " → ANC aware") end
    end)
  end
end

function M.start()
  M.hotkey = hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, toggle)
  M.ancHotkey = hs.hotkey.bind(ANC_MODS, ANC_KEY, cycleAnc)
  M.connectHotkey = hs.hotkey.bind(CONNECT_MODS, CONNECT_KEY, connectHere)
  M.appWatcher = hs.application.watcher.new(onAppEvent)
  M.appWatcher:start()
  return M
end

function M.stop()
  if M.hotkey then M.hotkey:delete(); M.hotkey = nil end
  if M.ancHotkey then M.ancHotkey:delete(); M.ancHotkey = nil end
  if M.connectHotkey then M.connectHotkey:delete(); M.connectHotkey = nil end
  if M.appWatcher then M.appWatcher:stop(); M.appWatcher = nil end
end

return M
