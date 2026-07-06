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
