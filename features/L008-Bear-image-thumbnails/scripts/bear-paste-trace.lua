-- Bear paste tracer — log-only observer for L008 false-trigger diagnosis.
--
-- Purpose: answer "when does the ￼ count go up by 1 WITHOUT a paste?" The
-- production module (bear-paste.lua) uses a +1 ￼-delta as its trigger and is
-- misfiring on Enter and on `> ` prepend. We need raw data on every single
-- AXSelectedTextChanged fire so we can find the off-by-one pattern.
--
-- Design: mirrors bear-paste.lua's observer setup 1:1 but writes ZERO and
-- logs every fire to both the HS console and an NDJSON file. Each line
-- records enough state to reconstruct what happened:
--   t          — monotonic seconds since start() (ms-precision float)
--   i          — event index (1-based)
--   role       — AXRole of the fired element
--   len        — AXValue byte length (#value)
--   ffc        — ￼ count (U+FFFC)
--   dLen       — delta vs previous fire on same element
--   dFfc       — delta vs previous fire on same element
--   caret      — AXSelectedTextRange.location
--   selLen     — AXSelectedTextRange.length
--   clipImg    — true iff hs.pasteboard.readImage() ~= nil
--   clipCnt    — hs.pasteboard.changeCount()
--   taSwitched — true iff fired on a different textarea than last fire
--
-- Usage (in Hammerspoon console):
--   trace = dofile("/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/scripts/bear-paste-trace.lua")
--   trace.start()
--   -- Do your actions in Bear (paste, Enter, type ">", etc.). Narrate them
--   -- out loud to yourself — we'll correlate with the timestamps.
--   trace.stop()
--   -- Log file path is printed on start/stop. Grep or cat it.
--
-- The tracer writes NDJSON to:
--   features/L008-Bear-image-thumbnails/data/trace-{timestamp}.ndjson
-- so each session is a fresh file.

local M = {}

local UTF8_OBJ_REPL = "\239\191\188" -- U+FFFC

local DATA_DIR = "/Users/sara/Library/CloudStorage/Dropbox/projects/log/2025/hammerspoon/stepper/features/L008-Bear-image-thumbnails/data"

local observer = nil
local logFile = nil
local logPath = nil
local startEpoch = nil
local eventIdx = 0
local lastTa = nil
local lastLen = nil
local lastFfc = nil
local logger = hs.logger.new("bear-paste-trace", "info")

local function countObjRepl(s)
    local n = 0
    for _ in s:gmatch(UTF8_OBJ_REPL) do n = n + 1 end
    return n
end

-- Minimal JSON serializer — only handles what we emit. Avoids pulling in a
-- full JSON dep for this diagnostic.
local function jsonEscape(s)
    if s == nil then return "null" end
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function jsonVal(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then return tostring(v)
    else return jsonEscape(v) end
end

local function jsonObj(o)
    -- Stable-ordered keys for grep-friendliness.
    local order = { "t", "i", "role", "len", "ffc", "dLen", "dFfc",
                    "caret", "selLen", "clipImg", "clipCnt", "taSwitched", "note" }
    local parts = {}
    for _, k in ipairs(order) do
        if o[k] ~= nil then
            parts[#parts + 1] = jsonEscape(k) .. ":" .. jsonVal(o[k])
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function writeLine(rec)
    local line = jsonObj(rec)
    if logFile then
        logFile:write(line .. "\n")
        logFile:flush()
    end
    -- Mirror to console at info level — short form.
    logger.i(string.format("i=%d len=%s ffc=%s dLen=%s dFfc=%s clipImg=%s clipCnt=%s%s",
        rec.i, tostring(rec.len), tostring(rec.ffc),
        tostring(rec.dLen), tostring(rec.dFfc),
        tostring(rec.clipImg), tostring(rec.clipCnt),
        rec.taSwitched and " [TA-SWITCHED]" or ""))
end

local function onFire(_obs, el, _notif)
    if not el then return end
    eventIdx = eventIdx + 1

    local t = hs.timer.secondsSinceEpoch() - startEpoch
    local role = "?"
    pcall(function() role = el:attributeValue("AXRole") or "?" end)

    local value = ""
    pcall(function() value = el:attributeValue("AXValue") or "" end)
    local len = #value
    local ffc = countObjRepl(value)

    local range = nil
    pcall(function() range = el:attributeValue("AXSelectedTextRange") end)

    local switched = (el ~= lastTa)
    local dLen = (lastLen and not switched) and (len - lastLen) or nil
    local dFfc = (lastFfc and not switched) and (ffc - lastFfc) or nil

    local rec = {
        t = tonumber(string.format("%.3f", t)),
        i = eventIdx,
        role = role,
        len = len,
        ffc = ffc,
        dLen = dLen,
        dFfc = dFfc,
        caret = range and range.location or nil,
        selLen = range and range.length or nil,
        clipImg = hs.pasteboard.readImage() ~= nil,
        clipCnt = hs.pasteboard.changeCount(),
        taSwitched = switched or nil,
    }
    writeLine(rec)

    lastTa = el
    if role == "AXTextArea" then
        lastLen = len
        lastFfc = ffc
    end
end

function M.start()
    M.stop()
    local bear = hs.application.get("Bear")
    if not bear then
        print("[trace] Bear not running; open it first")
        return
    end

    -- Fresh log file per session.
    local stamp = os.date("%Y%m%d-%H%M%S")
    logPath = DATA_DIR .. "/trace-" .. stamp .. ".ndjson"
    local f, err = io.open(logPath, "w")
    if not f then
        print("[trace] could not open log file: " .. tostring(err))
        return
    end
    logFile = f
    logFile:write(string.format(
        '{"t":0,"i":0,"note":"session start @ %s"}\n', stamp))
    logFile:flush()

    startEpoch = hs.timer.secondsSinceEpoch()
    eventIdx = 0
    lastTa = nil
    lastLen = nil
    lastFfc = nil

    observer = hs.axuielement.observer.new(bear:pid())
    observer:callback(onFire)
    local appEl = hs.axuielement.applicationElement(bear)
    local ok, werr = pcall(function()
        observer:addWatcher(appEl, "AXSelectedTextChanged")
    end)
    if not ok then
        print("[trace] addWatcher failed: " .. tostring(werr))
        observer = nil
        logFile:close()
        logFile = nil
        return
    end
    observer:start()
    print("[trace] started — log: " .. logPath)
    print("[trace] now do actions in Bear; call trace.stop() when done.")
end

function M.stop()
    if observer then
        pcall(function() observer:stop() end)
        observer = nil
    end
    if logFile then
        logFile:write(string.format('{"note":"session stop after %d fires"}\n', eventIdx))
        logFile:close()
        logFile = nil
        if logPath then
            print("[trace] stopped — log: " .. logPath)
            print(string.format("[trace] %d fires recorded", eventIdx))
        end
    end
    lastTa = nil
    lastLen = nil
    lastFfc = nil
end

function M.logPath()
    return logPath
end

-- Insert a labeled marker line into the log. Use to delimit scenarios so the
-- analysis step can bucket fires by what the user was doing at the time.
function M.mark(label)
    if not logFile then
        print("[trace] not started — call trace.start() first")
        return
    end
    local t = hs.timer.secondsSinceEpoch() - startEpoch
    logFile:write(string.format(
        '{"t":%.3f,"note":"MARK %s"}\n', t, tostring(label):gsub('"', '\\"')))
    logFile:flush()
    logger.i("MARK " .. tostring(label))
end

return M
