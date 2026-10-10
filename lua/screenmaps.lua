-- =============================================================================
-- Screenmaps — a digital twin of each display config's layout
-- =============================================================================
-- layout.lua hands over every save that changed something. This writes what the page in
-- features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/ draws:
--   data/screenmap-<config>.json  every display (with its size in millimetres), the windows
--                                 front to back and the minimized ones, each with when it
--                                 was first saved, last moved and last used. One file per
--                                 config, so each keeps its last layout while you're away
--   data/screenmaps-now.json      the current config, and when each config was saved
-- It also saves the app icons the page shows (data/app-icons/<bundleID>.png, shared with
-- bear-hud and keymapwatch), and brings a window forward when the page asks:
-- hammerspoon://screenmaps?focus=<window id>
--
-- screenmaps.init()                               — the URL handler
-- screenmaps.setConfigs(knownConfigs)             — layout.lua's KNOWN_CONFIGS
-- screenmaps.setCurrent(name, screenCount)        — the config in use
-- screenmaps.record(name, count, entries, ids, idToPos, extra) — a save that changed something

local M = {}

local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local dataDir = scriptPath .. "../data/"
local iconDir = dataDir .. "app-icons/"
local nowFile = dataDir .. "screenmaps-now.json"
local MOVE_TOL = 2  -- px: a frame within this of the last one hasn't moved (Retina rounding)

local configs = {}    -- {name, screens}, most screens first
local current = nil   -- {name, screens}
-- App name → bundle ID: the running apps, read at each config change (walking all ~190
-- processes takes ~40 ms), plus every app a save records
local appBundles = {}

-- Per config, what the last record said:
--   byKey[key]  {seen, moved, used, frame, screen, minimized}, key = window id, or
--               "App\nTitle" for a window kept from an earlier save
--   order       the on-screen windows' keys, front to back
--   minimized   the minimized windows' records, kept for apps that don't answer
--   since       when this config's screenmap began: windows first saved then were
--               already open, and how long before is unknown
local known = {}
local iconChecked = {}  -- bundle IDs whose icon was looked for since load

local function mapFile(name) return dataDir .. "screenmap-" .. name .. ".json" end

local function keyOf(w) return w.id or (tostring(w.app) .. "\n" .. tostring(w.title)) end

local function writeJSON(path, value)
  local fh, err = io.open(path, "w")
  if not fh then
    print("[screenmaps] ERROR: could not write " .. path .. ": " .. tostring(err))
    return false
  end
  fh:write(hs.json.encode(value, true))
  fh:close()
  return true
end

local function mtime(path)
  local a = hs.fs.attributes(path)
  return a and math.floor(a.modification) or nil
end

local function rect(f)
  return {x = math.floor(f.x + 0.5), y = math.floor(f.y + 0.5),
          w = math.floor(f.w + 0.5), h = math.floor(f.h + 0.5)}
end

-- Once per load and app: the icon file outlives reloads
local function ensureIcon(bundle)
  if not bundle or iconChecked[bundle] then return end
  iconChecked[bundle] = true
  local path = iconDir .. bundle .. ".png"
  if hs.fs.attributes(path) then return end
  local img = hs.image.imageFromAppBundle(bundle)
  if not img then return end
  hs.fs.mkdir(iconDir)
  img:copy():setSize({w = 64, h = 64}):saveToFile(path)
end

-- The current config; per config, when its screenmap and its layout were last written
-- (the page rebuilds a config that has no screenmap yet from its layout file); and the
-- running apps' bundle IDs by name, which give icons to those older layouts' windows
local function writeNow()
  local list = {}
  for _, c in ipairs(configs) do
    table.insert(list, {
      name = c.name,
      screens = c.screens,
      saved = mtime(mapFile(c.name)),
      layoutSaved = mtime(dataDir .. string.format("window-layout-%d.json", c.screens)),
    })
  end
  writeJSON(nowFile, {current = current and current.name, configs = list, apps = appBundles})
end

local function readRunningApps()
  for _, app in ipairs(hs.application.runningApplications()) do
    local name, bundle = app:name(), app:bundleID()
    if app:kind() == 1 and name and bundle then
      appBundles[name] = bundle
      ensureIcon(bundle)
    end
  end
end

-- What this config's file says, the first time it's recorded after a load, so the times
-- outlive reloads
local function seed(name)
  local s = {byKey = {}, order = {}, minimized = {}}
  local fh = io.open(mapFile(name), "r")
  if not fh then return s end
  local ok, doc = pcall(hs.json.decode, fh:read("*a"))
  fh:close()
  if not (ok and type(doc) == "table") then return s end
  local earliest = nil
  for _, w in ipairs(type(doc.windows) == "table" and doc.windows or {}) do
    s.byKey[keyOf(w)] = {seen = w.seen, moved = w.moved, used = w.used, frame = w.frame, screen = w.screen}
    table.insert(s.order, keyOf(w))
    if w.seen and (not earliest or w.seen < earliest) then earliest = w.seen end
  end
  for _, w in ipairs(type(doc.minimized) == "table" and doc.minimized or {}) do
    s.byKey[keyOf(w)] = {seen = w.seen, moved = w.moved, used = w.used, frame = w.frame,
                         screen = w.screen, minimized = true}
    table.insert(s.minimized, w)
  end
  -- A file from before "since" was kept: its first save was the earliest first-saved time
  s.since = doc.since or earliest
  return s
