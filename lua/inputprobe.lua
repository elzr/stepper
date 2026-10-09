-- Context for stepper's "[stepper] lost key-up" console line. On 2026-10-07 a key-up
-- went missing upstream of Hammerspoon, apparently after a wake, and nothing recorded
-- where. inputprobe.swift reads what Hammerspoon can't: whether the HID system still
-- holds the key down (key-up never generated, vs. eaten downstream by an event tap),
-- and every process's event taps on key events. Wake and unlock times frame the report.
-- See case-studies/2026-10-07-runaway-hotkey-repeat-after-lost-key-up.md
--
-- On 2026-10-09 the cause turned out to be Hammerspoon itself being busy: macOS drops a
-- hotkey's release when its modifier comes up before the key while Hammerspoon's main
-- thread is stuck. So stepper's repeat now asks the HID system directly whether the key
-- is still down (watchHold), and the report says how late the main thread ran.
-- See case-studies/2026-10-09-lost-key-up-walked-note-down.md

local M = {}

local scriptDir = debug.getinfo(1, "S").source:match("@(.*/)")
local SWIFTC = "/usr/bin/swiftc"              -- Xcode Command Line Tools
local toolSource = scriptDir .. "inputprobe.swift"
local toolBinary = scriptDir .. "inputprobe"  -- built from toolSource on demand, not tracked
-- The console doesn't survive a Hammerspoon relaunch or reboot; this does (untracked)
local logFile = scriptDir .. "../data/lost-key-ups.log"

-- The keys stepper binds (fn+arrows arrive as these) and the arrows themselves: an
-- arrow still held where its fn-key should be means the fn remap split the pair
local KEYCODES = {home = 115, ["end"] = 119, pageup = 116, pagedown = 121,
                  left = 123, right = 124, down = 125, up = 126}

local pending = {}           -- running hs.task objects, held so they aren't collected
local lastWake, lastUnlock = nil, nil
local SAVED_TIMES = "stepper.inputprobe.times"  -- hs.settings key: wake/unlock outlive reloads
local baseline = nil         -- {label = "wake"|"load", taps = {...}} for "changed since"

-- Main-thread lag: a ticker that notes every time it runs more than LAG_MIN late. The
-- reports quote the worst stall around the press, the condition that loses key-ups.
local LAG_TICK, LAG_MIN, LAG_KEEP = 0.25, 0.15, 120
local lastTick = nil
local lags = {}              -- {at = when the late tick finally ran, late = seconds}

local function oneLine(s)
  return (tostring(s or ""):gsub("%s+", " "))
end

-- Returns the task when it was launched, else nil; callback(exitCode, stdout, stderr)
local function run(binary, args, callback)
  local task
  task = hs.task.new(binary, function(exitCode, stdout, stderr)
    pending[task] = nil
    callback(exitCode, stdout, stderr)
  end, args)
  pending[task] = true
  if task:start() then return task end
  pending[task] = nil
  return nil
end

local function toolIsCurrent()
  local bin, src = hs.fs.attributes(toolBinary), hs.fs.attributes(toolSource)
  return bin ~= nil and src ~= nil and bin.modification >= src.modification
end

-- callback(true, doc) with the tool's JSON document, or callback(false, err)
local function probe(args, callback)
  local function launch()
    local launched = run(toolBinary, args, function(exitCode, stdout, stderr)
      local decoded, doc = pcall(hs.json.decode, stdout or "")
      if decoded and type(doc) == "table" and doc.ok then
        callback(true, doc)
      else
        callback(false, string.format("inputprobe exit %d: %s", exitCode,
          oneLine((stdout or "") .. " " .. (stderr or "")):sub(1, 160)))
      end
    end)
    if not launched then callback(false, "couldn't launch " .. toolBinary) end
  end
  if toolIsCurrent() then return launch() end
  local launched = run(SWIFTC, {"-O", "-o", toolBinary, toolSource}, function(exitCode, _, stderr)
    if exitCode == 0 then
      launch()
    else
      callback(false, string.format("swiftc exit %d: %s", exitCode, oneLine(stderr):sub(1, 160)))
    end
  end)
  if not launched then callback(false, "couldn't launch " .. SWIFTC) end
