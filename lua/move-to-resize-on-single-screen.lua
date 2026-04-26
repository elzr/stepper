-- =============================================================================
-- L010 — move-to-resize-on-single-screen ("shove and stretch")
-- =============================================================================
-- On single-screen mode, fuses move and shrink: shoving a window past a screen
-- edge squeezes the visible frame while the virtual frame extends past the
-- edge; pulling back stretches the visible frame as the absorbed offset
-- contracts. Bottoms out at a per-app floor.
--
-- This module is gated at the call site by stepper.lua via layout.activeCount.
-- Persistence, visual feedback, divergence detection, and multi-screen
-- transition handling land in later phases (see plan.md).
--
-- Design:  features/L010-move-to-resize-on-single-screen/design.md
-- Plan:    features/L010-move-to-resize-on-single-screen/plan.md

local M = {}

local PROJECT_FLOOR = 200

local minShrinkSize = {}

-- [winID] = { virtualFrame, expectedVisible, ts }
M.sessionVirtual = {}

local function now()
  return hs.timer.secondsSinceEpoch()
end

-- ---------------------------------------------------------------------------
-- Pure helpers — testable without a window handle
-- ---------------------------------------------------------------------------

function M.clampToScreen(virtual, screen)
  local x = math.max(virtual.x, screen.x)
  local y = math.max(virtual.y, screen.y)
  local right = math.min(virtual.x + virtual.w, screen.x + screen.w)
  local bottom = math.min(virtual.y + virtual.h, screen.y + screen.h)
  return { x = x, y = y, w = right - x, h = bottom - y }
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

function M.computeMove(virtual, dir, step, screen, floor)
  local nv = { x = virtual.x, y = virtual.y, w = virtual.w, h = virtual.h }
  if dir == "left" then
    nv.x = math.max(virtual.x - step.w, screen.x + floor.w - nv.w)
  elseif dir == "right" then
    nv.x = math.min(virtual.x + step.w, screen.x + screen.w - floor.w)
  elseif dir == "up" then
    nv.y = math.max(virtual.y - step.h, screen.y + floor.h - nv.h)
  elseif dir == "down" then
    nv.y = math.min(virtual.y + step.h, screen.y + screen.h - floor.h)
  end
  return nv
end

local function absorbed(virtual, screen)
  return {
    L = math.max(0, screen.x - virtual.x),
    R = math.max(0, (virtual.x + virtual.w) - (screen.x + screen.w)),
    T = math.max(0, screen.y - virtual.y),
    B = math.max(0, (virtual.y + virtual.h) - (screen.y + screen.h)),
  }
end
M._absorbed = absorbed

-- ---------------------------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------------------------

function M.getVirtual(win)
  if not win then return nil end
  local entry = M.sessionVirtual[win:id()]
  return entry and entry.virtualFrame or nil
end

function M.reset(win)
  if not win then return end
  if M.sessionVirtual[win:id()] then
    print(string.format("[reset] win=%q", (win:title() or "?")))
  end
  M.sessionVirtual[win:id()] = nil
end

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

function M.shove(win, dir)
  if not win then return end
  local appName = (win:application() and win:application():name()) or ""
  local screen = win:screen():frame()
  local virtual = M.getVirtual(win) or win:frame()
  local step = M.getStep(screen)
  local floor = M.getFloor(appName)

  local newVirtual = M.computeMove(virtual, dir, step, screen, floor)
  local newVisible = M.clampToScreen(newVirtual, screen)

  win:setFrame(newVisible)

  M.sessionVirtual[win:id()] = {
    virtualFrame = newVirtual,
    expectedVisible = newVisible,
    ts = now(),
  }

  local abs = absorbed(newVirtual, screen)
  print(string.format(
    "[shove] win=%q dir=%s vis=%dx%d absL=%d absR=%d absT=%d absB=%d",
    appName .. ":" .. (win:title() or ""), dir,
    math.floor(newVisible.w + 0.5), math.floor(newVisible.h + 0.5),
    math.floor(abs.L + 0.5), math.floor(abs.R + 0.5),
    math.floor(abs.T + 0.5), math.floor(abs.B + 0.5)
  ))
end

-- Mirror a visible-frame delta on the virtual frame (B4: resize preserves
-- absorbed). Caller passes the deltas it already applied to the visible frame.
function M.bumpVirtual(win, dx, dy, dw, dh)
  if not win then return end
  local entry = M.sessionVirtual[win:id()]
  if not entry then return end

  local v = entry.virtualFrame
  local e = entry.expectedVisible
  M.sessionVirtual[win:id()] = {
    virtualFrame = {
      x = v.x + (dx or 0), y = v.y + (dy or 0),
      w = v.w + (dw or 0), h = v.h + (dh or 0),
    },
    expectedVisible = {
      x = e.x + (dx or 0), y = e.y + (dy or 0),
      w = e.w + (dw or 0), h = e.h + (dh or 0),
    },
    ts = now(),
  }
