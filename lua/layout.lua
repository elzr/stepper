-- =============================================================================
-- Window layout save / restore / gather
-- =============================================================================
-- layout.save()    — snapshot all visible window positions to data/window-layout.json
-- layout.restore() — restore windows to saved positions
-- layout.gather()  — consolidate all windows into one space on the built-in display
--
-- Designed for a 5-display setup with 4 identical LG HDR 4K monitors (no serials).
-- Screens are identified by spatial position name (via screenswitch.buildScreenMap),
-- with origin/resolution fallback for backwards compatibility.

local M = {}

local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local dataFile = scriptPath .. "../data/window-layout.json"
local lunarSyncScript = scriptPath .. "../features/sync-display-names-in-Lunar/lunar-sync-names.py"

local TARGET_DISPLAY_COUNT = 5
local DEBOUNCE_DELAY = 2          -- seconds (screens appear sequentially)
local PERIODIC_SAVE_INTERVAL = 300  -- 5 minutes
local LUNAR_SYNC_DELAY = 3         -- seconds after screen stabilization

local screenWatcher = nil
local debounceTimer = nil
local periodicTimer = nil
local lunarSyncTimer = nil
local lastScreenCount = 0

-- screenswitch module reference (set during init)
local screenswitch = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function roundFrame(f)
  return {
    x = math.floor(f.x + 0.5),
    y = math.floor(f.y + 0.5),
    w = math.floor(f.w + 0.5),
    h = math.floor(f.h + 0.5),
  }
end

-- Reverse lookup: screen ID -> position name using screenswitch.buildScreenMap()
local function buildScreenIdToPosition()
  if not screenswitch then return {} end
  local map = screenswitch.buildScreenMap()
  local idToPos = {}
  for position, screen in pairs(map) do
    idToPos[screen:id()] = position
  end
  return idToPos
end

-- Find the live screen matching a saved entry.
-- Pass 1: position name match (stable across reconnections)
-- Pass 2: origin match (for backwards compat with old save files)
-- Pass 3: resolution match
-- Pass 4: mainScreen fallback
local function findScreen(entry)
  local savedSF = entry.screenFrame
  local savedPos = entry.screenPosition
  local tol = 2
  local allScreens = hs.screen.allScreens()

  -- Pass 1: position name match via screenswitch
  if savedPos and screenswitch then
    local map = screenswitch.buildScreenMap()
    if map[savedPos] then
      return map[savedPos], "position"
    end
  end

  -- Pass 2: exact origin match
  for _, s in ipairs(allScreens) do
    local sf = s:frame()
    if math.abs(sf.x - savedSF.x) <= tol and math.abs(sf.y - savedSF.y) <= tol then
      return s, "exact"
    end
  end

  -- Pass 3: resolution match
  for _, s in ipairs(allScreens) do
    local sf = s:frame()
    if math.abs(sf.w - savedSF.w) <= tol and math.abs(sf.h - savedSF.h) <= tol then
      return s, "resolution"
    end
  end

  return hs.screen.mainScreen(), "fallback"
end

local function showRestoreHint()
  print("[layout] Restore available — fn+ctrl+alt+delete to restore layout")
end

-- ---------------------------------------------------------------------------
-- Lunar display name sync
-- ---------------------------------------------------------------------------
-- Position names displayed in Lunar's UI (matches user's existing naming)
local positionNames = {
  bottom = "↓Bottom Center",
  center = "⊙Middle Center",
  top    = "↑Top Center",
  left   = "←Left",
  right  = "Right→",
}

