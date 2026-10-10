-- =============================================================================
-- Screenmaps — a digital twin of each display config's layout
-- =============================================================================
-- layout.lua hands over every save that changed something. This writes what the page in
-- features/L006-layout-restore-of-windows-in-screens/subfeatures/screenmaps/ draws:
--   data/screenmap-<config>.json  every display, and the windows front to back, each with
--                                 when it was first saved and last moved. One file per
--                                 config, so each keeps its last layout while you're away
--   data/screenmaps-now.json      the current config, and when each config was saved
-- It also saves the app icons the page shows (data/app-icons/<bundleID>.png, shared with
-- bear-hud and keymapwatch), and brings a window forward when the page asks:
-- hammerspoon://screenmaps?focus=<window id>
--
-- screenmaps.init()                               — the URL handler
-- screenmaps.setConfigs(knownConfigs)             — layout.lua's KNOWN_CONFIGS
-- screenmaps.setCurrent(name, screenCount)        — the config in use
-- screenmaps.record(name, count, entries, ids, idToPos) — a save that changed something

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

-- Per config, what the last record said about each window, keyed by window id (or
-- "App\nTitle" for a window kept from an earlier save): {seen, moved, frame, screen}
local known = {}
local iconChecked = {}  -- bundle IDs whose icon was looked for since load

local function mapFile(name) return dataDir .. "screenmap-" .. name .. ".json" end

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

-- What this config's file says about its windows, the first time it's recorded after a
-- load, so first-saved and moved times outlive reloads
local function seed(name)
  local seeded = {}
  local fh = io.open(mapFile(name), "r")
  if not fh then return seeded end
  local ok, doc = pcall(hs.json.decode, fh:read("*a"))
  fh:close()
  if ok and type(doc) == "table" and type(doc.windows) == "table" then
    for _, w in ipairs(doc.windows) do
      local key = w.id or (tostring(w.app) .. "\n" .. tostring(w.title))
      seeded[key] = {seen = w.seen, moved = w.moved, frame = w.frame, screen = w.screen}
    end
  end
  return seeded
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
-- save; idToPos: screen id → position name
function M.record(name, count, entries, ids, idToPos)
  local now = os.time()
  local before = known[name] or seed(name)
  local after, windows = {}, {}
  for i, e in ipairs(entries) do
    local key = ids[i] or (e.app .. "\n" .. e.title)
    local prev = before[key]
    local moved = (prev and sameSpot(prev, e.frame, e.screenPosition)) and prev.moved or now
    local w = {
      id = ids[i], app = e.app, bundle = e.bundle, title = e.title,
      screen = e.screenPosition, frame = e.frame,
      seen = prev and prev.seen or now, moved = moved,
    }
    table.insert(windows, w)
    after[key] = {seen = w.seen, moved = w.moved, frame = e.frame, screen = e.screenPosition}
    if e.bundle then appBundles[e.app] = e.bundle end
    ensureIcon(e.bundle)
  end
  known[name] = after

  local displays = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    table.insert(displays, {
      id = s:id(), position = idToPos[s:id()], name = s:name(),
      full = rect(s:fullFrame()), frame = rect(s:frame()), rotation = s:rotate(),
    })
  end
  if writeJSON(mapFile(name), {config = name, screens = count, saved = now,
                               displays = displays, windows = windows}) then
    writeNow()
  end
end

function M.init()
  -- The page's windows link here: bring that window forward, wherever it is.
  -- hs -c 'return hs.inspect(_G._stepper.screenmaps.lastFocus)' shows the last request
  hs.urlevent.bind("screenmaps", function(_, params)
    local id = tonumber(params.focus)
    local win = id and hs.window.get(id)
    M.lastFocus = {id = id, found = win ~= nil, at = os.date("%H:%M:%S")}
    if win then
      win:focus()
    else
      hs.alert.show("That window is gone")
    end
  end)
end

return M
