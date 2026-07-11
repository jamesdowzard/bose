-- Pure decision for the walk-back auto-reconnect (no hs.* deps, so it's unit-testable).
-- Reconnect the Mac iff ALL of these hold:
--   * the user just returned after a real absence           (gap >= idleGap)
--   * the headphones are NOT currently connected to the Mac (not connected)
--   * the Mac was the last active source                    (flagSet)
--   * that "last active" signal is still FRESH              (flagAge < flagTtl)
--
-- The freshness gate (flagAge < flagTtl) exists because the last-active-mac flag is
-- written ONLY by the Mac `bose` CLI. A source switch made on the PHONE side (Android
-- BoseControl app / QS tile / headphone button) sends BMAP directly and never touches the
-- Mac flag, so it can go stale-set: you were on the Mac, switched to the phone from the
-- phone, and the Mac flag still says "Mac". Without the TTL a later walk-back would fire
-- `connect mac` and STEAL audio off the phone — the one thing this feature must never do
-- (#139 finding #1). The TTL NARROWS that hole to switches made within flagTtl of the last
-- Mac connect; it cannot fully CLOSE it (a same-session phone-switch leaves a still-fresh
-- flag). See bose.lua WALKBACK_FLAG_TTL for the tradeoff behind the chosen value.
-- @param gap       number  seconds of inactivity that just ended
-- @param idleGap   number  threshold that counts as "walked away"
-- @param connected boolean blueutil --is-connected result (channel-free)
-- @param flagSet   boolean last-active-mac flag present
-- @param flagAge   number  seconds since the flag was last written (its mtime); math.huge if absent
-- @param flagTtl   number  max flag age still trusted as "the Mac was last active"
return function(gap, idleGap, connected, flagSet, flagAge, flagTtl)
  return gap >= idleGap
     and not connected
     and flagSet
     and flagAge < flagTtl
end
