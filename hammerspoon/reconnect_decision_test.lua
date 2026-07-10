-- Run: lua hammerspoon/reconnect_decision_test.lua   (exits non-zero on failure)
local decide = require("reconnect_decision")

local function eq(got, want, msg)
  if got ~= want then error(string.format("FAIL %s: got %s want %s", msg, tostring(got), tostring(want)))
  else print("ok   - " .. msg) end
end

local IDLE  = 150
local TTL   = 8 * 3600     -- mirrors WALKBACK_FLAG_TTL in bose.lua
local FRESH = 60           -- flag written a minute ago (Mac genuinely last active)
local STALE = TTL + 60     -- flag older than the TTL (possible phone-side switch since)

-- gap below idle threshold → never reconnect (just a brief pause at the desk)
eq(decide(10,  IDLE, false, true,  FRESH,     TTL), false, "short gap → no")
-- long gap, but already connected → no (link never dropped)
eq(decide(300, IDLE, true,  true,  FRESH,     TTL), false, "connected → no")
-- long gap, disconnected, flag NOT set (was on phone) → no
eq(decide(300, IDLE, false, false, math.huge, TTL), false, "flag unset → no")
-- long gap, disconnected, flag set AND fresh → YES (the walk-back case)
eq(decide(300, IDLE, false, true,  FRESH,     TTL), true,  "fresh walk-back → yes")
-- long gap, disconnected, flag set but STALE → no (phone-switch guard: never steal audio)
eq(decide(300, IDLE, false, true,  STALE,     TTL), false, "stale flag → no (phone-switch guard)")
-- boundary: age exactly at the TTL counts as expired (strict <)
eq(decide(300, IDLE, false, true,  TTL,       TTL), false, "flag age == TTL → no (boundary)")
-- boundary: age one second under the TTL still fires
eq(decide(300, IDLE, false, true,  TTL - 1,   TTL), true,  "flag age just under TTL → yes")
print("all passed")
