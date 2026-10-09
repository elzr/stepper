-- Probe: is it Hammerspoon's own event taps that lose the release? Repeats the shape
-- that lost it in slow-callback-release-probe.lua (K4: ctrl released before the key
-- while the press callback keeps the main thread busy), alternately with Hammerspoon's
-- event taps running and paused. Every trial uses ctrl+F20 (a first run gave each its
-- own key, but ctrl+F17..F19 never reached Hammerspoon at all), and a quick flush press
-- afterwards closes the hotkey if macOS still thinks it is down.
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.tpp.log, "\n")'   (after ~32 s)

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local CTRL = 59
local BUSY = 2.0

local t0 = hs.timer.secondsSinceEpoch()
_G.tpp = {log = {}, timers = {}, tasks = {}, hotkeys = {}, count = {}, busy = false}
local function L(s)
  table.insert(_G.tpp.log, string.format("%6.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.tpp.timers, hs.timer.doAfter(seconds, fn)) end

-- Every hs.eventtap reachable from _G, the registry and loaded modules (they live in module locals)
local function findTaps()
  local tapMeta = hs.getObjectMetatable("hs.eventtap")
  local seen, queue, taps = {}, {_G, debug.getregistry(), package.loaded}, {}
  while #queue > 0 do
    local v = table.remove(queue)
    if not seen[v] then
      seen[v] = true
      local kind = type(v)
      if kind == "table" then
        for k, x in pairs(v) do
          if type(k) == "table" or type(k) == "function" or type(k) == "userdata" then table.insert(queue, k) end
          if type(x) == "table" or type(x) == "function" or type(x) == "userdata" then table.insert(queue, x) end
        end
      elseif kind == "function" then
        for i = 1, 255 do
          local name, x = debug.getupvalue(v, i)
          if not name then break end
          if type(x) == "table" or type(x) == "function" or type(x) == "userdata" then table.insert(queue, x) end
        end
      elseif kind == "userdata" and getmetatable(v) == tapMeta then
        table.insert(taps, v)
      end
    end
  end
  return taps
end

local paused = {}
local function pauseTaps()
  paused = {}
  for _, tap in ipairs(findTaps()) do
    if tap:isEnabled() then tap:stop(); table.insert(paused, tap) end
  end
  L(string.format("  paused %d running Hammerspoon event taps", #paused))
end
local function resumeTaps()
  for _, tap in ipairs(paused) do tap:start() end
  L(string.format("  resumed %d taps", #paused))
  paused = {}
end
_G.tpp.resumeTaps = resumeTaps  -- in case a run is cut short

local F20 = 90
local count = {press = 0, release = 0}
table.insert(_G.tpp.hotkeys, hs.hotkey.new({"ctrl"}, "f20", function()
  count.press = count.press + 1
  L(string.format("  ctrl+F20 press%s", _G.tpp.busy and string.format(", busy %.1f s", BUSY) or ""))
  if _G.tpp.busy then hs.timer.usleep(math.floor(BUSY * 1e6)) end
end, function()
  count.release = count.release + 1
  L("  ctrl+F20 release")
end):enable())

local function keypost(name, args)
  local task = hs.task.new(KEYPOST, function(_, out)
    L(string.format("  %s keypost: %s", name, (out or ""):gsub("\n", " | ")))
  end, args)
  _G.tpp.tasks[name .. #_G.tpp.log] = task
  task:start()
end

-- One trial: ctrl down, key down, ctrl up (350 ms), key up (400 ms); the press callback
-- blocks for BUSY seconds. Then a flush press of the same chord with no busy callback.
local function trial(at, name, pause)
  local p0, r0
  later(at, function()
    p0, r0 = count.press, count.release
    L(string.format("%s: ctrl+F20, taps %s", name, pause and "PAUSED" or "running"))
    if pause then pauseTaps() end
    _G.tpp.busy = true
    keypost(name, {tostring(F20), "100", "400", tostring(CTRL), "350"})
  end)
  later(at + BUSY + 1.5, function()
    _G.tpp.busy = false
    if pause then resumeTaps() end
    L(string.format("%s RESULT: presses %d, releases %d", name, count.press - p0, count.release - r0))
    keypost(name .. " flush", {tostring(F20), "100", "200", tostring(CTRL)})
  end)
  later(at + BUSY + 3.5, function()
    L(string.format("%s after flush: presses %d, releases %d", name, count.press - p0, count.release - r0))
  end)
end

trial(0,  "P1", false)
trial(7,  "P2", true)
trial(14, "P3", false)
trial(21, "P4", true)
later(29, function()
  for _, hk in ipairs(_G.tpp.hotkeys) do hk:delete() end
  L("done: test hotkeys deleted")
end)
return "tap-pause probe scheduled (~29 s)"
