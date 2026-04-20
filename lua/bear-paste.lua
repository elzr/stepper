-- =============================================================================
-- bear-paste: auto-shrink images pasted into Bear to 150px thumbnails
-- =============================================================================
-- Hybrid: observer for the state-change write, eventtap-as-signal for intent.
--
-- Flow:
--   1. hs.axuielement.observer watches Bear at the *app* level for
--      AXSelectedTextChanged notifications (fires on typing, clicking, pasting).
--   2. A lightweight hs.eventtap on keyDown, non-intercepting, stamps a
--      `recentCmdV` timestamp whenever it sees ⌘V while Bear is frontmost.
--   3. On each observer fire we filter: element must be AXTextArea, the count
--      of ￼ (U+FFFC) placeholders in AXValue must have increased by exactly 1,
--      the clipboard must hold an image, AND *either* a ⌘V was seen in the
--      last ~2s *or* the clipboard's changeCount has advanced since our last
--      fire (covers Paste app / drag-drop / context-menu paths that don't
--      synthesize ⌘V — verified empirically, see probe notes below).
--   4. If all match, we append a width comment at the caret via
--      setAttributeValue("AXSelectedText", '<!-- {"width":150} -->'). Bear
--      attaches the comment to the preceding embed and re-renders the image
--      at the configured width.
--
-- Important quirks (all learned the hard way):
--
-- * Bear summarizes every embed (image/pdf) as ONE ￼ character in AXValue.
--   Adding a width comment does NOT grow AXValue — the comment gets attached
--   to the embed's markdown in Bear's database, which remains a single ￼ in
--   the AX layer. Don't use AXValue length to verify the write landed; verify
--   visually (image renders as thumbnail) or via clipboard roundtrip (⌘A →
--   ⌘C in a test note gives the full markdown).
--
-- * Format-glyph trap: Bear ALSO renders blockquote `>` markers, bullet list
--   items, and similar list glyphs as image tiles — and those show up as ￼
--   in AXValue too. So a ￼-count delta of +1 is NOT unique to image paste;
--   pressing Enter at the end of a blockquote-image line, or typing `> ` at
--   the start of a line, both bump ￼ by +1 with no real paste happening.
--   Diagnosed via [bear-paste-trace.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-paste-trace.lua).
--   Mitigation: require an explicit paste *intent* keystroke alongside the
--   ffc-delta match — see Gate 2 below.
--
-- * Why we can't just listen for ⌘V: verified via
--   [paste-source-probe.lua](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/paste-source-probe.lua)
--   that [Paste app](https://pasteapp.io/) does NOT synthesize a ⌘V keystroke
--   when you select a clip and hit Enter. It uses a different insertion
--   channel entirely. To cover Paste app we also watch for the
--   ⌘⇧Space → Enter sequence (opens the Paste panel, commits a clip).
--
-- * What's explicitly out of scope: drag-and-drop and Edit→Paste menu. No
--   keystroke signal to latch onto; earlier designs (clipboard changeCount
--   gate) false-fired on "copy image, type `>`, then paste" — we preferred
--   correctness over those two rare paste paths.
--
-- See [README.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/README.md)
-- and [dev-guide.md](openfile:///Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/dev-guide.md)
-- for the design doc.

local M = {}

local BEAR_BUNDLE = "net.shinyfrog.bear"
local THUMB_COMMENT_SMALL = '<!-- {"width":150} -->'
local UTF8_OBJ_REPL = "\239\191\188" -- U+FFFC in UTF-8

local observer = nil
local intentTap = nil                -- hs.eventtap for paste-intent signals
local lastTa = nil                   -- last textarea we saw (AX element reference)
local lastCount = nil                -- count of ￼ placeholders in that textarea's last-seen value
local recentCmdVAt = nil             -- timestamp of last ⌘V with Bear frontmost
local recentPasteAppAt = nil         -- timestamp when a Paste-app commit (Enter after ⌘⇧Space) completed
local pasteWatchStartedAt = nil      -- if set, a ⌘⇧Space from Bear is open; watching for Enter (commit) vs Esc/⌘⇧Space (cancel)
local inserting = false              -- guard against self-induced notifications
local logger = hs.logger.new("bear-paste", "info")

-- Window within which a keypress still "counts" as paste intent for the next
-- ffc+1 observer fire. ⌘V → Bear insert normally lands within ~100ms; Paste
-- app commit → Bear insert takes longer (UI animation + focus return).
local CMD_V_TTL = 2.0
local PASTE_APP_TTL = 5.0
-- Max time we keep a Paste watch pending (⌘⇧Space opened, no Enter/Esc seen).
-- If user browsed-and-clicked with the mouse, or abandoned the panel, the
-- watch times out harmlessly instead of mis-claiming the next stray Enter.
local PASTE_WATCH_TTL = 15.0

-- Count how many U+FFFC (￼) placeholders appear in a string. Each represents
-- an embed (image/PDF) in Bear's AX layer.
local function countObjRepl(s)
  local n = 0
  for _ in s:gmatch(UTF8_OBJ_REPL) do n = n + 1 end
  return n
end

-- =============================================================================
-- Observer callback
-- =============================================================================

local function onObserverFire(_obs, el, _notif)
  if inserting then return end
  if not el then return end
  local ok, role = pcall(function() return el:attributeValue("AXRole") end)
  if not ok or role ~= "AXTextArea" then return end

  local value = el:attributeValue("AXValue") or ""
  local curCount = countObjRepl(value)

  -- New textarea? Just snapshot the baseline and return.
  if el ~= lastTa then
    lastTa = el
    lastCount = curCount
    return
  end

  local delta = curCount - (lastCount or curCount)
  lastCount = curCount

  -- Filter: exactly one new ￼ appeared since last fire. Necessary but not
  -- sufficient — blockquote/bullet markers also show up as ￼ (see module
  -- header: "format-glyph trap").
  if delta ~= 1 then return end

  -- Gate 1: there must be an image on the clipboard. Rules out non-image
  -- pastes and similar.
  if not hs.pasteboard.readImage() then return end

  -- Gate 2: an *explicit paste intent* must have been observed recently. We
  -- require one of two key-level signals, both one-shot (consumed on fire):
  --   * Primary  — ⌘V keydown in Bear (covers direct paste)
  --   * Fallback — ⌘⇧Space keydown in Bear (covers Paste app: opens the
  --     Paste panel, which then inserts via its own channel). Paste app was
  --     verified NOT to synthesize ⌘V (paste-source-probe.lua, 2026-04-20).
  --
  -- This is strict: drag-and-drop and Edit→Paste menu are NOT covered —
  -- there's no key signal to latch onto. Accepting that by design; the
  -- alternative (clipboard changeCount gate) lets a format-glyph ffc+1
  -- through in the "copy image, type `>`, then paste" edge case.
  local now = hs.timer.secondsSinceEpoch()
  local cmdVRecent = recentCmdVAt and (now - recentCmdVAt) <= CMD_V_TTL
  local pasteAppRecent = recentPasteAppAt and (now - recentPasteAppAt) <= PASTE_APP_TTL
  if not (cmdVRecent or pasteAppRecent) then return end

  -- Fire the width-comment insert. Guard against our own feedback notifications.
  inserting = true
  pcall(function()
    el:setAttributeValue("AXSelectedText", THUMB_COMMENT_SMALL)
  end)
  inserting = false
  -- Consume both intent signals so a format-glyph fire within the same TTL
  -- doesn't reuse them.
  recentCmdVAt = nil
  recentPasteAppAt = nil
  -- Our insert writes a text comment, not another ￼, so lastCount stays valid.
  logger.i(string.format("paste→shrink applied (via %s)",
    cmdVRecent and "⌘V" or "⌘⇧Space"))
end

-- =============================================================================
-- Init / stop
-- =============================================================================

-- Paste-intent eventtap. Non-intercepting (returns false). Two signals:
--
--   1. ⌘V with Bear frontmost        → stamp `recentCmdVAt`
--   2. ⌘⇧Space (opens Paste app) while Bear frontmost → open a watch; then:
--        - Enter (any app)            → commit, stamp `recentPasteAppAt`
--        - Esc (any app)              → cancel, clear watch
--        - another ⌘⇧Space            → cancel (Paste toggled off), clear watch
--        - PASTE_WATCH_TTL elapses    → clear watch
--
-- The watch captures the "⌘⇧Space → Enter" commit shape. Opening Paste just
-- to browse (and dismissing with Esc/⌘⇧Space, or mouse-clicking an item, or
-- letting it time out) will NOT stamp — so the user can view clipboard
-- history without flipping us into width-comment-injecting mode.
local function onKeyDown(event)
  local flags = event:getFlags()
  local keyCode = event:getKeyCode()
  local V_CODE = hs.keycodes.map["v"]
  local SPACE_CODE = hs.keycodes.map["space"]
  local RETURN_CODE = hs.keycodes.map["return"]
  local ESC_CODE = hs.keycodes.map["escape"]
  local frontApp = hs.application.frontmostApplication()
  local bearFront = frontApp and frontApp:bundleID() == BEAR_BUNDLE
  local now = hs.timer.secondsSinceEpoch()

  -- Drop stale pending watches (user abandoned Paste panel, mouse-clicked, etc.)
  if pasteWatchStartedAt and (now - pasteWatchStartedAt) > PASTE_WATCH_TTL then
    pasteWatchStartedAt = nil
  end

  -- ⌘V in Bear → stamp
  if bearFront and flags.cmd and not flags.shift and not flags.alt and not flags.ctrl
      and keyCode == V_CODE then
    recentCmdVAt = now
    return false
  end

  -- ⌘⇧Space → open or close the Paste watch
  if flags.cmd and flags.shift and not flags.alt and not flags.ctrl
      and keyCode == SPACE_CODE then
    if pasteWatchStartedAt then
      -- Second ⌘⇧Space: user dismissed Paste. Cancel watch.
      pasteWatchStartedAt = nil
    elseif bearFront then
      -- ⌘⇧Space from Bear: Paste panel is opening with Bear as insertion target.
      pasteWatchStartedAt = now
    end
    -- If it wasn't from Bear and no watch was pending, it's unrelated — ignore.
    return false
  end

  -- Inside a pending Paste watch, Enter commits and Esc cancels.
  if pasteWatchStartedAt then
    if keyCode == RETURN_CODE then
      recentPasteAppAt = now
      pasteWatchStartedAt = nil
    elseif keyCode == ESC_CODE then
      pasteWatchStartedAt = nil
    end
  end
  return false
end

function M.init()
  M.stop()
  local bear = hs.application.get("Bear")
  if not bear then
    logger.w("Bear not running at init; restart Hammerspoon after launching Bear")
    return
  end

  -- AX observer for the paste state-change.
  observer = hs.axuielement.observer.new(bear:pid())
  observer:callback(onObserverFire)
  local appEl = hs.axuielement.applicationElement(bear)
  local ok = pcall(function()
    observer:addWatcher(appEl, "AXSelectedTextChanged")
  end)
  if not ok then
    logger.w("failed to addWatcher on Bear app element")
    observer = nil
    return
  end
  observer:start()

  -- Eventtap for paste-intent signals.
  intentTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKeyDown)
  intentTap:start()

  logger.i("initialized (observer + intent tap)")
end

function M.stop()
  if observer then
    pcall(function() observer:stop() end)
    observer = nil
  end
  if intentTap then
    pcall(function() intentTap:stop() end)
    intentTap = nil
  end
  lastTa = nil
  lastCount = nil
  recentCmdVAt = nil
  recentPasteAppAt = nil
  pasteWatchStartedAt = nil
  inserting = false
end

return M
