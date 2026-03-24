hs.loadSpoon("WinWin")

-- Load modules
local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local projectRoot = scriptPath .. "../"
local focus = dofile(scriptPath .. "focus.lua")
local mousemove = dofile(scriptPath .. "mousemove.lua")
local screenswitch = dofile(scriptPath .. "screenswitch.lua")
bear_hud = dofile(scriptPath .. "bear-hud.lua")
layout = dofile(scriptPath .. "layout.lua")

-- Clean up any orphaned focus highlights from previous session
focus.clearHighlight()

-- Adaptive animation: luxurious by default, snappy when rapidly iterating
local luxuriousDuration = 0.3
local snappyDuration = 0.1
local rapidThreshold = 0.4  -- seconds between operations to trigger snappy mode
local lastOperationTime = 0
local animationLocked = false

local function updateAnimationDuration()
  local now = hs.timer.secondsSinceEpoch()
  local elapsed = now - lastOperationTime
  lastOperationTime = now

  if animationLocked then return end

  if elapsed < rapidThreshold then
    hs.window.animationDuration = snappyDuration
  else
    hs.window.animationDuration = luxuriousDuration
  end
end

-- Helper for instant (non-animated) window operations
local function instant(fn)
  updateAnimationDuration()  -- Track timing even for instant ops
  local original = hs.window.animationDuration
  animationLocked = true
  hs.window.animationDuration = 0
  fn()
  animationLocked = false
  hs.window.animationDuration = original
end

local function stepMove(dir)
  updateAnimationDuration()
  spoon.WinWin:stepMove(dir)
end

local function stepResize(dir)
  updateAnimationDuration()
  spoon.WinWin:stepResize(dir)
end

-- Minimum shrink sizes for specific apps (add more as needed)
local minShrinkSize = {
  kitty = {w = 900, h = 400},
}

-- Default compact size for PiP mode
local defaultCompactSize = {w = 400, h = 300}

-- Track compact windows: {winID = {original = frame, screenID = id}}
local compactWindows = {}

-- Track shrunk windows for toggle behavior: {winID = {width = originalW, height = originalH}}
local shrunkWindows = {}

-- Move-to-display undo: winID -> {frame, screenID, position, timestamp}
-- Stores original screen + frame before a cross-screen move.
-- Pressing the same combo again within 1 hour restores the window.
local displayUndo = {}
local DISPLAY_UNDO_TTL = 3600  -- seconds

-- Forward declaration for edge highlight (defined later with other visual feedback)
local flashEdgeHighlight

-- Shift-first resize mode (global, managed by callback at end of file)
_G.shiftFirstMode = false

-- Clear existing hotkeys
local existingHotkeys = hs.hotkey.getHotkeys()
for _, hotkey in ipairs(existingHotkeys) do
  hotkey:delete()
end

local function setupWindowOperation(shouldSave)
  local win = hs.window.focusedWindow()
  if not win then return nil end
  
  local frame = win:frame()
  local screen = win:screen():frame()
  
  -- Save original position for WinWin's undo
  -- but only if shouldSave is true
  -- and only for properties that changed
  if shouldSave ~= false then  -- saves by default if no parameter passed
    -- get first position or empty table if nil
    local lastPos = (spoon.WinWin._lastPositions or {})[1] or {}
    local newPos = {}

    for _, prop in ipairs({'x', 'y', 'w', 'h'}) do
          newPos[prop] = (
              frame[prop] ~= lastPos[prop]  -- change?
              and frame[prop]               -- if true: use new value
              or lastPos[prop]              -- if false: keep old value
          )
      end
      
    spoon.WinWin._lastPositions = {newPos}
    spoon.WinWin._lastWins = {win}
  end
  
  return win, frame, screen
end

