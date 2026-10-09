-- Probe: when a hotkey's press callback runs, does the HID system already hold the key?
-- The hold watcher (inputprobe hold) assumes it does; if the HID state lagged the hotkey,
-- the watcher would report "let go" at once and stepper's repeat would never start.
-- Five keypost presses of F20 (0.8 s holds); at each press the callback starts
-- `inputprobe keys 90` and `inputprobe hold 90`, and logs what they answer and when.
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.hap.log, "\n")'   (after ~12 s)

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local PROBE = here .. "../../lua/inputprobe"
local F20 = 90

local t0 = hs.timer.secondsSinceEpoch()
_G.hap = {log = {}, timers = {}, tasks = {}, n = 0}
local function L(s)
  table.insert(_G.hap.log, string.format("%6.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.hap.timers, hs.timer.doAfter(seconds, fn)) end
local function task(name, binary, args)
  local t = hs.task.new(binary, function(_, out)
    L(string.format("  %s: %s", name, (out or ""):gsub("\n", " | ")))
  end, args)
  _G.hap.tasks[name] = t
  t:start()
end

_G.hap.hk = hs.hotkey.new({}, "f20", function()
  _G.hap.n = _G.hap.n + 1
  local n = _G.hap.n
  L(string.format("press %d", n))
  task("keys " .. n, PROBE, {"keys", tostring(F20)})
  task("hold " .. n, PROBE, {"hold", tostring(F20), "5"})
end, function() L("  release") end):enable()

for i = 0, 4 do
  later(i * 2, function() task("keypost " .. (i + 1), KEYPOST, {tostring(F20), "50", "850"}) end)
end
later(11, function() _G.hap.hk:delete(); L("done") end)
return "hid-at-press probe scheduled (~11 s)"
