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