-- Move window to edge (or restore if already at edge)
local function moveToEdge(dir)
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  -- Check if already at target edge
  local atEdge = (dir == "left" and frame.x <= screen.x) or
                 (dir == "right" and frame.x + frame.w >= screen.x + screen.w) or
                 (dir == "up" and frame.y <= screen.y) or
                 (dir == "down" and frame.y + frame.h >= screen.y + screen.h)

  if atEdge and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous position
    local lastPos = spoon.WinWin._lastPositions[1]
    if dir == "left" or dir == "right" then
      frame.x = lastPos.x or frame.x
    else
      frame.y = lastPos.y or frame.y
    end
  else
    -- Save current position, then move to edge
    setupWindowOperation(true)
    flashEdgeHighlight(screen, dir)
    if dir == "left" then
        frame.x = screen.x
    elseif dir == "right" then
        frame.x = screen.x + screen.w - frame.w
    elseif dir == "up" then
        frame.y = screen.y
    elseif dir == "down" then
        frame.y = screen.y + screen.h - frame.h
    end
  end

  instant(function() win:setFrame(frame) end)
end

-- Resize window to edge (or restore if already at edge)
local function resizeToEdge(dir)
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  -- Check if already extends to target edge
  local atEdge = (dir == "left" and frame.x <= screen.x) or
                 (dir == "right" and frame.x + frame.w >= screen.x + screen.w) or
                 (dir == "up" and frame.y <= screen.y) or
                 (dir == "down" and frame.y + frame.h >= screen.y + screen.h)

  if atEdge and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous size/position
    local lastPos = spoon.WinWin._lastPositions[1]
    if dir == "left" or dir == "right" then
      frame.x = lastPos.x or frame.x
      frame.w = lastPos.w or frame.w
    else
      frame.y = lastPos.y or frame.y
      frame.h = lastPos.h or frame.h
    end
  else
    -- Save current position, then resize to edge (single step)
    setupWindowOperation(true)
    flashEdgeHighlight(screen, dir)
    if dir == "left" then
        -- Expand to left edge, keeping right edge fixed
        frame.w = frame.x + frame.w - screen.x
        frame.x = screen.x
    elseif dir == "right" then
        -- Expand to right edge, keeping left edge fixed
        frame.w = screen.x + screen.w - frame.x
    elseif dir == "up" then
        -- Expand to top edge, keeping bottom edge fixed
        frame.h = frame.y + frame.h - screen.y
        frame.y = screen.y
    elseif dir == "down" then
        -- Expand to bottom edge, keeping top edge fixed
        frame.h = screen.y + screen.h - frame.y
    end
  end

  instant(function() win:setFrame(frame) end)
end

-- Resize from the top-left anchor (opposite of default bottom-right)
-- up = grow upward (y decreases, h increases), down = shrink from top (y increases, h decreases)
-- left = grow leftward (x decreases, w increases), right = shrink from left (x increases, w decreases)
local function topLeftAnchorResize(dir)
  local win = hs.window.focusedWindow()
  if not win then return end

  local f = win:frame()
  local step = spoon.WinWin.gridparts
  local screen = win:screen():frame()
  local stepW = screen.w / step
  local stepH = screen.h / step

  if dir == "up" then
    f.y = f.y - stepH
    f.h = f.h + stepH
  elseif dir == "down" then
    f.y = f.y + stepH
    f.h = f.h - stepH
  elseif dir == "left" then
    f.x = f.x - stepW
    f.w = f.w + stepW
  elseif dir == "right" then
    f.x = f.x + stepW
    f.w = f.w - stepW
  end

  instant(function() win:setFrame(f) end)
end

