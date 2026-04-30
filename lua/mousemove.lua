-- =============================================================================
-- Mouse move/resize window under cursor
-- =============================================================================
-- fn + move        → move window
-- fn + shift + move → resize window (nearest corner/edge algorithm)
--
-- Useful for apps like Kitty and Bear where Better Touch Tool doesn't work.
-- Uses global _G.windowMove table to prevent garbage collection of eventtaps
-- and includes zombie detection (eventtaps that report enabled but don't fire)

local M = {}

-- Border canvas functions (injected via init)
local createBorderCanvas = nil
local updateBorderCanvas = nil
local deleteBorderCanvas = nil

-- Persistent move border highlight
local moveBorder = nil

local function showMoveBorder(frame, win)
    if not moveBorder then
        moveBorder = createBorderCanvas(frame, nil, win)
    else
        updateBorderCanvas(moveBorder, frame)
    end
end

local function hideMoveBorder()
    if moveBorder then
        deleteBorderCanvas(moveBorder)
        moveBorder = nil
    end
end

-- Global state to prevent garbage collection
_G.windowMove = _G.windowMove or {}
_G.windowMove.moveState = {
    mode = "idle",        -- "idle", "move", "resize"
    startedAs = "none",   -- "fnOnly" or "fnShift" — which combo initiated the move
    resizeDirX = "none",  -- "left", "right", or "none"
    resizeDirY = "none",  -- "top", "bottom", or "none"
    window = nil,
    windowStartX = 0,
    windowStartY = 0,
    mouseStartX = 0,
    mouseStartY = 0,
    pendingDX = 0,        -- accumulated resize deltas for throttling
    pendingDY = 0,
    frame = nil           -- cached frame during resize (avoids stale reads)
}
_G.windowMove.mouseMoveHandler = nil
_G.windowMove.flagsHandler = nil
_G.windowMove.watchdog = nil
_G.windowMove.lastCallbackTime = hs.timer.secondsSinceEpoch()

local function getWindowUnderMouse()
    local mousePos = hs.mouse.absolutePosition()
    local windows = hs.window.orderedWindows()

    for _, win in ipairs(windows) do
        if win:isStandard() then
            local frame = win:frame()
            if mousePos.x >= frame.x and mousePos.x <= frame.x + frame.w and
               mousePos.y >= frame.y and mousePos.y <= frame.y + frame.h then
                return win
            end
        end
    end
    return nil
end

-- Divide window into 3x3 grid and return which corner/edge to resize from
local function computeResizeSection(win, mousePos)
    local frame = win:frame()
    local relX = mousePos.x - frame.x
    local relY = mousePos.y - frame.y
    local dirX = relX < frame.w / 3 and "left" or relX > 2 * frame.w / 3 and "right" or "none"
    local dirY = relY < frame.h / 3 and "top" or relY > 2 * frame.h / 3 and "bottom" or "none"
    return dirX, dirY
end

local RESIZE_INTERVAL = 0.033  -- ~30fps resize timer

local function stopResizeTimer()
    if _G.windowMove.resizeTimer then
        _G.windowMove.resizeTimer:stop()
        _G.windowMove.resizeTimer = nil
    end
end

local function startResizeTimer()
    stopResizeTimer()
    _G.windowMove.resizeTimer = hs.timer.doEvery(RESIZE_INTERVAL, function()
        local moveState = _G.windowMove.moveState
        if moveState.mode ~= "resize" or not moveState.window then
            stopResizeTimer()
            return
        end
        local tdx = moveState.pendingDX
        local tdy = moveState.pendingDY
        if tdx == 0 and tdy == 0 then return end
        moveState.pendingDX = 0
        moveState.pendingDY = 0

        local f = moveState.frame

        if moveState.resizeDirX == "left" then
            f.x = f.x + tdx
            f.w = f.w - tdx
        elseif moveState.resizeDirX == "right" then
            f.w = f.w + tdx
        end

        if moveState.resizeDirY == "top" then
            f.y = f.y + tdy
            f.h = f.h - tdy
        elseif moveState.resizeDirY == "bottom" then
            f.h = f.h + tdy
        end

        local prev = hs.window.animationDuration
        hs.window.animationDuration = 0
        moveState.window:setFrame(f)
        hs.window.animationDuration = prev
        showMoveBorder(f)
    end)
end

local function clearMoveState(moveState)
    moveState.mode = "idle"
    moveState.startedAs = "none"
    moveState.resizeDirX = "none"
    moveState.resizeDirY = "none"
    moveState.window = nil
    moveState.pendingDX = 0
    moveState.pendingDY = 0
    moveState.frame = nil
    stopResizeTimer()
    hideMoveBorder()
end

local function createMouseMoveHandler()
    return hs.eventtap.new({hs.eventtap.event.types.mouseMoved}, function(event)
        -- Track callback time for zombie detection
        _G.windowMove.lastCallbackTime = hs.timer.secondsSinceEpoch()

        local flags = event:getFlags()
        local fnOnly = flags.fn and not (flags.shift or flags.cmd or flags.alt or flags.ctrl)
        local fnShift = flags.fn and flags.shift and not (flags.cmd or flags.alt or flags.ctrl)
        local moveState = _G.windowMove.moveState

        -- Modifier changed from what started the current operation → end it
        if moveState.mode ~= "idle" then
            local mismatch = (moveState.startedAs == "fnOnly" and not fnOnly)
                          or (moveState.startedAs == "fnShift" and not fnShift)
            if mismatch then
                clearMoveState(moveState)
            end
        end

        if moveState.mode == "idle" then
            if fnShift or fnOnly then
                -- Start a new operation
                local win = getWindowUnderMouse()
                if win then
                    local mousePos = hs.mouse.absolutePosition()
                    if fnShift then
                        local dirX, dirY = computeResizeSection(win, mousePos)
                        if dirX == "none" and dirY == "none" then
                            -- Center of window: move instead
                            moveState.mode = "move"
                        else
                            moveState.mode = "resize"
                            moveState.resizeDirX = dirX
                            moveState.resizeDirY = dirY
                            moveState.frame = win:frame()
                            startResizeTimer()
                        end
                        moveState.startedAs = "fnShift"
                    else
                        moveState.mode = "move"
                        moveState.startedAs = "fnOnly"
                    end
                    moveState.window = win
                    win:raise()
                    showMoveBorder(win:frame(), win)
                    local frame = win:frame()
                    moveState.windowStartX = frame.x
                    moveState.windowStartY = frame.y
                    moveState.mouseStartX = mousePos.x
                    moveState.mouseStartY = mousePos.y
                end
            end
        elseif moveState.mode == "move" then
            if moveState.window and moveState.window:isVisible() then
                local dx = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaX)
                local dy = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaY)
                local frame = moveState.window:frame()
                moveState.window:setTopLeft({x = frame.x + dx, y = frame.y + dy})
                showMoveBorder(moveState.window:frame())
            end
        elseif moveState.mode == "resize" then
            -- Just accumulate deltas; the resize timer applies them
            local dx = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaX)
            local dy = event:getProperty(hs.eventtap.event.properties.mouseEventDeltaY)
            moveState.pendingDX = moveState.pendingDX + dx
            moveState.pendingDY = moveState.pendingDY + dy
        end

        return false  -- Don't consume the event
    end)
