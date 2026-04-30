-- =============================================================================
-- L010 — move-to-resize-on-single-screen ("shove")
-- =============================================================================
-- On single-screen mode, fuses move and shrink: shoving a window past a screen
-- edge squeezes the visible frame by the off-screen overflow. The shrink has
-- no memory — moving back is a normal slide, not a stretch-back.
--
-- Earlier versions (v0.1–v0.3.5) tracked a persisted virtual frame so the
-- window would stretch back to its original size when moved away from the
-- absorbed edge. That stretch behavior turned out to be almost never wanted,
-- and shift+arrow already covers intentional resize-from-edge. The pared-down
-- model below is just the absorption math, applied one-shot per keypress.
--
-- This module is gated at the call site by stepper.lua via currentDisplayConfig.
--
-- Design:  features/L010-move-to-resize-on-single-screen/design.md

local M = {}

local PROJECT_FLOOR = 200

local SQUEEZE_RED = {red = 0.9, green = 0.2, blue = 0.2, alpha = 0.95}

local minShrinkSize = {}
local flashEdge = nil  -- (screen, dir, color) — screen-edge flash for squeeze

-- ---------------------------------------------------------------------------
-- Pure helpers — testable without a window handle
-- ---------------------------------------------------------------------------

-- Clamp a (potentially off-screen) virtual frame to the screen bounds, with a
-- floor cap on width/height. The off-screen overflow becomes visible-frame
-- shrink on the absorbed edge; if the shrink would cross the floor, we pin
-- at floor on the appropriate edge instead.
function M.clampToScreen(virtual, screen, floor)
  floor = floor or { w = 0, h = 0 }
  local left = math.max(virtual.x, screen.x)
  local top = math.max(virtual.y, screen.y)
  local right = math.min(virtual.x + virtual.w, screen.x + screen.w)
  local bottom = math.min(virtual.y + virtual.h, screen.y + screen.h)
  local w = right - left
  local h = bottom - top

  if w < floor.w then
    if virtual.x + virtual.w > screen.x + screen.w then
      left = screen.x + screen.w - floor.w  -- absorbed-right edge stays put
    else
      left = math.max(virtual.x, screen.x)  -- absorbed-left edge stays put
    end
    w = floor.w
  end
  if h < floor.h then
    if virtual.y + virtual.h > screen.y + screen.h then
      top = screen.y + screen.h - floor.h
    else
      top = math.max(virtual.y, screen.y)
    end
    h = floor.h
  end

  return { x = left, y = top, w = w, h = h }
end

function M.getStep(screen)
  local gp = (spoon and spoon.WinWin and spoon.WinWin.gridparts) or 30
  return { w = screen.w / gp, h = screen.h / gp }
end

function M.getFloor(appName)
  local appKey = (appName or ""):lower()
  local appMin = minShrinkSize[appKey] or {}
  return {
    w = math.max(PROJECT_FLOOR, appMin.w or 0),
    h = math.max(PROJECT_FLOOR, appMin.h or 0),
  }
end

-- ---------------------------------------------------------------------------
-- Operation
-- ---------------------------------------------------------------------------

function M.shove(win, dir)
  if not win then return end
  local appName = (win:application() and win:application():name()) or ""
  local screen = win:screen():frame()
  local frame = win:frame()
  local step = M.getStep(screen)
  local floor = M.getFloor(appName)

  -- One-shot virtual: where the window would go if the screen were infinite.
  -- Not stored anywhere — the next keypress reads live frame and recomputes.
  local dx = (dir == "left" and -step.w) or (dir == "right" and step.w) or 0
  local dy = (dir == "up" and -step.h) or (dir == "down" and step.h) or 0
  local virtual = { x = frame.x + dx, y = frame.y + dy, w = frame.w, h = frame.h }
  local newFrame = M.clampToScreen(virtual, screen, floor)

  local moved = math.abs(newFrame.x - frame.x) > 0.5
             or math.abs(newFrame.y - frame.y) > 0.5
             or math.abs(newFrame.w - frame.w) > 0.5
             or math.abs(newFrame.h - frame.h) > 0.5
  if not moved then return end  -- pinned at floor; ignore press

  win:setFrame(newFrame)

  local shrunk = newFrame.w < frame.w - 0.5 or newFrame.h < frame.h - 0.5
  if shrunk and flashEdge then flashEdge(screen, dir, SQUEEZE_RED) end

  print(string.format(
    "[shove] win=%q dir=%s vis=%dx%d %s",
    appName .. ":" .. (win:title() or ""), dir,
    math.floor(newFrame.w + 0.5), math.floor(newFrame.h + 0.5),
    shrunk and "(squeeze)" or "(slide)"))