local function smartStepResize(dir)
  local win = hs.window.focusedWindow()
  if not win then return end

  local frame = win:frame()
  local screen = win:screen():frame()
  local snap = 5

  -- Edge detection
  local atBottom = frame.y + frame.h >= screen.y + screen.h - snap
  local atTop = frame.y <= screen.y + snap
  local atRight = frame.x + frame.w >= screen.x + screen.w - snap
  local atLeft = frame.x <= screen.x + snap

  -- Skip wraparound when touching both opposite edges (max height/width)
  local bottomOnly = atBottom and not atTop
  local rightOnly = atRight and not atLeft

  if dir == "down" and atBottom then
    -- Wraparound: bottom edge at screen bottom, shrink from top instead
    stepResize("up")
    local f = win:frame()
    f.y = screen.y + screen.h - f.h
    instant(function() win:setFrame(f) end)
    return
  end

  if dir == "up" and bottomOnly then
    -- Grow upward: bottom pinned to screen bottom, extend top edge up
    updateAnimationDuration()
    local stepH = screen.h / spoon.WinWin.gridparts
    frame.y = frame.y - stepH
    frame.h = frame.h + stepH
    win:setFrame(frame)
    -- Re-snap bottom edge after Retina rounding
    local f = win:frame()
    f.y = screen.y + screen.h - f.h
    instant(function() win:setFrame(f) end)
    return
  end

  if dir == "right" and atRight then
    -- Wraparound: right edge at screen right, shrink from left instead
    stepResize("left")
    local f = win:frame()
    f.x = screen.x + screen.w - f.w
    instant(function() win:setFrame(f) end)
    return
  end

  if dir == "left" and rightOnly then
    -- Grow leftward: right pinned to screen right, extend left edge left
    updateAnimationDuration()
    local stepW = screen.w / spoon.WinWin.gridparts
    frame.x = frame.x - stepW
    frame.w = frame.w + stepW
    win:setFrame(frame)
    -- Re-snap right edge after Retina rounding
    local f = win:frame()
    f.x = screen.x + screen.w - f.w
    instant(function() win:setFrame(f) end)
    return
  end

  stepResize(dir)
end

-- Toggle shrink width (left) or height (up)
local function toggleShrink(dir)
  instant(function()
    local win, frame, screen = setupWindowOperation(false)
    if not win then return end
    local winID = win:id()

    -- Get app-specific minimum size (if any)
    local appName = win:application():name():lower()
    local minSize = minShrinkSize[appName] or {w = 0, h = 0}

    -- Initialize tracking for this window if needed
    if not shrunkWindows[winID] then
      shrunkWindows[winID] = {}
    end

    if dir == "left" then
      -- Toggle width shrink
      if shrunkWindows[winID].width then
        -- Restore original width
        frame.w = shrunkWindows[winID].width
        frame.x = shrunkWindows[winID].x
        win:setFrame(frame)
        shrunkWindows[winID].width = nil
        shrunkWindows[winID].x = nil
      else
        -- Save current width and shrink to minimum in one shot
        shrunkWindows[winID].width = frame.w
        shrunkWindows[winID].x = frame.x
        local targetW = math.max(minSize.w, 1)
        win:setFrame({x = frame.x, y = frame.y, w = targetW, h = frame.h})
      end
    elseif dir == "up" then
      -- Toggle height shrink
      if shrunkWindows[winID].height then
        -- Restore original height
        frame.h = shrunkWindows[winID].height
        frame.y = shrunkWindows[winID].y
        win:setFrame(frame)
        shrunkWindows[winID].height = nil
        shrunkWindows[winID].y = nil
      else
        -- Save current height and shrink to minimum in one shot
        shrunkWindows[winID].height = frame.h
        shrunkWindows[winID].y = frame.y
        local targetH = math.max(minSize.h, 1)
        win:setFrame({x = frame.x, y = frame.y, w = frame.w, h = targetH})
      end
    end

    -- Clean up empty entries
    if not shrunkWindows[winID].width and not shrunkWindows[winID].height then
      shrunkWindows[winID] = nil
    end
  end)
end

-- Restore shrunk dimension, or grow to edge if not shrunk (toggle)
local function restoreOrGrow(dir)
  local win, frame, screen = setupWindowOperation(false)
  if not win then return end
  local winID = win:id()

  if dir == "right" then
    -- Check if width is shrunk
    if shrunkWindows[winID] and shrunkWindows[winID].width then
      -- Restore shrunk width
      instant(function()
        frame.w = shrunkWindows[winID].width
        frame.x = shrunkWindows[winID].x
        win:setFrame(frame)
      end)
      shrunkWindows[winID].width = nil
      shrunkWindows[winID].x = nil
      if not shrunkWindows[winID].height then
        shrunkWindows[winID] = nil
      end
    else
      -- Not shrunk - resize to right edge (toggle)
      resizeToEdge("right")
    end
  elseif dir == "down" then
    -- Check if height is shrunk
    if shrunkWindows[winID] and shrunkWindows[winID].height then
      -- Restore shrunk height
      instant(function()
        frame.h = shrunkWindows[winID].height
        frame.y = shrunkWindows[winID].y
        win:setFrame(frame)
      end)
      shrunkWindows[winID].height = nil
      shrunkWindows[winID].y = nil
      if not shrunkWindows[winID].width then
        shrunkWindows[winID] = nil
      end
    else
      -- Not shrunk - resize to bottom edge (toggle)
      resizeToEdge("down")
    end
  end