end

local function createFlagsHandler()
    return hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
        -- Track callback time for zombie detection
        _G.windowMove.lastCallbackTime = hs.timer.secondsSinceEpoch()

        local flags = event:getFlags()
        local fnOnly = flags.fn and not (flags.shift or flags.cmd or flags.alt or flags.ctrl)
        local fnShift = flags.fn and flags.shift and not (flags.cmd or flags.alt or flags.ctrl)
        local moveState = _G.windowMove.moveState

        if moveState.mode ~= "idle" then
            local mismatch = (moveState.startedAs == "fnOnly" and not fnOnly)
                          or (moveState.startedAs == "fnShift" and not fnShift)
            if mismatch then
                clearMoveState(moveState)
            end
        end

        return false
    end)
end

local function startEventTaps()
    -- Stop existing handlers if any
    if _G.windowMove.mouseMoveHandler then
        _G.windowMove.mouseMoveHandler:stop()
    end
    if _G.windowMove.flagsHandler then
        _G.windowMove.flagsHandler:stop()
    end

    -- Create and start new handlers
    _G.windowMove.mouseMoveHandler = createMouseMoveHandler()
    _G.windowMove.flagsHandler = createFlagsHandler()

    _G.windowMove.mouseMoveHandler:start()
    _G.windowMove.flagsHandler:start()

    -- Reset callback time
    _G.windowMove.lastCallbackTime = hs.timer.secondsSinceEpoch()
end

-- Initialize and start the mouse move functionality
function M.init(opts)
    opts = opts or {}
    createBorderCanvas = opts.createBorderCanvas
    updateBorderCanvas = opts.updateBorderCanvas
    deleteBorderCanvas = opts.deleteBorderCanvas

    -- Start the eventtaps
    startEventTaps()

    -- Stop existing watchdog if reloading
    if _G.windowMove.watchdog then
        _G.windowMove.watchdog:stop()
    end

    -- Enhanced watchdog: detect both disabled eventtaps AND zombie state
    _G.windowMove.watchdog = hs.timer.new(3, function()
        local handler = _G.windowMove.mouseMoveHandler
        if not handler then
            startEventTaps()
            return
        end

        local enabled = handler:isEnabled()
        local timeSinceCallback = hs.timer.secondsSinceEpoch() - _G.windowMove.lastCallbackTime

        -- Restart if:
        -- 1. Handler reports disabled, OR
        -- 2. No callbacks for 10+ seconds while mouse is visible (zombie state)
        --    (mouse not visible = screensaver/lock, so no events expected)
        if not enabled or (timeSinceCallback > 10 and hs.mouse.absolutePosition()) then
            startEventTaps()
        end
    end)
    _G.windowMove.watchdog:start()
end

return M