end

-- ---------------------------------------------------------------------------
-- Init + self-test
-- ---------------------------------------------------------------------------

function M.init(opts)
  opts = opts or {}
  if opts.minShrinkSize then minShrinkSize = opts.minShrinkSize end
  if opts.flashEdge then flashEdge = opts.flashEdge end
  print(string.format("[ofsr] initialized; floor=%dpx, flashEdge=%s",
    PROJECT_FLOOR, flashEdge and "on" or "off"))
end

-- Synthetic-frame assertions; run via:
--   hs -c 'return dofile(".../move-to-resize-on-single-screen.lua").selfTest()'
function M.selfTest()
  local results = {}
  local function eq(label, a, b)
    local pass = (math.abs(a - b) < 0.001)
    table.insert(results, { label = label, pass = pass, got = a, want = b })
  end

  local screen = { x = 0, y = 0, w = 1440, h = 900 }
  local floor = { w = 200, h = 200 }

  -- 1. clampToScreen: window fully on-screen → unchanged
  local c1 = M.clampToScreen({ x = 100, y = 100, w = 800, h = 600 }, screen, floor)
  eq("clamp-onscreen.x", c1.x, 100); eq("clamp-onscreen.w", c1.w, 800)

  -- 2. clampToScreen: virtual extends past left → visible shrinks
  local c2 = M.clampToScreen({ x = -100, y = 100, w = 800, h = 600 }, screen, floor)
  eq("clamp-leftabs.x", c2.x, 0); eq("clamp-leftabs.w", c2.w, 700)

  -- 3. clampToScreen: virtual extends past right → visible shrinks, right pinned
  local c3 = M.clampToScreen({ x = 700, y = 100, w = 800, h = 600 }, screen, floor)
  eq("clamp-rightabs.x", c3.x, 700); eq("clamp-rightabs.w", c3.w, 740)

  -- 4. clampToScreen: floor cap on left absorption
  -- virtual.x=-700, w=800 → naive visible.w = 100 (< floor 200)
  -- → pin left at screen.x=0, set w=200
  local c4 = M.clampToScreen({ x = -700, y = 0, w = 800, h = 600 }, screen, floor)
  eq("clamp-floor-left.x", c4.x, 0); eq("clamp-floor-left.w", c4.w, 200)

  -- 5. clampToScreen: floor cap on right absorption
  -- virtual.x=1340, w=800 → naive visible.w = 100 (< floor 200)
  -- → pin right at screen.right=1440, set x=1240, w=200
  local c5 = M.clampToScreen({ x = 1340, y = 0, w = 800, h = 600 }, screen, floor)
  eq("clamp-floor-right.x", c5.x, 1240); eq("clamp-floor-right.w", c5.w, 200)

  -- 6. clampToScreen: wider-than-screen, both sides absorbed → fills screen
  local c6 = M.clampToScreen({ x = -100, y = 0, w = 1600, h = 900 }, screen, floor)
  eq("clamp-wider.x", c6.x, 0); eq("clamp-wider.w", c6.w, 1440)

  -- 7. getFloor: project default
  minShrinkSize = {}
  local f7 = M.getFloor("Bear")
  eq("floor-default.w", f7.w, 200); eq("floor-default.h", f7.h, 200)

  -- 8. getFloor: app-specific min beats project floor
  minShrinkSize = { kitty = { w = 900, h = 400 } }
  local f8 = M.getFloor("kitty")
  eq("floor-kitty.w", f8.w, 900); eq("floor-kitty.h", f8.h, 400)

  -- 9. getFloor: lowercased lookup
  local f9 = M.getFloor("Kitty")
  eq("floor-kitty-cased.w", f9.w, 900)

  -- Tally
  local pass, fail = 0, 0
  for _, r in ipairs(results) do
    if r.pass then pass = pass + 1
    else
      fail = fail + 1
      print(string.format("[selfTest FAIL] %s: got=%s want=%s",
        r.label, tostring(r.got), tostring(r.want)))
    end
  end
  print(string.format("[selfTest] %d/%d passed", pass, pass + fail))
  minShrinkSize = {}  -- reset
  return { pass = pass, fail = fail }
end

return M