end

-- Cycle maximize: max height → max height+width → restore
local function cycleMaximize()
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  local tolerance = 10
  local isMaxHeight = math.abs(frame.y - screen.y) < tolerance and
                      math.abs(frame.h - screen.h) < tolerance
  local isMaxWidth = math.abs(frame.x - screen.x) < tolerance and
                     math.abs(frame.w - screen.w) < tolerance

  if isMaxHeight and isMaxWidth then
    -- Fully maximized → restore
    if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
      local lastPos = spoon.WinWin._lastPositions[1]
      frame.x = lastPos.x or frame.x
      frame.y = lastPos.y or frame.y
      frame.w = lastPos.w or frame.w
      frame.h = lastPos.h or frame.h
    end
  elseif isMaxHeight then
    -- Max height only → add max width (true maximize)
    frame.x = screen.x
    frame.w = screen.w
  else
    -- Normal → max height (save original first)
    setupWindowOperation(true)
    flashEdgeHighlight(screen, {"up", "down"})
    frame.y = screen.y
    frame.h = screen.h
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle center: vertical first, then horizontal, then restore
local function toggleCenter()
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  local centerX = screen.x + (screen.w - frame.w) / 2
  local centerY = screen.y + (screen.h - frame.h) / 2
  local isCenteredH = math.abs(frame.x - centerX) < 10
  local isCenteredV = math.abs(frame.y - centerY) < 10

  if not isCenteredV then
    -- First: center vertically
    setupWindowOperation(true)
    frame.y = centerY
  elseif not isCenteredH then
    -- Second: center horizontally
    frame.x = centerX
  elseif spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Third: restore previous position
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.x = lastPos.x or frame.x
    frame.y = lastPos.y or frame.y
  end

  instant(function() win:setFrame(frame) end)
end

