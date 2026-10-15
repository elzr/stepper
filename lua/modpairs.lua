-- A same-side modifier pair tapped twice: R⌘ + R⌥ ×2 and L⌥ + L⌘ ×2 (a trial since 2026-10-15).
-- Both keys go down together, either one first, nothing else is held or typed, both come up, and
-- again within a moment. BTT can't bind these (a BTT key sequence wants one key down before the
-- other); a flagsChanged tap can, since rawFlags tells left and right apart. For now each pair only
-- shows an alert, to learn whether tapping it also sets off BTT's ⌘ ⌘ or ⌥ ⌥ double-taps.
-- Keymap: fleet F002's Modifiers card lists them (the census's HS_GESTURES).

local M = {}

-- rawFlags' side bits (IOKit's NX_DEVICE*KEYMASK)
local SIDE = { lctrl = 0x01, lshift = 0x02, rshift = 0x04, lcmd = 0x08, rcmd = 0x10, lopt = 0x20, ropt = 0x40,
               rctrl = 0x2000 }
local ANY_SIDE = 0
for _, bit in pairs(SIDE) do ANY_SIDE = ANY_SIDE | bit end
local FN = 0x800000

local TAP_MAX = 0.5   -- first key down to both up
local GAP_MAX = 0.45  -- first tap's release to the second tap's first key down

M.pairs = {
  { name = "R⌘ + R⌥ ×2", bits = SIDE.rcmd | SIDE.ropt },
  { name = "L⌥ + L⌘ ×2", bits = SIDE.lopt | SIDE.lcmd },
}

local tap = nil
local keyTap = nil
local down = nil      -- the press under way: { at, union of keys, held together, spoiled }
local lastTap = nil   -- { pair, at } of the previous clean tap

local function fire(pair)
  print(string.format("[modpairs] %s", pair.name))
  hs.alert.show(pair.name .. "  ·  Hammerspoon test", 1.5)
  if M.onFire then M.onFire(pair) end
end

local function onFlags(event)
  local raw = event:rawFlags()
  local held = raw & ANY_SIDE
  if raw & FN ~= 0 then held = held | FN end
  local now = hs.timer.secondsSinceEpoch()
  if held ~= 0 then
    if not down then down = { at = now, union = 0, together = 0, spoiled = false } end
    down.union = down.union | held
    for _, p in ipairs(M.pairs) do
      if held & p.bits == p.bits then down.together = down.together | p.bits end
    end
    return false
  end
  -- Everything is up: was it a clean tap of a pair?
  local press = down
  down = nil
  if not press then return false end
  local pair = nil
  for _, p in ipairs(M.pairs) do
    if press.union == p.bits and press.together == p.bits then pair = p end
  end
  if not pair or press.spoiled or now - press.at > TAP_MAX then
    lastTap = nil
    return false
  end
  if lastTap and lastTap.pair == pair and press.at - lastTap.at <= GAP_MAX then
    lastTap = nil
    fire(pair)
  else
    lastTap = { pair = pair, at = now }
  end
  return false
end

M._onFlags = onFlags  -- for tests: feed it { rawFlags = function() return bits end }

function M.init()
  tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, onFlags)
  tap:start()
  -- A key typed while a pair is down makes it a chord, not a tap
  keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
    if down then down.spoiled = true end
    lastTap = nil
    return false
  end)
  keyTap:start()
  M._taps = { tap, keyTap }  -- module scope, so they aren't collected
end

return M