end

-- ---------------------------------------------------------------------------
-- Init + self-test
-- ---------------------------------------------------------------------------

function M.init(opts)
  opts = opts or {}
  if opts.minShrinkSize then minShrinkSize = opts.minShrinkSize end
  print("[ofsr] initialized; project floor=" .. PROJECT_FLOOR .. "px")
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
  local step = { w = 48, h = 30 }

  -- 1. clampToScreen: window fully on-screen → unchanged
  local v1 = { x = 100, y = 100, w = 800, h = 600 }
  local c1 = M.clampToScreen(v1, screen)
  eq("clamp-onscreen.x", c1.x, 100); eq("clamp-onscreen.w", c1.w, 800)

  -- 2. clampToScreen: virtual extends past left → visible shrinks
  local v2 = { x = -100, y = 100, w = 800, h = 600 }
  local c2 = M.clampToScreen(v2, screen)
  eq("clamp-leftabs.x", c2.x, 0); eq("clamp-leftabs.w", c2.w, 700)

  -- 3. clampToScreen: virtual extends past right → visible shrinks
  local v3 = { x = 700, y = 100, w = 800, h = 600 }
  local c3 = M.clampToScreen(v3, screen)
  eq("clamp-rightabs.x", c3.x, 700); eq("clamp-rightabs.w", c3.w, 740)

  -- 4. clampToScreen: wider-than-screen, both sides absorbed
  local v4 = { x = -100, y = 0, w = 1600, h = 900 }
  local c4 = M.clampToScreen(v4, screen)
  eq("clamp-wider.x", c4.x, 0); eq("clamp-wider.w", c4.w, 1440)

  -- 5. computeMove: normal slide left (no absorb yet)
  local m5 = M.computeMove({ x = 200, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-slide-left.x", m5.x, 152)

  -- 6. computeMove: cross threshold into absorb
  local m6 = M.computeMove({ x = 0, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-into-absorb-left.x", m6.x, -48)

  -- 7. computeMove: floor cap on left
  -- nv.w=800, floor.w=200 → minX = 0 + 200 - 800 = -600
  local m7 = M.computeMove({ x = -580, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-floor-left.x", m7.x, -600)
  -- And again from already-floored position should stay
  local m7b = M.computeMove({ x = -600, y = 100, w = 800, h = 600 }, "left", step, screen, floor)
  eq("move-floor-left-stays.x", m7b.x, -600)

  -- 8. computeMove: floor cap on right
  local m8 = M.computeMove({ x = 1220, y = 100, w = 800, h = 600 }, "right", step, screen, floor)
  -- maxX = 1440 - 200 = 1240
  eq("move-floor-right.x", m8.x, 1240)

  -- 9. computeMove: release absorbed by moving toward absorbed edge
  -- start with virtual.x=-100 (100 absorbed on left), move right
  local m9 = M.computeMove({ x = -100, y = 100, w = 800, h = 600 }, "right", step, screen, floor)
  eq("move-release-left.x", m9.x, -52)

  -- 10. getFloor: project default
  minShrinkSize = {}
  local f10 = M.getFloor("Bear")
  eq("floor-default.w", f10.w, 200); eq("floor-default.h", f10.h, 200)

  -- 11. getFloor: app-specific min beats project floor
  minShrinkSize = { kitty = { w = 900, h = 400 } }
  local f11 = M.getFloor("kitty")
  eq("floor-kitty.w", f11.w, 900); eq("floor-kitty.h", f11.h, 400)

  -- 12. getFloor: lowercased lookup
  local f12 = M.getFloor("Kitty")
  eq("floor-kitty-cased.w", f12.w, 900)

  -- 13. absorbed: derive from virtual + screen
  local a13 = absorbed({ x = -120, y = 0, w = 800, h = 900 }, screen)
  eq("absorbed.L", a13.L, 120); eq("absorbed.R", a13.R, 0)

  -- Tally
  local pass, fail = 0, 0
  for _, r in ipairs(results) do
    if r.pass then pass = pass + 1
    else
      fail = fail + 1
      print(string.format("[selfTest FAIL] %s: got=%s want=%s", r.label, tostring(r.got), tostring(r.want)))
    end
  end
  print(string.format("[selfTest] %d/%d passed", pass, pass + fail))
  minShrinkSize = {}  -- reset
  return { pass = pass, fail = fail }
end

return M