-- Cycle through half/third/middle-third/two-thirds width aligned to edge (or restore)
local function cycleHalfThird(dir)
  local win, frame, screen = setupWindowOperation(false)  -- don't save yet
  if not win then return end

  local halfW = screen.w / 2
  local thirdW = screen.w / 3
  local twoThirdW = screen.w * 2 / 3
  local tolerance = 10

  local atLeft = math.abs(frame.x - screen.x) < tolerance
  local atRight = math.abs((frame.x + frame.w) - (screen.x + screen.w)) < tolerance
  local centerX = screen.x + (screen.w - frame.w) / 2
  local isCentered = math.abs(frame.x - centerX) < tolerance
  local isHalf = math.abs(frame.w - halfW) < tolerance
  local isThird = math.abs(frame.w - thirdW) < tolerance
  local isTwoThird = math.abs(frame.w - twoThirdW) < tolerance
  local isFullHeight = math.abs(frame.h - screen.h) < tolerance

  if dir == "left" then
    if atLeft and isHalf and isFullHeight then
      -- Half → Third
      frame.w = thirdW
      frame.x = screen.x
    elseif atLeft and isThird and isFullHeight then
      -- Third → Middle third
      frame.w = thirdW
      frame.x = screen.x + (screen.w - thirdW) / 2
    elseif isCentered and isThird and isFullHeight then
      -- Middle third → Two-thirds
      frame.w = twoThirdW
      frame.x = screen.x
    elseif atLeft and isTwoThird and isFullHeight then
      -- Two-thirds → Restore
      if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
        local lastPos = spoon.WinWin._lastPositions[1]
        frame.x = lastPos.x or frame.x
        frame.y = lastPos.y or frame.y
        frame.w = lastPos.w or frame.w
        frame.h = lastPos.h or frame.h
      end
    else
      -- Any other state → Half + full height (save first)
      setupWindowOperation(true)
      frame.x = screen.x
      frame.y = screen.y
      frame.w = halfW
      frame.h = screen.h
    end
  else  -- right
    if atRight and isHalf and isFullHeight then
      -- Half → Third
      frame.w = thirdW
      frame.x = screen.x + screen.w - frame.w
    elseif atRight and isThird and isFullHeight then
      -- Third → Middle third
      frame.w = thirdW
      frame.x = screen.x + (screen.w - thirdW) / 2
    elseif isCentered and isThird and isFullHeight then
      -- Middle third → Two-thirds
      frame.w = twoThirdW
      frame.x = screen.x + screen.w - frame.w
    elseif atRight and isTwoThird and isFullHeight then
      -- Two-thirds → Restore
      if spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
        local lastPos = spoon.WinWin._lastPositions[1]
        frame.x = lastPos.x or frame.x
        frame.y = lastPos.y or frame.y
        frame.w = lastPos.w or frame.w
        frame.h = lastPos.h or frame.h
      end
    else
      -- Any other state → Half + full height (save first)
      setupWindowOperation(true)
      frame.y = screen.y
      frame.w = halfW
      frame.h = screen.h
      frame.x = screen.x + screen.w - frame.w
    end
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle max height (keep width/x, expand height to full screen)
local function toggleMaxHeight()
  local win, frame, screen = setupWindowOperation(false)
  if not win then return end

  local tolerance = 10
  local isMaxHeight = math.abs(frame.y - screen.y) < tolerance and
                      math.abs(frame.h - screen.h) < tolerance

  if isMaxHeight and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous height/y
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.y = lastPos.y or frame.y
    frame.h = lastPos.h or frame.h
  else
    -- Save current position, then maximize height
    setupWindowOperation(true)
    flashEdgeHighlight(screen, {"up", "down"})
    frame.y = screen.y
    frame.h = screen.h
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle native macOS fullscreen
local function toggleFullScreen()
  local win = hs.window.focusedWindow()
  if win then win:toggleFullScreen() end
end

-- Toggle max width (keep height/y, expand width to full screen)
local function toggleMaxWidth()
  local win, frame, screen = setupWindowOperation(false)
  if not win then return end

  local tolerance = 10
  local isMaxWidth = math.abs(frame.x - screen.x) < tolerance and
                     math.abs(frame.w - screen.w) < tolerance

  if isMaxWidth and spoon.WinWin._lastPositions and spoon.WinWin._lastPositions[1] then
    -- Restore previous width/x
    local lastPos = spoon.WinWin._lastPositions[1]
    frame.x = lastPos.x or frame.x
    frame.w = lastPos.w or frame.w
  else
    -- Save current position, then maximize width
    setupWindowOperation(true)
    flashEdgeHighlight(screen, {"left", "right"})
    frame.x = screen.x
    frame.w = screen.w
  end

  instant(function() win:setFrame(frame) end)
end

