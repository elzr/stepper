-- Throwaway probe: which key-up shapes does the WindowServer turn into a
-- Carbon hotkey release? Uses F20 / cmd+F20 test hotkeys with counting
-- repeat functions (no window operations). Results land in _G.rx.log.
local t0 = hs.timer.secondsSinceEpoch()
_G.rx = {log = {}, rep = {f20 = 0, cf20 = 0}, timers = {}}
local function L(s)
  table.insert(_G.rx.log, string.format("%5.2f  %s", hs.timer.secondsSinceEpoch() - t0, s))
end

_G.rx.hk1 = hs.hotkey.new({}, "f20",
  function() L("F20 press") end,
  function() L("F20 release") end,
  function() _G.rx.rep.f20 = _G.rx.rep.f20 + 1 end):enable()
_G.rx.hk2 = hs.hotkey.new({"cmd"}, "f20",
  function() L("cmd+F20 press") end,
  function() L("cmd+F20 release") end,
  function() _G.rx.rep.cf20 = _G.rx.rep.cf20 + 1 end):enable()

local function key(mods, k, down)
  return function()
    hs.eventtap.event.newKeyEvent(mods, k, down):post()
    L(string.format("post %s %s%s", down and "down" or "up  ", (#mods > 0 and table.concat(mods, "+") .. "+" or ""), k))
  end
end
local function snap(label)
  return function() L(string.format("%s  rep F20=%d cmd+F20=%d", label, _G.rx.rep.f20, _G.rx.rep.cf20)) end
end

local plan = {
  -- T1 control: plain down/up
  {0.0, key({}, "f20", true)},
  {0.6, key({}, "f20", false)},
  {0.9, snap("T1 after up")}, {1.4, snap("T1 +0.5s")},
  -- T2: down with no mods, up with cmd held
  {2.0, key({}, "f20", true)},
  {2.2, key({"cmd"}, "f20", false)},
  {2.8, snap("T2 after up")}, {3.3, snap("T2 +0.5s")},
  {3.5, key({}, "f20", false)},          -- cleanup
  -- T3: down with cmd, up with no mods
  {4.5, key({"cmd"}, "f20", true)},
  {4.7, key({}, "f20", false)},
  {5.3, snap("T3 after up")}, {5.8, snap("T3 +0.5s")},
  {6.0, key({"cmd"}, "f20", false)},     -- cleanup
  -- T5: key-up arrives with a different keycode
  {7.0, key({}, "f20", true)},
  {7.2, key({}, "f17", false)},
  {7.8, snap("T5 after up")}, {8.3, snap("T5 +0.5s")},
  {8.5, key({}, "f20", false)},          -- cleanup
  {9.0, snap("final")},
  {9.2, function() _G.rx.hk1:delete(); _G.rx.hk2:delete(); L("probe hotkeys deleted") end},
}
for _, step in ipairs(plan) do
  table.insert(_G.rx.timers, hs.timer.doAfter(step[1], step[2]))
end
return "probe scheduled"
