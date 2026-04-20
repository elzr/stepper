-- Driver: reproduce the L008 false-trigger scenarios in a KNOWN-correct Bear note.
--
-- Learned-the-hard-way safety rules after driver v1 pasted into "apr2026 CDMX trip":
--   1. Never inject keystrokes based on a URL call alone — the URL scheme
--      doesn't always switch the focused note. Verify via AX.
--   2. Before firing any scenario, confirm the focused Bear window's title
--      matches the target. If it doesn't, ABORT the run.
--   3. Target keystrokes via event:post(bearApp) so they can't leak into
--      another frontmost app even if focus shifts mid-run.
--   4. Keep timer handles so we can cancel the run cleanly without a full
--      Hammerspoon reload.
--
-- Prereqs:
--   * _G.trace from bear-paste-trace.lua is running (or M.run continues anyway
--     — trace is optional; scenarios still execute, marks are just skipped).
--   * Bear is open, the "test of Bear images" note exists in Bear.
--   * An image is on the clipboard.
--
-- Usage:
--   hs -c 'dofile(".../drive-trace-run.lua").run()'
--
-- Cancel mid-run:
--   hs -c 'dofile(".../drive-trace-run.lua").cancel()'

local M = {}

local TARGET_TITLE = "test of Bear images"
local pendingTimers = {}
_G.__driverAborted = false

local function mark(label)
    if _G.trace and _G.trace.mark then _G.trace.mark(label) end
end

