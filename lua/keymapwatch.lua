-- Keeps fleet F002's keymap current: keymap.html, every ◆ and ⌥ key with its clashes. F002's census
-- (keybinding-census.py) reads every app's shortcuts into keybindings-census.json, which the page polls.
-- This module keeps the census live: it reruns it once after each load, whenever rcmd's key assignments
-- or stepper's own hotkey data change, whenever an app launches or quits (an update relaunches it, and
-- updates bring shortcuts: ChatGPT's ⌃⇧4 on 2026-10-09), and every 15 minutes for settings changed
-- in place, and the moment a ChatGPT update lands. After each run it saves an icon for any rcmd app
-- that has none yet, and for the page's BTT and Raycast filters.
-- It replaced L009-keymap's generator on 2026-10-09.
-- Hammerspoon's hotkeys go to the census on stdin: a run that Hammerspoon starts must not call back
-- into Hammerspoon over IPC (a stuck hs CLI has crashed it before).
-- Page: https://fleet.internal/features/F002-harmonious-keybindings/subfeatures/keymap/keymap.html
-- (F002/keymap and F002/census are subfeatures since 2026-10-15)
-- The page's × on a Modifiers row asks here, hammerspoon://keymap-clear?btt=<uuid>: the BTT trigger is
-- disabled (BTT's own switch, so it can be turned back on there) and the census reruns, recording who
-- freed it in modifier-history.jsonl. Only BTT triggers the census lists; Raycast's and the other apps'
-- hotkeys live where nothing else can write them (since 2026-10-15).

local M = {}

local F002 = "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2026/fleet/features/F002-harmonious-keybindings/subfeatures/census/"
local CENSUS = F002 .. "keybinding-census.py"
local CENSUS_JSON = F002 .. "keybindings-census.json"
local PYTHON = "/opt/homebrew/bin/python3"  -- native arm64, no Rosetta needed
local BTTCLI = "/Applications/BetterTouchTool.app/Contents/SharedSupport/bin/bttcli"
local RCMD_PLIST = os.getenv("HOME") ..
  "/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist"
local CHATGPT_ASAR = "/Applications/ChatGPT.app/Contents/Resources/app.asar"
local BEAR = "net.shinyfrog.bear"
local FILTER_ICONS = {"com.hegenberg.BetterTouchTool", "com.raycast.macos"}  -- the page's BTT and Raycast filters
local EVERY = 15 * 60

M._watchers = {}       -- module scope, so they aren't collected
local task = nil       -- the running census, held for the same reason
local timer = nil      -- debounces bursts of events
local timerDue = nil   -- when that timer fires
local startTimer = nil
local periodic = nil
local appWatcher = nil
local pending = nil    -- a change that came in while the census ran
local rcmdKeys = nil   -- rcmd's assignments as last seen
local iconDir = nil    -- stepper's data/app-icons/, shared with bear-hud.lua's live slots (untracked)
local clearing = {}    -- the keymap-clear URL's bttcli tasks and timers, held until they finish
local freedBy = nil    -- who freed what the next census run finds gone (its --by)

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

-- The page shows each rcmd app's icon (and those of apps rcmd once had), each app with in-app keys of
-- yours (inApp), Bear's, and BTT's and Raycast's on its filters; saved once per
-- app, as bear-hud.lua does for live slots
local function saveIcons()
  local census = hs.json.read(CENSUS_JSON)
  if not census then return end
  local wanted = {BEAR, table.unpack(FILTER_ICONS)}
  for _, r in ipairs(census.rcmd and census.rcmd.keys or {}) do table.insert(wanted, r.bundleID) end
  for _, h in ipairs(census.inApp or {}) do table.insert(wanted, h.bundleID) end
  local hist = io.open(F002 .. "rcmd-history.jsonl", "r")   -- apps rcmd once had, for the ⏱ history
  if hist then
    for line in hist:lines() do
      local bundleID = line:match('"bundleID": "([^"]+)"')
      if bundleID then table.insert(wanted, bundleID) end
    end
    hist:close()
  end
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
  local args = {CENSUS, "--json-only", "--hammerspoon-stdin"}
  if freedBy then table.insert(args, "--by"); table.insert(args, freedBy); freedBy = nil end
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
  end, args)
  task:setInput(hs.json.encode(hotkeys))  -- stdin closes once written
  if not task:start() then
    print("[keymapwatch] couldn't start " .. PYTHON)
    task = nil
  end
end

