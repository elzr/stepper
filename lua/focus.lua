-- =============================================================================
-- Window focus navigation (same screen + cross-screen)
-- =============================================================================
-- Provides directional focus switching with:
-- - Occlusion detection (skip fully hidden windows)
-- - Center-point screen detection (reliable for edge-spanning windows)
-- - Visual highlight feedback
-- - Chrome-style app focus jump workaround

local M = {}

-- Module state
local focusHighlight = nil      -- current canvas (if showing)
local focusHighlightTimer = nil     -- 0.3s cleanup timer (stored to prevent GC)
local focusHighlightFailsafe = nil  -- 2.0s failsafe timer (stored to prevent GC)
local lastFocusedByUs = nil

-- =============================================================================
-- Helper functions
-- =============================================================================

-- Check if two ranges overlap (any overlap counts)
local function rangesOverlap(aStart, aEnd, bStart, bEnd)
  return aStart < bEnd and aEnd > bStart
end

-- Check if a window's center point is within a screen's frame
local function isWindowCenteredOnScreen(winFrame, screenFrame)
  local centerX = winFrame.x + winFrame.w / 2
  local centerY = winFrame.y + winFrame.h / 2
  return centerX >= screenFrame.x and centerX < screenFrame.x + screenFrame.w and
         centerY >= screenFrame.y and centerY < screenFrame.y + screenFrame.h
end

-- Find the screen containing a point (more reliable than win:screen() for edge cases)
local function getScreenAtPoint(x, y)
  for _, screen in ipairs(hs.screen.allScreens()) do
    local sf = screen:frame()
    if x >= sf.x and x < sf.x + sf.w and
       y >= sf.y and y < sf.y + sf.h then
      return screen
    end
  end
  return nil
end

-- Check if a window frame has at least some visible portion (not fully occluded by frames above it)
-- Takes pre-cached frames to avoid repeated API calls
local function isFrameVisible(frame, framesAbove)
  -- Check 5 points: 4 corners (inset by 5px) + center
  local checkPoints = {
    {x = frame.x + 5, y = frame.y + 5},                           -- top-left
    {x = frame.x + frame.w - 5, y = frame.y + 5},                 -- top-right
    {x = frame.x + 5, y = frame.y + frame.h - 5},                 -- bottom-left
    {x = frame.x + frame.w - 5, y = frame.y + frame.h - 5},       -- bottom-right
    {x = frame.x + frame.w / 2, y = frame.y + frame.h / 2},       -- center
  }

  for _, point in ipairs(checkPoints) do
    local covered = false
    for _, aboveFrame in ipairs(framesAbove) do
      if point.x >= aboveFrame.x and point.x < aboveFrame.x + aboveFrame.w and
         point.y >= aboveFrame.y and point.y < aboveFrame.y + aboveFrame.h then
        covered = true
        break
      end
    end
    if not covered then
      return true  -- At least one point is visible
    end
  end

  return false  -- All points covered
end

-- Focus a single window without moving mouse
-- raise() brings to front visually, focus() gives keyboard focus
local function focusSingleWindow(win)
  local app = win:application()
  local appName = app and app:name() or "unknown"
  local winTitle = win:title() or "untitled"
  print(string.format("[focusSingleWindow] Targeting: %s - %s", appName, winTitle))

  if win:isMinimized() then win:unminimize() end
  local raiseResult = win:raise()
  print(string.format("[focusSingleWindow] raise() returned: %s", tostring(raiseResult)))

  hs.timer.usleep(10000)  -- 10ms delay

  local focusResult = win:focus()
  print(string.format("[focusSingleWindow] focus() returned: %s", tostring(focusResult)))

  -- Check what actually got focused
  hs.timer.doAfter(0.1, function()
    local focused = hs.window.focusedWindow()
    if focused then
      local focusedApp = focused:application()
      print(string.format("[focusSingleWindow] After 100ms, focused: %s - %s",
        focusedApp and focusedApp:name() or "unknown",
        focused:title() or "untitled"))
    else
      print("[focusSingleWindow] After 100ms, no focused window!")
    end
  end)
end

-- =============================================================================
-- Visual feedback
-- =============================================================================

