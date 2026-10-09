-- Probe: is a hotkey's release lost when the key goes down and up while
-- Hammerspoon's main thread is busy? keypost (built from keypost.swift next to
-- this file) presses F20 from outside Hammerspoon, while a timer here blocks the
-- main thread with hs.timer.usleep. F20 is bound to a counting test hotkey, so
-- nothing reaches the focused app.
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.brp.log, "\n")'   (after ~35 s)

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local F20 = 90

local t0 = hs.timer.secondsSinceEpoch()
_G.brp = {log = {}, timers = {}, tasks = {}, press = 0, release = 0}
local function L(s)
  table.insert(_G.brp.log, string.format("%6.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.brp.timers, hs.timer.doAfter(seconds, fn)) end

_G.brp.hk = hs.hotkey.new({}, "f20",
  function() _G.brp.press = _G.brp.press + 1; L("  F20 press") end,
  function() _G.brp.release = _G.brp.release + 1; L("  F20 release") end):enable()

-- downAt/upAt: ms after keypost starts; blockAt (ms after the trial starts) and
-- blockFor (s) freeze Hammerspoon's main thread, or nil for a control run
local function trial(at, name, downAt, upAt, blockAt, blockFor)
  later(at, function()
    local p0, r0 = _G.brp.press, _G.brp.release
    L(string.format("%s: F20 down@%d up@%d ms%s", name, downAt, upAt,
      blockFor and string.format(", main thread blocked %.1f s from %d ms", blockFor, blockAt) or ""))
    local task = hs.task.new(KEYPOST, function(_, out, err)
      L(string.format("  %s keypost: %s%s", name, (out or ""):gsub("\n", " | "),
        (err and err ~= "") and (" stderr: " .. err) or ""))
    end, {tostring(F20), tostring(downAt), tostring(upAt)})
    _G.brp.tasks[name] = task
    if not task:start() then L("  keypost failed to start") end
    if blockFor then
      later(blockAt / 1000, function()
        local b = hs.timer.secondsSinceEpoch()
        hs.timer.usleep(math.floor(blockFor * 1e6))
        L(string.format("  %s: main thread back after %.2f s", name, hs.timer.secondsSinceEpoch() - b))
      end)
    end
    local settle = math.max(upAt / 1000, (blockAt or 0) / 1000 + (blockFor or 0)) + 1.5
    later(settle, function()
      L(string.format("%s RESULT: presses %d, releases %d", name, _G.brp.press - p0, _G.brp.release - r0))
    end)
  end)
end

trial(0,  "C1 control",            300, 450)
trial(4,  "B1 down+up while busy", 400, 550, 100, 2.0)
trial(9,  "B2 down+up while busy", 400, 550, 100, 2.0)
trial(14, "B3 up after busy",      400, 2500, 100, 2.0)
trial(20, "B4 down+up, 4 s busy",  400, 550, 100, 4.0)
trial(27, "C2 control",            300, 450)
later(31, function()
  _G.brp.hk:delete()
  L(string.format("done: totals presses %d, releases %d; test hotkey deleted", _G.brp.press, _G.brp.release))
end)
return "busy-release probe scheduled (~31 s)"
