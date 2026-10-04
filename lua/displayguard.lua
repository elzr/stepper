-- =============================================================================
-- Display arrangement guard — keeps the Samsung LS37D70xE pair in portrait
-- =============================================================================
-- The two Samsungs are EDID twins (same vendor, model and numeric serial), so
-- macOS keys their display UUIDs by the DisplayPort path each one lands on, and
-- that path is handed out again whenever a hub re-enumerates (reboot, re-cabling,
-- the hubs losing power). A UUID pair macOS has never saved an arrangement for
-- comes up landscape at 1920x1080 HiDPI next to the built-in display. Details in
-- features/F010-sync-display-names-in-Lunar/README.md.
--
-- The guard identifies each Samsung by its text serial (display-serials.py
-- --json: ioreg + CoreDisplay), compares its rotation with the mounting recorded
-- in data/display-guard.json, and when a monitor is wrong re-applies the
-- rotation through Lunar (hs.screen:rotate() and displayplacer's degree: are
-- no-ops on Apple Silicon), then the last known-good mode and origin natively.
-- While both rotations are right, the current mode and origin are learned, so a
-- rearrangement in System Settings becomes the new target instead of a fight.
--
-- Driven by layout.lua: check(configName, reason, opts) is asynchronous and
-- returns immediately; opts.onFixed(summary) fires after a successful fix,
-- opts.dryRun only reports. isBusy() lets Lunar syncs wait; status() is for the
-- console.

local M = {}

local PYTHON = "/opt/homebrew/bin/python3"   -- native; the Intel /usr/local one goes away with F040
local LUNAR  = "/Applications/Lunar.app/Contents/MacOS/Lunar"

local scriptPath  = debug.getinfo(1, "S").source:match("@(.*/)")
local dataFile    = scriptPath .. "../data/display-guard.json"
local probeScript = scriptPath .. "../features/F010-sync-display-names-in-Lunar/display-serials.py"

local SETTLE_DELAY      = 1    -- s before probing (screens appear sequentially)
local ROTATE_GAP        = 2    -- s between the two Lunar rotation commands
local ROTATE_POLL       = 1    -- s between checks that a rotation has landed
local ROTATE_TIMEOUT    = 15   -- s to wait for rotations before giving up
local LUNAR_RETRIES     = 6    -- F010 may be restarting Lunar: retry this many
local LUNAR_RETRY_DELAY = 3    --   times, LUNAR_RETRY_DELAY s apart
local STEP_GAP          = 1    -- s between consecutive mode / origin changes
local VERIFY_DELAY      = 3    -- s after the last change before verifying
local MAX_ATTEMPTS      = 2    -- fix attempts per episode
local COOLDOWN          = 60   -- s after an episode before another may start
local WATCHDOG          = 120  -- s after which a stuck episode is abandoned
local ORIGIN_TOLERANCE  = 4    -- px of origin drift that still counts as fixed

local targets = nil            -- config name → serial → {side, rotation, mode, origin}
local busy = false
local episode = 0
local lastEpisodeEnd = 0
local lastStatus = "never run"

local function log(msg) print("[layout.guard] " .. msg) end

local function setStatus(msg)
  lastStatus = os.date("%H:%M:%S") .. " " .. msg
  log(msg)
end

-- Timers and tasks are only referenced here until they fire: an unreferenced
-- hs.timer or hs.task can be garbage-collected before it runs (stepper.lua even
-- forces a full collection right after init), which silently drops the step.
local pending = {}

local function later(seconds, fn)
  local t
  t = hs.timer.doAfter(seconds, function()
    pending[t] = nil
    fn()
  end)
  pending[t] = true
  return t
end

-- Returns true when the task was launched; callback(exitCode, stdout, stderr)
local function run(binary, args, callback)
  local task
  task = hs.task.new(binary, function(exitCode, stdout, stderr)
    pending[task] = nil
    callback(exitCode, stdout, stderr)
  end, args)
  pending[task] = true
  if task:start() then return true end
  pending[task] = nil
  return false
end

-- ---------------------------------------------------------------------------
-- Targets file
-- ---------------------------------------------------------------------------

local function loadTargets()
  if targets then return targets end
  targets = {}
  local fh = io.open(dataFile, "r")
  if not fh then
    log("Error: no targets file at " .. dataFile)
    return targets
  end
  local json = fh:read("*a")
  fh:close()
  local ok, data = pcall(hs.json.decode, json)
  if ok and type(data) == "table" then
    targets = data
  else
    log("Error: couldn't parse " .. dataFile)
  end
  return targets
end

local function saveTargets()
  local fh = io.open(dataFile, "w")
  if not fh then
    log("Error: couldn't write " .. dataFile)
    return
  end
  fh:write(hs.json.encode(targets, true))
  fh:close()
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function screenById(id)
  for _, s in ipairs(hs.screen.allScreens()) do
    if s:id() == id then return s end
  end
  return nil
