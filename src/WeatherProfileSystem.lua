WeatherProfileSystem = {}

WeatherProfileSystem.RAINFALL_WEIGHT_SCALE = 10
WeatherProfileSystem.TEMPERATURE_OFFSET_SCALE = 1.0
WeatherProfileSystem.MOISTURE_CLAMP_SCALE = 1.0

function WeatherProfileSystem:loadMap()
    g_currentMission.WeatherProfileSystem = self
    self.profiles = {}
    self.activeProfileId = "centraleurope"
    self.activeScenarioId = "normal"
    self:loadProfiles()
end

function WeatherProfileSystem:loadProfiles()
    local profileDir = MoistureSystem.dir .. "xml/weatherProfiles/"
    local profileFiles = {
        "ukeast.xml",
        "ukwest.xml",
        "centraleurope.xml",
        "mediterranean.xml",
        "usmidwest.xml",
        "uspnw.xml",
        "eastasia.xml",
    }
    for _, filename in ipairs(profileFiles) do
        local path = profileDir .. filename
        if fileExists(path) then
            self:loadProfileXML(path)
        end
    end
end

function WeatherProfileSystem:loadProfileXML(path)
    local xmlFile = loadXMLFile("WPS_Profile", path)
    if not xmlFile then return end

    local profileKey = "weatherProfile"
    local id = getXMLString(xmlFile, profileKey .. "#id")
    local displayName = getXMLString(xmlFile, profileKey .. "#displayName")
    if not id or not displayName then
        delete(xmlFile)
        return
    end

    local profile = { id = id, displayName = displayName, scenarios = {} }

    local si = 0
    while true do
        local sKey = string.format("%s.scenarios.scenario(%d)", profileKey, si)
        if not hasXMLProperty(xmlFile, sKey) then break end

        local scenarioId = getXMLString(xmlFile, sKey .. "#id")
        local weight = getXMLFloat(xmlFile, sKey .. "#weight") or 1
        if scenarioId then
            local scenario = { id = scenarioId, weight = weight, months = {} }
            for m = 1, 12 do
                local mKey = string.format("%s.month(%d)", sKey, m - 1)
                if hasXMLProperty(xmlFile, mKey) then
                    local mid = getXMLInt(xmlFile, mKey .. "#id") or m
                    scenario.months[mid] = {
                        rainfall = getXMLFloat(xmlFile, mKey .. "#rainfall") or 0.5,
                        tempMinOffset = getXMLFloat(xmlFile, mKey .. "#tempMinOffset") or 0,
                        tempMaxOffset = getXMLFloat(xmlFile, mKey .. "#tempMaxOffset") or 0,
                        moistureMin = getXMLFloat(xmlFile, mKey .. "#moistureMin") or 10,
                        moistureMax = getXMLFloat(xmlFile, mKey .. "#moistureMax") or 30,
                    }
                end
            end
            table.insert(profile.scenarios, scenario)
        end
        si = si + 1
    end

    self.profiles[id] = profile
    delete(xmlFile)
end

function WeatherProfileSystem:onStartMission()
    local wps = g_currentMission.WeatherProfileSystem
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, WeatherProfileSystem.onPeriodChanged, wps)
        wps:installWeatherOverrides()
    end
end

function WeatherProfileSystem:installWeatherOverrides()
    local weather = g_currentMission.environment.weather

    Weather.fillWeatherForecast = Utils.overwrittenFunction(
        Weather.fillWeatherForecast,
        function(self, superFunc, isInitialSync)
            g_currentMission.WeatherProfileSystem:rebuildWeatherWeights(self)
            superFunc(self, isInitialSync)
        end
    )

    WeatherObject.activate = Utils.overwrittenFunction(
        WeatherObject.activate,
        function(self, superFunc, instance, changeDuration)
            if instance and instance.startDay then
                local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
                local offsets = g_currentMission.WeatherProfileSystem:getTemperatureOffsetsForMonth(month)
                if offsets and instance.variation then
                    instance.variation.minTemperature = (instance.variation.minTemperature or 0)
                        + offsets.minOffset * WeatherProfileSystem.TEMPERATURE_OFFSET_SCALE
                    instance.variation.maxTemperature = (instance.variation.maxTemperature or 10)
                        + offsets.maxOffset * WeatherProfileSystem.TEMPERATURE_OFFSET_SCALE
                end
            end
            superFunc(self, instance, changeDuration)
        end
    )
end

function WeatherProfileSystem:rebuildWeatherWeights(weather)
    if not g_currentMission:getIsServer() then return end
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local rainfall = self:getRainfallWeightForMonth(month)
    local scaledWeight = math.max(1, math.floor(rainfall * WeatherProfileSystem.RAINFALL_WEIGHT_SCALE))

    -- weightedWeatherObjects is indexed by season (0-3), each entry is a list of repeated objectIndex values
    -- We rebuild the rain entries proportionally by clearing and re-inserting
    for season = 0, 3 do
        local baseObjects = weather.weatherObjects[season]
        if baseObjects == nil then break end

        local rainWeight = scaledWeight
        local sunWeight = math.max(1, WeatherProfileSystem.RAINFALL_WEIGHT_SCALE - scaledWeight)

        local newWeighted = {}
        for _, obj in ipairs(baseObjects) do
            local wt
            if obj.weatherType == WeatherType.RAIN or obj.weatherType == WeatherType.THUNDER then
                wt = rainWeight
            elseif obj.weatherType == WeatherType.SNOW then
                wt = math.max(1, math.floor(rainWeight * 0.5))
            else
                wt = sunWeight
            end
            for _ = 1, wt do
                table.insert(newWeighted, obj)
            end
        end
        weather.weightedWeatherObjects[season] = newWeighted
    end
end

