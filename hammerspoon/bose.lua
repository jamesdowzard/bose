-- bose.lua — Opt+B toggles the Bose QC Ultra between Mac and phone.
--
-- Direction is decided from the Mac's current default OUTPUT device (no need to
-- query the headphones over Bluetooth): if the Bose is the Mac's output, the next
-- press sends audio to the phone; otherwise it brings the headphones to the Mac.
-- Routing runs via `bose-ctl` (the on-demand RFCOMM CLI) as an async hs.task so it
-- never blocks Hammerspoon. A brief alert confirms where audio went.
--
-- Install: this file lives in ~/.hammerspoon/modules/. Wire it in init.lua:
--     Bose = require("bose")
--     Bose.start()

local M = {}

-- Config ---------------------------------------------------------------------
local CTL          = os.getenv("HOME") .. "/bin/bose-ctl"
local BOSE_NAME    = "verBosita"             -- macOS output-device name when on the Mac
local MAC_SPEAKERS = "MacBook Pro Speakers"  -- Mac audio falls back here after "→ phone"
local HOTKEY_MODS  = { "alt" }
local HOTKEY_KEY   = "b"
local TO_MAC       = "mac"                    -- the two favourites this hotkey flips between
local TO_PHONE     = "phone"
-------------------------------------------------------------------------------

local function boseIsMacOutput()
  local out = hs.audiodevice.defaultOutputDevice()
  return out ~= nil and out:name():find(BOSE_NAME, 1, true) ~= nil
end

local function setMacOutput(name)
  local dev = hs.audiodevice.findOutputByName(name)
  if dev then dev:setDefaultOutputDevice() end
end

local function ctl(args, done)
  hs.task.new(CTL, function(code) if done then done(code == 0) end end, args):start()
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
end

function M.start()
  M.hotkey = hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, toggle)
  return M
end

function M.stop()
  if M.hotkey then M.hotkey:delete(); M.hotkey = nil end
end

return M
