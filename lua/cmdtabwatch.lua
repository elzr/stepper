-- Dead ⌘⇥ forensics for the AltTab trial. Now and then ⌘⇥ does nothing at all: no
-- AltTab switcher, no switch, while the rest of the Mac is fine. cmdtabwatch.swift
-- watches every ⌘⇥ through listen-only taps and logs each press that did nothing,
-- with the evidence that tells the suspects apart. This module builds it, keeps it
-- running, and puts its findings in the console (and an alert per episode).
-- Notes: https://fleet.internal/features/F040-tiptop-software-infrastructure/subfeatures/AltTab/

local M = {}

local scriptDir = debug.getinfo(1, "S").source:match("@(.*/)")
local SWIFTC = "/usr/bin/swiftc"                -- Xcode Command Line Tools
local toolSource = scriptDir .. "cmdtabwatch.swift"
local toolBinary = scriptDir .. "cmdtabwatch"  -- built from toolSource on demand, not tracked
-- The console doesn't survive a Hammerspoon relaunch; these do (untracked)
local defaults = {
  log = scriptDir .. "../data/cmd-tab-watch.jsonl",
  samples = scriptDir .. "../data/cmd-tab-samples",
  pidfile = hs.fs.temporaryDirectory() .. "cmdtabwatch.pid",
}

local task = nil         -- the running watcher, held so it isn't collected
local builder = nil      -- swiftc, while it builds the watcher
local restartTimer = nil
local exits = {}         -- times of recent unexpected exits, for the backoff
local options = nil      -- what the watcher was started with
local buffer = ""        -- stdout not yet split into lines
local lastRecord = nil

local function oneLine(s)
  return (tostring(s or ""):gsub("%s+", " "))
end

local function onRecord(doc)
  lastRecord = doc
  local line = "[cmdtabwatch] " .. (doc.summary or doc.event or "?")
  if doc.event == "dead" then
    print(line)
    -- Once per episode, as the watcher decides: at once with evidence, else on a second press
    if doc.alertNow then
      hs.alert.show((doc.test and "test: " or "") .. "⌘⇥ did nothing, logged · " .. (doc.alert or ""), 5)
    end
  elseif doc.event ~= "overlay" and doc.event ~= "overlay-gone" and doc.event ~= "tally" then
    print(line)
  end
end

-- Records arrive one JSON document per line, but not necessarily one line per read
local function onOutput(_, stdout, stderr)
  buffer = buffer .. (stdout or "")
  while true do
    local line, rest = buffer:match("^(.-)\n(.*)$")
    if not line then break end
    buffer = rest
    local ok, doc = pcall(hs.json.decode, line)
    if ok and type(doc) == "table" then onRecord(doc) end
  end
  if stderr and stderr ~= "" then print("[cmdtabwatch] " .. oneLine(stderr)) end
  return true
end

local launch

local function scheduleRestart(why)
  local now = hs.timer.secondsSinceEpoch()
  local recent = {}
  for _, t in ipairs(exits) do
    if now - t < 600 then table.insert(recent, t) end
  end
  table.insert(recent, now)
  exits = recent
  if #exits > 5 then
    print("[cmdtabwatch] stopped 6 times in 10 min, giving up until the next reload: " .. why)
    return
  end
  restartTimer = hs.timer.doAfter(10 * #exits, function()
    restartTimer = nil
    launch()
  end)
end

launch = function()
  buffer = ""
  local args = {"--log", options.log, "--samples", options.samples, "--pidfile", options.pidfile}
  if options.key then
    table.insert(args, "--key")
    table.insert(args, tostring(options.key))
  end
  if options.panelOwner then
    table.insert(args, "--panel-owner")
    table.insert(args, options.panelOwner)
  end
  local this
  this = hs.task.new(toolBinary, function(exitCode, _, stderr)
    -- Only the current watcher's exit matters: a stopped or replaced one was meant to go
    if task ~= this then return end
    task = nil
    -- 3: no event tap could be made, which retrying won't change
    if exitCode == 3 then
      print("[cmdtabwatch] can't watch: no event tap (Hammerspoon needs Accessibility)")
      return
    end
    local why = string.format("exit %d %s", exitCode, oneLine(stderr):sub(1, 160))
    print("[cmdtabwatch] watcher stopped (" .. why .. "), restarting")
    scheduleRestart(why)
  end, onOutput, args)
  task = this
  if not this:start() then
    task = nil
    print("[cmdtabwatch] couldn't launch " .. toolBinary)
  end
end

local function toolIsCurrent()
  local bin, src = hs.fs.attributes(toolBinary), hs.fs.attributes(toolSource)
  return bin ~= nil and src ~= nil and bin.modification >= src.modification
end

-- opts (tests only): key = another keycode to watch with ⌘, panelOwner = the bundle id
-- whose window counts as the switcher, log/samples/pidfile = other paths
function M.start(opts)
  M.stop()
  options = {}
  for k, v in pairs(defaults) do options[k] = v end
  for k, v in pairs(opts or {}) do options[k] = v end
  exits = {}
  if builder then return end  -- the build under way launches with these options
  if toolIsCurrent() then return launch() end
  -- Swift 5 mode pinned: the tool's globals are fine there, not under Swift 6's checks
  builder = hs.task.new(SWIFTC, function(exitCode, _, stderr)
    builder = nil
    if exitCode == 0 then
      launch()
    else
      print(string.format("[cmdtabwatch] swiftc exit %d: %s", exitCode, oneLine(stderr):sub(1, 300)))
    end
  end, {"-O", "-swift-version", "5", "-o", toolBinary, toolSource})
  if not builder:start() then
    builder = nil
    print("[cmdtabwatch] couldn't launch " .. SWIFTC)
  end
end

function M.stop()
  if restartTimer then restartTimer:stop(); restartTimer = nil end
  local running = task
  task = nil
  if running then running:terminate() end
end

-- For IPC checks: hs -c "return hs.inspect(_G._stepper.cmdtabwatch.status())"
function M.status()
  return {
    running = task ~= nil and task:isRunning(),
    pid = task and task:pid() or nil,
    building = builder ~= nil,
    log = options and options.log,
    last = lastRecord and (lastRecord.event .. ": " .. tostring(lastRecord.summary)) or nil,
  }
end

return M
