-- =============================================================================
-- Per-screen window position memory
-- =============================================================================
-- Remembers where each window was on each screen, so cross-screen moves
-- restore the window's previous position on the target screen.
--
-- Two-tier storage:
--   Session memory (winID key)      — in-memory, all windows, lost on reload
--   Persistent memory (app+title)   — on disk, survives reload, 30-day expiry,
--                                     newest MAX_TITLES_PER_APP titles per app
--
-- screenmemory.saveDeparture(win, screenPos)   — record frame before moving away
-- screenmemory.lookupArrival(win, screenPos)   — returns frameRel or nil
-- screenmemory.updateFromLayout(entries, ids)  — bulk update from layout autosave
-- screenmemory.seedFromRestore(win, pos, rel)  — seed session after layout restore
--
-- On disk the memory is one flat JSON object, "App\nTitle\nscreenPos" → "x y w h ts".
-- hs.json.decode slows with the square of how many same-sized objects a document holds,
-- and until 2026-10-09 this file kept one {frameRel = {x, y, w, h}, ts} per window and
-- screen: its 2,881 entries took 8.7 s to load at every reload, all of it on
-- Hammerspoon's main thread. Strings decode in linear time.
-- See changelog/2026-10-09-layout-saves-off-the-main-thread.md

local M = {}

local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local dataFile = scriptPath .. "../data/screen-memory.json"

local PRUNE_AGE = 30 * 24 * 3600  -- 30 days in seconds
local WRITE_DEBOUNCE = 5          -- seconds after last change
-- Titles kept per app, newest first. Apps whose titles keep changing filled the memory
-- otherwise: a Chrome tab with a clock in its title added a key every minute, 1,401
-- Chrome titles by 2026-10-09.
local MAX_TITLES_PER_APP = 200

-- Session memory: winID → screenPos → {frameRel={x,y,w,h}, ts=epoch}
local sessionMemory = {}

-- Persistent memory: "app\ntitle" → screenPos → {frameRel={x,y,w,h}, ts=epoch}
local persistentMemory = {}

-- Rename tracking: winID → {app=str, title=str}
local lastKnownTitle = {}

-- Debounced disk write
local writeTimer = nil
local dirty = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function persistKey(appName, title)
  return appName .. "\n" .. title
end

local function now()
  return hs.timer.secondsSinceEpoch()
end

-- ---------------------------------------------------------------------------
-- Pruning: 30-day expiry, and each app's newest MAX_TITLES_PER_APP titles
-- ---------------------------------------------------------------------------

local function prune()
  local cutoff = now() - PRUNE_AGE
  local pruned = 0
  local titlesByApp = {}  -- app → {{key, ts of its newest entry}, ...}
  for key, screens in pairs(persistentMemory) do
    local newest = 0
    for pos, entry in pairs(screens) do
      if entry.ts and entry.ts < cutoff then
        screens[pos] = nil
        pruned = pruned + 1
      elseif (entry.ts or 0) > newest then
        newest = entry.ts or 0
      end
    end
    if not next(screens) then
      persistentMemory[key] = nil
    else
      local app = key:match("^(.-)\n") or key
      titlesByApp[app] = titlesByApp[app] or {}
      table.insert(titlesByApp[app], {key = key, ts = newest})
    end
  end
  for _, titles in pairs(titlesByApp) do
    if #titles > MAX_TITLES_PER_APP then
      table.sort(titles, function(a, b) return a.ts > b.ts end)
      for i = MAX_TITLES_PER_APP + 1, #titles do
        for _ in pairs(persistentMemory[titles[i].key]) do pruned = pruned + 1 end
        persistentMemory[titles[i].key] = nil
      end
    end
  end
  return pruned
end

-- ---------------------------------------------------------------------------
-- Disk I/O
-- ---------------------------------------------------------------------------

local function writeToDisk()
  prune()
  local flat = {}
  for key, screens in pairs(persistentMemory) do
    for pos, entry in pairs(screens) do
      local r = entry.frameRel
      if r then
        flat[key .. "\n" .. pos] = string.format("%.6f %.6f %.6f %.6f %d",
          r.x, r.y, r.w, r.h, math.floor(entry.ts or 0))
      end
    end
  end
  local json = hs.json.encode(flat, true)
  local fh, err = io.open(dataFile, "w")
  if not fh then
    print("[screenmemory] ERROR: could not write " .. dataFile .. ": " .. tostring(err))
    return
  end
  fh:write(json)
  fh:close()
  dirty = false
end

local function scheduleDiskWrite()
  dirty = true
  if writeTimer then writeTimer:stop() end
  writeTimer = hs.timer.doAfter(WRITE_DEBOUNCE, function()
    writeTimer = nil
    writeToDisk()
  end)
end

local function loadFromDisk()
  local fh = io.open(dataFile, "r")
  if not fh then return end
  local json = fh:read("*a")
  fh:close()
  local ok, data = pcall(hs.json.decode, json)
  if not ok or type(data) ~= "table" then return end
  local nested = false
  for k, v in pairs(data) do
    if type(v) == "string" then
      local key, pos = k:match("^(.*)\n([^\n]*)$")
      local x, y, w, h, ts = v:match("^(%S+) (%S+) (%S+) (%S+) (%S+)$")
      if key and x then
        persistentMemory[key] = persistentMemory[key] or {}
        persistentMemory[key][pos] = {
          frameRel = {x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h)},
          ts = tonumber(ts),
        }
      end
    elseif type(v) == "table" then
      persistentMemory[k] = v  -- the nested shape from before 2026-10-09
      nested = true
    end
  end
  -- Store it flat right away, so the next load is quick
  if nested then scheduleDiskWrite() end
