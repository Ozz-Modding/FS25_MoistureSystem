WeatherProfileSystem = {}

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
                        tempMinOffset = getXMLFloat(xmlFile, mKey .. "#tempMinOffset") or 0,
                        tempMaxOffset = getXMLFloat(xmlFile, mKey .. "#tempMaxOffset") or 0,
                        moistureMin   = getXMLFloat(xmlFile, mKey .. "#moistureMin")   or 10,
                        moistureMax   = getXMLFloat(xmlFile, mKey .. "#moistureMax")   or 30,
                        wRain         = getXMLInt(xmlFile, mKey .. "#wRain")           or 0,
                        wThunder      = getXMLInt(xmlFile, mKey .. "#wThunder")        or 0,
                        wSnow         = getXMLInt(xmlFile, mKey .. "#wSnow")           or 0,
                        wHail         = getXMLInt(xmlFile, mKey .. "#wHail")           or 0,
                        wSun          = getXMLInt(xmlFile, mKey .. "#wSun")            or 1,
                        wPartlyCloudy = getXMLInt(xmlFile, mKey .. "#wPartlyCloudy")   or 1,
                        wCloudy       = getXMLInt(xmlFile, mKey .. "#wCloudy")         or 1,
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

    Weather.updateAvailableWeatherObjects = Utils.appendedFunction(
        Weather.updateAvailableWeatherObjects,
        function(self)
            if g_currentMission and g_currentMission.WeatherProfileSystem then
                g_currentMission.WeatherProfileSystem:rebuildWeatherWeights(self)
            end
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
    local md = self:getMonthData(month)
    if not md then return end

    for season, baseObjects in pairs(weather.weatherObjects) do
        local newWeighted = {}
        for _, obj in ipairs(baseObjects) do
            local wt
            if     obj.weatherType == WeatherType.RAIN             then wt = md.wRain
            elseif obj.weatherType == WeatherType.THUNDER          then wt = md.wThunder
            elseif obj.weatherType == WeatherType.SNOW             then wt = md.wSnow
            elseif obj.weatherType == WeatherType.HAIL             then wt = md.wHail
            elseif obj.weatherType == WeatherType.SUN              then wt = md.wSun
            elseif obj.weatherType == WeatherType.PARTIALLY_CLOUDY then wt = md.wPartlyCloudy
            elseif obj.weatherType == WeatherType.CLOUDY           then wt = md.wCloudy
            else wt = 1
            end
            if wt > 0 then
                for _ = 1, wt do
                    table.insert(newWeighted, obj.index)
                end
            end
        end
        -- Never leave a season's pool empty: getRandomWeatherObjectVariation does
        -- math.random(1, #pool) and would crash on an empty list. Fall back to the
        -- base game's weighting for this season if every type resolved to weight 0.
        if #newWeighted > 0 then
            weather.weightedWeatherObjects[season] = newWeighted
        end
    end
end

function WeatherProfileSystem:onPeriodChanged()
    if not g_currentMission:getIsServer() then return end
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    if month == 1 then
        self:selectScenario()
    end
    g_currentMission.environment.weather:rebuild()
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
    local md = self:getMonthData(month)
    if not md then return { min = 10, max = 30 } end
    return {
        min = md.moistureMin * WeatherProfileSystem.MOISTURE_CLAMP_SCALE,
        max = md.moistureMax * WeatherProfileSystem.MOISTURE_CLAMP_SCALE,
    }
end

function WeatherProfileSystem:getMonthData(month)
    local scenario = self:getActiveScenario()
    if not scenario then return nil end
    return scenario.months[month]
end

function WeatherProfileSystem:getRainfallWeightForMonth(month)
    local md = self:getMonthData(month)
    if not md then return 0 end
    local total = md.wRain + md.wThunder + md.wSnow + md.wHail + md.wSun + md.wPartlyCloudy + md.wCloudy
    if total == 0 then return 0 end
    return (md.wRain + md.wThunder) / total
end

function WeatherProfileSystem:getTemperatureOffsetsForMonth(month)
    local md = self:getMonthData(month)
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
    local offsets = self:getTemperatureOffsetsForMonth(month)
    local md = self:getMonthData(month)
    local weight = scenario and scenario.weight or 0
    local lines = {
        string.format("Profile:  %s", self.activeProfileId),
        string.format("Scenario: %s (weight %.1f)", self.activeScenarioId, weight),
        string.format("Month:    %d", month),
        string.format("Weights:  rain=%d thunder=%d snow=%d hail=%d sun=%d partCloud=%d cloudy=%d",
            md and md.wRain or 0, md and md.wThunder or 0, md and md.wSnow or 0, md and md.wHail or 0,
            md and md.wSun or 0, md and md.wPartlyCloudy or 0, md and md.wCloudy or 0),
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