end

local function fmtMode(m)
  if not m then return "?" end
  return string.format("%dx%d@%sx %sHz", m.w, m.h, tostring(m.scale), tostring(m.freq))
end

local function describe(screen)
  local f = screen:fullFrame()
  return string.format("rot %s %s at (%d,%d)",
    tostring(screen:rotate()), fmtMode(screen:currentMode()), f.x, f.y)
end

local function sameMode(a, b)
  return a and b and a.w == b.w and a.h == b.h and a.scale == b.scale and a.freq == b.freq
end

local function nearOrigin(f, origin)
  return origin and math.abs(f.x - origin.x) <= ORIGIN_TOLERANCE
    and math.abs(f.y - origin.y) <= ORIGIN_TOLERANCE
end

local function oneLine(s)
  return (tostring(s or ""):gsub("%s+", " "))
end

-- Entries sorted left before right, for stable logs and a stable fix order
local function sortedEntries(matched)
  local entries = {}
  for _, entry in pairs(matched) do entries[#entries + 1] = entry end
  table.sort(entries, function(a, b) return a.target.side < b.target.side end)
  return entries
end

-- ---------------------------------------------------------------------------
-- Probe: which macOS display carries which monitor, by text serial
-- ---------------------------------------------------------------------------

-- callback(rows) with one row per external monitor ({displayID, serial, asleep, ...}),
-- or callback(nil, err)
local function probe(callback)
  local launched = run(PYTHON, {probeScript, "--json"}, function(exitCode, stdout, stderr)
    if exitCode ~= 0 then
      callback(nil, string.format("probe exit %d: %s", exitCode, oneLine(stderr):sub(1, 200)))
      return
    end
    local ok, rows = pcall(hs.json.decode, stdout)
    if ok and type(rows) == "table" then
      callback(rows)
    else
      callback(nil, "probe output not JSON: " .. oneLine(stdout):sub(1, 200))
    end
  end)
  -- A python that can't launch never calls back, so report it here
  if not launched then
    callback(nil, "couldn't launch " .. PYTHON)
  end
end

-- {serial → {screen, target, serial}} for the guarded monitors that are connected
local function matchScreens(cfgTargets, rows)
  local matched = {}
  for _, row in ipairs(rows) do
    local target = row.serial and cfgTargets[row.serial]
    if target and row.displayID then
      local screen = screenById(row.displayID)
      if screen then
        matched[row.serial] = { screen = screen, target = target, serial = row.serial, asleep = row.asleep }
      end
    end
  end
  return matched
end

-- The one invariant: a monitor's rotation matches how it is mounted
local function wrongRotation(entry)
  local rot = entry.screen:rotate()
  if rot ~= entry.target.rotation then
    return string.format("%s %s rotation %s, want %d",
      entry.target.side, entry.serial, tostring(rot), entry.target.rotation)
  end
  return nil
end

-- With both rotations right, the current mode and origin are the arrangement to restore
local function learn(cfgName, matched)
  local changed = false
  for _, entry in pairs(matched) do
    local t = entry.target
    local m = entry.screen:currentMode()
    local f = entry.screen:fullFrame()
    if m and m.w < m.h and not sameMode(t.mode, m) then
      t.mode = { w = m.w, h = m.h, scale = m.scale, freq = m.freq, depth = m.depth }
      changed = true
    end
    if not t.origin or t.origin.x ~= f.x or t.origin.y ~= f.y then
      t.origin = { x = f.x, y = f.y }
      changed = true
    end
  end
  if changed then
    saveTargets()
    log("learned the current arrangement for " .. cfgName)
  end
end

-- ---------------------------------------------------------------------------
-- Fix: rotate through Lunar, then mode and origin natively, then verify
-- ---------------------------------------------------------------------------

local function finishEpisode(summary, fixed, opts)
  busy = false
  lastEpisodeEnd = hs.timer.secondsSinceEpoch()
  setStatus(summary)
  if fixed and opts.onFixed then opts.onFixed(summary) end
end

-- Lunar's rotation is the value it last set, not the display's state (it reads 0 while
-- macOS shows 90/270), and setting a Lunar property to its stored value is a no-op: on
-- 2026-10-03 a hub swap put each Samsung on a UUID whose stored rotation was exactly the
-- target, the guard asked twice, Lunar answered "rotation: N" and nothing rotated. So
-- read what Lunar believes first; when it already equals the target, pass the display's
-- current rotation through Lunar to make the real request a change.
local function lunarBelievedRotation(uuid, callback)
  local launched = run(LUNAR, {"@", "--remote", "displays", uuid, "rotation"},
    function(_, stdout, stderr)
      local out = oneLine((stdout or "") .. " " .. (stderr or ""))
      callback(tonumber(out:match("rotation:%s*(%d+)")))
    end)
  if not launched then callback(nil) end
end

-- Lunar talks to Apple's MonitorPanel framework, the same path System Settings uses.
-- F010 restarts Lunar around screen changes, so an unreachable Lunar is retried.
local function lunarRotate(uuid, degrees, attempt, callback)
  local launched = run(LUNAR, {"@", "--remote", "displays", uuid, "rotation", tostring(degrees)},
    function(_, stdout, stderr)
      local out = oneLine((stdout or "") .. " " .. (stderr or ""))
      if out:find("rotation: " .. degrees, 1, true) then
        callback(true)
      elseif attempt < LUNAR_RETRIES then
        log(string.format("Lunar didn't take rotation %d for %s (try %d/%d): %s",
          degrees, uuid:sub(1, 8), attempt, LUNAR_RETRIES, out:sub(1, 120)))
        later(LUNAR_RETRY_DELAY, function()
          lunarRotate(uuid, degrees, attempt + 1, callback)
        end)
      else
        callback(false, out:sub(1, 200))
      end
    end)
  if not launched then callback(false, "couldn't launch " .. LUNAR) end
end

local function waitForRotations(entries, deadline, callback)
  local pending = {}
  for _, entry in ipairs(entries) do
    local s = screenById(entry.screen:id())
    if not s or s:rotate() ~= entry.target.rotation then
      pending[#pending + 1] = entry.serial
    end
  end
  if #pending == 0 then
    callback(true)
  elseif hs.timer.secondsSinceEpoch() > deadline then
    callback(false, "rotation didn't land for " .. table.concat(pending, ", "))
  else
    later(ROTATE_POLL, function() waitForRotations(entries, deadline, callback) end)
  end
end

-- Mode first (the rotated panel reports portrait modes, e.g. 2160x3840), then origin,
-- one display at a time with a pause for WindowServer between changes
local function applyGeometry(entries, index, callback)
  local entry = entries[index]
  if not entry then
    callback(true)
    return
  end
  local t = entry.target
  local s = screenById(entry.screen:id())
  if not s then
    callback(false, entry.serial .. " vanished")
    return
  end
  local pause = 0.1
  if t.mode and not sameMode(t.mode, s:currentMode()) then
    local ok = s:setMode(t.mode.w, t.mode.h, t.mode.scale, t.mode.freq, t.mode.depth)
    log(string.format("%s %s: setMode %s → %s", t.side, entry.serial, fmtMode(t.mode), ok and "ok" or "FAILED"))
    pause = STEP_GAP
  end
  later(pause, function()
    local s2 = screenById(entry.screen:id())
    if not s2 then
      callback(false, entry.serial .. " vanished")
      return
    end
    local pause2 = 0.1
    if t.origin and not nearOrigin(s2:fullFrame(), t.origin) then
      local ok = s2:setOrigin(t.origin.x, t.origin.y)
      log(string.format("%s %s: setOrigin (%d,%d) → %s",
        t.side, entry.serial, t.origin.x, t.origin.y, ok and "ok" or "FAILED"))
      pause2 = STEP_GAP
    end
    later(pause2, function() applyGeometry(entries, index + 1, callback) end)
  end)
end

local fix  -- forward declaration (fix and failed call each other)

local function failed(cfgName, matched, attempt, opts, err)
  if attempt < MAX_ATTEMPTS then
    log(string.format("attempt %d failed (%s), retrying", attempt, err))
    later(5, function() fix(cfgName, matched, attempt + 1, opts) end)
  else
    finishEpisode(string.format("Error: gave up after %d attempts: %s", attempt, err), false, opts)
  end
end

local function verify(cfgName, matched, attempt, opts)
  local remaining, warnings, parts = {}, {}, {}
  for _, entry in ipairs(sortedEntries(matched)) do
    local s = screenById(entry.screen:id())
    if not s then
      remaining[#remaining + 1] = entry.serial .. " vanished"
    else
      entry.screen = s
      local problem = wrongRotation(entry)
      if problem then
        remaining[#remaining + 1] = problem
      elseif entry.target.origin and not nearOrigin(s:fullFrame(), entry.target.origin) then
        local f = s:fullFrame()
        warnings[#warnings + 1] = string.format("%s %s landed at (%d,%d), wanted (%d,%d)",
          entry.target.side, entry.serial, f.x, f.y, entry.target.origin.x, entry.target.origin.y)
      end
      parts[#parts + 1] = string.format("%s %s %s", entry.target.side, entry.serial, describe(s))
    end
  end
  if #remaining > 0 then
    failed(cfgName, matched, attempt, opts, table.concat(remaining, "; "))
    return
  end
  local summary = "fixed: " .. table.concat(parts, "; ")
  if #warnings > 0 then summary = summary .. " (warning: " .. table.concat(warnings, "; ") .. ")" end
  finishEpisode(summary, true, opts)
end

fix = function(cfgName, matched, attempt, opts)
  local entries = sortedEntries(matched)
  local function rotateNext(i)
    local entry = entries[i]
    if not entry then
      waitForRotations(entries, hs.timer.secondsSinceEpoch() + ROTATE_TIMEOUT, function(ok, err)
        if not ok then
          failed(cfgName, matched, attempt, opts, err)
          return
        end
        later(STEP_GAP, function()
          applyGeometry(entries, 1, function(ok2, err2)
            if not ok2 then
              failed(cfgName, matched, attempt, opts, err2)
              return
            end
            later(VERIFY_DELAY, function() verify(cfgName, matched, attempt, opts) end)
          end)
        end)
      end)
      return
    end
    local s = screenById(entry.screen:id())
    if not s then
      failed(cfgName, matched, attempt, opts, entry.serial .. " vanished")
      return
    end
    if s:rotate() == entry.target.rotation then
      rotateNext(i + 1)
      return
    end
    local uuid, target, current = s:getUUID(), entry.target.rotation, s:rotate()
    local function rotateToTarget()
      lunarRotate(uuid, target, 1, function(ok, err)
        if not ok then
          failed(cfgName, matched, attempt, opts, "Lunar rotation failed: " .. tostring(err))
          return
        end
        later(ROTATE_GAP, function() rotateNext(i + 1) end)
      end)
    end
    lunarBelievedRotation(uuid, function(believed)
      if believed ~= target then
        log(string.format("%s %s: rotating to %d via Lunar", entry.target.side, entry.serial, target))
        rotateToTarget()
        return
      end
      -- Lunar already holds the target, so asking for it would do nothing: nudge first
      log(string.format("%s %s: Lunar already believes %d, nudging through %d then %d",
        entry.target.side, entry.serial, believed, current, target))
      lunarRotate(uuid, current, 1, function(ok, err)
        if not ok then
          failed(cfgName, matched, attempt, opts, "Lunar nudge failed: " .. tostring(err))
          return
        end
        later(ROTATE_GAP, rotateToTarget)
      end)
    end)
  end
  rotateNext(1)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Asynchronous. opts.onFixed(summary) runs after a successful fix; opts.dryRun reports
-- without acting. Every check logs one verdict line.
function M.check(cfgName, reason, opts)
  opts = opts or {}
  local cfgTargets = loadTargets()[cfgName]
  if not cfgTargets then return end   -- nothing guarded in this config
  if busy then
    log("busy, ignoring check (" .. reason .. ")")
    return
  end
  later(SETTLE_DELAY, function()
    if busy then return end
    probe(function(rows, err)
      if not rows then
        setStatus("Error: " .. err)
        return
      end
      local matched = matchScreens(cfgTargets, rows)
      local entries = sortedEntries(matched)
      if #entries == 0 then return end   -- none of the guarded monitors is connected
      for _, entry in ipairs(entries) do
        if entry.asleep then
          log(string.format("%s asleep, skipping (%s)", entry.serial, reason))
          return
        end
      end
      local problems = {}
      for _, entry in ipairs(entries) do
        local p = wrongRotation(entry)
        if p then problems[#problems + 1] = p end
      end
      if #problems == 0 then
        learn(cfgName, matched)
        local parts = {}
        for _, entry in ipairs(entries) do
          parts[#parts + 1] = string.format("%s %s %s", entry.target.side, entry.serial, describe(entry.screen))
        end
        setStatus(string.format("ok (%s): %s", reason, table.concat(parts, "; ")))
        return
      end
      local what = table.concat(problems, "; ")
      if opts.dryRun then
        setStatus(string.format("dry run (%s): would fix %s", reason, what))
        return
      end
      local sinceLast = hs.timer.secondsSinceEpoch() - lastEpisodeEnd
      if sinceLast < COOLDOWN then
        -- Nothing else may trigger a check for a long time, so come back when the cooldown ends
        setStatus(string.format("cooling down, re-checking in %ds: %s", math.ceil(COOLDOWN - sinceLast), what))
        later(COOLDOWN - sinceLast + 1, function() M.check(cfgName, "cooldown-retry", opts) end)
        return
      end
      busy = true
      episode = episode + 1
      local thisEpisode = episode
      later(WATCHDOG, function()
        if busy and episode == thisEpisode then
          finishEpisode("Error: watchdog abandoned a stuck fix", false, opts)
        end
      end)
      log(string.format("fixing (%s): %s", reason, what))
      fix(cfgName, matched, 1, opts)
    end)
  end)
end

function M.isBusy()
  return busy
end

function M.status()
  return lastStatus
end

function M.reloadTargets()
  targets = nil
  return loadTargets()
end

return M
