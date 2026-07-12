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
-- * Liveness is EVENT-DRIVEN, not polled. The observer (bound to Bear's PID) and
--   the intent tap can die silently; we reconcile via ensureHealthy() fired from
--   two independent sources — the app-watcher's `activated` (Bear comes to front,
--   right before any paste; can revive a fully-dead tap) and a per-keystroke
--   heartbeat in onKeyDown (heals a stale observer even if app events stop). Note
--   Hammerspoon ALREADY auto-re-enables a tap disabled by timeout/secure-input
--   (its C callback calls CGEventTapEnable and never surfaces the event to Lua —
--   hence no `tapDisabledByTimeout` in hs.eventtap.event.types), so we only mop up
--   the residue. The lone un-catchable mode is a "silent wedge" (tap enabled but
--   no events flow): it emits no event, so no event-driven source can see it.
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
local appWatcher = nil               -- hs.application.watcher for Bear launch/terminate (rebinds observer on PID change)
local lastTa = nil                   -- last textarea we saw (AX element reference)
local lastCount = nil                -- count of ￼ placeholders in that textarea's last-seen value
local recentCmdVAt = nil             -- timestamp of last ⌘V with Bear frontmost
local recentPasteAppAt = nil         -- timestamp when a Paste-app commit (Enter after ⌘⇧Space) completed
local pasteWatchStartedAt = nil      -- if set, a ⌘⇧Space from Bear is open; watching for Enter (commit) vs Esc/⌘⇧Space (cancel)
local inserting = false              -- guard against self-induced notifications
local boundPid = nil                 -- PID the observer/tap are bound to; compared against the live Bear PID to spot a stale binding
local lastFireAt = nil               -- timestamp of the most recent observer fire (liveness: proves the observer is still delivering)
local ensureHealthy = nil            -- forward decl: the event-driven reconciler (assigned after setupHooks below)
local logger = hs.logger.new("bear-paste", "info")

-- Durable event log. The hs.logger sink above writes ONLY to Hammerspoon's
-- in-memory console, which is wiped on every reload and capped in size — so it
-- could not actually support the "next time it goes dead, the logs will tell us
-- why" promise (the diagnostics were evaporating). Every info-level event is also
-- appended here as NDJSON so it survives reloads/restarts. Post-mortem on the
-- ephemeral-logging oversight: F028 case-study 2026-05-30-ephemeral-safety-net.
local scriptPath = debug.getinfo(1, "S").source:match("@(.*/)")
local LOG_DIR = scriptPath .. "../features/L008-Bear-image-thumbnails/data"
local LOG_PATH = LOG_DIR .. "/bear-paste.log.ndjson"
local LOG_PATH_PREV = LOG_DIR .. "/bear-paste.log.1.ndjson"
local LOG_CAP_BYTES = 512 * 1024     -- rotate one generation past this so the file can't grow unbounded
local logFile = nil

-- Logging policy (so the console doesn't flood — AXSelectedTextChanged fires on
-- every keystroke/click): high-frequency, expected no-ops log at DEBUG (hidden at
-- the default "info" level); low-frequency, diagnostically interesting events
-- (paste intent seen, a ￼ appeared, a gate rejected it, success, binding/liveness
-- changes) log at INFO. Crank to the firehose with bear_paste.setLogLevel("debug").

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
-- Durable NDJSON event log (survives reloads — see LOG_PATH note above)
-- =============================================================================
-- Minimal JSON serializer — only the value types we emit. Schema mirrors the
-- April diagnostic tracer (scripts/bear-paste-trace.lua) so old and new logs read
-- alike and grep the same way.
local function jsonStr(s)
  s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return '"' .. s .. '"'
end

