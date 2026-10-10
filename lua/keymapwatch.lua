-- Keeps fleet F002's keymap current: keymap.html, every ◆ and ⌥ key with its clashes. F002's census
-- (keybinding-census.py) reads every app's shortcuts into keybindings-census.json, which the page polls.
-- This module keeps the census live: it reruns it once after each load, whenever rcmd's key assignments
-- or stepper's own hotkey data change, whenever an app launches or quits (an update relaunches it, and
-- updates bring shortcuts: ChatGPT's ⌃⇧4 on 2026-10-09), and every 15 minutes for settings changed
-- in place. After each run it saves an icon for any rcmd app that has none yet, and for the page's
-- BTT and Raycast filters.
-- It replaced L009-keymap's generator on 2026-10-09.
-- Hammerspoon's hotkeys go to the census on stdin: a run that Hammerspoon starts must not call back
-- into Hammerspoon over IPC (a stuck hs CLI has crashed it before).
-- Page: https://fleet.internal/features/F002-harmonious-keybindings/keymap.html

local M = {}

local F002 = "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/"
local CENSUS = F002 .. "keybinding-census.py"
local CENSUS_JSON = F002 .. "keybindings-census.json"
local PYTHON = "/opt/homebrew/bin/python3"  -- native arm64, no Rosetta needed
local RCMD_PLIST = os.getenv("HOME") ..
  "/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist"
local BEAR = "net.shinyfrog.bear"
local FILTER_ICONS = {"com.hegenberg.BetterTouchTool", "com.raycast.macos"}  -- the page's BTT and Raycast filters
local EVERY = 15 * 60

M._watchers = {}       -- module scope, so they aren't collected
local task = nil       -- the running census, held for the same reason
local timer = nil      -- debounces bursts of events
local startTimer = nil
local periodic = nil
local appWatcher = nil
local pending = nil    -- a change that came in while the census ran
local rcmdKeys = nil   -- rcmd's assignments as last seen
local iconDir = nil    -- stepper's data/app-icons/, shared with bear-hud.lua's live slots (untracked)

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

-- The page shows each rcmd app's icon, Bear's, and BTT's and Raycast's on its filters; saved once per
-- app, as bear-hud.lua does for live slots
local function saveIcons()
  local census = hs.json.read(CENSUS_JSON)
  if not census then return end
  local wanted = {BEAR, table.unpack(FILTER_ICONS)}
  for _, r in ipairs(census.rcmd and census.rcmd.keys or {}) do table.insert(wanted, r.bundleID) end
  hs.fs.mkdir(iconDir)
  for _, bundleID in ipairs(wanted) do
    local path = iconDir .. bundleID .. ".png"
    if bundleID ~= "" and not hs.fs.attributes(path) then
      local img = hs.image.imageFromAppBundle(bundleID)
      if img then img:copy():setSize({w = 64, h = 64}):saveToFile(path) end
    end
  end
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
    else
      saveIcons()
    end
    if pending then local r = pending; pending = nil; schedule(r) end
  end, {CENSUS, "--json-only", "--hammerspoon-stdin"})
  task:setInput(hs.json.encode(hotkeys))  -- stdin closes once written
  if not task:start() then
    print("[keymapwatch] couldn't start " .. PYTHON)
    task = nil
  end
end

schedule = function(reason, delay)
  if timer then timer:stop() end
  timer = hs.timer.doAfter(delay or 1, function() timer = nil; run(reason) end)
end

function M.run(reason) run(reason or "a manual run") end

function M.init(root)
  iconDir = root .. "data/app-icons/"
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
  -- Launches come in bursts (helpers, login items), so wait for a quiet 10 s
  local appEvents = hs.application.watcher
  appWatcher = appEvents.new(function(name, event)
    if event == appEvents.launched or event == appEvents.terminated then
      schedule(string.format("%s %s", name or "an app", event == appEvents.launched and "launching" or "quitting"), 10)
    end
  end)
  appWatcher:start()
  periodic = hs.timer.doEvery(EVERY, function() run("the quarter-hourly check") end)
  -- After the rest of stepper has bound its hotkeys
  startTimer = hs.timer.doAfter(5, function() startTimer = nil; run("the load") end)
  print("[keymapwatch] keeps fleet F002's census live: rcmd, stepper's hotkey data, app launches and quits, every 15 min")
end

return M