end

-- "Hyperkey session +up": +up marks taps that receive key-ups
local function tapIdentity(t)
  return string.format("%s %s%s%s", t.process, t.point, t.listenOnly and " listen" or "",
    t.keyUp and " +up" or "")
end

-- Only an enabled, filtering tap that receives key-ups can swallow one
local function keyUpSuspects(taps)
  local names, seen = {}, {}
  for _, t in ipairs(taps) do
    local name = t.process .. " " .. t.point
    if t.keyUp and t.enabled and not t.listenOnly and not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  return #names > 0 and table.concat(names, " · ") or "none"
end

-- Taps that appeared, vanished or switched on/off since the baseline census
local function changesSince(old, new)
  local function tally(taps)
    local on, all = {}, {}
    for _, t in ipairs(taps) do
      local id = tapIdentity(t)
      all[id] = (all[id] or 0) + 1
      if t.enabled then on[id] = (on[id] or 0) + 1 end
    end
    return on, all
  end
  local oldOn, oldAll = tally(old)
  local newOn, newAll = tally(new)
  local ids, changes = {}, {}
  for id in pairs(oldAll) do ids[id] = true end
  for id in pairs(newAll) do ids[id] = true end
  for id in pairs(ids) do
    local a, b = oldAll[id] or 0, newAll[id] or 0
    local aOn, bOn = oldOn[id] or 0, newOn[id] or 0
    if a ~= b then
      table.insert(changes, string.format("%s %d→%d", id, a, b))
    elseif aOn ~= bOn then
      table.insert(changes, string.format("%s on %d→%d", id, aOn, bOn))
    end
  end
  table.sort(changes)
  return changes
end

local function takeBaseline(label)
  probe({"taps"}, function(ok, doc)
    if ok then baseline = {label = label, taps = doc.taps} end
  end)
end

local function lagTick()
  local now = hs.timer.secondsSinceEpoch()
  if lastTick and now - lastTick - LAG_TICK > LAG_MIN then
    table.insert(lags, {at = now, late = now - lastTick - LAG_TICK})
  end
  lastTick = now
  while lags[1] and now - lags[1].at > LAG_KEEP do table.remove(lags, 1) end
end

-- "main thread stalled 2.0s, until 0.1s after the press": the worst stall that ended
-- between 3 s before the press (it held the press back) and 6 s after it
local function lagNear(pressAt)
  local worst = nil
  for _, l in ipairs(lags) do
    if l.at >= pressAt - 3 and l.at <= pressAt + 6 and (not worst or l.late > worst.late) then worst = l end
  end
  if not worst then return "main thread on time" end
  local offset = worst.at - pressAt
  return string.format("main thread stalled %.1fs, until %.1fs %s the press",
    worst.late, math.abs(offset), offset < 0 and "before" or "after")
end

local function saveTimes()
  hs.settings.set(SAVED_TIMES, {wake = lastWake, unlock = lastUnlock})
end

function M.init()
  local saved = hs.settings.get(SAVED_TIMES) or {}
  lastWake, lastUnlock = saved.wake, saved.unlock
  M._lagTimer = hs.timer.doEvery(LAG_TICK, lagTick)
  takeBaseline("load")  -- also builds the tool now, so it's ready before it's needed
end

function M.noteWake()
  lastWake = hs.timer.secondsSinceEpoch()
  saveTimes()
  takeBaseline("wake")
end

function M.noteUnlock()
  lastUnlock = hs.timer.secondsSinceEpoch()
  saveTimes()
end

-- What the last holds' watchers reported, newest last, for checking by IPC:
-- hs -c 'return _G._stepper.inputprobe.recentHolds()'
local holds = {}
local watchWarned = false

