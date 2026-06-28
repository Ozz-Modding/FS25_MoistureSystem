WeatherProfileSystem = {}

WeatherProfileSystem.TEMPERATURE_OFFSET_SCALE = 1.0
WeatherProfileSystem.MOISTURE_CLAMP_SCALE = 1.0

WeatherProfileSystem.SEASONS = {
    {months = {3, 4, 5}},
    {months = {6, 7, 8}},
    {months = {9, 10, 11}},
    {months = {12, 1, 2}},
}

local SEASON_START_MONTHS = {[3] = true, [6] = true, [9] = true, [12] = true}

local GROUP_WEIGHT_KEYS = {
    wRain = "precipitation", wThunder = "precipitation",
    wSnow = "precipitation", wHail = "precipitation",
    wSun = "sun",
    wPartlyCloudy = "cloudy", wCloudy = "cloudy",
}

function WeatherProfileSystem:loadMap()
    g_currentMission.WeatherProfileSystem = self
    self.profiles = {}
    self.activeScenarioId = "normal"
    self.nextYearScenarioId = nil
    self.forecastOffsets = nil
    self.historyCollector = WeatherHistoryCollector.new()
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
        wps.historyCollector:install()
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

function WeatherProfileSystem:rollWeightVariation(month)
    local md = self:getMonthData(month)
    if not md or md.wRain == 0 then
        self.weightVariation = nil
        return
    end

    local roll = math.random(3)
    if roll == 1 then
        self.weightVariation = nil
        return
    end

    local pct = 0.08 + math.random() * 0.04
    local delta = math.floor(md.wRain * pct + 0.5)
    if delta == 0 then
        self.weightVariation = nil
        return
    end

    local otherKeys = { "wThunder", "wSnow", "wHail", "wSun", "wPartlyCloudy", "wCloudy" }
    local candidates = {}
    for _, k in ipairs(otherKeys) do
        if roll == 2 then
            if (md[k] or 0) >= delta then
                table.insert(candidates, k)
            end
        else
            table.insert(candidates, k)
        end
    end

    if #candidates == 0 then
        self.weightVariation = nil
        return
    end

    self.weightVariation = {
        direction = roll,
        delta = delta,
        targetKey = candidates[math.random(#candidates)],
    }
end

function WeatherProfileSystem:rebuildWeatherWeights(weather)
    if not g_currentMission:getIsServer() then return end
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local md = self:getMonthData(month)
    if not md then return end

    local weights = {
        wRain         = md.wRain,
        wThunder      = md.wThunder,
        wSnow         = md.wSnow,
        wHail         = md.wHail,
        wSun          = md.wSun,
        wPartlyCloudy = md.wPartlyCloudy,
        wCloudy       = md.wCloudy,
    }
    local v = self.weightVariation
    if v then
        if v.direction == 2 then
            weights.wRain = weights.wRain + v.delta
            weights[v.targetKey] = math.max(0, weights[v.targetKey] - v.delta)
        else
            weights.wRain = math.max(0, weights.wRain - v.delta)
            weights[v.targetKey] = weights[v.targetKey] + v.delta
        end
    end

    local typeToWeight = {
        [WeatherType.RAIN]             = weights.wRain,
        [WeatherType.THUNDER]          = weights.wThunder,
        [WeatherType.SNOW]             = weights.wSnow,
        [WeatherType.HAIL]             = weights.wHail,
        [WeatherType.SUN]              = weights.wSun,
        [WeatherType.PARTIALLY_CLOUDY] = weights.wPartlyCloudy,
        [WeatherType.CLOUDY]           = weights.wCloudy,
    }

    for season, baseObjects in pairs(weather.weatherObjects) do
        local newWeighted = {}
        for _, obj in ipairs(baseObjects) do
            local wt = typeToWeight[obj.weatherType] or 1
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
        self.historyCollector:archiveYear(g_currentMission.environment.currentYear, self:getNormalScenario())
        if self.nextYearScenarioId ~= nil then
            self.activeScenarioId = self.nextYearScenarioId
        end
        self.nextYearScenarioId = nil
        self:selectNextYearScenario()
    elseif month == 9 then
        if self.nextYearScenarioId == nil then
            self:selectNextYearScenario()
        end
    end
    if SEASON_START_MONTHS[month] then
        self:rollForecastOffsets()
    end
    self:rollWeightVariation(month)
    g_currentMission.environment.weather:rebuild()
end

function WeatherProfileSystem:selectScenarioForProfile(profileId)
    local profile = self.profiles[profileId]
    if not profile or #profile.scenarios == 0 then return nil end

    local totalWeight = 0
    for _, s in ipairs(profile.scenarios) do
        totalWeight = totalWeight + s.weight
    end

    local roll = math.random() * totalWeight
    local cumulative = 0
    for _, s in ipairs(profile.scenarios) do
        cumulative = cumulative + s.weight
        if roll <= cumulative then
            return s.id
        end
    end
    return profile.scenarios[#profile.scenarios].id
end

function WeatherProfileSystem:selectNextYearScenario()
    local profileId = g_currentMission.MoistureSystem.settings.weatherProfile
    self.nextYearScenarioId = self:selectScenarioForProfile(profileId)
end

function WeatherProfileSystem:getActiveScenario()
    local profile = self.profiles[g_currentMission.MoistureSystem.settings.weatherProfile]
    if not profile then return nil end
    for _, s in ipairs(profile.scenarios) do
        if s.id == self.activeScenarioId then return s end
    end
    for _, s in ipairs(profile.scenarios) do
        if s.id == "normal" then return s end
    end
    return profile.scenarios[1]
end

function WeatherProfileSystem:getNormalScenario()
    local profile = self.profiles[g_currentMission.MoistureSystem.settings.weatherProfile]
    if not profile then return nil end
    for _, s in ipairs(profile.scenarios) do
        if s.id == "normal" then return s end
    end
    return profile.scenarios[1]
end

function WeatherProfileSystem:getScenarioById(scenarioId)
    local profile = self.profiles[g_currentMission.MoistureSystem.settings.weatherProfile]
    if not profile or not scenarioId then return nil end
    for _, s in ipairs(profile.scenarios) do
        if s.id == scenarioId then return s end
    end
    return nil
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
    if not self.profiles[profileId] then return end
    g_currentMission.MoistureSystem.settings.weatherProfile = profileId
    self.activeScenarioId = "normal"
    self.nextYearScenarioId = nil
    self:selectNextYearScenario()
    self:rollForecastOffsets()
    local env = g_currentMission and g_currentMission.environment
    if env then
        local month = MoistureSystem.periodToMonth(env.currentPeriod)
        self:rollWeightVariation(month)
        env.weather:rebuild()
    end
end

-- Forecast query interface

function WeatherProfileSystem:rollForecastOffsets()
    -- Store as fractions; applied as (normal_value * fraction) in getForecastData so
    -- the absolute swing scales with how much of that weather type normally exists.
    local function jitter(range)
        return {
            precipitation = (math.random() * 2 - 1) * range,
            sun           = (math.random() * 2 - 1) * range,
            cloudy        = (math.random() * 2 - 1) * range,
        }
    end
    -- Ranges: current season ±5%, next ±10%, season after ±20%
    self.forecastOffsets = { jitter(0.05), jitter(0.10), jitter(0.20) }
end

function WeatherProfileSystem:ensureForecastOffsets()
    if not self.forecastOffsets then
        self:rollForecastOffsets()
    end
end

function WeatherProfileSystem:getGroupPercentagesForMonths(scenario, months)
    local groupTotals = { precipitation = 0, sun = 0, cloudy = 0 }
    local grandTotal = 0
    for _, month in ipairs(months) do
        local md = scenario and scenario.months[month]
        if md then
            for wKey, groupName in pairs(GROUP_WEIGHT_KEYS) do
                local w = md[wKey] or 0
                groupTotals[groupName] = groupTotals[groupName] + w
                grandTotal = grandTotal + w
            end
        end
    end
    if grandTotal == 0 then
        return { precipitation = 0, sun = 0, cloudy = 0 }
    end
    return {
        precipitation = (groupTotals.precipitation / grandTotal) * 100,
        sun           = (groupTotals.sun / grandTotal) * 100,
        cloudy        = (groupTotals.cloudy / grandTotal) * 100,
    }
end

function WeatherProfileSystem:getCurrentSeasonIndex()
    local currentMonth = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    for i, season in ipairs(WeatherProfileSystem.SEASONS) do
        for _, m in ipairs(season.months) do
            if m == currentMonth then return i end
        end
    end
    return 1
end

-- Returns forecast data for seasonIndex 0 (current), 1 (next), or 2 (season after).
-- Each month entry: {month, precipitation, sun, cloudy, precipitationDiff, sunDiff, cloudyDiff, isActual}
-- Season aggregate has the same group keys plus jitter applied.
function WeatherProfileSystem:getForecastData(seasonIndex)
    self:ensureForecastOffsets()

    local currentMonth = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local currentSeasonIdx = self:getCurrentSeasonIndex()
    local currentPosInSeason = 1
    for j, m in ipairs(WeatherProfileSystem.SEASONS[currentSeasonIdx].months) do
        if m == currentMonth then
            currentPosInSeason = j
            break
        end
    end

    local targetSeasonIdx = ((currentSeasonIdx - 1 + seasonIndex) % 4) + 1
    local targetMonths = WeatherProfileSystem.SEASONS[targetSeasonIdx].months

    local normalScenario = self:getNormalScenario()
    local activeScenario = self:getActiveScenario()
    local nextYearScenario = self:getScenarioById(self.nextYearScenarioId) or activeScenario

    -- currentMonth >= 3 means January hasn't occurred yet this year; months 1-2 belong to nextYear
    local function scenarioForMonth(month)
        if currentMonth >= 3 and month <= 2 then
            return nextYearScenario
        end
        return activeScenario
    end

    local monthData = {}
    for j, month in ipairs(targetMonths) do
        local scenario = scenarioForMonth(month)
        local groups  = self:getGroupPercentagesForMonths(scenario,       {month})
        local normal  = self:getGroupPercentagesForMonths(normalScenario, {month})
        table.insert(monthData, {
            month             = month,
            isActual          = (seasonIndex == 0) and (j < currentPosInSeason),
            precipitation     = groups.precipitation,
            sun               = groups.sun,
            cloudy            = groups.cloudy,
            precipitationDiff = groups.precipitation - normal.precipitation,
            sunDiff           = groups.sun           - normal.sun,
            cloudyDiff        = groups.cloudy        - normal.cloudy,
        })
    end

    -- Season-level aggregate (average across constituent months)
    local aggG = { precipitation = 0, sun = 0, cloudy = 0 }
    local aggN = { precipitation = 0, sun = 0, cloudy = 0 }
    for _, month in ipairs(targetMonths) do
        local g = self:getGroupPercentagesForMonths(scenarioForMonth(month), {month})
        local n = self:getGroupPercentagesForMonths(normalScenario,          {month})
        for _, grp in ipairs({"precipitation", "sun", "cloudy"}) do
            aggG[grp] = aggG[grp] + g[grp]
            aggN[grp] = aggN[grp] + n[grp]
        end
    end
    local n = #targetMonths
    for _, grp in ipairs({"precipitation", "sun", "cloudy"}) do
        aggG[grp] = aggG[grp] / n
        aggN[grp] = aggN[grp] / n
    end

    -- Apply jitter scaled to the normal baseline: swing = normal_value * fraction.
    -- This keeps small-value groups (e.g. 5% sun) from swinging to zero or negative,
    -- while larger groups (e.g. 55% precipitation) get proportionally larger wobble.
    local offsets = self.forecastOffsets[seasonIndex + 1]
    local jitterPrec = aggN.precipitation * offsets.precipitation
    local jitterSun  = aggN.sun           * offsets.sun
    local jitterCld  = aggN.cloudy        * offsets.cloudy
    return {
        seasonIndex       = seasonIndex,
        seasonDef         = WeatherProfileSystem.SEASONS[targetSeasonIdx],
        months            = monthData,
        precipitation     = aggG.precipitation     + jitterPrec,
        sun               = aggG.sun               + jitterSun,
        cloudy            = aggG.cloudy            + jitterCld,
        precipitationDiff = (aggG.precipitation - aggN.precipitation) + jitterPrec,
        sunDiff           = (aggG.sun           - aggN.sun)           + jitterSun,
        cloudyDiff        = (aggG.cloudy        - aggN.cloudy)        + jitterCld,
    }
end

-- Returns history data for yearOffset 1 (last year), 2, or 3. Returns nil if no data.
function WeatherProfileSystem:getHistoryData(yearOffset)
    return self.historyCollector:getHistoryData(yearOffset)
end

function WeatherProfileSystem:loadFromXMLFile(xmlFile, key)
    local scenarioId = getXMLString(xmlFile, key .. ".weatherProfile#activeScenarioId")
    if scenarioId then
        self.activeScenarioId = scenarioId
    end
    local nextId = getXMLString(xmlFile, key .. ".weatherProfile#nextYearScenarioId")
    if nextId then
        self.nextYearScenarioId = nextId
    end
    if self.nextYearScenarioId == nil then
        self:selectNextYearScenario()
    end

    local offsetsKey = key .. ".forecastOffsets"
    if hasXMLProperty(xmlFile, offsetsKey) then
        local loaded = {}
        for i = 0, 2 do
            local oKey = string.format("%s.season(%d)", offsetsKey, i)
            if hasXMLProperty(xmlFile, oKey) then
                loaded[i + 1] = {
                    precipitation = getXMLFloat(xmlFile, oKey .. "#precipitation") or 0,
                    sun           = getXMLFloat(xmlFile, oKey .. "#sun")           or 0,
                    cloudy        = getXMLFloat(xmlFile, oKey .. "#cloudy")        or 0,
                }
            end
        end
        if #loaded == 3 then
            self.forecastOffsets = loaded
        end
    end

    self.historyCollector:loadFromXMLFile(xmlFile, key)
end

function WeatherProfileSystem:saveToXMLFile(xmlFile, key)
    setXMLString(xmlFile, key .. ".weatherProfile#activeScenarioId", self.activeScenarioId)
    if self.nextYearScenarioId ~= nil then
        setXMLString(xmlFile, key .. ".weatherProfile#nextYearScenarioId", self.nextYearScenarioId)
    end

    if self.forecastOffsets then
        for i, offsets in ipairs(self.forecastOffsets) do
            local oKey = string.format("%s.forecastOffsets.season(%d)", key, i - 1)
            setXMLFloat(xmlFile, oKey .. "#precipitation", offsets.precipitation)
            setXMLFloat(xmlFile, oKey .. "#sun",           offsets.sun)
            setXMLFloat(xmlFile, oKey .. "#cloudy",        offsets.cloudy)
        end
    end

    self.historyCollector:saveToXMLFile(xmlFile, key)
end

function WeatherProfileSystem:writeClientState(streamId)
    streamWriteString(streamId, self.activeScenarioId or "normal")
    streamWriteString(streamId, self.nextYearScenarioId or "")
end

function WeatherProfileSystem:readClientState(streamId)
    self.activeScenarioId = streamReadString(streamId)
    local nextId = streamReadString(streamId)
    self.nextYearScenarioId = nextId ~= "" and nextId or nil
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
        string.format("Profile:  %s", g_currentMission.MoistureSystem.settings.weatherProfile),
        string.format("Scenario: %s (weight %.1f)", self.activeScenarioId, weight),
        string.format("NextYear: %s", self.nextYearScenarioId or "none"),
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
    local profile = self.profiles[g_currentMission.MoistureSystem.settings.weatherProfile]
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
    local profile = self.profiles[g_currentMission.MoistureSystem.settings.weatherProfile]
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