-- Toggle compact/PiP mode (shrink to min size, stack at bottom of screen)
-- Works like a dock: compacted windows line up from left to right at screen bottom
local function toggleCompact()
  local win = hs.window.focusedWindow()
  if not win then return end

  local winID = win:id()
  local frame = win:frame()
  local screenObj = win:screen()
  local screen = screenObj:frame()
  local currentScreenID = screenObj:id()

  -- Check if this window is already compact (has saved original frame)
  if compactWindows[winID] then
    -- Restore original frame
    instant(function() win:setFrame(compactWindows[winID].original) end)
    compactWindows[winID] = nil
    return
  end

  -- Get compact size (app-specific or default)
  local appName = win:application():name():lower()
  local compactSize = minShrinkSize[appName] or defaultCompactSize
  local compactW = compactSize.w
  local compactH = compactSize.h

  -- Clean up stale entries and collect valid compact windows on this screen by row
  -- Row 0 = bottom, Row 1 = one up, etc.
  local rows = {}  -- rows[rowNum] = sorted list of {x, rightEdge}
  local staleIDs = {}

  for otherWinID, info in pairs(compactWindows) do
    local otherWin = hs.window.get(otherWinID)
    if not otherWin or not otherWin:isVisible() then
      -- Window no longer exists or is hidden - mark for cleanup
      table.insert(staleIDs, otherWinID)
    elseif info.screenID == currentScreenID then
      -- Valid compact window on this screen
      local otherFrame = otherWin:frame()
      -- Determine row based on y position (bottom of screen = row 0)
      local bottomY = screen.y + screen.h
      local rowNum = math.floor((bottomY - otherFrame.y - otherFrame.h + compactH/2) / compactH)
      if rowNum < 0 then rowNum = 0 end

      if not rows[rowNum] then rows[rowNum] = {} end
      table.insert(rows[rowNum], {
        x = otherFrame.x,
        rightEdge = otherFrame.x + otherFrame.w
      })
    end
  end

  -- Remove stale entries
  for _, id in ipairs(staleIDs) do
    compactWindows[id] = nil
  end

  -- Sort each row by x position
  for rowNum, rowWindows in pairs(rows) do
    table.sort(rowWindows, function(a, b) return a.x < b.x end)
  end

  -- Find placement: start at row 0, find the rightmost edge, place after it
  -- If row is full, go to next row
  local maxX = screen.x + screen.w - compactW
  local slotX = screen.x
  local slotRow = 0

  for rowNum = 0, 10 do  -- Check up to 10 rows
    local rowWindows = rows[rowNum]
    if not rowWindows or #rowWindows == 0 then
      -- Empty row - start at left edge
      slotX = screen.x
      slotRow = rowNum
      break
    else
      -- Find rightmost edge in this row
      local rightmost = screen.x
      for _, w in ipairs(rowWindows) do
        if w.rightEdge > rightmost then
          rightmost = w.rightEdge
        end
      end
      -- Check if there's room for another window
      if rightmost <= maxX then
        slotX = rightmost
        slotRow = rowNum
        break
      end
      -- Row is full, try next row
    end
  end

  -- Calculate final position
  local newFrame = {
    x = slotX,
    y = screen.y + screen.h - compactH - (slotRow * compactH),
    w = compactW,
    h = compactH
  }

  -- Save original frame and screen before compacting
  compactWindows[winID] = {
    original = {x = frame.x, y = frame.y, w = frame.w, h = frame.h},
    screenID = currentScreenID
  }

  flashEdgeHighlight(screen, {"down", "left"})
  instant(function() win:setFrame(newFrame) end)
end

-- Flash a thick blue border on the screen edge(s)
-- dir can be a single direction ("left") or a table of directions ({"left", "right"})
local edgeHighlight = nil
flashEdgeHighlight = function(screen, dir)
  if edgeHighlight then
    edgeHighlight:delete()
    edgeHighlight = nil
  end

  local thick = 12
  local color = {red = 0.3, green = 0.8, blue = 0.4, alpha = 0.9}

  -- Normalize to table of directions
  local dirs = type(dir) == "table" and dir or {dir}

  -- Create full-screen canvas to hold all edge lines
  edgeHighlight = hs.canvas.new({x = screen.x, y = screen.y, w = screen.w, h = screen.h})

  for _, d in ipairs(dirs) do
    local lineCoords
    if d == "left" then
      lineCoords = {
        {x = thick / 2, y = 0},
        {x = thick / 2, y = screen.h}
      }
    elseif d == "right" then
      lineCoords = {
        {x = screen.w - thick / 2, y = 0},
        {x = screen.w - thick / 2, y = screen.h}
      }
    elseif d == "up" then
      lineCoords = {
        {x = 0, y = thick / 2},
        {x = screen.w, y = thick / 2}
      }
    elseif d == "down" then
      lineCoords = {
        {x = 0, y = screen.h - thick / 2},
        {x = screen.w, y = screen.h - thick / 2}
      }
    end

    if lineCoords then
      edgeHighlight:appendElements({
        type = "segments",
        action = "stroke",
        strokeColor = color,
        strokeWidth = thick,
        strokeCapStyle = "butt",
        coordinates = lineCoords
      })
    end
  end

  edgeHighlight:show()

  hs.timer.doAfter(0.3, function()
    if edgeHighlight then
      edgeHighlight:delete()
      edgeHighlight = nil
    end
  end)
end

