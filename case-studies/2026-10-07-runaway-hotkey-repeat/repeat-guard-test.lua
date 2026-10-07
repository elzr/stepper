-- Regression test for stepper's guarded key repeat (bindWithRepeat).
-- Binds a throwaway F20 hotkey through the real bindWithRepeat with a counting
-- operation (no windows touched), drives it with synthetic F20 key events, and
-- fakes the physical modifier state by swapping hs.eventtap.checkKeyboardModifiers.
--
-- Run:   hs -c 'return dofile("<this file>")'
-- Read:  hs -c 'return table.concat(_G.rgt.log, "\n")'   (after ~17 s)
-- Then check the console for exactly two "[stepper] lost key-up" lines (S2, S4).
--
-- S1 normal hold, fn held, key-up arrives        → repeats, then stops at key-up
-- S2 key-up lost, fn released mid-hold           → stops within one tick, logs lost key-up
-- S3 fn released 20 ms before the key-up         → stops, no lost key-up log
-- S4 key-up lost, nothing to check (no mods)     → stops at the 5 s cap, logs lost key-up

local t0 = hs.timer.secondsSinceEpoch()
local realCheck = hs.eventtap.checkKeyboardModifiers
_G.rgt = {log = {}, calls = 0, fake = nil, timers = {}}

local function L(s)
  table.insert(_G.rgt.log, string.format("%5.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end

hs.eventtap.checkKeyboardModifiers = function(...)
  if _G.rgt.fake then return _G.rgt.fake end
  return realCheck(...)
end

_G.rgt.hk = _G._stepper.bindWithRepeat({}, "f20", function() _G.rgt.calls = _G.rgt.calls + 1 end)

local function post(down)
  return function()
    hs.eventtap.event.newKeyEvent({}, "f20", down):post()
    L(down and "F20 down" or "F20 up")
  end
end
local function fake(mods, label)
  return function() _G.rgt.fake = mods; L("modifiers now " .. label) end
end
local function snap(label)
  return function() L(string.format("%-22s calls=%d", label, _G.rgt.calls)) end
end

local plan = {
  -- S1
  {0.00, fake({fn = true}, "{fn}")},
  {0.05, post(true)},
  {0.85, post(false)},
  {0.95, snap("S1 after key-up")}, {1.45, snap("S1 +0.5s")},
  -- S2
  {2.00, post(true)},
  {2.60, fake({}, "{} (fn released, no key-up)")},
  {2.80, snap("S2 after fn release")}, {3.30, snap("S2 +0.5s")},
  {5.00, post(false)},                       -- the key-up finally (after the 2 s check)
  -- S3
  {6.00, fake({fn = true}, "{fn}")},
  {6.05, post(true)},
  {6.65, fake({}, "{} (fn released first)")},
  {6.67, post(false)},
  {6.90, snap("S3 after key-up")}, {7.40, snap("S3 +0.5s")},
  -- S4
  {8.00, fake({}, "{} (no modifiers at press)")},
  {8.05, post(true)},
  {12.50, snap("S4 at 4.45s")},
  {13.30, snap("S4 at 5.25s")}, {13.80, snap("S4 at 5.75s")},
  {15.60, post(false)},                      -- after the 2 s check fired at ~15.1
  -- cleanup
  {16.00, function()
    _G.rgt.hk:delete()
    hs.eventtap.checkKeyboardModifiers = realCheck
    _G.rgt.fake = nil
    L("done: test hotkey deleted, checkKeyboardModifiers restored")
  end},
}
for _, step in ipairs(plan) do
  table.insert(_G.rgt.timers, hs.timer.doAfter(step[1], step[2]))
end
return "repeat-guard test scheduled (~16 s)"