end

-- ---------------------------------------------------------------------------
-- M.init()
-- ---------------------------------------------------------------------------

function M.init()
  loadFromDisk()
  local pruned = prune()
  if pruned > 0 then
    print(string.format("[screenmemory] Pruned %d entries (older than 30 days, or past %d titles per app)",
      pruned, MAX_TITLES_PER_APP))
    scheduleDiskWrite()
  end
  local count = 0
  for _ in pairs(persistentMemory) do count = count + 1 end
  print(string.format("[screenmemory] Loaded %d persistent entries from disk", count))
end

-- ---------------------------------------------------------------------------
-- M.saveDeparture(win, screenPos)
-- ---------------------------------------------------------------------------
-- Called BEFORE a window moves away from a screen. Records current frame.

function M.saveDeparture(win, screenPos)
  if not win or not screenPos then return end

  local app = win:application()
  if not app then return end
  local winID = win:id()
  local appName = app:name()
  local title = win:title()
  local f = win:frame()
  local sf = win:screen():frame()

  local frameRel = {
    x = (f.x - sf.x) / sf.w,
    y = (f.y - sf.y) / sf.h,
    w = f.w / sf.w,
    h = f.h / sf.h,
  }

  local ts = now()

  -- Session memory
  if not sessionMemory[winID] then sessionMemory[winID] = {} end
  sessionMemory[winID][screenPos] = {frameRel = frameRel, ts = ts}

  -- Rename detection: if title changed, migrate persistent entries
  local curKey = persistKey(appName, title)
  local prev = lastKnownTitle[winID]
  if prev then
    local prevKey = persistKey(prev.app, prev.title)
    if prevKey ~= curKey then
      -- Merge old entries into new key (keep newer timestamps)
      local oldEntries = persistentMemory[prevKey]
      if oldEntries then
        if not persistentMemory[curKey] then persistentMemory[curKey] = {} end
        for pos, entry in pairs(oldEntries) do
          local existing = persistentMemory[curKey][pos]
          if not existing or existing.ts < entry.ts then
            persistentMemory[curKey][pos] = entry
          end
        end
        persistentMemory[prevKey] = nil
        print(string.format("[screenmemory] Renamed: '%s' → '%s'", prev.title, title))
      end
    end
  end
  lastKnownTitle[winID] = {app = appName, title = title}

  -- Persistent memory
  if not persistentMemory[curKey] then persistentMemory[curKey] = {} end
  persistentMemory[curKey][screenPos] = {frameRel = frameRel, ts = ts}

  scheduleDiskWrite()
end

-- ---------------------------------------------------------------------------
-- M.lookupArrival(win, screenPos)
-- ---------------------------------------------------------------------------
-- Returns frameRel table {x, y, w, h} or nil.

function M.lookupArrival(win, screenPos)
  if not win or not screenPos then return nil end

  local winID = win:id()

  -- Tier 1: session memory (exact winID)
  local session = sessionMemory[winID]
  if session and session[screenPos] then
    return session[screenPos].frameRel
  end

  -- Tier 2: persistent memory (app+title)
  local app = win:application()
  if app then
    local key = persistKey(app:name(), win:title())
    local persist = persistentMemory[key]
    if persist and persist[screenPos] then
      return persist[screenPos].frameRel
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- M.updateFromLayout(entries)
-- ---------------------------------------------------------------------------
-- Bulk update from layout.save() data. Each entry has app, title,
-- screenPosition, frameRel. Called after position-protection substitution,
-- so entries reflect correct (not macOS-shuffled) positions. liveIDs maps
-- "App\nTitle" to the live window id; layout passes the ones its snapshot read.

function M.updateFromLayout(entries, liveIDs)
  if not entries then return end

  local ts = now()

  -- Build live winID lookup for session memory updates
  local titleToWinID = liveIDs
  if not titleToWinID then
    titleToWinID = {}
    for _, win in ipairs(hs.window.orderedWindows()) do
      local app = win:application()
      if app then
        local key = persistKey(app:name(), win:title())
        titleToWinID[key] = win:id()
      end
    end
  end

  for _, entry in ipairs(entries) do
    if entry.screenPosition and entry.frameRel then
      local key = persistKey(entry.app, entry.title)

      -- Update persistent memory
      if not persistentMemory[key] then persistentMemory[key] = {} end
      persistentMemory[key][entry.screenPosition] = {
        frameRel = entry.frameRel,
        ts = ts,
      }

      -- Update session memory if we can find the live window
      local winID = titleToWinID[key]
      if winID then
        if not sessionMemory[winID] then sessionMemory[winID] = {} end
        sessionMemory[winID][entry.screenPosition] = {
          frameRel = entry.frameRel,
          ts = ts,
        }
      end
    end
  end

  scheduleDiskWrite()
end

-- ---------------------------------------------------------------------------
-- M.seedFromRestore(win, screenPos, frameRel)
-- ---------------------------------------------------------------------------
-- Called after layout restore places a window. Seeds session memory only.

function M.seedFromRestore(win, screenPos, frameRel)
  if not win or not screenPos or not frameRel then return end
  local winID = win:id()
  if not sessionMemory[winID] then sessionMemory[winID] = {} end
  sessionMemory[winID][screenPos] = {
    frameRel = frameRel,
    ts = now(),
  }
end

return M
