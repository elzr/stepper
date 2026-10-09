-- Probe: S1 of repeat-guard-test.lua on its own, three times. A 0.8 s keypost hold of F20
-- through the real bindWithRepeat, with ctrl+F20 bound too and fn faked as held, logging
-- when the hold watcher reports and how many steps each hold gave (expected ~20).
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.s1r.log, "\n")'   (after ~8 s)

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local F20 = 90

local t0 = hs.timer.secondsSinceEpoch()
local ip = _G._stepper.inputprobe
local realCheck, realWatch = hs.eventtap.checkKeyboardModifiers, ip.watchHold
_G.s1r = {log = {}, calls = 0, timers = {}, tasks = {}}
local function L(s)
  table.insert(_G.s1r.log, string.format("%5.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.s1r.timers, hs.timer.doAfter(seconds, fn)) end

hs.eventtap.checkKeyboardModifiers = function() return {fn = true} end
ip.watchHold = function(key, onLetGo)
  local task = realWatch(key, function() L("  watcher: keyboard let go of " .. key); onLetGo() end)
  L(string.format("  press: watcher %s", task and "started" or "NOT started"))
  return task
end
local function count() _G.s1r.calls = _G.s1r.calls + 1 end
_G.s1r.hk = _G._stepper.bindWithRepeat({}, "f20", count)
_G.s1r.hkc = _G._stepper.bindWithRepeat({"ctrl"}, "f20", count)

for i = 0, 2 do
  later(i * 2.5, function()
    _G.s1r.start = _G.s1r.calls
    local task = hs.task.new(KEYPOST, function(_, out)
      L(string.format("hold %d keypost: %s", i + 1, (out or ""):gsub("\n", " | ")))
    end, {tostring(F20), "50", "850"})
    _G.s1r.tasks[i] = task
    task:start()
  end)
  later(i * 2.5 + 2.0, function()
    L(string.format("hold %d RESULT: %d steps", i + 1, _G.s1r.calls - _G.s1r.start))
  end)
end
later(7.6, function()
  _G.s1r.hk:delete()
  _G.s1r.hkc:delete()
  hs.eventtap.checkKeyboardModifiers = realCheck
  ip.watchHold = realWatch
  L("done: restored")
end)
return "S1 repro scheduled (~8 s)"
