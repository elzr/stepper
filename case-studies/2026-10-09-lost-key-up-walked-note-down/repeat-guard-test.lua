-- Regression test for stepper's guarded key repeat (bindWithRepeat), 2026-10-09 version.
-- Binds throwaway F20 / ctrl+F20 hotkeys through the real bindWithRepeat with a counting
-- operation (no windows touched) and presses them with keypost (next to this file), whose
-- events go through the HID system like real keys, so inputprobe's hold watcher sees them.
-- S1, S4 and S5 fake the physical fn key by swapping hs.eventtap.checkKeyboardModifiers.
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.rgt2.log, "\n")'   (after ~26 s)
-- Then check the console for exactly one "[stepper] lost key-up" line (S2).
--
-- S1 normal hold, fn held, key-up arrives          → repeats, stops at the key-up
-- S2 the 2026-10-09 loss for real: ctrl lifts before
--    the key while the first call is busy for 2 s   → no repeat (keyboard let go), one
--                                                      lost key-up report, closed with a
--                                                      synthetic key-up
-- S3 the next ctrl+F20 press                        → works (S2's hotkey was closed)
-- S4 held 8 s, past the 5 s cap                     → stops at 5 s, no report (still held)
-- S5 fn released mid-hold, key-up 0.9 s later      → stops within one tick, no report

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local F20, CTRL = 90, 59

local t0 = hs.timer.secondsSinceEpoch()
local realCheck = hs.eventtap.checkKeyboardModifiers
_G.rgt2 = {log = {}, calls = 0, fake = nil, slow = false, timers = {}, tasks = {}}

local function L(s)
  table.insert(_G.rgt2.log, string.format("%5.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.rgt2.timers, hs.timer.doAfter(seconds, fn)) end

hs.eventtap.checkKeyboardModifiers = function(...)
  if _G.rgt2.fake then return _G.rgt2.fake end
  return realCheck(...)
end

local function count()
  _G.rgt2.calls = _G.rgt2.calls + 1
  if _G.rgt2.slow then
    _G.rgt2.slow = false
    hs.timer.usleep(2000000)  -- a slow first step, like an AX move in a busy Bear
  end
end
_G.rgt2.hk = _G._stepper.bindWithRepeat({}, "f20", count)
_G.rgt2.hkc = _G._stepper.bindWithRepeat({"ctrl"}, "f20", count)

local function keypost(name, args)
  return function()
    local task = hs.task.new(KEYPOST, function(_, out)
      L(string.format("%s keypost: %s", name, (out or ""):gsub("\n", " | ")))
    end, args)
    _G.rgt2.tasks[name] = task
    task:start()
  end
end
local function fake(mods, label)
  return function() _G.rgt2.fake = mods; L("modifiers now " .. label) end
end
local function snap(label)
  return function() L(string.format("%-28s calls=%d", label, _G.rgt2.calls)) end
end

local plan = {
  -- S1
  {0.0, fake({fn = true}, "{fn}")},
  {0.0, keypost("S1", {tostring(F20), "50", "850"})},
  {1.5, snap("S1 after key-up")}, {2.0, snap("S1 +0.5s")},
  -- S2
  {3.0, fake(nil, "real")},
  {3.0, function() _G.rgt2.slow = true end},
  {3.0, keypost("S2", {tostring(F20), "100", "400", tostring(CTRL), "350"})},
  {6.0, snap("S2 after the busy call")}, {6.5, snap("S2 +0.5s")},
  -- S3 (S2's report and synthetic key-up land around 8.0)
  {9.0, keypost("S3", {tostring(F20), "100", "500", tostring(CTRL)})},
  {10.2, snap("S3 after key-up")}, {10.7, snap("S3 +0.5s")},
  -- S4
  {11.0, fake({fn = true}, "{fn}")},
  {11.0, keypost("S4", {tostring(F20), "50", "8000"})},
  {15.8, snap("S4 at 4.8s")}, {16.6, snap("S4 at 5.6s")}, {20.5, snap("S4 after key-up")},
  -- S5
  {21.0, keypost("S5", {tostring(F20), "50", "1500"})},
  {21.6, fake({}, "{} (fn released, key still down)")},
  {21.9, snap("S5 after fn release")}, {22.4, snap("S5 +0.5s")}, {24.5, snap("S5 after key-up")},
  -- cleanup
  {26.0, function()
    _G.rgt2.hk:delete()
    _G.rgt2.hkc:delete()
    hs.eventtap.checkKeyboardModifiers = realCheck
    _G.rgt2.fake = nil
    L("done: test hotkeys deleted, checkKeyboardModifiers restored")
  end},
}
for _, step in ipairs(plan) do later(step[1], step[2]) end
return "repeat-guard test scheduled (~26 s)"
