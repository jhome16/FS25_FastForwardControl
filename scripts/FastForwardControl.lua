--[[
    Fast Forward Control - Farming Simulator 25

    Opens a panel (default: Left Alt + T, rebindable in Settings > Controls) where you can:
      * see the current in-game day, month, year and time
      * choose the fast-forward speed
      * choose the in-game day and time to fast-forward to
      * tick "Stop on Markets and Futures alerts" so an alert from that mod stops the
        fast-forward and puts the game speed back to what it was before

    Other mods can talk to this one through:
        g_currentMission.fastForwardControl

        :onExternalAlert(sourceName, message) -> true if a running fast-forward was stopped
        :isFastForwarding()                    -> true while a fast-forward is running
        :isInterruptEnabled()                  -> state of the checkbox

    Console command for testing:  ffcSimulateAlert [message]
]]

FastForwardControl = {}
local FFC = FastForwardControl

FFC.MOD_NAME = g_currentModName
FFC.MOD_DIR = g_currentModDirectory
FFC.SETTINGS_FILENAME = "FS25_FastForwardControl.xml"

FFC.FALLBACK_SPEEDS = {1, 2, 3, 5, 10, 15, 30, 60, 120}
FFC.EXTENDED_SPEEDS = {240, 360, 480}   -- beyond the game's own menu; marked "extended" in the panel
FFC.MAX_DAYS_AHEAD = 365
FFC.MINUTES_PER_DAY = 1440

FFC.PANEL_WIDTH = 580
FFC.PANEL_HEIGHT = 560

FFC.COLORS = {
    panel    = {0.03, 0.04, 0.03, 0.90},
    title    = {0.19, 0.38, 0.08, 0.97},
    divider  = {1.00, 1.00, 1.00, 0.10},
    field    = {0.00, 0.00, 0.00, 0.35},
    button   = {0.17, 0.19, 0.17, 0.97},
    hover    = {0.30, 0.55, 0.13, 0.97},
    disabled = {0.10, 0.10, 0.10, 0.70},
    primary  = {0.26, 0.55, 0.10, 0.97},
    danger   = {0.60, 0.17, 0.12, 0.97},
    check    = {0.48, 0.82, 0.22, 1.00},
    banner   = {0.00, 0.00, 0.00, 0.70},
}

FFC.TEXT_WHITE = {1, 1, 1, 1}
FFC.TEXT_DIM   = {0.70, 0.75, 0.68, 1}
FFC.TEXT_ACC   = {0.62, 0.90, 0.35, 1}
FFC.TEXT_WARN  = {1.00, 0.55, 0.40, 1}
FFC.TEXT_OFF   = {0.45, 0.45, 0.45, 1}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

function FFC:resetState()
    self.isOpen = false
    self.isSkipping = false
    self.previousTimeScale = 1
    self.targetAbs = nil          -- absolute minutes: currentDay * 1440 + minute of day
    self.speeds = {}
    self.extended = {}
    self.speedIndex = 1
    self.interruptOnAlerts = true
    self.buttons = {}
    self.mouseX, self.mouseY = 0, 0
    self.statusText = nil
    self.statusIsError = false
    self.statusTimer = 0
    self.overlays = {}
    self.actionEventIds = {}
    self.cameraLockIds = {}
    self.cameraLockContext = nil
    self.pendingToggle = false
    self.pendingClose = false
    self.lastToggleTime = nil
end

FFC:resetState()

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function px(v)
    local aspect = g_screenAspectRatio or (16 / 9)
    return v / 1080 / aspect
end

local function py(v)
    return v / 1080
end

-- Looks a text up in this mod's translation files (translations/translation_xx.xml)
local function T(key)
    if g_i18n ~= nil then
        local res = g_i18n:getText(key, FFC.MOD_NAME)
        if type(res) == "string" then
            return res
        end
    end
    return key
end

local function formatSpeed(s)
    return string.format("x%g", s)
end

local function formatClock(minuteOfDay)
    minuteOfDay = math.floor(minuteOfDay) % 1440
    return string.format("%02d:%02d", math.floor(minuteOfDay / 60), minuteOfDay % 60)
end

local function formatDuration(minutes)
    minutes = math.max(0, math.floor(minutes))
    local days = math.floor(minutes / 1440)
    local rest = minutes % 1440
    local hm = string.format("%d:%02d %s", math.floor(rest / 60), rest % 60, T("ffc_unit_hour"))
    if days > 0 then
        return string.format("%d %s %s", days, T("ffc_unit_day"), hm)
    end
    return hm
end