-- A request never postpones a run already due sooner: a ChatGPT update's 1 s run must not wait out
-- the 10 s that the app's relaunch asks for
schedule = function(reason, delay)
  local due = hs.timer.secondsSinceEpoch() + (delay or 1)
  if timer and timerDue <= due then return end
  if timer then timer:stop() end
  timerDue = due
  timer = hs.timer.doAfter(delay or 1, function() timer = nil; run(reason) end)
end

function M.run(reason) run(reason or "a manual run") end

-- What the census lists under this BTT uuid: a gesture's trigger, or a chord's keys
local function listedTrigger(uuid)
  local census = hs.json.read(CENSUS_JSON)
  if not census then return nil end
  for _, g in ipairs(census.gestures or {}) do
    if g.uuid == uuid then return g.gesture, g.what end
  end
  for _, list in ipairs({census.hotkeys or {}, census.inApp or {}}) do
    for _, h in ipairs(list) do
      if h.uuid == uuid then return h.show, h.what end
    end
  end
end

local function bttcli(args, done)
  local t
  t = hs.task.new(BTTCLI, function(code, out)
    clearing[t] = nil
    done(code, out or "")
  end, args)
  clearing[t] = true
  if not t:start() then clearing[t] = nil; done(-1, "") end
end

-- hammerspoon://keymap-clear?btt=<uuid>: disable that BTT trigger, check BTT took it, rerun the census
local function clearBtt(uuid)
  local trigger, what = listedTrigger(uuid)
  if not trigger then
    hs.sound.getByName("Basso"):play()
    hs.alert.show("Not cleared: the census lists no BTT trigger " .. uuid, 4)
    return
  end
  bttcli({"update_trigger", "uuid=" .. uuid, 'json={"BTTEnabled":0,"BTTEnabled2":0}'}, function()
    bttcli({"get_trigger", "uuid=" .. uuid}, function(_, out)
      local t = hs.json.decode(out) or {}
      if t.BTTEnabled == 0 or t.BTTEnabled2 == 0 then
        hs.alert.show(string.format("%s cleared\n%s · disabled in BTT", trigger, what), 3)
        print(string.format("[keymapwatch] the keymap cleared %s (%s): BTT trigger %s disabled", trigger, what, uuid))
        freedBy = "keymap ×: disabled in BTT"
        schedule("the keymap's ×")
      else
        hs.sound.getByName("Basso"):play()
        hs.alert.show(string.format("%s not cleared: BTT didn't take it", trigger), 4)
      end
    end)
  end)
end

function M.init(root)
  -- The census describes the MacBook's apps and is tracked in fleet, so only the MacBook runs it;
  -- another Mac's run would overwrite it with its own (machine.lua, fleet F040/well-kept-logs)
  local machine = dofile(root .. "lua/machine.lua")
  if not machine.primary then
    print("[keymapwatch] off on this Mac (" .. machine.tag .. "): F002's census is the MacBook's")
    return
  end
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
  -- ChatGPT's updates bring system-wide shortcuts, which the census switches off (its chatgpt_guard) in
  -- the override file ChatGPT reads as it starts; so it runs as soon as a new build lands, ahead of
  -- the relaunch an update may do at once
  local asarChanged = (hs.fs.attributes(CHATGPT_ASAR) or {}).change
  watch("/Applications/ChatGPT.app/Contents/Resources/", "a ChatGPT update", function()
    local now = (hs.fs.attributes(CHATGPT_ASAR) or {}).change
    if now == asarChanged then return false end
    asarChanged = now
    return true
  end)
  -- Launches come in bursts (helpers, login items), so wait for a quiet 10 s
  local appEvents = hs.application.watcher
  appWatcher = appEvents.new(function(name, event)
    if event == appEvents.launched or event == appEvents.terminated then
      schedule(string.format("%s %s", name or "an app", event == appEvents.launched and "launching" or "quitting"), 10)
    end
  end)
  appWatcher:start()
  hs.urlevent.bind("keymap-clear", function(_, params)
    local uuid = params.btt or ""
    if not uuid:match("^[%x%-]+$") then return end
    local t
    t = hs.timer.doAfter(0, function() clearing[t] = nil; clearBtt(uuid) end)
    clearing[t] = true
  end)
  periodic = hs.timer.doEvery(EVERY, function() run("the quarter-hourly check") end)
  -- After the rest of stepper has bound its hotkeys
  startTimer = hs.timer.doAfter(5, function() startTimer = nil; run("the load") end)
  print("[keymapwatch] keeps fleet F002's census live: rcmd, stepper's hotkey data, app launches and quits, ChatGPT updates, every 15 min")
end

return M
