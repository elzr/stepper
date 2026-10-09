-- Probe: the 2026-10-09 shape. The press arrives, its callback keeps Hammerspoon's
-- main thread busy (as a slow AX move of a Bear window would), and the key, with or
-- without a modifier, is released meanwhile. Does the release still arrive? Is the
-- modifier still reported held afterwards? keypost (keypost.swift, next to this file)
-- presses from outside Hammerspoon; F20 and ctrl+F20 are counting test hotkeys.
--
-- Run:   hs -q -t 5 -c 'return dofile("<this file>")'
-- Read:  hs -q -t 5 -c 'return table.concat(_G.scp.log, "\n")'   (after ~25 s)

local here = debug.getinfo(1, "S").source:match("@(.*/)")
local KEYPOST = here .. "keypost"
local F20, CTRL = 90, 59
local BUSY = 2.0  -- seconds each press callback blocks, when the trial asks for it

local t0 = hs.timer.secondsSinceEpoch()
_G.scp = {log = {}, timers = {}, tasks = {}, press = 0, release = 0, busy = false}
local function L(s)
  table.insert(_G.scp.log, string.format("%6.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end
local function later(seconds, fn) table.insert(_G.scp.timers, hs.timer.doAfter(seconds, fn)) end
local function mods()
  local now, held = hs.eventtap.checkKeyboardModifiers(), {}
  for _, m in ipairs({"fn", "cmd", "alt", "shift", "ctrl"}) do
    if now[m] then table.insert(held, m) end
  end
  return #held > 0 and table.concat(held, "+") or "none"
end

local function pressed(name)
  return function()
    _G.scp.press = _G.scp.press + 1
    L(string.format("  %s press (mods %s)%s", name, mods(), _G.scp.busy and string.format(", busy %.1f s", BUSY) or ""))
    if _G.scp.busy then
      hs.timer.usleep(math.floor(BUSY * 1e6))
      L(string.format("  %s press callback returns (mods now %s)", name, mods()))
    end
  end
end
local function released(name)
  return function()
    _G.scp.release = _G.scp.release + 1
    L(string.format("  %s release (mods %s)", name, mods()))
  end
end
_G.scp.hk = hs.hotkey.new({}, "f20", pressed("F20"), released("F20")):enable()
_G.scp.hkc = hs.hotkey.new({"ctrl"}, "f20", pressed("ctrl+F20"), released("ctrl+F20")):enable()

-- args: keypost arguments after the keycode; busy: whether the press callback blocks
local function trial(at, name, busy, args)
  later(at, function()
    local p0, r0 = _G.scp.press, _G.scp.release
    _G.scp.busy = busy
    L(string.format("%s: keypost %s%s", name, table.concat(args, " "), busy and ", slow press callback" or ""))
    local task = hs.task.new(KEYPOST, function(_, out, err)
      L(string.format("  %s keypost: %s%s", name, (out or ""):gsub("\n", " | "),
        (err and err ~= "") and (" stderr: " .. err) or ""))
    end, {tostring(F20), table.unpack(args)})
    _G.scp.tasks[name] = task
    if not task:start() then L("  keypost failed to start") end
    later(BUSY + 2.5, function()
      L(string.format("%s RESULT: presses %d, releases %d, mods now %s",
        name, _G.scp.press - p0, _G.scp.release - r0, mods()))
    end)
  end)
end

trial(0,  "K1 control, no modifier",               false, {"100", "400"})
trial(5,  "K2 busy, no modifier",                  true,  {"100", "400"})
trial(10, "K3 busy, ctrl released after the key",  true,  {"100", "400", tostring(CTRL)})
trial(15, "K4 busy, ctrl released before the key", true,  {"100", "400", tostring(CTRL), "350"})
trial(20, "K5 control, ctrl",                      false, {"100", "400", tostring(CTRL)})
later(25, function()
  _G.scp.hk:delete()
  _G.scp.hkc:delete()
  L(string.format("done: totals presses %d, releases %d; test hotkeys deleted", _G.scp.press, _G.scp.release))
end)
return "slow-callback release probe scheduled (~25 s)"