local function bindWithRepeat(mods, key, fn)
    hs.hotkey.bind(mods, key, fn, nil, fn)
end

-- Define mappings of keys to dirs
local keyMap = {
  home = "left",
  ["end"] = "right",
  pageup = "up",
  pagedown = "down"
}

-- Define operations with modifiers
local operations = {
  [{} ]                = {fn = function(dir) _G.shiftFirstMode = false; stepMove(dir) end},
  [{"shift"}]          = {fn = function(dir)
    if _G.shiftFirstMode then
      topLeftAnchorResize(dir)
    else
      smartStepResize(dir)
    end
  end},
  [{"ctrl"}]           = {fn = function(dir) _G.shiftFirstMode = false; moveToEdge(dir) end},
  [{"ctrl", "shift"}]  = {fn = function(dir) _G.shiftFirstMode = false; resizeToEdge(dir) end},
  -- option is handled separately below for toggle shrink behavior
}

-- Bind all operations
for key, dir in pairs(keyMap) do
    for mods, op in pairs(operations) do
        bindWithRepeat(mods, key, function()
            op.fn(dir)
        end)
    end
end

-- Special bindings for option (shrink/grow)
bindWithRepeat({"option"}, "home", function() toggleShrink("left") end)
bindWithRepeat({"option"}, "pageup", function() toggleShrink("up") end)
bindWithRepeat({"option"}, "end", function() restoreOrGrow("right") end)
bindWithRepeat({"option"}, "pagedown", function() restoreOrGrow("down") end)

-- Special bindings for cmd (focus direction on same screen)
bindWithRepeat({"cmd"}, "home", function() focus.focusDirection("left") end)
bindWithRepeat({"cmd"}, "end", function() focus.focusDirection("right") end)
bindWithRepeat({"cmd"}, "pageup", function() focus.focusDirection("up") end)
bindWithRepeat({"cmd"}, "pagedown", function() focus.focusDirection("down") end)

-- Special bindings for shift+option (center/maximize/half-third)
bindWithRepeat({"shift", "option"}, "home", function() cycleHalfThird("left") end)
bindWithRepeat({"shift", "option"}, "end", function() cycleHalfThird("right") end)
bindWithRepeat({"shift", "option"}, "pageup", cycleMaximize)
bindWithRepeat({"shift", "option"}, "pagedown", toggleCenter)

-- Special bindings for option+cmd (focus across screens)
bindWithRepeat({"option", "cmd"}, "home", function() focus.focusScreen("left") end)
bindWithRepeat({"option", "cmd"}, "end", function() focus.focusScreen("right") end)
bindWithRepeat({"option", "cmd"}, "pageup", function() focus.focusScreen("up") end)
bindWithRepeat({"option", "cmd"}, "pagedown", function() focus.focusScreen("down") end)

-- Move window to specific display (ctrl+option + arrows/return)
-- Pressing the same combo again within 1 hour undoes the move.
local function moveToDisplay(position)
  local win = hs.window.focusedWindow()
  if not win then return end
  local winID = win:id()

  -- Check for undo: same combo pressed again within TTL
  local undo = displayUndo[winID]
  if undo and undo.position == position
     and (hs.timer.secondsSinceEpoch() - undo.timestamp) < DISPLAY_UNDO_TTL then
    displayUndo[winID] = nil
    setupWindowOperation(true)
    instant(function() win:setFrame(undo.frame) end)
    focus.flashFocusHighlight(win, nil)
    local app = win:application()
    layout.triggerSave(string.format("undo-display:%s '%s'", position, app and app:name() or "?"))
    return
  end

  -- Check if move is possible (target screen exists and differs from current)
  local map = screenswitch.buildScreenMap()
  local targetScreen = map[position]
  if not targetScreen then return end
  if win:screen():id() == targetScreen:id() then return end

  -- Store undo state before moving
  displayUndo[winID] = {
    frame = win:frame(),
    position = position,
    timestamp = hs.timer.secondsSinceEpoch(),
  }

  -- Perform the move
  screenswitch.moveToScreen(position, setupWindowOperation, instant, focus.flashFocusHighlight)
  local app = win:application()
  layout.triggerSave(string.format("move-to-display:%s '%s'", position, app and app:name() or "?"))