local function jsonVal(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then return string.format("%.4g", v)
  else return jsonStr(v) end
end

-- Append one event as a single NDJSON line, then flush (crash-safe: a mid-write
-- crash costs only the trailing line). No-ops silently if the file isn't open —
-- the console sink still has the event, so logging never depends on a writable disk.
local function persistEvent(kind, fields)
  if not logFile then return end
  local parts = {
    '"ts":' .. string.format("%.3f", hs.timer.secondsSinceEpoch()),
    '"time":' .. jsonStr(os.date("%Y-%m-%d %H:%M:%S")),
    '"kind":' .. jsonStr(kind),
  }
  if fields then
    for k, v in pairs(fields) do
      parts[#parts + 1] = jsonStr(k) .. ":" .. jsonVal(v)
    end
  end
  pcall(function()
    logFile:write("{" .. table.concat(parts, ",") .. "}\n")
    logFile:flush()
  end)
end

-- Emit an event to BOTH sinks: the human-readable console (ephemeral) and the
-- durable NDJSON file. Use for every info-level event; the per-keystroke debug
-- firehose stays console-only via logger.d so the file stays small.
local function report(kind, humanMsg, fields)
  logger.i(humanMsg)
  persistEvent(kind, fields)
end

-- Open the durable log in append mode, rotating one generation if it has grown
-- past the cap. The handle lives for the module's lifetime (closed in M.stop).
local function openLogFile()
  if logFile then return end
  pcall(function()
    local attrs = hs.fs.attributes(LOG_PATH)
    if attrs and attrs.size and attrs.size > LOG_CAP_BYTES then
      os.remove(LOG_PATH_PREV)
      os.rename(LOG_PATH, LOG_PATH_PREV)
    end
    logFile = io.open(LOG_PATH, "a")
  end)
  if logFile then
    persistEvent("session", { note = "log opened" })
  else
    logger.w("durable log: could not open " .. LOG_PATH .. " (console-only this session)")
  end
end

local function closeLogFile()
  if logFile then
    persistEvent("session", { note = "log closing" })
    pcall(function() logFile:close() end)
    logFile = nil
  end
end

-- Best-effort "is the observer running?" — pcall-guarded in case the method is
-- ever absent on a Hammerspoon version (it exists as of this writing).
local function observerRunning()
  if not observer then return false end
  local ok, r = pcall(function() return observer:isRunning() end)
  if ok then return r end
  return true
end

-- =============================================================================
-- Observer callback
-- =============================================================================

local function onObserverFire(_obs, el, _notif)
  if inserting then return end          -- our own write echoing back; ignore silently
  lastFireAt = hs.timer.secondsSinceEpoch()  -- LIVENESS: observer is alive and delivering
  if not el then return end
  local ok, role = pcall(function() return el:attributeValue("AXRole") end)
  if not ok or role ~= "AXTextArea" then
    logger.d(string.format("fire ignored: role=%s", tostring(ok and role or "<err>")))
    return
  end

  local value = el:attributeValue("AXValue") or ""
  local curCount = countObjRepl(value)

  -- New textarea? Just snapshot the baseline and return. NOTE: if a paste is the
  -- VERY FIRST selection-change fire on a freshly-focused note (e.g. you reached
  -- Bear via ⌘-tab with no prior click), it is swallowed here as the baseline —
  -- a known single-miss source. Logged so a trace can reveal it.
  if el ~= lastTa then
    logger.d(string.format("baseline snapshot on new textarea: ￼=%d (was lastCount=%s)",
      curCount, tostring(lastCount)))
    lastTa = el
    lastCount = curCount
    return
  end

  local delta = curCount - (lastCount or curCount)
  lastCount = curCount

  -- delta==0 is the common per-keystroke case (typing/selection adds no ￼).
  -- Debug-level so it doesn't flood the console.
  if delta == 0 then
    logger.d("fire: delta=0 (no embed change)")
    return
  end

  -- Intent recency + clipboard state, computed up front so the reject logs below
  -- can report WHY a fire didn't apply. These fields are the evidence we need to
  -- tell a lossy-delta miss (image=true, cmdV=true, but delta≠1) apart from a
  -- genuine non-paste (image=false / cmdV=false) — see the diagnostics notes.
  local now = hs.timer.secondsSinceEpoch()
  local cmdVRecent = recentCmdVAt and (now - recentCmdVAt) <= CMD_V_TTL
  local pasteAppRecent = recentPasteAppAt and (now - recentPasteAppAt) <= PASTE_APP_TTL
  local hasImage = hs.pasteboard.readImage() ~= nil
  local changeCount = hs.pasteboard.changeCount()

  -- Filter: exactly one new ￼ appeared since last fire. delta>1 or <0 means the
  -- observer's fires aren't 1:1 with ￼ changes (Bear coalesces/drops them), so a
  -- real paste can land on +2 and be wrongly rejected here. The enriched fields
  -- expose whether THIS rejected fire was actually a paste (image=true, cmdV=true)
  -- — the data needed before deciding to relax the gate. (Still ==1 for now.)
  if delta ~= 1 then
    report("reject",
      string.format("reject: delta=%+d (need +1); ￼=%d, image=%s, cmdV=%s, pasteApp=%s, changeCount=%d",
        delta, curCount, tostring(hasImage), tostring(cmdVRecent), tostring(pasteAppRecent), changeCount),
      { reason = "delta", delta = delta, ffc = curCount, image = hasImage,
        cmdV = cmdVRecent and true or false, pasteApp = pasteAppRecent and true or false, changeCount = changeCount })
    return
  end

  -- One new ￼ — the interesting case (a real paste, OR a format glyph).

  -- Gate 1: there must be an image on the clipboard. Rules out non-image
  -- pastes and (most) format glyphs. If this rejects WITH cmdV recent, suspect a
  -- readImage() race right after a real paste rather than a true format glyph.
  if not hasImage then
    report("reject",
      string.format("reject: ￼+1 but no image on clipboard; cmdV=%s, changeCount=%d "..
        "(format glyph — or a readImage() race just after a real ⌘V paste?)",
        tostring(cmdVRecent), changeCount),
      { reason = "no-image", ffc = curCount, cmdV = cmdVRecent and true or false, changeCount = changeCount })
    return
  end

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
  if not (cmdVRecent or pasteAppRecent) then
    report("reject",
      string.format(
        "reject: ￼+1 with image, but NO recent paste intent (⌘V age=%s, pasteApp age=%s). "..
        "→ intent tap dead, or a drag/menu paste (out of scope)?",
        recentCmdVAt and string.format("%.2fs", now - recentCmdVAt) or "never",
        recentPasteAppAt and string.format("%.2fs", now - recentPasteAppAt) or "never"),
      { reason = "no-intent", ffc = curCount,
        cmdVAge = recentCmdVAt and (now - recentCmdVAt) or nil,
        pasteAppAge = recentPasteAppAt and (now - recentPasteAppAt) or nil,
        changeCount = changeCount })
    return
  end

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
  report("applied",
    string.format("paste→shrink APPLIED (via %s)", cmdVRecent and "⌘V" or "⌘⇧Space"),
    { via = cmdVRecent and "cmdV" or "pasteApp", ffc = curCount })
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

  -- Heartbeat reconcile (event-driven, and independent of the app-watcher): the
  -- mere fact that this callback ran proves the intent tap is alive. So while
  -- we're in Bear, cheaply verify the OTHER half — the AX observer — is bound to
  -- THIS Bear and still running; rebind if not. This self-heals a stale observer
  -- from ordinary typing in Bear, before any paste, with no polling timer. (The
  -- tap can't heal itself this way — a dead tap never reaches here — so tap
  -- recovery rides the app-watcher instead; see ensureHealthy.)
  --
  -- Deferred by one runloop turn via doAfter(0): ensureHealthy may stop/recreate
  -- the intent tap, which is unsafe to do from inside that very tap's callback.
  -- This is a one-shot deferral triggered by THIS keystroke — not a poll. The
  -- triggering condition self-clears once rebound, so rapid typing won't pile up
  -- more than a turn's worth of (idempotent, no-op) reconciles.
  if bearFront and ensureHealthy and (boundPid ~= frontApp:pid() or not observerRunning()) then
    hs.timer.doAfter(0, function() ensureHealthy("keydown-heartbeat") end)
  end

  -- Drop stale pending watches (user abandoned Paste panel, mouse-clicked, etc.)
  if pasteWatchStartedAt and (now - pasteWatchStartedAt) > PASTE_WATCH_TTL then
    report("intent",
      string.format("intent: paste-watch timed out (%.1fs, no commit)", now - pasteWatchStartedAt),
      { signal = "pasteTimeout" })
    pasteWatchStartedAt = nil
  end

  -- ⌘V in Bear → stamp
  if bearFront and flags.cmd and not flags.shift and not flags.alt and not flags.ctrl
      and keyCode == V_CODE then
    recentCmdVAt = now
    report("intent", "intent: ⌘V in Bear → stamped", { signal = "cmdV" })  -- LIVENESS: the eventtap is alive and seeing keys
    return false
  end

  -- ⌘⇧Space → open or close the Paste watch
  if flags.cmd and flags.shift and not flags.alt and not flags.ctrl
      and keyCode == SPACE_CODE then
    if pasteWatchStartedAt then
      -- Second ⌘⇧Space: user dismissed Paste. Cancel watch.
      report("intent", "intent: ⌘⇧Space again → paste-watch cancelled", { signal = "pasteSpace", action = "cancel" })
      pasteWatchStartedAt = nil
    elseif bearFront then
      -- ⌘⇧Space from Bear: Paste panel is opening with Bear as insertion target.
      report("intent", "intent: ⌘⇧Space in Bear → paste-watch opened", { signal = "pasteSpace", action = "open" })
      pasteWatchStartedAt = now
    end
    -- If it wasn't from Bear and no watch was pending, it's unrelated — ignore.
    return false
  end

  -- Inside a pending Paste watch, Enter commits and Esc cancels.
  if pasteWatchStartedAt then
    if keyCode == RETURN_CODE then
      report("intent", "intent: Enter in paste-watch → paste-app commit stamped", { signal = "pasteEnter" })
      recentPasteAppAt = now
      pasteWatchStartedAt = nil
    elseif keyCode == ESC_CODE then
      report("intent", "intent: Esc in paste-watch → cancelled", { signal = "pasteEsc", action = "cancel" })
      pasteWatchStartedAt = nil
    end
  end
  return false
end

-- Tear down Bear-specific hooks (observer + intent tap). The app watcher
-- stays alive so we can re-hook if Bear relaunches.
local function teardownHooks()
  if observer then
    pcall(function() observer:stop() end)
    observer = nil
  end
  if intentTap then
    pcall(function() intentTap:stop() end)
    intentTap = nil
  end
  boundPid = nil
  lastTa = nil
  lastCount = nil
  recentCmdVAt = nil
  recentPasteAppAt = nil
  pasteWatchStartedAt = nil
  inserting = false
end

-- Bind AX observer + intent eventtap to a running Bear instance. Called
-- from M.init() (if Bear is already running) and from the app watcher on
-- Bear launch. AX observers are bound to a PID at creation — if Bear
-- restarts, the old observer silently stops firing, so we must rebind.
local function setupHooks(bear)
  teardownHooks()

  boundPid = bear:pid()
  observer = hs.axuielement.observer.new(boundPid)
  observer:callback(onObserverFire)
  local appEl = hs.axuielement.applicationElement(bear)
  local ok = pcall(function()
    observer:addWatcher(appEl, "AXSelectedTextChanged")
  end)
  if not ok then
    logger.w(string.format("failed to addWatcher on Bear app element (pid=%d)", boundPid))
    persistEvent("bind-fail", { pid = boundPid })
    observer = nil
    boundPid = nil
    return
  end
  observer:start()

  intentTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKeyDown)
  intentTap:start()

  report("bound",
    string.format("hooks bound: Bear pid=%d, observer running=%s, intent tap enabled=%s",
      boundPid, tostring(observerRunning()), tostring(intentTap:isEnabled())),
    { pid = boundPid, observerRunning = observerRunning(), tapEnabled = intentTap:isEnabled() })
end

-- =============================================================================
-- Event-driven reconciler (replaces the old 60s polling watchdog)
-- =============================================================================
-- Reconcile the live hooks against desired state for the current Bear. Idempotent
-- and cheap on the happy path (PID matches, observer running, tap enabled → no-op,
-- logs nothing). Invoked ONLY from event sources, never a timer:
--
--   * app-watcher `activated` (Bear came to front)  — fires right before any
--     paste, since you must focus Bear to paste into it. Independent of the
--     CGEventTap, so it's the lifeline that can resurrect a DEAD intent tap.
--   * onKeyDown heartbeat (a keystroke in Bear)      — independent of the
--     app-watcher, so it heals a stale OBSERVER even if app events stop arriving.
--
-- The two sources cover each other's blind spot. NOTE on Hammerspoon internals:
-- a tap disabled by timeout/secure-input is auto-re-enabled by HS itself (its C
-- callback calls CGEventTapEnable on kCGEventTapDisabledBy* and never surfaces it
-- to Lua — which is why there's no such constant in hs.eventtap.event.types). So
-- the tap path here only has to handle the residue HS's auto-re-enable leaves
-- behind (e.g. a tap left disabled after a secure-input lock finally clears).
-- The one mode NEITHER source can catch is a "silent wedge" — tap reports
-- :isEnabled()==true but events stop flowing — because that emits no event at all.
ensureHealthy = function(reason)
  local bear = hs.application.get("Bear")
  if not bear then
    if observer or intentTap then
      report("reconcile",
        string.format("reconcile(%s): Bear gone → teardown", reason),
        { action = "teardown", reason = reason })
      teardownHooks()
    end
    return
  end

  local pid = bear:pid()

  -- Observer stale (bound to an old PID) or stopped → full rebind. setupHooks
  -- also recreates the intent tap, so this covers both halves at once.
  if boundPid ~= pid or not observerRunning() then
    report("reconcile",
      string.format("reconcile(%s): observer stale/stopped (bound=%s, live=%d) → rebind",
        reason, tostring(boundPid), pid),
      { action = "rebind", reason = reason, boundPid = boundPid, livePid = pid })
    setupHooks(bear)
    return
  end

  -- Observer is fine; check the tap on its own. A tap that reports disabled gets
  -- recreated (not merely :start()ed — a wedged tap can lie about being enabled,
  -- so a fresh object is the safe move).
  if intentTap and not intentTap:isEnabled() then
    report("reconcile",
      string.format("reconcile(%s): intent tap disabled → recreate", reason),
      { action = "recreate-tap", reason = reason })
    pcall(function() intentTap:stop() end)
    intentTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKeyDown)
    intentTap:start()
    return
  end

  -- Fell through → everything already healthy. Debug-only so the (frequent,
  -- event-driven) happy-path checks are visible when tracing but silent normally.
  logger.d(string.format("reconcile(%s): healthy, no-op (pid=%d)", reason, pid))
end

function M.init()
  M.stop()
  openLogFile()  -- (re)open the durable log first, so the binding events below persist

  appWatcher = hs.application.watcher.new(function(_appName, eventType, app)
    if not app or app:bundleID() ~= BEAR_BUNDLE then return end
    if eventType == hs.application.watcher.launched then
      report("watcher", "Bear launched, rebinding hooks", { event = "launched" })
      setupHooks(app)
    elseif eventType == hs.application.watcher.terminated then
      report("watcher", "Bear terminated, releasing hooks", { event = "terminated" })
      teardownHooks()
    elseif eventType == hs.application.watcher.activated then
      -- Bear came to front — the moment right before any paste. Reconcile so a
      -- stale observer or a disabled tap is healed before the user pastes. This
      -- is the event-driven replacement for the old 60s polling watchdog, and
      -- the only source that can revive a fully-dead intent tap.
      ensureHealthy("bear-activated")
    end
  end)
  appWatcher:start()

  local bear = hs.application.get("Bear")
  if bear then
    setupHooks(bear)
  else
    logger.w("Bear not running; will hook on launch")
    persistEvent("watcher", { event = "init-no-bear" })
  end
end

function M.stop()
  teardownHooks()
  if appWatcher then
    pcall(function() appWatcher:stop() end)
    appWatcher = nil
  end
  closeLogFile()
end

-- On-demand health snapshot. Query from the CLI:
--   hs -c 'return hs.inspect(bear_paste.health())'
-- Distinguishes the failure classes: `stale` true → observer bound to a dead PID;
-- `tapEnabled` false → intent eventtap died (⌘V never stamped); `lastFireAgo` huge
-- while Bear is in use → observer not delivering. `reconcile()` runs the same
-- event-driven repair the watchers trigger — useful to force a check by hand.
function M.health()
  local bear = hs.application.get("Bear")
  local bearPid = bear and bear:pid() or nil
  local now = hs.timer.secondsSinceEpoch()
  local h = {
    bound          = observer ~= nil,
    boundPid       = boundPid,
    bearPid        = bearPid,
    stale          = (boundPid ~= nil and bearPid ~= nil and boundPid ~= bearPid),
    observerRunning = observerRunning(),
    tapEnabled     = intentTap ~= nil and intentTap:isEnabled() or false,
    appWatcher     = appWatcher ~= nil,
    lastFireAgo    = lastFireAt and (now - lastFireAt) or nil,
    lastCount      = lastCount,
    recentCmdVAgo  = recentCmdVAt and (now - recentCmdVAt) or nil,
    pasteWatchOpen = pasteWatchStartedAt ~= nil,
    logOpen        = logFile ~= nil,
    logPath        = LOG_PATH,
  }
  logger.i("health: " .. (hs.inspect(h):gsub("%s+", " ")))
  return h
end

-- Manually trigger the event-driven reconciler (same path the watchers use).
-- hs -c 'return bear_paste.reconcile()'
function M.reconcile()
  if ensureHealthy then ensureHealthy("manual") end
  return M.health()
end

-- Crank logging to "debug" for the full per-keystroke firehose; back to "info"
-- for normal low-noise operation. hs -c 'return bear_paste.setLogLevel("debug")'
function M.setLogLevel(lvl)
  logger.setLogLevel(lvl)
  return "bear-paste log level set to: " .. tostring(lvl)
end

return M