-- Push a scheduled timer into the cancellable list.
local function schedule(delay, fn)
    local t
    t = hs.timer.doAfter(delay, function()
        if _G.__driverAborted then return end
        fn()
    end)
    pendingTimers[#pendingTimers + 1] = t
    return t
end

function M.cancel()
    _G.__driverAborted = true
    for _, t in ipairs(pendingTimers) do pcall(function() t:stop() end) end
    pendingTimers = {}
    if _G.trace and _G.trace.mark then _G.trace.mark("ABORTED") end
    return "driver aborted; " .. #pendingTimers .. " timers stopped"
end

-- -----------------------------------------------------------------------
-- Bear window targeting
-- -----------------------------------------------------------------------

local function findBearWindowByTitle(title)
    local bear = hs.application.get("Bear")
    if not bear then return nil, nil end
    for _, win in ipairs(bear:allWindows()) do
        if win:title() == title then return win, bear end
    end
    return nil, bear
end

local function openNoteInBear(title)
    -- Matches bear-hud.lua's pattern: edit=yes + new_window=yes ensures Bear
    -- opens a dedicated editing window rather than searching.
    local url = "bear://x-callback-url/open-note?title=" .. title:gsub(" ", "%%20")
        .. "&edit=yes&new_window=yes"
    hs.urlevent.openURL(url)
end

-- Verify both (a) hs.window.focused is the target Bear window AND
-- (b) AX-focused window title matches. Returns bearApp, targetWin on success;
-- nil, reason on failure.
local function verifyFocus()
    local bear = hs.application.get("Bear")
    if not bear then return nil, "Bear not running" end
    local focusedWin = bear:focusedWindow()
    if not focusedWin then return nil, "no focused Bear window" end
    local focusedTitle = focusedWin:title()
    if focusedTitle ~= TARGET_TITLE then
        return nil, string.format("focused Bear window is '%s', not '%s'",
            tostring(focusedTitle), TARGET_TITLE)
    end
    -- Cross-check via AX
    local appEl = hs.axuielement.applicationElement(bear)
    if appEl then
        local axFocusedWin = appEl:attributeValue("AXFocusedWindow")
        local axTitle = axFocusedWin and axFocusedWin:attributeValue("AXTitle")
        if axTitle ~= TARGET_TITLE then
            return nil, string.format("AX focused window is '%s', not '%s'",
                tostring(axTitle), TARGET_TITLE)
        end
    end
    return bear, focusedWin
end

-- Post a keystroke directly to the Bear app (not globally). This prevents
-- the keys from going to Terminal/etc. even if focus shifts.
local function postToBear(bear, key, mods)
    if not bear then return end
    local flagTable = {}
    for _, m in ipairs(mods or {}) do flagTable[m] = true end
    local down = hs.eventtap.event.newKeyEvent(key, true)
    down:setFlags(flagTable)
    local up = hs.eventtap.event.newKeyEvent(key, false)
    up:setFlags(flagTable)
    down:post(bear)
    up:post(bear)
end

-- Type a string targeted at Bear. hs.eventtap.keyStrokes(text, app) handles
-- space, shifted chars, unicode, etc. — iterating newKeyEvent by character
-- silently drops anything without a simple keycode.
local function typeToBear(bear, str)
    hs.eventtap.keyStrokes(str, bear)
end

-- Refresh the clipboard with a fresh screenshot. Used between paste scenarios
-- so that subsequent "real paste" scenarios have an advanced changeCount (the
-- bear-paste module's gate requires it). Blocking; returns after completion.
local function refreshClipboardWithScreenshot()
    hs.execute("/usr/sbin/screencapture -c -x -R 100,100,300,200", false)
end

-- Wrap an action: verify focus, abort the whole run on mismatch.
local function guarded(label, actionFn)
    return function()
        local bear, err = verifyFocus()
        if not bear then
            mark("ABORT: " .. label .. " — " .. tostring(err))
            print("[driver] ABORT at '" .. label .. "': " .. tostring(err))
            M.cancel()
            return
        end
        mark(label)
        actionFn(bear)
    end
end

-- -----------------------------------------------------------------------
-- Scenario list
-- -----------------------------------------------------------------------

local scenarios = {
    { delay = 0.6, label = "setup: move caret to end-of-note", action = function(bear)
        postToBear(bear, "down", { "cmd" })
    end },
    { delay = 0.4, label = "setup: blank line + plain separator + blank line", action = function(bear)
        -- Avoid `---` / `> ` / `- ` here: those are auto-format triggers that
        -- produce ￼ glyphs in AXValue and would prematurely fire the module.
        postToBear(bear, "return")
        postToBear(bear, "return")
        typeToBear(bear, "trace " .. os.date("%H.%M.%S"))
        postToBear(bear, "return")
        postToBear(bear, "return")
    end },
    -- ---------- baseline: clean paste ----------
    { delay = 0.6, label = "A: CLEAN paste (baseline — expect ffc +1)", action = function(bear)
        postToBear(bear, "v", { "cmd" })
    end },
    -- ---------- control: Enter x3 after plain image line ----------
    { delay = 1.5, label = "B: Enter x3 after plain image line", action = function(bear)
        postToBear(bear, "return")
        postToBear(bear, "return")
        postToBear(bear, "return")
    end },
    -- ---------- control: plain text typing ----------
    { delay = 1.0, label = "B2: type plain 'hello world'", action = function(bear)
        typeToBear(bear, "hello world")
    end },
    -- ---------- REPRO 1: image in blockquote, then Enter ----------
    { delay = 1.0, label = "C-setup: new line, type '> '", action = function(bear)
        postToBear(bear, "return")
        typeToBear(bear, "> ")
    end },
    { delay = 0.3, label = "C-refresh: new screenshot (advances clipCount)", action = function(bear)
        refreshClipboardWithScreenshot()
    end },
    { delay = 0.8, label = "C: paste image into blockquote line", action = function(bear)
        postToBear(bear, "v", { "cmd" })
    end },
    { delay = 1.5, label = "C-REPRO1: Enter at end of blockquote-image line", action = function(bear)
        postToBear(bear, "return")
    end },
    { delay = 1.5, label = "C-REPRO1b: Enter again on new (possibly `>`-prefixed) line", action = function(bear)
        postToBear(bear, "return")
    end },
    { delay = 1.5, label = "C-REPRO1c: Enter third time", action = function(bear)
        postToBear(bear, "return")
    end },
    -- ---------- REPRO 2: paste image, cmd+left, prepend '> ' ----------
    { delay = 0.6, label = "D-refresh: new screenshot (advances clipCount)", action = function(bear)
        refreshClipboardWithScreenshot()
    end },
    { delay = 0.4, label = "D-setup: new blank line, paste fresh image", action = function(bear)
        postToBear(bear, "return")
        postToBear(bear, "v", { "cmd" })
    end },
    { delay = 1.5, label = "D-REPRO2: cmd+left then type '> '", action = function(bear)
        postToBear(bear, "left", { "cmd" })
        typeToBear(bear, "> ")
    end },
    -- ---------- control: '> ' on plain (non-image) line ----------
    { delay = 1.0, label = "E: new line, '> plain text'", action = function(bear)
        postToBear(bear, "down", { "cmd" })
        postToBear(bear, "return")
        typeToBear(bear, "> plain text")
    end },
    { delay = 1.0, label = "RUN_END", action = function(bear)
        if _G.trace and _G.trace.stop then _G.trace.stop() end
    end },
}

-- -----------------------------------------------------------------------
-- Runner
-- -----------------------------------------------------------------------

function M.run()
    _G.__driverAborted = false
    pendingTimers = {}

    -- Gate 1: Bear must be running.
    local win, bear = findBearWindowByTitle(TARGET_TITLE)
    if not bear then
        return "ERR: Bear not running"
    end

    mark("RUN_BEGIN")

    local function beginScenarios()
        -- Final gate check before any keystrokes fire.
        local okBear, err = verifyFocus()
        if not okBear then
            mark("ABORT at beginScenarios: " .. tostring(err))
            print("[driver] ABORT: " .. tostring(err))
            M.cancel()
            return
        end
        mark("focus verified — starting scenarios")

        local t = 0
        for _, s in ipairs(scenarios) do
            t = t + s.delay
            schedule(t, guarded(s.label, s.action))
        end
    end

    if win then
        -- Window already exists — activate Bear, focus that window, proceed.
        -- Two-step focus dance: activate, then focus, wait, then re-focus
        -- just before the verify. Between Bear windows, a single win:focus()
        -- doesn't reliably switch which note is frontmost.
        bear:activate()
        win:focus()
        schedule(0.4, function()
            local w = findBearWindowByTitle(TARGET_TITLE)
            if w then w:focus() end
            schedule(0.3, beginScenarios)
        end)
        return "test note already open; starting in ~0.7s"
    end

    -- Window not open yet — open via URL, poll for it.
    mark("opening test note via bear:// URL")
    openNoteInBear(TARGET_TITLE)
    local attempts = 0
    local function poll()
        if _G.__driverAborted then return end
        attempts = attempts + 1
        local w = findBearWindowByTitle(TARGET_TITLE)
        if w then
            w:focus()
            schedule(0.4, beginScenarios)
        elseif attempts < 30 then
            schedule(0.15, poll)
        else
            mark("ABORT: timed out waiting for test note window")
            print("[driver] timed out waiting for '" .. TARGET_TITLE .. "'")
            M.cancel()
        end
    end
    schedule(0.3, poll)
    return "test note not open; opening, polling up to ~4.5s"
end

return M