-- Stores corner radius per canvas (hs.canvas doesn't support custom fields)
local canvasRadii = {}

-- Safely delete a canvas (no-op if already deleted or nil)
local function safeDeleteCanvas(canvas)
  if canvas then
    canvasRadii[canvas] = nil
    pcall(function() canvas:delete() end)
  end
end

-- =============================================================================
-- Continuous corner path (matches macOS Tahoe window chrome)
-- =============================================================================
-- Apple uses 3 cubic bezier segments per corner instead of circular arcs.
-- Constants from PaintCode's reverse-engineering of Apple's implementation.

-- Multiples of corner radius r.  For the top-right corner (x = leftward from
-- corner, y = downward), the three bezier segments are:
--   Seg 1: (a,0) → (p,q)  c1=(b,0)   c2=(c,0)
--   Seg 2: (p,q) → (q,p)  c1=(f,g)   c2=(g,f)
--   Seg 3: (q,p) → (0,a)  c1=(0,c)   c2=(0,b)
local CC = {
  a = 1.52866483,   -- curve start/end distance from corner on each edge
  b = 1.08849296,   -- control point near straight edge
  c = 0.86840694,   -- control point farther from straight edge
  p = 0.63149379,   -- junction point (major coord)
  q = 0.07491139,   -- junction point (minor coord)
  f = 0.37282383,   -- mid-curve control point (major)
  g = 0.16905956,   -- mid-curve control point (minor)
}

-- Build continuous-corner path coordinates for hs.canvas segments element.
-- w, h = inner dimensions of the border rect; r = corner radius.
-- ox, oy = offset of the rect origin within the canvas.
-- Returns a coordinates array (closed path, clockwise from top-left straight).
local function continuousCornerCoords(w, h, r, ox, oy)
  -- Clamp: if the curve extent (a*r) exceeds half the edge, scale down
  local maxR = math.min(w, h) / (2 * CC.a)
  if r > maxR then r = maxR end

  local a, b, c = CC.a*r, CC.b*r, CC.c*r
  local p, q    = CC.p*r, CC.q*r
  local f, g    = CC.f*r, CC.g*r

  -- Corner origins (inner rect corners)
  local L, R, T, B = ox, ox + w, oy, oy + h

  return {
    -- Top edge (left to right)
    {x = L + a, y = T},
    {x = R - a, y = T},
    -- Top-right corner (3 bezier segments)
    {x = R - p, y = T + q, c1x = R - b, c1y = T,     c2x = R - c, c2y = T},
    {x = R - q, y = T + p, c1x = R - f, c1y = T + g,  c2x = R - g, c2y = T + f},
    {x = R,     y = T + a, c1x = R,     c1y = T + c,  c2x = R,     c2y = T + b},
    -- Right edge (top to bottom)
    {x = R, y = B - a},
    -- Bottom-right corner
    {x = R - q, y = B - p, c1x = R,     c1y = B - b,  c2x = R,     c2y = B - c},
    {x = R - p, y = B - q, c1x = R - g, c1y = B - f,  c2x = R - f, c2y = B - g},
    {x = R - a, y = B,     c1x = R - c, c1y = B,      c2x = R - b, c2y = B},
    -- Bottom edge (right to left)
    {x = L + a, y = B},
    -- Bottom-left corner
    {x = L + p, y = B - q, c1x = L + b, c1y = B,      c2x = L + c, c2y = B},
    {x = L + q, y = B - p, c1x = L + f, c1y = B - g,  c2x = L + g, c2y = B - f},
    {x = L,     y = B - a, c1x = L,     c1y = B - c,  c2x = L,     c2y = B - b},
    -- Left edge (bottom to top)
    {x = L, y = T + a},
    -- Top-left corner
    {x = L + q, y = T + p, c1x = L,     c1y = T + b,  c2x = L,     c2y = T + c},
    {x = L + p, y = T + q, c1x = L + g, c1y = T + f,  c2x = L + f, c2y = T + g},
    {x = L + a, y = T,     c1x = L + c, c1y = T,      c2x = L + b, c2y = T},
  }
end

-- Emphasis line coordinates for a direction (thick line on one edge, inset by a*r).
-- Returns coordinates array or nil.
local function emphasisCoords(w, h, r, ox, oy, dir)
  local ar = CC.a * r
  -- Clamp same as continuousCornerCoords
  local maxR = math.min(w, h) / (2 * CC.a)
  if r > maxR then ar = CC.a * maxR end

  if dir == "left" then
    return {{x = ox, y = oy + ar}, {x = ox, y = oy + h - ar}}
  elseif dir == "right" then
    return {{x = ox + w, y = oy + ar}, {x = ox + w, y = oy + h - ar}}
  elseif dir == "up" then
    return {{x = ox + ar, y = oy}, {x = ox + w - ar, y = oy}}
  elseif dir == "down" then
    return {{x = ox + ar, y = oy + h}, {x = ox + w - ar, y = oy + h}}
  end
  return nil
end

-- =============================================================================
-- Border canvas API (shared by focus highlight and mouse move)
-- =============================================================================

local borderThin = 4
local borderThick = 12
local radiusToolbar = 22    -- native toolbar windows (Bear, Finder, Safari)
local radiusNoToolbar = 8   -- plain titlebar windows (Kitty, Chrome, Electron)
local borderColor = {red = 0.4, green = 0.7, blue = 1.0, alpha = 0.9}
local borderPadding = borderThick / 2 + 2

-- Per-app toolbar cache (toolbar presence is an app-level property, not per-window)
local toolbarCache = {}

-- Check if a window has a native macOS toolbar (AXToolbar in accessibility tree).
-- Cached per bundle ID; wrapped in pcall to guard against AX hangs.
local function hasNativeToolbar(win)
  local app = win:application()
  if not app then return false end
  local bid = app:bundleID()
  if not bid then return false end
  if toolbarCache[bid] ~= nil then return toolbarCache[bid] end
  local ok, result = pcall(function()
    local ax = hs.axuielement.windowElement(win)
    local children = ax:attributeValue("AXChildren") or {}
    for _, child in ipairs(children) do
      if child:attributeValue("AXRole") == "AXToolbar" then
        return true
      end
    end
    return false
  end)
  local has = ok and result or false
  toolbarCache[bid] = has
  return has
end

-- Creates a canvas with continuous-corner border around `frame`, shown immediately.
-- `dir` (optional) adds a thick emphasis line on that edge ("left"/"right"/"up"/"down").
-- `win` (optional) used to detect toolbar and pick matching corner radius.
function M.createBorderCanvas(frame, dir, win, opts)
  local r = (win and hasNativeToolbar(win)) and radiusToolbar or radiusNoToolbar
  local pad = borderPadding
  local color = (opts and opts.color) or borderColor
  local c = hs.canvas.new({
    x = frame.x - pad, y = frame.y - pad,
    w = frame.w + pad * 2, h = frame.h + pad * 2
  })

  -- Continuous-corner border path
  c:appendElements({
    type = "segments",
    action = "stroke",
    strokeColor = color,
    strokeWidth = borderThin,
    closed = true,
    coordinates = continuousCornerCoords(frame.w, frame.h, r, pad, pad),
  })

  -- Emphasis line
  local emph = emphasisCoords(frame.w, frame.h, r, pad, pad, dir)
  if emph then
    c:appendElements({
      type = "segments",
      action = "stroke",
      strokeColor = color,
      strokeWidth = borderThick,
      strokeCapStyle = "round",
      coordinates = emph,
    })
  end

  c:show()
  canvasRadii[c] = r
  return c
end

-- Repositions/resizes an existing border canvas to a new frame.
function M.updateBorderCanvas(canvas, frame)
  if not canvas then return end
  local r = canvasRadii[canvas] or radiusNoToolbar
  local pad = borderPadding
  canvas:frame({
    x = frame.x - pad, y = frame.y - pad,
    w = frame.w + pad * 2, h = frame.h + pad * 2
  })
  -- Update path coordinates (element 1 = border path)
  canvas[1].coordinates = continuousCornerCoords(frame.w, frame.h, r, pad, pad)
  -- Update emphasis line if present (element 2)
  if canvas[2] then
    -- Detect direction from existing emphasis coordinates
    local old = canvas[2].coordinates
    if old and #old == 2 then
      local dir = nil
      if old[1].x == old[2].x and old[1].x < pad + 1 then dir = "left"
      elseif old[1].x == old[2].x then dir = "right"
      elseif old[1].y == old[2].y and old[1].y < pad + 1 then dir = "up"
      elseif old[1].y == old[2].y then dir = "down"
      end
      local emph = emphasisCoords(frame.w, frame.h, r, pad, pad, dir)
      if emph then canvas[2].coordinates = emph end
    end
  end
end

-- Safely deletes a border canvas.
function M.deleteBorderCanvas(canvas)
  if canvas then canvasRadii[canvas] = nil end
  safeDeleteCanvas(canvas)
end

-- Flash a border around a window to highlight it (thicker on the focus direction side)
function M.flashFocusHighlight(win, dir, opts)
  -- Always clean up previous highlight and cancel pending timers
  safeDeleteCanvas(focusHighlight)
  focusHighlight = nil
  if focusHighlightTimer then focusHighlightTimer:stop() end
  if focusHighlightFailsafe then focusHighlightFailsafe:stop() end

  local frame = win:frame()
  focusHighlight = M.createBorderCanvas(frame, dir, win, opts)

  -- Fade out after a brief moment (stored to prevent GC)
  focusHighlightTimer = hs.timer.doAfter(0.3, function()
    if focusHighlight then
      safeDeleteCanvas(focusHighlight)
      focusHighlight = nil
    end
  end)

  -- Failsafe: ensure cleanup even if something unexpected happens
  focusHighlightFailsafe = hs.timer.doAfter(2.0, function()
    if focusHighlight then
      print("[flashFocusHighlight] Failsafe cleanup triggered")
      safeDeleteCanvas(focusHighlight)
      focusHighlight = nil
    end
  end)
end

-- =============================================================================
-- Focus navigation
-- =============================================================================

-- Focus window in direction (on same screen, with wrap-around)
function M.focusDirection(dir)
  local win = hs.window.focusedWindow()
  if not win then return end

  -- Work around apps (like Chrome) that switch focus to a different window on another screen
  -- Only intervene if: same app, different screen (user clicking different app = intentional)
  if lastFocusedByUs then
    local lastWin = hs.window.get(lastFocusedByUs)
    if lastWin and lastWin:isVisible() then
      local sameApp = win:application():pid() == lastWin:application():pid()
      if sameApp then
        local lastFrame = lastWin:frame()
        local lastCenterX = lastFrame.x + lastFrame.w / 2
        local lastCenterY = lastFrame.y + lastFrame.h / 2
        local lastScreen = getScreenAtPoint(lastCenterX, lastCenterY)

        local winFrame = win:frame()
        local winCenterX = winFrame.x + winFrame.w / 2
        local winCenterY = winFrame.y + winFrame.h / 2
        local winScreen = getScreenAtPoint(winCenterX, winCenterY)

        -- Same app jumped to different screen = likely Chrome-style bug
        if lastScreen and winScreen and lastScreen:id() ~= winScreen:id() then
          print(string.format("[focusDirection] Same app jumped screens! Using tracked window instead"))
          win = lastWin
        end
      else
        -- Different app = user intentionally switched, clear tracking
        lastFocusedByUs = nil
      end
    end
  end

  -- Use the screen containing the window's center (consistent with our filtering logic)
  local winFrame = win:frame()
  local centerX = winFrame.x + winFrame.w / 2
  local centerY = winFrame.y + winFrame.h / 2
  local currentScreen = getScreenAtPoint(centerX, centerY) or win:screen()
  local screenFrame = currentScreen:frame()

  local windows = hs.window.orderedWindows()

  -- Collect all standard windows on the same screen (in z-order, front to back)
  -- Use center-point check instead of w:screen() for reliability with edge-spanning windows
  local screenWindows = {}
  for _, w in ipairs(windows) do
    if w:isStandard() then
      local frame = w:frame()
      if isWindowCenteredOnScreen(frame, screenFrame) then
        local pos = (dir == "left" or dir == "right") and frame.x or frame.y
        table.insert(screenWindows, {win = w, frame = frame, pos = pos})
      end
    end
  end

  -- DEBUG: Log screen info and all windows before occlusion filter
  print(string.format("[focusDirection] dir=%s, screen: x=%d w=%d, from: %s",
    dir, screenFrame.x, screenFrame.w, win:application():name()))
  print(string.format("[focusDirection] Before occlusion (%d windows):", #screenWindows))
  for i, entry in ipairs(screenWindows) do
    local appName = entry.win:application():name()
    local winScreen = entry.win:screen():name()
    print(string.format("  %d. %s (x=%d, screen=%s)", i, appName, entry.frame.x, winScreen))
  end

  -- Filter to only visible (unoccluded) windows using cached frames
  -- Always include current window so user can navigate away from it
  local visibleWindows = {}
  local framesAbove = {}
  for _, entry in ipairs(screenWindows) do
    if entry.win:id() == win:id() or isFrameVisible(entry.frame, framesAbove) then
      table.insert(visibleWindows, entry)
    end
    -- Add this window's frame to the "above" list for subsequent checks
    table.insert(framesAbove, entry.frame)
  end
  screenWindows = visibleWindows

  if #screenWindows <= 1 then
    print("[focusDirection] Only 1 or 0 windows after occlusion, returning")
    return
  end

  -- Shadow-constrained navigation: first look for windows in the current window's "shadow"
  -- (overlapping projection in the perpendicular axis)
  local currentFrame = win:frame()
  local shadowWindows = {}

  for _, entry in ipairs(screenWindows) do
    local inShadow
    if dir == "left" or dir == "right" then
      -- Vertical shadow: check Y overlap
      inShadow = rangesOverlap(entry.frame.y, entry.frame.y + entry.frame.h,
                                currentFrame.y, currentFrame.y + currentFrame.h)
    else
      -- Horizontal shadow: check X overlap
      inShadow = rangesOverlap(entry.frame.x, entry.frame.x + entry.frame.w,
                                currentFrame.x, currentFrame.x + currentFrame.w)
    end
    if inShadow then
      table.insert(shadowWindows, entry)
    end
  end

  -- Use shadow windows if we have more than just the current window
  local navigableWindows = shadowWindows
  local usingShadow = #shadowWindows > 1
  if not usingShadow then
    navigableWindows = screenWindows  -- Fallback to all windows
  end

  print(string.format("[focusDirection] Shadow filter: %d in shadow, using %s (%d windows)",
    #shadowWindows, usingShadow and "shadow" or "all", #navigableWindows))

  -- Sort by position (ascending)
  table.sort(navigableWindows, function(a, b) return a.pos < b.pos end)

  -- Find current window index in sorted list
  local currentIdx = nil
  for i, entry in ipairs(navigableWindows) do
    if entry.win:id() == win:id() then
      currentIdx = i
      break
    end
  end

  if not currentIdx then
    print("[focusDirection] Current window not found in list!")
    return
  end

  -- Calculate next index with wrap-around
  local nextIdx
  if dir == "left" or dir == "up" then
    nextIdx = currentIdx - 1
    if nextIdx < 1 then nextIdx = #navigableWindows end
  else
    nextIdx = currentIdx + 1
    if nextIdx > #navigableWindows then nextIdx = 1 end
  end

  local targetWin = navigableWindows[nextIdx].win
  local targetApp = targetWin:application():name()
  local targetScreen = targetWin:screen():name()
  local currentApp = win:application():name()

  -- DEBUG: Log final decision
  print(string.format("[focusDirection] After shadow & sort (%d windows, shadow=%s):", #navigableWindows, tostring(usingShadow)))
  for i, entry in ipairs(navigableWindows) do
    local marker = ""
    if i == currentIdx then marker = " <-- CURRENT"
    elseif i == nextIdx then marker = " <-- TARGET"
    end
    print(string.format("  %d. %s (x=%d)%s", i, entry.win:application():name(), entry.pos, marker))
  end
  print(string.format("[focusDirection] FOCUS: %s -> %s (screen: %s)", currentApp, targetApp, targetScreen))

  focusSingleWindow(targetWin)
  lastFocusedByUs = targetWin:id()  -- Track so we can detect if focus jumps unexpectedly
  M.flashFocusHighlight(targetWin, dir)
end

-- Focus window on adjacent screen (focusing the window closest to where you came from)
function M.focusScreen(dir)
  local win = hs.window.focusedWindow()
  local currentScreen
  if win then
    -- Use the screen containing the window's center (consistent with focusDirection)
    local winFrame = win:frame()
    local centerX = winFrame.x + winFrame.w / 2
    local centerY = winFrame.y + winFrame.h / 2
    currentScreen = getScreenAtPoint(centerX, centerY) or win:screen()
  else
    currentScreen = hs.mouse.getCurrentScreen()
  end
  if not currentScreen then return end

  -- Find the screen in the given direction
  local targetScreen
  if dir == "left" then
    targetScreen = currentScreen:toWest()
  elseif dir == "right" then
    targetScreen = currentScreen:toEast()
  elseif dir == "up" then
    targetScreen = currentScreen:toNorth()
  elseif dir == "down" then
    targetScreen = currentScreen:toSouth()
  end

  if not targetScreen then return end  -- No screen in that direction

  local targetScreenFrame = targetScreen:frame()
  local windows = hs.window.orderedWindows()

  -- Collect all standard windows on the target screen (in z-order, front to back)
  -- Use center-point check instead of w:screen() for reliability with edge-spanning windows
  local screenWindows = {}
  for _, w in ipairs(windows) do
    if w:isStandard() then
      local frame = w:frame()
      if isWindowCenteredOnScreen(frame, targetScreenFrame) then
        table.insert(screenWindows, {win = w, frame = frame})
      end
    end
  end

  if #screenWindows == 0 then return end  -- No windows on target screen

  -- Filter to only visible (unoccluded) windows
  local visibleWindows = {}
  local framesAbove = {}
  for _, entry in ipairs(screenWindows) do
    if isFrameVisible(entry.frame, framesAbove) then
      table.insert(visibleWindows, entry)
    end
    table.insert(framesAbove, entry.frame)
  end
  screenWindows = visibleWindows

  if #screenWindows == 0 then return end

  -- Sort by proximity to current window's position on the shared edge
  local currentFrame = win and win:frame() or nil
  table.sort(screenWindows, function(a, b)
    if not currentFrame then return false end
    -- Calculate distance from current window's center to each window's center
    local distA = math.abs(a.frame.y + a.frame.h/2 - (currentFrame.y + currentFrame.h/2))
    local distB = math.abs(b.frame.y + b.frame.h/2 - (currentFrame.y + currentFrame.h/2))
    return distA < distB
  end)

  local targetWin = screenWindows[1].win
  focusSingleWindow(targetWin)
  lastFocusedByUs = targetWin:id()  -- Track so we can detect if focus jumps unexpectedly
  M.flashFocusHighlight(targetWin, dir)
end

-- =============================================================================
-- Cycle the front app's windows (⌥` next, ⌥⇧` previous)
-- =============================================================================
-- macOS's "Move focus to next window" brings up the rearmost window, but it has
-- no previous, and ⌥⇧` doesn't reverse it once it's rebound off ⌘`. So both
-- directions live here, walking one front-to-back snapshot of the app's windows:
-- ⌥` steps back through it (rearmost first, as macOS does), ⌥⇧` forward (the one
-- just behind first), and each undoes the other. The snapshot lasts while the window
-- in front is the one we put there; a click elsewhere or a new window starts afresh.
local cycle = nil  -- {pid, ids = {front-to-back}, at = index of the window we focused}

function M.cycleAppWindows(dir)
  local front = hs.window.focusedWindow()
  if not front then return end
  local pid = front:pid()
  local alive, ordered = {}, {}
  for _, w in ipairs(hs.window.orderedWindows()) do
    if w:pid() == pid and w:isStandard() then alive[w:id()] = w; table.insert(ordered, w:id()) end
  end
  if not (cycle and cycle.pid == pid and cycle.ids[cycle.at] == front:id()) then
    cycle = {pid = pid, ids = ordered, at = 1}
  end
  local n = #cycle.ids
  for _ = 1, n do  -- skip windows closed or minimized since the snapshot
    cycle.at = (cycle.at - 1 + (dir == "previous" and 1 or -1)) % n + 1
    local win = alive[cycle.ids[cycle.at]]
    if win then
      if win:id() ~= front:id() then win:focus() end
      return
    end
  end
end

-- Get debug info about tracking state (for the confirm focus hotkey)
function M.getTrackingInfo()
  return lastFocusedByUs
end

-- Clean up any lingering highlight (call on reload or if highlight gets stuck)
function M.clearHighlight()
  safeDeleteCanvas(focusHighlight)
  focusHighlight = nil
  if focusHighlightTimer then focusHighlightTimer:stop(); focusHighlightTimer = nil end
  if focusHighlightFailsafe then focusHighlightFailsafe:stop(); focusHighlightFailsafe = nil end
end

M.focusSingleWindow = focusSingleWindow

return M