local function syncLunarNames()
  if not screenswitch then
    print("[layout.lunar] screenswitch not available, skipping sync")
    return
  end

  local map = screenswitch.buildScreenMap()
  local uuidToName = {}

  for position, screen in pairs(map) do
    local uuid = screen:getUUID()
    local name = positionNames[position]
    if uuid and name then
      uuidToName[uuid] = name
    end
  end

  if not next(uuidToName) then
    print("[layout.lunar] No screens mapped, skipping sync")
    return
  end

  local jsonArg = hs.json.encode(uuidToName)
  -- Escape single quotes in JSON for shell
  jsonArg = jsonArg:gsub("'", "'\\''")

  -- Quit Lunar, update plist, relaunch (only if names changed)
  local cmd = string.format(
    "python3 '%s' '%s'\n" ..
    "rc=$?\n" ..
    "if [ $rc -eq 0 ]; then\n" ..
    "  osascript -e 'tell application \"Lunar\" to quit' 2>/dev/null\n" ..
    "  sleep 2\n" ..
    "  open -a Lunar\n" ..
    "  echo 'RESTARTED'\n" ..
    "fi\n" ..
    "exit $rc",
    lunarSyncScript, jsonArg
  )

  hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
    if stdout and #stdout > 0 then
      for line in stdout:gmatch("[^\n]+") do
        print("[layout.lunar] " .. line)
      end
    end
    if exitCode == 0 then
      print("[layout.lunar] Lunar display names synced and relaunched")
    elseif exitCode == 1 then
      print("[layout.lunar] Names already correct")
    else
      print("[layout.lunar] Error: " .. tostring(stderr))
    end
  end, {"-c", cmd}):start()
end

function M.syncLunarNames()
  syncLunarNames()
end

-- ---------------------------------------------------------------------------
-- M.save()
-- ---------------------------------------------------------------------------