end

local function sameSpot(prev, frame, screen)
  local p = prev.frame
  return p and prev.screen == screen
    and math.abs(p.x - frame.x) <= MOVE_TOL and math.abs(p.y - frame.y) <= MOVE_TOL
    and math.abs(p.w - frame.w) <= MOVE_TOL and math.abs(p.h - frame.h) <= MOVE_TOL
end

function M.setConfigs(knownConfigs)
  configs = {}
  for count, cfg in pairs(knownConfigs) do
    table.insert(configs, {name = cfg.name, screens = count})
  end
  table.sort(configs, function(a, b) return a.screens > b.screens end)
end

function M.setCurrent(name, count)
  current = {name = name, screens = count}
  readRunningApps()
  writeNow()
end

-- entries: the save, front to back (layout.lua's fileSnapshot, after position
-- protection); ids[i]: entries[i]'s window id, nil for a window kept from an earlier
-- save; idToPos: screen id → position name; extra: the helper's displays (sizes in mm),
-- minimized windows, and the apps that didn't answer
function M.record(name, count, entries, ids, idToPos, extra)
  extra = extra or {}
  local now = os.time()
  local before = known[name] or seed(name)
  local after = {byKey = {}, order = {}, minimized = {}, since = before.since or now}

  -- Where the window that was in front last time stands now: every window above it was
  -- brought forward since, which is the use a save can see
  local keys, prevFrontAt = {}, nil
  for i, e in ipairs(entries) do
    keys[i] = ids[i] or (e.app .. "\n" .. e.title)
    if keys[i] == before.order[1] then prevFrontAt = i end
  end

  local windows = {}
  for i, e in ipairs(entries) do
    local prev = before.byKey[keys[i]]
    local samePlace = prev and sameSpot(prev, e.frame, e.screenPosition)
    -- In use: new, moved, back from the Dock, in front, or raised above the last front one
    local inUse = not samePlace or prev.minimized or i == 1 or (prevFrontAt and i < prevFrontAt)
    local w = {
      id = ids[i], app = e.app, bundle = e.bundle, title = e.title,
      screen = e.screenPosition, frame = e.frame,
      seen = prev and prev.seen or now,
      moved = samePlace and prev.moved or now,
      used = inUse and now or (prev.used or prev.seen or now),
    }
    table.insert(windows, w)
    table.insert(after.order, keys[i])
    after.byKey[keys[i]] = {seen = w.seen, moved = w.moved, used = w.used, frame = w.frame, screen = w.screen}
    if e.bundle then appBundles[e.app] = e.bundle end
    ensureIcon(e.bundle)
  end

  local failedApps = {}
  for _, f in ipairs(extra.failed or {}) do failedApps[f.app] = true end
  for _, m in ipairs(extra.minimized or {}) do
    local frame = rect(m)
    local key = m.id or (m.app .. "\n" .. m.title)
    local prev = before.byKey[key]
    local screen = hs.screen.find(frame)
    local w = {
      id = m.id, app = m.app, bundle = m.bundle ~= "" and m.bundle or nil, title = m.title,
      screen = screen and idToPos[screen:id()], frame = frame,
      seen = prev and prev.seen or now,
      moved = prev and prev.moved or now,
      -- Minimizing it was using it
      used = (prev and prev.minimized) and (prev.used or prev.seen or now) or now,
    }
    table.insert(after.minimized, w)
    after.byKey[key] = {seen = w.seen, moved = w.moved, used = w.used, frame = frame,
                        screen = w.screen, minimized = true}
    if w.bundle then appBundles[w.app] = w.bundle end
    ensureIcon(w.bundle)
  end
  -- An app that didn't answer keeps the minimized windows it had
  for _, w in ipairs(before.minimized) do
    if failedApps[w.app] then
      table.insert(after.minimized, w)
      after.byKey[keyOf(w)] = before.byKey[keyOf(w)]
    end
  end
  known[name] = after

  local mmById = {}
  for _, d in ipairs(extra.displays or {}) do
    if (d.mmW or 0) > 0 and (d.mmH or 0) > 0 then
      mmById[d.id] = {w = math.floor(d.mmW + 0.5), h = math.floor(d.mmH + 0.5)}
    end
  end
  local displays = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    table.insert(displays, {
      id = s:id(), position = idToPos[s:id()], name = s:name(), mm = mmById[s:id()],
      full = rect(s:fullFrame()), frame = rect(s:frame()), rotation = s:rotate(),
    })
  end
  if writeJSON(mapFile(name), {config = name, screens = count, saved = now, since = after.since,
                               displays = displays, windows = windows, minimized = after.minimized}) then
    writeNow()
  end
end

function M.init()
  -- The page's windows link here: bring that window forward, wherever it is, out of the
  -- Dock if it's minimized.
  -- hs -c 'return hs.inspect(_G._stepper.screenmaps.lastFocus)' shows the last request
  hs.urlevent.bind("screenmaps", function(_, params)
    local id = tonumber(params.focus)
    local win = id and hs.window.get(id)
    M.lastFocus = {id = id, found = win ~= nil, at = os.date("%H:%M:%S")}
    if win then
      if win:isMinimized() then win:unminimize() end
      win:focus()
    else
      hs.alert.show("That window is gone")
    end
  end)
end

return M
