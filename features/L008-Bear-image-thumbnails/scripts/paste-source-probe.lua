-- Paste source probe — does Paste app synthesize a real cmd+V keystroke?
--
-- Installs a non-intercepting hs.eventtap on keyDown. For each cmd+V event,
-- logs: timestamp, frontmost app, source PID (from the event), and the event's
-- "synthesized" property if readable. Stays running until paste_source.stop()
-- is called.
--
-- If Paste app synthesizes ⌘V when you hit Enter on a clip, the tap sees it
-- and logs it with a source PID (Paste app's PID or 0). If not, nothing logs
-- during a Paste-app paste.
--
-- Usage (in Hammerspoon console):
--   probe = dofile("/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/paste-source-probe.lua")
--   probe.start()
--   -- Test 1: focus Bear, press ⌘V manually. Should log.
--   -- Test 2: focus Bear, open Paste (⌘⇧Space), select item, press Enter. Does it log?
--   -- Test 3: drag-and-drop an image from Finder. (No log expected; confirms sanity.)
--   probe.stop()
--   probe.summary()

local M = {}

local tap = nil
local events = {}
local logger = hs.logger.new("paste-probe", "info")

local function getKeycode(event)
    local ok, k = pcall(function()
        return event:getKeyCode()
    end)
    return ok and k or nil
end

local function vKeycode()
    return hs.keycodes.map["v"]
end

function M.start()
    M.stop()
    events = {}
    local V_CODE = vKeycode()
    tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
        local flags = event:getFlags()
        if not flags.cmd then return false end
        if getKeycode(event) ~= V_CODE then return false end

        local frontApp = hs.application.frontmostApplication()
        local frontName = frontApp and frontApp:name() or "<none>"
        local frontBundle = frontApp and frontApp:bundleID() or "<none>"

        -- Event source properties. Real key presses from the keyboard typically
        -- have sourcePID = 0 (HID). Synthetic events often have the poster's PID.
        local srcPid = event:getProperty(hs.eventtap.event.properties.eventSourceUnixProcessID)
        local srcStateID = event:getProperty(hs.eventtap.event.properties.eventSourceStateID)
        local srcUserData = event:getProperty(hs.eventtap.event.properties.eventSourceUserData)

        local rec = {
            t = hs.timer.secondsSinceEpoch(),
            frontApp = frontName,
            frontBundle = frontBundle,
            srcPid = srcPid,
            srcStateID = srcStateID,
            srcUserData = srcUserData,
            flags = flags,
        }
        events[#events + 1] = rec
        logger.i(string.format(
            "⌘V → front=%s (%s) srcPid=%s srcStateID=%s",
            frontName, frontBundle, tostring(srcPid), tostring(srcStateID)))
        return false -- non-intercepting
    end)
    tap:start()
    logger.i("started — keyDown tap on cmd+V")
    return "probe running; call probe.stop() or probe.summary() any time"
end

function M.stop()
    if tap then
        pcall(function() tap:stop() end)
        tap = nil
        logger.i("stopped")
    end
end

function M.summary()
    print("---- paste-source-probe summary ----")
    print(string.format("events recorded: %d", #events))
    for i, e in ipairs(events) do
        print(string.format(
            "%2d. t=%.3f front=%-20s srcPid=%s srcStateID=%s",
            i, e.t, e.frontApp, tostring(e.srcPid), tostring(e.srcStateID)))
    end
    print("-------- end --------")
    return events
end

function M.events() return events end

return M
