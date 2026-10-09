-- Probe: controls for the lost release. I1/I2 release the modifier before the key
-- with Hammerspoon idle (expected: release arrives, as in 2026-10-07's T3). K4 repeats
-- the busy case and samples hs.eventtap.checkKeyboardModifiers() every 100 ms after the
-- busy press callback returns, to see how long the released ctrl still reads as held.
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.icp.log, "\n")'   (after ~17 s)

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local F20, CTRL = 90, 59
local BUSY = 2.0

local t0 = hs.timer.secondsSinceEpoch()
_G.icp = {log = {}, timers = {}, tasks = {}, busy = false}
local function L(s)
  table.insert(_G.icp.log, string.format("%6.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.icp.timers, hs.timer.doAfter(seconds, fn)) end
local function ctrlHeld() return hs.eventtap.checkKeyboardModifiers().ctrl and "ctrl" or "none" end

local samples = {}
local sampler = nil
local function sample(seconds)
  samples = {}
  local started = hs.timer.secondsSinceEpoch()
  sampler = hs.timer.doEvery(0.1, function()
    table.insert(samples, ctrlHeld() == "ctrl" and "C" or ".")
    if hs.timer.secondsSinceEpoch() - started >= seconds then
      sampler:stop()
      L("  modifiers every 100 ms after the callback (C = ctrl reads held): " .. table.concat(samples))
    end
  end)
  _G.icp.sampler = sampler
end

local count = {press = 0, release = 0}
_G.icp.hk = hs.hotkey.new({"ctrl"}, "f20", function()
  count.press = count.press + 1
  L(string.format("  ctrl+F20 press (mods %s)%s", ctrlHeld(), _G.icp.busy and ", busy" or ""))
  if _G.icp.busy then
    hs.timer.usleep(math.floor(BUSY * 1e6))
    L(string.format("  press callback returns (mods %s)", ctrlHeld()))
    sample(3)
  end
end, function()
  count.release = count.release + 1
  L(string.format("  ctrl+F20 release (mods %s)", ctrlHeld()))
end):enable()

local function keypost(name, args)
  local task = hs.task.new(KEYPOST, function(_, out)
    L(string.format("  %s keypost: %s", name, (out or ""):gsub("\n", " | ")))
  end, args)
  _G.icp.tasks[name] = task
  task:start()
end

local function trial(at, name, busy)
  local p0, r0
  later(at, function()
    p0, r0 = count.press, count.release
    _G.icp.busy = busy
    L(string.format("%s: ctrl up before the key, Hammerspoon %s", name, busy and "busy" or "idle"))
    keypost(name, {tostring(F20), "100", "400", tostring(CTRL), "350"})
  end)
  later(at + (busy and BUSY + 3.6 or 1.5), function()
    _G.icp.busy = false
    L(string.format("%s RESULT: presses %d, releases %d", name, count.press - p0, count.release - r0))
    if count.release - r0 == 0 then keypost(name .. " flush", {tostring(F20), "100", "200", tostring(CTRL)}) end
  end)
end

trial(0, "I1", false)
trial(3, "I2", false)
trial(6, "K4", true)
later(16, function()
  _G.icp.hk:delete()
  L(string.format("done: totals presses %d, releases %d", count.press, count.release))
end)
return "idle-control probe scheduled (~16 s)"
