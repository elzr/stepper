-- Keeps fleet F002's keymap current: keymap.html, every ◆ and R⌥ key with its clashes. F002's census
-- (keybinding-census.py) reads every app's shortcuts into keybindings-census.json, which the page polls.
-- This module reruns it once after each load and whenever rcmd's key assignments or stepper's own
-- hotkey data change. It replaced L009-keymap's generator on 2026-10-09.
-- Hammerspoon's hotkeys go to the census on stdin: a run that Hammerspoon starts must not call back
-- into Hammerspoon over IPC (a stuck hs CLI has crashed it before).
-- Page: https://fleet.internal/features/F002-harmonious-keybindings/keymap.html

local M = {}

local F002 = "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/"
local CENSUS = F002 .. "keybinding-census.py"
local PYTHON = "/opt/homebrew/bin/python3"  -- native arm64, no Rosetta needed
local RCMD_PLIST = os.getenv("HOME") ..
  "/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist"

M._watchers = {}       -- module scope, so they aren't collected
local task = nil       -- the running census, held for the same reason
local timer = nil      -- debounces bursts of file events
local startTimer = nil
local pending = nil    -- a change that came in while the census ran
local rcmdKeys = nil   -- rcmd's assignments as last seen

-- rcmd rewrites its plist on every use (use counts), so compare the assignments themselves
local function rcmdSignature()
  local plist = hs.plist.read(RCMD_PLIST)
  local parts = {}
  for _, s in ipairs(plist and plist.appKeyAssignments or {}) do
    local e = hs.json.decode(s)
    if e and e.key and e.app then table.insert(parts, e.key .. "=" .. tostring(e.app.path)) end
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

local schedule

local function run(reason)
  if task and task:isRunning() then pending = reason; return end
  local hotkeys = {}
  for _, h in ipairs(hs.hotkey.getHotkeys()) do table.insert(hotkeys, {idx = h.idx, msg = h.msg}) end
  task = hs.task.new(PYTHON, function(code, _, stderr)
    task = nil
    if code ~= 0 then
      print(string.format("[keymapwatch] census failed after %s: %s", reason, (stderr or ""):gsub("%s+$", "")))
    end
    if pending then local r = pending; pending = nil; schedule(r) end
  end, {CENSUS, "--json-only", "--hammerspoon-stdin"})
  task:setInput(hs.json.encode(hotkeys))  -- stdin closes once written
  if not task:start() then
    print("[keymapwatch] couldn't start " .. PYTHON)
    task = nil
  end
end

schedule = function(reason)
  if timer then timer:stop() end
  timer = hs.timer.doAfter(1, function() timer = nil; run(reason) end)
end

function M.run(reason) run(reason or "a manual run") end

function M.init(root)
  rcmdKeys = rcmdSignature()
  local function watch(path, reason, changed)
    local w = hs.pathwatcher.new(path, function()
      if changed == nil or changed() then schedule(reason) end
    end)
    w:start()
    table.insert(M._watchers, w)
  end
  watch(RCMD_PLIST, "a change to rcmd's keys", function()
    local now = rcmdSignature()
    if now == rcmdKeys then return false end
    rcmdKeys = now
    return true
  end)
  watch(root .. "data/bear-notes.jsonc", "a change to bear-notes.jsonc")
  watch(root .. "data/hyper-actions.jsonc", "a change to hyper-actions.jsonc")
  -- After the rest of stepper has bound its hotkeys
  startTimer = hs.timer.doAfter(5, function() startTimer = nil; run("the load") end)
  print("[keymapwatch] reruns fleet F002's census when rcmd's keys or stepper's hotkey data change")
end

return M