local function formatRealTime(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    if seconds < 90 then
        return string.format("%d %s", seconds, T("ffc_unit_second"))
    end
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 90 then
        return string.format("%d %s", minutes, T("ffc_unit_minute"))
    end
    return string.format("%d %s %02d %s", math.floor(minutes / 60), T("ffc_unit_hour"), minutes % 60, T("ffc_unit_minute"))
end

function FFC:getEnvironment()
    if g_currentMission ~= nil then
        return g_currentMission.environment
    end
    return nil
end

function FFC:getNowAbs()
    local env = self:getEnvironment()
    if env == nil or env.currentDay == nil or env.dayTime == nil then
        return nil
    end
    return env.currentDay * FFC.MINUTES_PER_DAY + math.floor(env.dayTime / 60000)
end

function FFC:getToday()
    local env = self:getEnvironment()
    if env == nil then
        return 1
    end
    return env.currentDay or 1
end

function FFC:getCurrentTimeScale()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.timeScale ~= nil then
        return g_currentMission.missionInfo.timeScale
    end
    return 1
end

function FFC:applyTimeScale(scale)
    if g_currentMission == nil or scale == nil then
        return
    end
    if g_currentMission.setTimeScale ~= nil then
        g_currentMission:setTimeScale(scale)
    elseif g_currentMission.missionInfo ~= nil then
        g_currentMission.missionInfo.timeScale = scale
    end
end

-- Returns periodName, dayInPeriod, daysPerPeriod for an absolute game day
function FFC:getDateInfo(day)
    local env = self:getEnvironment()
    local daysPerPeriod = 1
    local period, dayInPeriod

    if env ~= nil then
        daysPerPeriod = math.max(1, env.daysPerPeriod or env.plannedDaysPerPeriod or 1)

        -- count forward from today's known period
        if env.currentPeriod ~= nil and env.currentDayInPeriod ~= nil then
            local offset = (env.currentDayInPeriod - 1) + (day - (env.currentDay or day))
            local periodOffset = math.floor(offset / daysPerPeriod)
            period = ((env.currentPeriod - 1 + periodOffset) % 12) + 1
            dayInPeriod = (offset % daysPerPeriod) + 1
        end
    end

    period = period or 1
    dayInPeriod = dayInPeriod or 1

    local name
    if g_i18n ~= nil and g_i18n.formatPeriod ~= nil then
        local res = g_i18n:formatPeriod(period, false)
        if type(res) == "string" then name = res end
    end
    name = name or string.format(T("ffc_period_fallback"), period)

    return name, dayInPeriod, daysPerPeriod
end

function FFC:formatDate(day, includeYear)
    local name, dayInPeriod, daysPerPeriod = self:getDateInfo(day)
    local text = string.format(T("ffc_date_day"), day) .. "  -  " .. name
    if daysPerPeriod > 1 then
        text = text .. ", " .. string.format(T("ffc_date_dayOfPeriod"), dayInPeriod, daysPerPeriod)
    end
    if includeYear then
        local env = self:getEnvironment()
        if env ~= nil and env.currentYear ~= nil then
            text = text .. "  -  " .. string.format(T("ffc_date_year"), env.currentYear)
        end
    end
    return text
end

function FFC:setStatus(text, isError, duration)
    self.statusText = text
    self.statusIsError = isError == true
    self.statusTimer = duration or 6000
end

function FFC:notify(text, kind)
    if g_currentMission == nil or g_currentMission.addIngameNotification == nil then
        return
    end
    local notifType
    if FSBaseMission ~= nil then
        if kind == "critical" then
            notifType = FSBaseMission.INGAME_NOTIFICATION_CRITICAL
        elseif kind == "info" then
            notifType = FSBaseMission.INGAME_NOTIFICATION_INFO
        else
            notifType = FSBaseMission.INGAME_NOTIFICATION_OK
        end
    end
    if notifType ~= nil then
        g_currentMission:addIngameNotification(notifType, text)
    end
end

---------------------------------------------------------------------------
-- Speeds
---------------------------------------------------------------------------

function FFC:buildSpeedList()
    local list, seen = {}, {}

    local source
    if Platform ~= nil and Platform.gameplay ~= nil then
        source = Platform.gameplay.timeScaleSettings
    end
    if type(source) == "table" then
        for _, v in ipairs(source) do
            if type(v) == "number" and v >= 1 and not seen[v] then
                seen[v] = true
                table.insert(list, v)
            end
        end
    end
    if #list == 0 then
        for _, v in ipairs(FFC.FALLBACK_SPEEDS) do
            seen[v] = true
            table.insert(list, v)
        end
    end

    local gameMax = 0
    for _, v in ipairs(list) do
        gameMax = math.max(gameMax, v)
    end
    self.gameMaxSpeed = gameMax

    for _, v in ipairs(FFC.EXTENDED_SPEEDS) do
        if v > gameMax and not seen[v] then
            seen[v] = true
            self.extended[v] = true
            table.insert(list, v)
        end
    end

    table.sort(list)
    self.speeds = list
    self:selectSpeed(gameMax)
end

function FFC:selectSpeed(value)
    local best, bestDiff = 1, math.huge
    for i, v in ipairs(self.speeds) do
        local diff = math.abs(v - value)
        if diff < bestDiff then
            best, bestDiff = i, diff
        end
    end
    self.speedIndex = best
end

function FFC:getSelectedSpeed()
    return self.speeds[self.speedIndex] or 1
end

function FFC:changeSpeed(delta)
    local newIndex = math.max(1, math.min(#self.speeds, self.speedIndex + delta))
    if newIndex == self.speedIndex then
        return
    end
    self.speedIndex = newIndex
    if self.isSkipping then
        self:applyTimeScale(self:getSelectedSpeed())
    end
    self:saveSettings()
end

---------------------------------------------------------------------------
-- Target day / time
---------------------------------------------------------------------------

function FFC:setDefaultTarget()
    -- Tomorrow at 06:00
    self.targetAbs = (self:getToday() + 1) * FFC.MINUTES_PER_DAY + 6 * 60
end

function FFC:clampTarget()
    if self.targetAbs == nil then
        self:setDefaultTarget()
    end
    local today = self:getToday()
    local minAbs = today * FFC.MINUTES_PER_DAY
    local maxAbs = (today + FFC.MAX_DAYS_AHEAD) * FFC.MINUTES_PER_DAY + FFC.MINUTES_PER_DAY - 1
    self.targetAbs = math.max(minAbs, math.min(maxAbs, self.targetAbs))
end

function FFC:shiftTarget(minutes)
    self:clampTarget()
    self.targetAbs = self.targetAbs + minutes
    self:clampTarget()
end

function FFC:snapTargetToQuarter()
    self.targetAbs = math.floor(self.targetAbs / 15 + 0.5) * 15
end

function FFC:setTargetTomorrowMorning()
    self.targetAbs = (self:getToday() + 1) * FFC.MINUTES_PER_DAY + 6 * 60
end

function FFC:setTargetFromNow(minutes)
    local now = self:getNowAbs()
    if now ~= nil then
        self.targetAbs = now + minutes
        self:snapTargetToQuarter()
        self:clampTarget()
    end
end

function FFC:getTargetDay()
    return math.floor(self.targetAbs / FFC.MINUTES_PER_DAY)
end

function FFC:getTargetMinuteOfDay()
    return self.targetAbs % FFC.MINUTES_PER_DAY
end

---------------------------------------------------------------------------
-- Fast-forward
---------------------------------------------------------------------------

function FFC:startSkip()
    self:clampTarget()
    local now = self:getNowAbs()
    if now == nil then
        self:setStatus(T("ffc_msg_unavailable"), true)
        return
    end
    if self.targetAbs <= now then
        self:setStatus(T("ffc_msg_pickFuture"), true)
        return
    end

    if not self.isSkipping then
        self.previousTimeScale = self:getCurrentTimeScale()
    end
    self.isSkipping = true
    self:applyTimeScale(self:getSelectedSpeed())

    local msg = string.format(T("ffc_msg_started"),
        self:getTargetDay(), formatClock(self:getTargetMinuteOfDay()), formatSpeed(self:getSelectedSpeed()))
    self:setStatus(msg, false)
    self:notify(msg, "info")
end

function FFC:stopSkip(reason, kind)
    if not self.isSkipping then
        return
    end
    self.isSkipping = false
    self:applyTimeScale(self.previousTimeScale)

    local msg = string.format(T("ffc_msg_speedBack"), reason or T("ffc_msg_stopped"), formatSpeed(self.previousTimeScale))
    self:setStatus(msg, kind == "critical")
    self:notify(msg, kind or "ok")
end

function FFC:isFastForwarding()
    return self.isSkipping
end

function FFC:isInterruptEnabled()
    return self.interruptOnAlerts
end

--- Called by other mods (Markets and Futures) when one of their alerts fires.
-- @param sourceName  name of the calling mod, e.g. "Markets and Futures"
-- @param message     the alert text, shown in the notification
-- @return true if a running fast-forward was stopped
function FFC:onExternalAlert(sourceName, message)
    Logging.info("[FastForwardControl] Alert received from '%s' (fast-forwarding: %s, stop-on-alert checkbox: %s)",
        tostring(sourceName), tostring(self.isSkipping), tostring(self.interruptOnAlerts))
    if not self.isSkipping or not self.interruptOnAlerts then
        return false
    end
    local reason = T("ffc_msg_alert")
    if message ~= nil and message ~= "" then
        reason = string.format(T("ffc_msg_alertText"), tostring(message))
    elseif sourceName ~= nil then
        reason = string.format(T("ffc_msg_alertFrom"), tostring(sourceName))
    end
    self:stopSkip(reason, "critical")
    return true
end

function FFC:consoleSimulateAlert(...)
    local text = table.concat({...}, " ")
    if text == "" then
        text = "Test alert"
    end
    if not self.isSkipping then
        return "Not fast-forwarding right now - start a fast-forward first."
    end
    if not self.interruptOnAlerts then
        return "Alert received, but the interrupt checkbox is off - fast-forward continues."
    end
    self:onExternalAlert("Markets and Futures", text)
    return "Alert sent - fast-forward stopped and speed restored."
end

---------------------------------------------------------------------------
-- Settings (saved to <user profile>/modSettings/FS25_FastForwardControl.xml)
---------------------------------------------------------------------------

function FFC:getSettingsPath()
    local dir = getUserProfileAppPath() .. "modSettings/"
    createFolder(dir)
    return dir .. FFC.SETTINGS_FILENAME
end

function FFC:loadSettings()
    local path = self:getSettingsPath()
    if not fileExists(path) then
        return
    end
    local xml = loadXMLFile("ffcSettings", path)
    if xml == nil or xml == 0 then
        return
    end
    local speed = getXMLFloat(xml, "fastForwardControl.speed")
    local interrupt = getXMLBool(xml, "fastForwardControl.interruptOnAlerts")
    delete(xml)
    if speed ~= nil then
        self:selectSpeed(speed)
    end
    if interrupt ~= nil then
        self.interruptOnAlerts = interrupt
    end
end

function FFC:saveSettings()
    local xml = createXMLFile("ffcSettings", self:getSettingsPath(), "fastForwardControl")
    if xml == nil or xml == 0 then
        return
    end
    setXMLFloat(xml, "fastForwardControl.speed", self:getSelectedSpeed())
    setXMLBool(xml, "fastForwardControl.interruptOnAlerts", self.interruptOnAlerts)
    saveXMLFile(xml)
    delete(xml)
end

---------------------------------------------------------------------------
-- Opening / closing the panel
---------------------------------------------------------------------------

-- Camera look actions that are blocked while the panel is open (on foot and in vehicles).
-- Names that do not exist in this game version are skipped.
FFC.CAMERA_LOCK_ACTIONS = {
    "AXIS_LOOK_LEFTRIGHT_PLAYER", "AXIS_LOOK_UPDOWN_PLAYER",
    "AXIS_LOOK_LEFTRIGHT_VEHICLE", "AXIS_LOOK_UPDOWN_VEHICLE",
    "AXIS_LOOK_LEFTRIGHT_DRAG", "AXIS_LOOK_UPDOWN_DRAG",
    "CAMERA_ZOOM_IN", "CAMERA_ZOOM_OUT",
}

function FFC:getInputContext()
    if g_inputBinding.getContextName ~= nil then
        return g_inputBinding:getContextName()
    end
    return g_inputBinding.currentContextName
end

function FFC.onSwallowInput() end

-- Registers do-nothing listeners on the look actions with "disable conflicting bindings",
-- so the game's own camera handlers do not receive mouse movement while the panel is open.
function FFC:lockCamera()
    self:unlockCamera()
    self.cameraLockIds = {}
    local ctx = self:getInputContext()
    self.cameraLockContext = ctx

    if ctx ~= nil then
        g_inputBinding:beginActionEventsModification(ctx)
    end
    for _, name in ipairs(FFC.CAMERA_LOCK_ACTIONS) do
        local actionId = InputAction[name]
        if actionId ~= nil then
            local ok, id = g_inputBinding:registerActionEvent(actionId, FFC, FFC.onSwallowInput,
                false, false, true, true, nil, true)
            if ok and id ~= nil then
                table.insert(self.cameraLockIds, id)
                g_inputBinding:setActionEventTextVisibility(id, false)
            end
        end
    end
    if ctx ~= nil then
        g_inputBinding:endActionEventsModification()
    end
end

function FFC:unlockCamera()
    local ids = self.cameraLockIds
    if ids == nil or #ids == 0 then
        self.cameraLockIds = {}
        self.cameraLockContext = nil
        return
    end
    local ctx = self.cameraLockContext
    -- if the input context changed meanwhile (menu opened, entered a vehicle) the game already dropped these events
    if ctx ~= nil and self:getInputContext() == ctx then
        g_inputBinding:beginActionEventsModification(ctx)
        for _, id in ipairs(ids) do
            g_inputBinding:removeActionEvent(id)
        end
        g_inputBinding:endActionEventsModification()
    end
    self.cameraLockIds = {}
    self.cameraLockContext = nil
end

function FFC:open()
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        return
    end
    if self.targetAbs == nil then
        self:setDefaultTarget()
    end
    self:clampTarget()
    self.isOpen = true
    g_inputBinding:setShowMouseCursor(true)
    self:lockCamera()
end

function FFC:close()
    if not self.isOpen then
        return
    end
    self.isOpen = false
    self:unlockCamera()
    g_inputBinding:setShowMouseCursor(false)
end

-- The toggle is only recorded here and carried out in update(): changing input bindings
-- (the camera lock) from inside an input callback does not take effect.
function FFC:onToggleAction(actionName, inputValue, callbackState, isAnalog)
    if inputValue ~= nil and inputValue <= 0 then
        return
    end
    local now = g_time or 0
    if self.lastToggleTime ~= nil and now - self.lastToggleTime < 300 then
        return
    end
    self.lastToggleTime = now
    self.pendingToggle = true
end

function FFC:registerActionEvents()
    if g_inputBinding == nil or InputAction == nil or InputAction.FFC_TOGGLE_HUD == nil then
        return
    end
    local ok, eventId = g_inputBinding:registerActionEvent(InputAction.FFC_TOGGLE_HUD, FFC, FFC.onToggleAction, false, true, false, true)
    if ok and eventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(eventId, true)
        if GS_PRIO_VERY_LOW ~= nil then
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_VERY_LOW)
        end
    end
end

-- Global key: works on foot and in vehicles
if PlayerInputComponent ~= nil and PlayerInputComponent.registerGlobalPlayerActionEvents ~= nil then
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents, function()
        FFC:registerActionEvents()
    end)
end
if FSBaseMission ~= nil and FSBaseMission.registerActionEvents ~= nil then
    FSBaseMission.registerActionEvents = Utils.appendedFunction(FSBaseMission.registerActionEvents, function()
        FFC:registerActionEvents()
    end)
end

-- On-foot camera lock.
-- The on-foot camera listens to the look actions itself, so blocking the bindings is not enough.
-- Every look/rotate input handler of the player classes is wrapped: while the panel is open it
-- receives an input value of 0, so the view stays still (passing 0 rather than skipping the call
-- also clears any value the handler stored on the previous frame).
FFC.hookedLookFunctions = {}

local function isLookHandler(name)
    if type(name) ~= "string" or name:sub(1, 2) ~= "on" then
        return false
    end
    local lower = name:lower()
    return lower:find("look") ~= nil or lower:find("rotat") ~= nil or lower:find("pitch") ~= nil or lower:find("yaw") ~= nil
end

local function hookLookHandlers(classTable, className)
    if type(classTable) ~= "table" then
        return
    end
    local names = {}
    for name, func in pairs(classTable) do
        if type(func) == "function" and isLookHandler(name) then
            table.insert(names, name)
        end
    end
    for _, name in ipairs(names) do
        classTable[name] = Utils.overwrittenFunction(classTable[name], function(obj, superFunc, actionName, inputValue, ...)
            if FFC.isOpen and type(inputValue) == "number" then
                return superFunc(obj, actionName, 0, ...)
            end
            return superFunc(obj, actionName, inputValue, ...)
        end)
        table.insert(FFC.hookedLookFunctions, className .. "." .. name)
    end
end

hookLookHandlers(PlayerInputComponent, "PlayerInputComponent")
hookLookHandlers(PlayerCamera, "PlayerCamera")
hookLookHandlers(Player, "Player")

-- Never save a savegame while it is sitting at the fast-forward speed
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.overwrittenFunction(FSCareerMissionInfo.saveToXMLFile, function(missionInfo, superFunc, ...)
        if FFC.isSkipping and missionInfo.timeScale ~= nil then
            local running = missionInfo.timeScale
            missionInfo.timeScale = FFC.previousTimeScale
            local results = {superFunc(missionInfo, ...)}
            missionInfo.timeScale = running
            return unpack(results)
        end
        return superFunc(missionInfo, ...)
    end)
end

---------------------------------------------------------------------------
-- Mod event listener
---------------------------------------------------------------------------

function FFC:loadMap(filename)
    self:resetState()
    self:buildSpeedList()
    self:loadSettings()

    local texture = Utils.getFilename("textures/white.dds", FFC.MOD_DIR)
    for key, color in pairs(FFC.COLORS) do
        local id = createImageOverlay(texture)
        if id ~= nil and id ~= 0 then
            setOverlayColor(id, color[1], color[2], color[3], color[4])
            self.overlays[key] = id
        end
    end

    if g_currentMission ~= nil then
        g_currentMission.fastForwardControl = self
        Logging.info("[FastForwardControl] Alert interface ready: g_currentMission.fastForwardControl")
    end

    if #FFC.hookedLookFunctions > 0 then
        Logging.info("[FastForwardControl] Camera lock hooked: %s", table.concat(FFC.hookedLookFunctions, ", "))
    else
        Logging.warning("[FastForwardControl] Camera lock: no on-foot look handlers found to hook")
    end

    addConsoleCommand("ffcSimulateAlert", "Simulates a Markets and Futures alert (tests the interrupt checkbox)", "consoleSimulateAlert", self)
end

function FFC:deleteMap()
    if self.isSkipping then
        self:applyTimeScale(self.previousTimeScale)
        self.isSkipping = false
    end
    if self.isOpen then
        self:close()
    end
    for _, id in pairs(self.overlays) do
        delete(id)
    end
    self.overlays = {}
    removeConsoleCommand("ffcSimulateAlert")
    if g_currentMission ~= nil then
        g_currentMission.fastForwardControl = nil
    end
end

function FFC:update(dt)
    -- open / close requests are carried out here, outside the input callbacks
    if self.pendingToggle then
        self.pendingToggle = false
        if self.isOpen then
            self:close()
        else
            self:open()
        end
    end
    if self.pendingClose then
        self.pendingClose = false
        self:close()
    end

    if self.statusTimer > 0 then
        self.statusTimer = self.statusTimer - dt
        if self.statusTimer <= 0 then
            self.statusText = nil
        end
    end

    -- A game menu opened on top: let it own the mouse cursor
    if self.isOpen and g_gui ~= nil and g_gui:getIsGuiVisible() then
        self.isOpen = false
        self:unlockCamera()
    end

    -- Entered / left a vehicle while the panel is open: lock the camera in the new context
    if self.isOpen and self.cameraLockContext ~= nil and self:getInputContext() ~= self.cameraLockContext then
        self:lockCamera()
        g_inputBinding:setShowMouseCursor(true)
    end

    if self.isSkipping then
        local now = self:getNowAbs()
        if now ~= nil and self.targetAbs ~= nil and now >= self.targetAbs then
            self:stopSkip(string.format(T("ffc_msg_arrived"), self:getTargetDay(), formatClock(self:getTargetMinuteOfDay())), "ok")
        end
    end
end

function FFC:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.isOpen then
        return
    end
    self.mouseX, self.mouseY = posX, posY

    local leftButton = (Input ~= nil and Input.MOUSE_BUTTON_LEFT) or 1
    if isDown and button == leftButton then
        for _, b in ipairs(self.buttons) do
            if b.enabled and posX >= b.x and posX <= b.x + b.w and posY >= b.y and posY <= b.y + b.h then
                b.onClick()
                return
            end
        end
    end
end

function FFC:keyEvent(unicode, sym, modifier, isDown)
    if self.isOpen and isDown and Input ~= nil and sym == Input.KEY_esc then
        self.pendingClose = true
    end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function FFC:drawRect(key, x, y, w, h)
    local id = self.overlays[key]
    if id ~= nil then
        renderOverlay(id, x, y, w, h)
    end
end

function FFC:isHovered(x, y, w, h)
    return self.mouseX >= x and self.mouseX <= x + w and self.mouseY >= y and self.mouseY <= y + h
end

-- Renders text vertically centred on a row. align: "left", "center", "right"
function FFC:drawText(x, rowY, rowH, text, size, align, color, bold, maxWidth)
    color = color or FFC.TEXT_WHITE
    setTextColor(color[1], color[2], color[3], color[4])
    setTextBold(bold == true)
    -- translations can be longer than English: shrink the text so it stays inside its box
    if maxWidth ~= nil and maxWidth > 0 then
        local textWidth = getTextWidth(size, text)
        if textWidth > maxWidth then
            size = size * maxWidth / textWidth
        end
    end
    if align == "center" then
        setTextAlignment(RenderText.ALIGN_CENTER)
    elseif align == "right" then
        setTextAlignment(RenderText.ALIGN_RIGHT)
    else
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
    local textY = rowY + (rowH - size) * 0.5 + size * 0.18
    renderText(x, textY, size, text)
end

function FFC:resetTextSettings()
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function FFC:draw()
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        return
    end
    if self.isOpen then
        self:drawPanel()
    elseif self.isSkipping then
        self:drawBanner()
    end
    self:resetTextSettings()
end

function FFC:drawBanner()
    local now = self:getNowAbs()
    if now == nil or self.targetAbs == nil then
        return
    end
    local text = string.format(T("ffc_banner"),
        formatSpeed(self:getCurrentTimeScale()), self:getTargetDay(),
        formatClock(self:getTargetMinuteOfDay()), formatDuration(self.targetAbs - now))
    local w, h = px(520), py(34)
    local x, y = 0.5 - w * 0.5, 0.955 - h
    self:drawRect("banner", x, y, w, h)
    self:drawText(0.5, y, h, text, py(17), "center", FFC.TEXT_ACC, true, w - px(20))
end

function FFC:drawPanel()
    local W, H = FFC.PANEL_WIDTH, FFC.PANEL_HEIGHT
    local ox = 0.5 - px(W) * 0.5
    local top = 0.5 + py(H) * 0.5

    -- layout helper: local (pixels from panel top-left) -> screen rect
    local function R(lx, ly, w, h)
        return ox + px(lx), top - py(ly + h), px(w), py(h)
    end

    self.buttons = {}

    local function text(lx, ly, h, str, size, align, color, bold, maxW)
        local x, y, _, rh = R(lx, ly, 0, h)
        if maxW == nil then
            maxW = (align == "center") and (W - 36) or (W - lx - 18)
        end
        self:drawText(x, y, rh, str, py(size), align, color, bold, px(maxW))
    end

    local function button(lx, ly, w, h, label, onClick, enabled, style, size)
        if enabled == nil then enabled = true end
        local x, y, bw, bh = R(lx, ly, w, h)
        local key = style or "button"
        if not enabled then
            key = "disabled"
        elseif self:isHovered(x, y, bw, bh) then
            key = "hover"
        end
        self:drawRect(key, x, y, bw, bh)
        self:drawText(x + bw * 0.5, y, bh, label, py(size or 16), "center",
            enabled and FFC.TEXT_WHITE or FFC.TEXT_OFF, true, bw - px(12))
        table.insert(self.buttons, {x = x, y = y, w = bw, h = bh, enabled = enabled, onClick = onClick})
    end

    local function rect(key, lx, ly, w, h)
        local x, y, rw, rh = R(lx, ly, w, h)
        self:drawRect(key, x, y, rw, rh)
    end

    self:clampTarget()
    local now = self:getNowAbs() or 0
    local today = self:getToday()

    -- Background + title bar
    rect("panel", 0, 0, W, H)
    rect("title", 0, 0, W, 48)
    text(18, 0, 48, T("ffc_title"), 19, "left", FFC.TEXT_WHITE, true, W - 80)
    button(W - 44, 7, 34, 34, "X", function() self.pendingClose = true end, true, "button", 16)

    -- Today
    text(18, 58, 22, T("ffc_today"), 13, "left", FFC.TEXT_DIM, true)
    text(18, 80, 28, self:formatDate(today, true), 19, "left", FFC.TEXT_WHITE, true)
    local timeLine = string.format(T("ffc_time"), formatClock(now % FFC.MINUTES_PER_DAY))
        .. "     " .. string.format(T("ffc_gameSpeed"), formatSpeed(self:getCurrentTimeScale()))
    if self.isSkipping then
        timeLine = timeLine .. "   " .. T("ffc_fastForwarding")
    end
    text(18, 108, 26, timeLine, 16, "left",
        self.isSkipping and FFC.TEXT_ACC or FFC.TEXT_DIM, false)
    rect("divider", 18, 144, W - 36, 2)

    -- Speed
    text(18, 154, 22, T("ffc_speed_header"), 13, "left", FFC.TEXT_DIM, true)
    local speed = self:getSelectedSpeed()
    button(18, 180, 46, 40, "<", function() self:changeSpeed(-1) end, self.speedIndex > 1)
    rect("field", 72, 180, W - 144, 40)
    local tag = ""
    if self.extended[speed] then
        tag = "   " .. T("ffc_speed_extended")
    elseif speed == self.gameMaxSpeed then
        tag = "   " .. T("ffc_speed_max")
    end
    text(W * 0.5, 180, 40, formatSpeed(speed) .. tag, 18, "center", FFC.TEXT_ACC, true, W - 160)
    button(W - 64, 180, 46, 40, ">", function() self:changeSpeed(1) end, self.speedIndex < #self.speeds)
    rect("divider", 18, 236, W - 36, 2)

    -- Target day / time
    text(18, 246, 22, T("ffc_until_header"), 13, "left", FFC.TEXT_DIM, true)
    local targetDay = self:getTargetDay()
    local daysAhead = targetDay - today
    button(18, 272, 46, 40, "<", function() self:shiftTarget(-FFC.MINUTES_PER_DAY) end, targetDay > today)
    rect("field", 72, 272, W - 144, 40)
    local dayLabel = self:formatDate(targetDay, false)
    if daysAhead == 0 then
        dayLabel = dayLabel .. "  " .. T("ffc_target_today")
    elseif daysAhead == 1 then
        dayLabel = dayLabel .. "  " .. T("ffc_target_tomorrow")
    else
        dayLabel = dayLabel .. string.format("  (+%d)", daysAhead)
    end
    text(W * 0.5, 272, 40, dayLabel, 16, "center", FFC.TEXT_WHITE, true, W - 160)
    button(W - 64, 272, 46, 40, ">", function() self:shiftTarget(FFC.MINUTES_PER_DAY) end, daysAhead < FFC.MAX_DAYS_AHEAD)

    local unitH, unitM = T("ffc_unit_hour"), T("ffc_unit_minute")
    button(18, 320, 70, 40, "-1 " .. unitH, function() self:shiftTarget(-60) end)
    button(94, 320, 70, 40, "-15 " .. unitM, function() self:shiftTarget(-15) end)
    rect("field", 172, 320, W - 344, 40)
    text(W * 0.5, 320, 40, formatClock(self:getTargetMinuteOfDay()), 22, "center", FFC.TEXT_WHITE, true)
    button(W - 164, 320, 70, 40, "+15 " .. unitM, function() self:shiftTarget(15) end)
    button(W - 88, 320, 70, 40, "+1 " .. unitH, function() self:shiftTarget(60) end)

    local pw = (W - 36 - 16) / 3
    button(18, 370, pw, 36, T("ffc_preset_tomorrow"), function() self:setTargetTomorrowMorning() end, true, "button", 15)
    button(18 + pw + 8, 370, pw, 36, T("ffc_preset_1h"), function() self:setTargetFromNow(60) end, true, "button", 15)
    button(18 + 2 * (pw + 8), 370, pw, 36, T("ffc_preset_6h"), function() self:setTargetFromNow(360) end, true, "button", 15)
    rect("divider", 18, 420, W - 36, 2)

    -- Interrupt checkbox (the whole row is clickable)
    local rx, ry, rw, rh = R(18, 430, W - 36, 34)
    local rowHover = self:isHovered(rx, ry, rw, rh)
    rect(rowHover and "button" or "field", 18, 430, W - 36, 34)
    rect("divider", 26, 435, 24, 24)
    if self.interruptOnAlerts then
        rect("check", 30, 439, 16, 16)
    end
    text(60, 430, 34, T("ffc_checkbox"), 16, "left", FFC.TEXT_WHITE, false, W - 60 - 24)
    table.insert(self.buttons, {x = rx, y = ry, w = rw, h = rh, enabled = true, onClick = function()
        self.interruptOnAlerts = not self.interruptOnAlerts
        self:saveSettings()
    end})

    -- Start / Stop
    local bw = (W - 36 - 10) / 2
    local remaining = self.targetAbs - now
    button(18, 476, bw, 44, self.isSkipping and T("ffc_btn_running") or T("ffc_btn_start"),
        function() self:startSkip() end, (not self.isSkipping) and remaining > 0, "primary", 18)
    button(18 + bw + 10, 476, bw, 44, T("ffc_btn_stop"),
        function() self:stopSkip(T("ffc_msg_stoppedByUser"), "ok") end, self.isSkipping, "danger", 18)

    -- Status line
    local status, statusColor
    if self.statusText ~= nil then
        status = self.statusText
        statusColor = self.statusIsError and FFC.TEXT_WARN or FFC.TEXT_ACC
    elseif remaining <= 0 then
        status = T("ffc_status_passed")
        statusColor = FFC.TEXT_WARN
    else
        local runSpeed = self:getSelectedSpeed()
        status = string.format(T("ffc_status_remaining"),
            formatDuration(remaining), formatRealTime(remaining * 60 / runSpeed), formatSpeed(runSpeed))
        statusColor = FFC.TEXT_DIM
    end
    text(W * 0.5, 526, 30, status, 15, "center", statusColor, false)
end

addModEventListener(FFC)
