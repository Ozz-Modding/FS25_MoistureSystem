-- Temporary debug module for moisture/weather calibration.
-- Disable by removing its <sourceFile> entry from modDesc.xml.

MoistureDebugLogger = {}
MoistureDebugLogger.LOG_EVERY_N_HOURS = 12

function MoistureDebugLogger:loadMap()
    self:_resetAccumulators()
end

function MoistureDebugLogger:_resetAccumulators()
    self.hourCounter = 0
    self.rainHours = 0
    self.snowHours = 0
    self.hailHours = 0
    self.peakRain = 0
    self.peakSnow = 0
    self.peakHail = 0
end

function MoistureDebugLogger:onStartMission()
    if not g_currentMission:getIsServer() then return end
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, MoistureDebugLogger.onHourChanged, MoistureDebugLogger)
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, MoistureDebugLogger.onMonthChanged, MoistureDebugLogger)
end

function MoistureDebugLogger:onHourChanged()
    if not g_currentMission:getIsServer() then return end

    local weather = g_currentMission.environment.weather
    local rainfall = weather:getRainFallScale()
    local snowfall = weather:getSnowFallScale()
    local hailfall = weather:getHailFallScale()

    if rainfall > 0 then self.rainHours = self.rainHours + 1; self.peakRain = math.max(self.peakRain, rainfall) end
    if snowfall > 0 then self.snowHours = self.snowHours + 1; self.peakSnow = math.max(self.peakSnow, snowfall) end
    if hailfall > 0 then self.hailHours = self.hailHours + 1; self.peakHail = math.max(self.peakHail, hailfall) end

    self.hourCounter = self.hourCounter + 1
    if self.hourCounter < MoistureDebugLogger.LOG_EVERY_N_HOURS then return end

    local ms = g_currentMission.MoistureSystem
    local wps = g_currentMission.WeatherProfileSystem
    if not ms or not wps then self:_resetAccumulators(); return end

    local env = g_currentMission.environment
    local month = MoistureSystem.periodToMonth(env.currentPeriod)
    local clamp = wps:getClampForMonth(month)
    local rangeSize = clamp.max - clamp.min
    local innerMin = clamp.min + rangeSize * 0.1
    local innerMax = clamp.max - rangeSize * 0.1

    local precipParts = {}
    if self.rainHours > 0 then table.insert(precipParts, string.format("rain %dh pk=%.2f", self.rainHours, self.peakRain)) end
    if self.snowHours > 0 then table.insert(precipParts, string.format("snow %dh pk=%.2f", self.snowHours, self.peakSnow)) end
    if self.hailHours > 0 then table.insert(precipParts, string.format("hail %dh pk=%.2f", self.hailHours, self.peakHail)) end
    local precipStr = #precipParts > 0 and table.concat(precipParts, " ") or "dry"

    print(string.format("[MSDebug] 12h | month=%d h=%02d | moisture=%.1f%% | inner=[%.1f-%.1f]%% | %s",
        month, env.currentHour, ms.currentMoisturePercent * 100, innerMin, innerMax, precipStr))

    self:_resetAccumulators()
end

function MoistureDebugLogger:onMonthChanged()
    if not g_currentMission:getIsServer() then return end
    self.hourCounter = 0  -- align next 12h tick cleanly after month boundary

    local ms = g_currentMission.MoistureSystem
    local wps = g_currentMission.WeatherProfileSystem
    if not ms or not wps then return end

    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local scenario = wps:getActiveScenario()
    local clamp = wps:getClampForMonth(month)
    local md = wps:getMonthData(month)
    local weight = scenario and scenario.weight or 0
    local rangeSize = clamp.max - clamp.min
    local innerMin = clamp.min + rangeSize * 0.1
    local innerMax = clamp.max - rangeSize * 0.1

    print("[MSDebug] ================================================")
    print(string.format("[MSDebug] Month %d  |  Profile: %s  |  Scenario: %s (w=%.1f)",
        month, g_currentMission.MoistureSystem.settings.weatherProfile, wps.activeScenarioId, weight))
    if md then
        print(string.format("[MSDebug]   Weights:    rain=%d thunder=%d snow=%d hail=%d sun=%d partCloud=%d cloudy=%d",
            md.rain, md.thunder, md.snow, md.hail, md.sun, md.partlyCloudy, md.cloudy))
    end
    print(string.format("[MSDebug]   Clamp:      %.0f%%-%.0f%%  inner [%.1f%%-%.1f%%]",
        clamp.min, clamp.max, innerMin, innerMax))
    print(string.format("[MSDebug]   Moisture now: %.1f%%", ms.currentMoisturePercent * 100))
    print("[MSDebug] ================================================")
end

FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, MoistureDebugLogger.onStartMission)
addModEventListener(MoistureDebugLogger)
