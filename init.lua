local class = require("middleclass")


-- BetterDisplay ================================================================

local DisplayFixer = class("DisplayFixer")

function DisplayFixer:initialize()
    self.binary = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    self.args = {
        "set",
        "-name=XZ340CUR W0",
        "-connectionMode=bpc:10+range:full+encoding:rgb",
        "-refreshRate=165Hz",
    }

    self.maxAttempts = 10
    self.retryDelay = 0.5
    self.debounceDelay = 0.25

    self.generation = 0
    self.debounceTimer = nil
    self.retryTimer = nil

    self:start()
end

function DisplayFixer:start()
    self.wakeWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.screensDidWake then
            self:request()
        end
    end):start()

    self.screenWatcher = hs.screen.watcher.new(function()
        self:request()
    end):start()
end

function DisplayFixer:request()
    self.generation = self.generation + 1
    local gen = self.generation

    if self.debounceTimer then
        self.debounceTimer:stop()
    end

    if self.retryTimer then
        self.retryTimer:stop()
        self.retryTimer = nil
    end

    self.debounceTimer = hs.timer.doAfter(self.debounceDelay, function()
        self.debounceTimer = nil
        self:tryFix(gen, 1)
    end)
end

function DisplayFixer:tryFix(gen, attempt)
    hs.task.new(self.binary, function(exitCode)
        if gen ~= self.generation then
            return
        end

        if exitCode ~= 0 and attempt < self.maxAttempts then
            self.retryTimer = hs.timer.doAfter(self.retryDelay, function()
                self.retryTimer = nil
                self:tryFix(gen, attempt + 1)
            end)
        end
    end, self.args):start()
end


-- Mouse clutches ===============================================================
local MouseClutch = class("MouseClutch")

function MouseClutch:initialize()
    self.et = hs.eventtap
    self.ev = hs.eventtap.event
    self.T = self.ev.types
    self.P = self.ev.properties

    self.middle = 2
    self.zoom = 3

    self.clickMax = 0.4
    self.cooldown = 0.15
    self.horizontalDirection = 1
    self.dragThreshold = 8

    self.tag = 0x5A004D
    self.active = nil
    self.blockedUntil = 0

    local T = self.T

    self.down = {
        [T.leftMouseDown]  = true,
        [T.rightMouseDown] = true,
        [T.otherMouseDown] = true,
    }

    self.up = {
        [T.leftMouseUp]  = true,
        [T.rightMouseUp] = true,
        [T.otherMouseUp] = true,
    }

    self.drag = {
        [T.leftMouseDragged]  = true,
        [T.rightMouseDragged] = true,
        [T.otherMouseDragged] = true,
    }

    self:start()
end

function MouseClutch:start()
    local T = self.T

    self.tap = self.et.new({
        T.leftMouseDown, T.leftMouseUp,
        T.rightMouseDown, T.rightMouseUp,
        T.otherMouseDown, T.otherMouseUp,
        T.leftMouseDragged, T.rightMouseDragged, T.otherMouseDragged,
        T.scrollWheel,
    }, function(e)
        return self:onEvent(e)
    end):start()
end

function MouseClutch:onEvent(e)
    local T, P = self.T, self.P

    if e:getProperty(P.eventSourceUserData) == self.tag then
        return false
    end

    local now = hs.timer.secondsSinceEpoch()
    local t = e:getType()
    local button = e:getProperty(P.mouseEventButtonNumber)

    -- Recover stale state if we somehow missed the owner's mouse-up.
    --
    -- Don't do this *on* the owner's mouse-up; naturally the button state
    -- is already false there, and the normal release handler should run.
    if self.active
        and not (self.up[t] and button == self.active.button)
        and not e:getButtonState(self.active.button) then

        self.active = nil
        self.blockedUntil = now + self.cooldown
    end

    -- Cooldown: block new downs/drags, never ups.
    if now < self.blockedUntil then
        return self.down[t] or self.drag[t] or false
    end

    -- Start clutch.
    if not self.active then
        if t == T.otherMouseDown
            and (button == self.middle or button == self.zoom) then

            self.active = {
                button = button,
                mode = "pending",
                started = now,
                pos = e:location(),
            }

            return true
        end

        return false
    end

    local a = self.active

    -- First clutch wins.
    if self.down[t] then
        return true
    end

    -- Preserve normal middle drag.
    if self.drag[t] then
        if a.button ~= self.middle or button ~= self.middle then
            return true
        end

        if a.mode == "pending" then
            local pos = e:location()
            local dx = pos.x - a.pos.x
            local dy = pos.y - a.pos.y

            -- Ignore little wheel-button jitters.
            if dx * dx + dy * dy < self.dragThreshold ^ 2 then
                return true
            end

            a.mode = "drag"

            local down = self.ev.newMouseEvent(T.otherMouseDown, a.pos)
            down:setProperty(P.mouseEventButtonNumber, a.button)
            down:setProperty(P.eventSourceUserData, self.tag)

            return false, { down }
        end

        return a.mode ~= "drag"
    end

    if t == T.scrollWheel then
        if a.button == self.middle and a.mode ~= "drag" then
            a.mode = "horizontal"

            local smooth =
                e:getProperty(P.scrollWheelEventIsContinuous) ~= 0

            local delta = e:getProperty(
                smooth
                    and P.scrollWheelEventPointDeltaAxis1
                    or P.scrollWheelEventDeltaAxis1
            )

            local scroll = self.ev.newScrollEvent(
                {
                    delta * self.horizontalDirection,
                    0,
                },
                e:getFlags(),
                smooth and "pixel" or "line"
            )

            scroll:setProperty(P.eventSourceUserData, self.tag)

            return true, { scroll }
        end

        if a.button == self.zoom then
            a.mode = "zoom"
            return false
        end
    end

    -- Mouse-up always propagates.
    if self.up[t] and button == a.button then
        self.active = nil

        if a.mode == "pending"
            and now - a.started <= self.clickMax then

            local down = self.ev.newMouseEvent(
                T.otherMouseDown,
                a.pos
            )

            down:setProperty(P.mouseEventButtonNumber, a.button)
            down:setProperty(P.eventSourceUserData, self.tag)

            -- Hammerspoon posts this through the current tap,
            -- then lets the real mouseUp continue.
            return false, { down }
        end

        if a.mode ~= "drag" then
            self.blockedUntil = now + self.cooldown
        end

        return false
    end

    return false
end

-- Start =======================================================================

displayFixer = DisplayFixer:new()
mouseClutch = MouseClutch:new()