function WeatherProfileSystem:onPeriodChanged()
    if not g_currentMission:getIsServer() then return end
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    if month == 1 then
        self:selectScenario()
    end
end

function WeatherProfileSystem:selectScenario()
    local profile = self.profiles[self.activeProfileId]
    if not profile or #profile.scenarios == 0 then return end

    local totalWeight = 0
    for _, s in ipairs(profile.scenarios) do
        totalWeight = totalWeight + s.weight
    end

    local roll = math.random() * totalWeight
    local cumulative = 0
    for _, s in ipairs(profile.scenarios) do
        cumulative = cumulative + s.weight
        if roll <= cumulative then
            self.activeScenarioId = s.id
            return
        end
    end
    self.activeScenarioId = profile.scenarios[#profile.scenarios].id
end

function WeatherProfileSystem:getActiveScenario()
    local profile = self.profiles[self.activeProfileId]
    if not profile then return nil end
    for _, s in ipairs(profile.scenarios) do
        if s.id == self.activeScenarioId then return s end
    end
    -- fallback to normal
    for _, s in ipairs(profile.scenarios) do
        if s.id == "normal" then return s end
    end
    return profile.scenarios[1]
end

function WeatherProfileSystem:getClampForMonth(month)
    local scenario = self:getActiveScenario()
    if not scenario then
        return { min = 10, max = 30 }
    end
    local md = scenario.months[month]
    if not md then
        return { min = 10, max = 30 }
    end
    return {
        min = md.moistureMin * WeatherProfileSystem.MOISTURE_CLAMP_SCALE,
        max = md.moistureMax * WeatherProfileSystem.MOISTURE_CLAMP_SCALE,
    }
end

function WeatherProfileSystem:getRainfallWeightForMonth(month)
    local scenario = self:getActiveScenario()
    if not scenario then return 0.5 end
    local md = scenario.months[month]
    if not md then return 0.5 end
    return md.rainfall
end

function WeatherProfileSystem:getTemperatureOffsetsForMonth(month)
    local scenario = self:getActiveScenario()
    if not scenario then return { minOffset = 0, maxOffset = 0 } end
    local md = scenario.months[month]
    if not md then return { minOffset = 0, maxOffset = 0 } end
    return { minOffset = md.tempMinOffset, maxOffset = md.tempMaxOffset }
end

function WeatherProfileSystem:getProfileIds()
    local ids = {}
    for id, _ in pairs(self.profiles) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

function WeatherProfileSystem:getProfileDisplayNames()
    local ids = self:getProfileIds()
    local names = {}
    for _, id in ipairs(ids) do
        table.insert(names, self.profiles[id].displayName)
    end
    return names
end

function WeatherProfileSystem:setActiveProfile(profileId)
    if self.profiles[profileId] then
        self.activeProfileId = profileId
    end
end

function WeatherProfileSystem:loadFromXMLFile(xmlFile, key)
    local profileId = getXMLString(xmlFile, key .. ".weatherProfile#activeProfileId")
    local scenarioId = getXMLString(xmlFile, key .. ".weatherProfile#activeScenarioId")
    if profileId and self.profiles[profileId] then
        self.activeProfileId = profileId
    end
    if scenarioId then
        self.activeScenarioId = scenarioId
    end
end

function WeatherProfileSystem:saveToXMLFile(xmlFile, key)
    setXMLString(xmlFile, key .. ".weatherProfile#activeProfileId", self.activeProfileId)
    setXMLString(xmlFile, key .. ".weatherProfile#activeScenarioId", self.activeScenarioId)
end

-- Console commands

function WeatherProfileSystem:consoleCommandWeatherDebug()
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local scenario = self:getActiveScenario()
    local clamp = self:getClampForMonth(month)
    local rainfall = self:getRainfallWeightForMonth(month)
    local offsets = self:getTemperatureOffsetsForMonth(month)
    local scaledRainfall = math.max(1, math.floor(rainfall * WeatherProfileSystem.RAINFALL_WEIGHT_SCALE))
    local weight = scenario and scenario.weight or 0
    local lines = {
        string.format("Profile:  %s", self.activeProfileId),
        string.format("Scenario: %s (weight %.1f)", self.activeScenarioId, weight),
        string.format("Month:    %d", month),
        string.format("Rainfall: %.2f (raw) | %d (scaled)", rainfall, scaledRainfall),
        string.format("TempOffset: min %+.1f  max %+.1f", offsets.minOffset, offsets.maxOffset),
        string.format("Clamp:    min %.0f%%  max %.0f%%", clamp.min, clamp.max),
    }
    for _, line in ipairs(lines) do print(line) end
    return table.concat(lines, " | ")
end

function WeatherProfileSystem:consoleCommandSetScenario(scenarioId)
    if not scenarioId then return "Usage: msSetScenario <scenarioId>" end
    local profile = self.profiles[self.activeProfileId]
    if not profile then return "No active profile" end
    for _, s in ipairs(profile.scenarios) do
        if s.id == scenarioId then
            self.activeScenarioId = scenarioId
            return string.format("Scenario set to: %s", scenarioId)
        end
    end
    return string.format("Unknown scenario '%s'. Use msListScenarios to see options.", scenarioId)
end

function WeatherProfileSystem:consoleCommandListScenarios()
    local profile = self.profiles[self.activeProfileId]
    if not profile then return "No active profile loaded" end
    local lines = { string.format("Profile: %s (%s)", profile.id, profile.displayName) }
    for _, s in ipairs(profile.scenarios) do
        table.insert(lines, string.format("  %s (weight %.1f)", s.id, s.weight))
    end
    for _, line in ipairs(lines) do print(line) end
    return table.concat(lines, "\n")
end

FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, WeatherProfileSystem.onStartMission)

addModEventListener(WeatherProfileSystem)