end
hs.hotkey.bind({"ctrl", "alt"}, "down", function() moveToDisplay("bottom") end)
hs.hotkey.bind({"ctrl", "alt"}, "up", function() moveToDisplay("top") end)
hs.hotkey.bind({"ctrl", "alt"}, "left", function() moveToDisplay("left") end)
hs.hotkey.bind({"ctrl", "alt"}, "right", function() moveToDisplay("right") end)
hs.hotkey.bind({"ctrl", "alt"}, "return", function() moveToDisplay("center") end)

-- Unassigned functions still available: toggleMaxHeight, toggleMaxWidth, toggleFullScreen, toggleCompact

-- Show focus highlight on current window (fn+cmd+delete = forwarddelete)
hs.hotkey.bind({"cmd"}, "forwarddelete", function()
  local win = hs.window.focusedWindow()
  if win then
    local frame = win:frame()
    local screen = win:screen():name()
    local app = win:application():name()
    local tracked = focus.getTrackingInfo()
    print(string.format("[confirmFocus] %s at x=%d on %s (tracked: %s)",
      app, frame.x, screen, tracked and tostring(tracked) or "none"))
    focus.flashFocusHighlight(win, nil)
  end
end)

-- Initialize mouse move module (inject shared border canvas API from focus)
mousemove.init({
  createBorderCanvas = focus.createBorderCanvas,
  updateBorderCanvas = focus.updateBorderCanvas,
  deleteBorderCanvas = focus.deleteBorderCanvas,
})

-- Initialize Bear HUD (note hotkeys + caret position persistence)
bear_hud.init(projectRoot, focus)

-- Initialize layout auto-save, screen watcher, and Lunar name sync
layout.init({screenswitch = screenswitch})

-- Manual layout save: fn+ctrl+alt+delete (pinned, survives autosave overwrites)
hs.hotkey.bind({"ctrl", "alt"}, "forwarddelete", layout.manualSave)

-- Manual layout restore: fn+ctrl+alt+shift+delete (reads pinned save, fallback to autosave)
hs.hotkey.bind({"ctrl", "alt", "shift"}, "forwarddelete", layout.manualRestore)

-- Save state before sleep, prompt restore on wake
hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemWillSleep
  or event == hs.caffeinate.watcher.screensDidSleep then
    print("[stepper] Sleep/screen-off — saving Bear positions + layout")
    bear_hud.saveCurrentPosition()
    layout.autoSave()
  elseif event == hs.caffeinate.watcher.screensDidWake then
    print("[stepper] Wake detected — checking displays")
    layout.onWake()
  end
end):start()

-- Weekly bear-notes.jsonc updater (replaces launchd which can't access CloudStorage)
-- Runs on load + daily at 7am. The python script is idempotent.
local weekUpdateScript = projectRoot .. "features/local/L005-weekly-updater-of-Bear-shortcuts/update-bear-weeks.py"
local function updateBearWeeks()
  hs.task.new("/usr/bin/python3", function(exitCode, stdout, stderr)
    if exitCode == 0 then
      print("[weekUpdate] " .. (stdout or ""):gsub("\n$", ""))
    else
      print("[weekUpdate] ERROR: " .. (stderr or ""):gsub("\n$", ""))
    end
  end, {weekUpdateScript}):start()
end
updateBearWeeks()  -- run on load
hs.timer.doAt("07:00", "1d", updateBearWeeks)

-- Shift-first detection: press shift before fn to resize from the top-left anchor.
-- This callback rides on bear-hud's raltWatcher because it's the only flagsChanged
-- eventtap that reliably sees getFlags().fn from physical keyboard input.
-- See the comment on raltWatcher in bear-hud.lua for details.
_G.shiftFirstCallback = function(flags)
  local before = _G.shiftFirstMode
  if flags.shift and not flags.fn then
    _G.shiftFirstMode = true
  elseif flags.fn and not flags.shift then
    _G.shiftFirstMode = false
  end
  if before ~= _G.shiftFirstMode then
    print(string.format("[shiftFirst] %s→%s", tostring(before), tostring(_G.shiftFirstMode)))
  end
end