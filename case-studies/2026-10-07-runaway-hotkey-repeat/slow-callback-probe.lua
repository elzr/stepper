-- Probe (Hammerspoon issue #3589): does Hammerspoon's built-in key repeat keep
-- running after the key-up when each repeat callback takes longer than the
-- repeat interval (33 ms)? Stepper's callbacks are AX calls, which get slow when
-- apps are sluggish — e.g. right after wake. Uses the OLD stepper pattern
-- (Hammerspoon's repeatfn) on a throwaway F20 hotkey; no window is moved.
--
-- Run:   hs -c 'return dofile("<this file>")'
-- Read:  hs -c 'return table.concat(_G.sc.log, "\n")'   (after ~3 s)

local t0 = hs.timer.secondsSinceEpoch()
_G.sc = {log = {}, rep = 0, timers = {}}
local function L(s)
  table.insert(_G.sc.log, string.format("%5.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end

_G.sc.hk = hs.hotkey.new({}, "f20",
  function() L("press") end,
  function() L("release callback (repeats so far: " .. _G.sc.rep .. ")") end,
  function()
    _G.sc.rep = _G.sc.rep + 1
    hs.timer.usleep(80000)  -- an 80 ms callback, like a slow AX round trip
  end):enable()

local plan = {
  {0.10, function() hs.eventtap.event.newKeyEvent({}, "f20", true):post(); L("posted F20 down") end},
  {0.70, function() hs.eventtap.event.newKeyEvent({}, "f20", false):post(); L("posted F20 up (repeats: " .. _G.sc.rep .. ")") end},
  {1.20, function() L("repeats 0.5 s after key-up: " .. _G.sc.rep) end},
  {1.70, function() L("repeats 1.0 s after key-up: " .. _G.sc.rep) end},
  {2.20, function() _G.sc.hk:delete(); L("probe hotkey deleted (stops any runaway)") end},
}
for _, step in ipairs(plan) do
  table.insert(_G.sc.timers, hs.timer.doAfter(step[1], step[2]))
end
return "slow-callback probe scheduled (~2.5 s)"
