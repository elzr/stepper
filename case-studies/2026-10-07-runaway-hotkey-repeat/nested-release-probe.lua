-- Probe: can a hotkey's key-up be handled *inside* its own press callback while
-- that callback waits on a synchronous AX call? If so, Hammerspoon's built-in
-- repeat (hs.hotkey repeatfn) starts its timer after the release and never stops.
-- Uses the OLD stepper pattern (Hammerspoon's repeatfn) on a throwaway F20 hotkey
-- with a counting repeat function; no window is moved.
--
-- Run:   hs -c 'return dofile("<this file>")'
-- Read:  hs -c 'return table.concat(_G.nr.log, "\n")'   (after ~3 s)

local t0 = hs.timer.secondsSinceEpoch()
_G.nr = {log = {}, rep = 0, released = false, timers = {}}
local function L(s)
  table.insert(_G.nr.log, string.format("%5.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end

_G.nr.hk = hs.hotkey.new({}, "f20",
  function()
    L("press callback begins")
    -- The key-up, sent while this press callback is still running
    hs.eventtap.event.newKeyEvent({}, "f20", false):post()
    local t = hs.timer.secondsSinceEpoch()
    local n = #hs.window.orderedWindows()  -- synchronous AX across every app
    L(string.format("AX call done: %d windows in %.0f ms; key-up already handled? %s",
      n, (hs.timer.secondsSinceEpoch() - t) * 1000, tostring(_G.nr.released)))
  end,
  function() _G.nr.released = true; L("release callback") end,
  function() _G.nr.rep = _G.nr.rep + 1 end):enable()

local plan = {
  {0.10, function() hs.eventtap.event.newKeyEvent({}, "f20", true):post(); L("posted F20 down") end},
  {2.00, function() L("repeats so far: " .. _G.nr.rep) end},
  {2.50, function() L("repeats so far: " .. _G.nr.rep) end},
  {3.00, function() _G.nr.hk:delete(); L("probe hotkey deleted (stops any runaway)") end},
}
for _, step in ipairs(plan) do
  table.insert(_G.nr.timers, hs.timer.doAfter(step[1], step[2]))
end
return "nested-release probe scheduled (~3 s)"