function M.recentHolds()
  local out = {}
  for _, h in ipairs(holds) do
    table.insert(out, string.format("%s  %-9s %s", os.date("%H:%M:%S", math.floor(h.at)), h.key, h.result))
  end
  return #out > 0 and table.concat(out, "\n") or "no holds watched since load"
end

-- Starts `inputprobe hold` on the key and calls onLetGo() once the HID system lets go of
-- it. Returns the task, to terminate when the hold is over some other way, or nil when
-- the tool isn't built yet (stepper's repeat then has only its own checks).
function M.watchHold(key, onLetGo)
  local code = hs.keycodes.map[key]
  local task = code and toolIsCurrent() and run(toolBinary, {"hold", tostring(code), "30"}, function(_, stdout)
    local result = "held until the hotkey release (watcher stopped)"
    -- A terminated watcher prints nothing; decoding that would log a LuaSkin error
    if (stdout or ""):find("^%s*{") then
      local decoded, doc = pcall(hs.json.decode, stdout)
      if decoded and type(doc) == "table" and doc.ok then
        result = string.format("keyboard let go after %d ms", doc.heldMs or -1)
        onLetGo()
      elseif decoded and type(doc) == "table" then
        result = "failed: " .. tostring(doc.error)
      end
    end
    table.insert(holds, {key = key, at = hs.timer.secondsSinceEpoch(), result = result})
    if #holds > 20 then table.remove(holds, 1) end
  end)
  if not task and not watchWarned then
    watchWarned = true
    print("[stepper] hold watcher unavailable (inputprobe not built or failed to start); "
      .. "key repeat falls back to the modifier check and the 5 s cap")
  end
  return task or nil
end

-- Console line, also kept in logFile for stepper's own keys (test keys like F20 aren't)
local function record(line, durable)
  print(line)
  if not durable then return end
  local f = io.open(logFile, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S  ") .. line .. "\n")
    f:close()
  end
end

-- Prints the lost key-up line with its context, then the tap census.
-- key is the Hammerspoon key name of the press (e.g. "end"), pressAt its time
function M.reportLostKeyUp(summary, key, pressAt)
  local durable = KEYCODES[key] ~= nil
  local now = hs.timer.secondsSinceEpoch()
  local context = {}
  if pressAt then table.insert(context, lagNear(pressAt)) end
  if lastWake then table.insert(context, string.format("%.1f min after wake", (now - lastWake) / 60)) end
  if lastUnlock then table.insert(context, string.format("%.1f min after unlock", (now - lastUnlock) / 60)) end
  table.insert(context, "secure input " .. (hs.eventtap.isSecureInputEnabled() and "ON" or "off"))

  local args = {"keys"}
  for _, code in pairs(KEYCODES) do table.insert(args, tostring(code)) end
  probe(args, function(ok, doc)
    if not ok then
      table.insert(context, "HID key state: " .. doc)
    elseif not doc.listenAccess then
      table.insert(context, "HID key state unreadable (no Input Monitoring access)")
    else
      local held = {}
      for name, code in pairs(KEYCODES) do
        if doc.down[tostring(code)] then table.insert(held, name) end
      end
      table.sort(held)
      table.insert(context, "HID holds: " .. (#held > 0 and table.concat(held, " ") or "nothing"))
    end
    record("[stepper] lost key-up: " .. summary .. " · " .. table.concat(context, " · "), durable)

    probe({"taps"}, function(okTaps, census)
      if not okTaps then
        record("[stepper] tap census failed: " .. census, durable)
        return
      end
      local line = "[stepper] taps that could drop a key-up: " .. keyUpSuspects(census.taps)
      if baseline then
        local changes = changesSince(baseline.taps, census.taps)
        line = line .. string.format(" | since %s: %s", baseline.label,
          #changes > 0 and table.concat(changes, ", ") or "no change")
      end
      record(line, durable)
    end)
  end)
end

return M