function M.save()
  local windows = hs.window.orderedWindows()
  local entries = {}
  local idToPos = buildScreenIdToPosition()

  for _, win in ipairs(windows) do
    local app = win:application()
    if not app then goto continue end

    local screen = win:screen()
    local sf = screen:frame()
    local f  = win:frame()
    local rf = roundFrame(f)
    local rsf = roundFrame(sf)

    table.insert(entries, {
      app            = app:name(),
      title          = win:title(),
      screenPosition = idToPos[screen:id()],
      screenFrame    = rsf,
      frame          = rf,
      frameRel       = {
        x = (f.x - sf.x) / sf.w,
        y = (f.y - sf.y) / sf.h,
        w = f.w / sf.w,
        h = f.h / sf.h,
      },
    })

    ::continue::
  end

  if #entries == 0 then
    print("[layout.save] Skipping save — 0 windows found (display may still be waking)")
    return
  end

  local json = hs.json.encode(entries, true)
  local fh, err = io.open(dataFile, "w")
  if not fh then
    print("[layout.save] ERROR: could not write " .. dataFile .. ": " .. tostring(err))
    return
  end
  fh:write(json)
  fh:close()

  print(string.format("[layout.save] Saved %d windows to %s", #entries, dataFile))
end

-- ---------------------------------------------------------------------------
-- M.restore()
-- ---------------------------------------------------------------------------

function M.restore()
  local fh = io.open(dataFile, "r")
  if not fh then
    print("[layout.restore] No saved layout found at " .. dataFile)
    return
  end
  local json = fh:read("*a")
  fh:close()

  local ok, entries = pcall(hs.json.decode, json)
  if not ok or type(entries) ~= "table" then
    print("[layout.restore] ERROR: could not parse layout JSON")
    return
  end

  -- Build per-app window list (same order as hs.window.allWindows, for index fallback)
  local appWindows = {}  -- appName -> { win, ... }
  for _, win in ipairs(hs.window.allWindows()) do
    local app = win:application()
    if app then
      local name = app:name()
      if not appWindows[name] then appWindows[name] = {} end
      table.insert(appWindows[name], win)
    end
  end

  -- Track which windows have been matched (to avoid double-matching)
  local matched = {}  -- winID -> true

  -- Match each saved entry to a live window
  local pairs_list = {}  -- { win, entry } for matched windows

  for idx, entry in ipairs(entries) do
    local candidates = appWindows[entry.app] or {}

    local found = nil

    -- Tier 1: exact title match
    for _, win in ipairs(candidates) do
      if not matched[win:id()] and win:title() == entry.title then
        found = win
        break
      end
    end

    -- Tier 2: 40-char prefix match
    if not found then
      local savedPrefix = entry.title:sub(1, 40)
      for _, win in ipairs(candidates) do
        if not matched[win:id()] and win:title():sub(1, 40) == savedPrefix then
          found = win
          break
        end
      end
    end

    -- Tier 3: index fallback (nth unmatched window for this app)
    if not found then
      local appIdx = 0
      for _, win in ipairs(candidates) do
        if not matched[win:id()] then
          appIdx = appIdx + 1
          -- Count how many saved entries before this one are for the same app
          -- and also unmatched → use a simple approach: match by insertion order
          found = win
          break
        end
      end
    end

    if found then
      matched[found:id()] = true
      table.insert(pairs_list, { win = found, entry = entry, idx = idx })
    end
  end

  -- Phase 1: restore frames
  local savedCount = 0
  local skippedCount = #entries - #pairs_list

  local origDuration = hs.window.animationDuration
  hs.window.animationDuration = 0

  for _, p in ipairs(pairs_list) do
    local win, entry = p.win, p.entry
    local screen, matchType = findScreen(entry)
    local sf = screen:frame()
    local targetFrame

    if matchType == "exact" or matchType == "position" then
      targetFrame = entry.frame
      -- If position matched but origins differ, use relative coordinates
      local sf_saved = entry.screenFrame
      if math.abs(sf.x - sf_saved.x) > 2 or math.abs(sf.y - sf_saved.y) > 2 then
        local rel = entry.frameRel
        targetFrame = {
          x = math.floor(sf.x + rel.x * sf.w + 0.5),
          y = math.floor(sf.y + rel.y * sf.h + 0.5),
          w = math.floor(rel.w * sf.w + 0.5),
          h = math.floor(rel.h * sf.h + 0.5),
        }
      end
    else
      -- Scale from relative coordinates onto the found screen
      local rel = entry.frameRel
      targetFrame = {
        x = math.floor(sf.x + rel.x * sf.w + 0.5),
        y = math.floor(sf.y + rel.y * sf.h + 0.5),
        w = math.floor(rel.w * sf.w + 0.5),
        h = math.floor(rel.h * sf.h + 0.5),
      }
    end

    win:setFrame(targetFrame)
    savedCount = savedCount + 1
  end

  hs.window.animationDuration = origDuration

  -- Phase 2: restore z-order (back-to-front = reverse array order)
  for i = #pairs_list, 1, -1 do
    pairs_list[i].win:focus()
  end

  print(string.format("[layout.restore] Restored %d windows, skipped %d", savedCount, skippedCount))
end

-- ---------------------------------------------------------------------------
-- M.gather()
-- ---------------------------------------------------------------------------

function M.gather()
  local mainScreen = hs.screen.mainScreen()
  local mainFrame  = mainScreen:frame()
  local closedSpaces = 0
  local movedWindows = 0

  -- Phase 1: close extra Mission Control spaces on built-in display
  local ok, spaces = pcall(function() return hs.spaces.allSpaces() end)
  if ok and spaces then
    local uuid = mainScreen:getUUID()
    local screenSpaces = spaces[uuid]
    if screenSpaces and #screenSpaces > 1 then
      -- Keep the first space; remove the rest (macOS migrates windows automatically)
      local activeSpace = hs.spaces.activeSpaceOnScreen(mainScreen)
      local keepID = activeSpace or screenSpaces[1]

      for _, sid in ipairs(screenSpaces) do
        if sid ~= keepID then
          local removeOk, err = pcall(hs.spaces.removeSpace, sid)
          if removeOk then
            closedSpaces = closedSpaces + 1
          else
            print(string.format("[layout.gather] Could not remove space %s: %s", tostring(sid), tostring(err)))
          end
        end
      end
    end
  else
    print("[layout.gather] hs.spaces not available (requires Accessibility permission)")
  end

  -- Phase 2: move windows on external displays to built-in (if externals are present)
  local allScreens = hs.screen.allScreens()
  if #allScreens > 1 then
    local origDuration = hs.window.animationDuration
    hs.window.animationDuration = 0

    for _, win in ipairs(hs.window.allWindows()) do
      local winScreen = win:screen()
      if winScreen and winScreen:id() ~= mainScreen:id() then
        local sf  = winScreen:frame()
        local f   = win:frame()

        -- Compute screen-relative position, scale onto built-in
        local relX = (f.x - sf.x) / sf.w
        local relY = (f.y - sf.y) / sf.h
        local relW = f.w / sf.w
        local relH = f.h / sf.h

        local newFrame = {
          x = math.floor(mainFrame.x + relX * mainFrame.w + 0.5),
          y = math.floor(mainFrame.y + relY * mainFrame.h + 0.5),
          w = math.floor(relW * mainFrame.w + 0.5),
          h = math.floor(relH * mainFrame.h + 0.5),
        }

        -- Clamp to built-in bounds
        newFrame.x = math.max(mainFrame.x, math.min(newFrame.x, mainFrame.x + mainFrame.w - newFrame.w))
        newFrame.y = math.max(mainFrame.y, math.min(newFrame.y, mainFrame.y + mainFrame.h - newFrame.h))

        win:setFrame(newFrame)
        movedWindows = movedWindows + 1
      end
    end

    hs.window.animationDuration = origDuration
  end

  print(string.format("[layout.gather] Closed %d spaces, moved %d windows to built-in", closedSpaces, movedWindows))
end

-- ---------------------------------------------------------------------------
-- M.autoSave() — guarded: only saves when at TARGET_DISPLAY_COUNT
-- ---------------------------------------------------------------------------

function M.autoSave()
  local count = #hs.screen.allScreens()
  if count ~= TARGET_DISPLAY_COUNT then
    return
  end
  M.save()
end

-- ---------------------------------------------------------------------------
-- Screen watcher — detect display changes, prompt for restore
-- ---------------------------------------------------------------------------

local function startPeriodicSave()
  if periodicTimer then periodicTimer:stop() end
  periodicTimer = hs.timer.doEvery(PERIODIC_SAVE_INTERVAL, function()
    M.autoSave()
  end)
  print("[layout] Periodic auto-save started (every " .. PERIODIC_SAVE_INTERVAL .. "s)")
end

local function stopPeriodicSave()
  if periodicTimer then
    periodicTimer:stop()
    periodicTimer = nil
    print("[layout] Periodic auto-save stopped")
  end
end

local function onScreenChange()
  -- Reset debounce timer on every callback (collapses rapid sequential detections)
  if debounceTimer then debounceTimer:stop() end
  debounceTimer = hs.timer.doAfter(DEBOUNCE_DELAY, function()
    local count = #hs.screen.allScreens()
    print(string.format("[layout] Screens stabilized: %d (was %d)", count, lastScreenCount))

    if count == TARGET_DISPLAY_COUNT and lastScreenCount ~= TARGET_DISPLAY_COUNT then
      -- Transitioning TO 5 displays — auto-restore after a short delay
      -- (give macOS a moment to finalize screen arrangement)
      hs.timer.doAfter(1, function()
        print("[layout] Auto-restoring layout for " .. TARGET_DISPLAY_COUNT .. " displays")
        M.restore()
      end)
      startPeriodicSave()
      -- Sync Lunar display names after a short delay for Lunar to detect screens
      if lunarSyncTimer then lunarSyncTimer:stop() end
      lunarSyncTimer = hs.timer.doAfter(LUNAR_SYNC_DELAY, syncLunarNames)
    elseif count ~= TARGET_DISPLAY_COUNT and lastScreenCount == TARGET_DISPLAY_COUNT then
      -- Transitioning FROM 5 displays
      stopPeriodicSave()
    end

    lastScreenCount = count
  end)
end

-- ---------------------------------------------------------------------------
-- M.onWake() — show restore prompt if waking at 5 displays
-- ---------------------------------------------------------------------------

function M.onWake()
  if #hs.screen.allScreens() == TARGET_DISPLAY_COUNT then
    showRestoreHint()
  end
end

-- ---------------------------------------------------------------------------
-- M.init() — start screen watcher and periodic save if already at 5
-- ---------------------------------------------------------------------------

function M.init(opts)
  opts = opts or {}
  screenswitch = opts.screenswitch

  lastScreenCount = #hs.screen.allScreens()

  screenWatcher = hs.screen.watcher.new(onScreenChange)
  screenWatcher:start()
  print("[layout] Screen watcher started")

  if lastScreenCount == TARGET_DISPLAY_COUNT then
    startPeriodicSave()
  end
end

return M
