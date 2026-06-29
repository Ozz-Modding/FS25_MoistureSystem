WeatherProfileSystem = {}

WeatherProfileSystem.TEMPERATURE_OFFSET_SCALE = 1.0
WeatherProfileSystem.MOISTURE_CLAMP_SCALE = 1.0

-- All weather spells are normalized to this duration range (hours). Giving every weather
-- type the SAME duration range is what lets the XML weights map directly to measured time:
-- with equal durations, a type's share of hours == its share of scheduled events == its
-- share of pool copies == its weight. Short, uniform spells also give enough events per
-- (short) month for the ratios to converge. See rebuildWeatherWeights.
WeatherProfileSystem.SPELL_MIN_HOURS = 2
WeatherProfileSystem.SPELL_MAX_HOURS = 5

WeatherProfileSystem.SEASONS = {
    {months = {3, 4, 5}},
    {months = {6, 7, 8}},
    {months = {9, 10, 11}},
    {months = {12, 1, 2}},
}

local SEASON_START_MONTHS = {[3] = true, [6] = true, [9] = true, [12] = true}

local GROUP_WEIGHT_KEYS = {
    rain = "precipitation", thunder = "precipitation",
    snow = "precipitation", hail = "precipitation",
    sun = "sun",
    partlyCloudy = "cloudy", cloudy = "cloudy",
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
    local files = Files.new(profileDir)
    for _, entry in pairs(files.files) do
        if not entry.isDirectory and entry.filename:sub(-4) == ".xml" then
            self:loadProfileXML(profileDir .. entry.filename)
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

    local scenarioIdx = 0
    while true do
        local scenarioXmlKey = string.format("%s.scenarios.scenario(%d)", profileKey, scenarioIdx)
        if not hasXMLProperty(xmlFile, scenarioXmlKey) then break end

        local scenarioId = getXMLString(xmlFile, scenarioXmlKey .. "#id")
        local weight = getXMLFloat(xmlFile, scenarioXmlKey .. "#weight") or 1
        if scenarioId then
            local scenario = { id = scenarioId, weight = weight, months = {} }
            for m = 1, 12 do
                local monthXmlKey = string.format("%s.month(%d)", scenarioXmlKey, m - 1)
                if hasXMLProperty(xmlFile, monthXmlKey) then
                    local monthId = getXMLInt(xmlFile, monthXmlKey .. "#id") or m
                    scenario.months[monthId] = {
                        tempMinOffset = getXMLFloat(xmlFile, monthXmlKey .. "#tempMinOffset") or 0,
                        tempMaxOffset = getXMLFloat(xmlFile, monthXmlKey .. "#tempMaxOffset") or 0,
                        moistureMin   = getXMLFloat(xmlFile, monthXmlKey .. "#moistureMin")   or 10,
                        moistureMax   = getXMLFloat(xmlFile, monthXmlKey .. "#moistureMax")   or 30,
                        rain         = getXMLInt(xmlFile, monthXmlKey .. "#rain")           or 0,
                        thunder      = getXMLInt(xmlFile, monthXmlKey .. "#thunder")        or 0,
                        snow         = getXMLInt(xmlFile, monthXmlKey .. "#snow")           or 0,
                        hail         = getXMLInt(xmlFile, monthXmlKey .. "#hail")           or 0,
                        sun          = getXMLInt(xmlFile, monthXmlKey .. "#sun")            or 1,
                        partlyCloudy = getXMLInt(xmlFile, monthXmlKey .. "#partlyCloudy")   or 1,
                        cloudy       = getXMLInt(xmlFile, monthXmlKey .. "#cloudy")         or 1,
                    }
                end
            end
            table.insert(profile.scenarios, scenario)
        end
        scenarioIdx = scenarioIdx + 1
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

-- Shallow+selective deep copy of a weather-object variation. We must NOT share variation
-- tables between the source season's object and the injected winter copy, because our
-- WeatherObject.activate hook mutates instance.variation.minTemperature/maxTemperature in
-- place; sharing would corrupt the source object. Sub-tables (rain/clouds/wind settings) are
-- read-only as far as we're concerned, so they can be shared by reference.
local function copyVariation(v)
    local c = {}
    for k, val in pairs(v) do
        c[k] = val
    end
    return c
end

-- Clone a weather object of weatherType into the given season, sourcing variations from an
-- object of that type in another season. Shares the engine's updaters (same references) but
-- deep-copies variation tables so our temperature mutation stays isolated per season. Returns
-- the new object, or nil if no source exists / it's already present.
function WeatherProfileSystem:cloneWeatherObjectInto(weather, season, weatherType)
    local objects = weather.weatherObjects[season]
    local typeMap = weather.typeToWeatherObject[season]
    if not objects or not typeMap then return nil end
    if typeMap[weatherType] then return nil end  -- already present

    local source
    for s, objs in pairs(weather.weatherObjects) do
        if s ~= season then
            for _, obj in ipairs(objs) do
                if obj.weatherType == weatherType then source = obj; break end
            end
        end
        if source then break end
    end
    if not source then return nil end

    -- Build the clone via the SOURCE's own class, not base WeatherObject.new: subclasses
    -- (e.g. WeatherObjectHail) override activate/update/initInstanceData and add instance
    -- fields (destructionArea, perlinPercentage), which a plain object would lack and crash on
    -- activation. source:class() returns the source's members table (its .new constructor).
    local sourceClass = source:class()
    local newObj = sourceClass.new(weatherType, source.cloudUpdater,
        source.temperatureUpdater, source.windUpdater, source.rainUpdater)
    newObj.weight = source.weight or 1
    newObj.variations = {}
    newObj.weightedVariations = {}
    for _, v in ipairs(source.variations or {}) do
        local nv = copyVariation(v)
        table.insert(newObj.variations, nv)
        nv.index = #newObj.variations
        for _ = 1, (nv.weight or 1) do
            table.insert(newObj.weightedVariations, nv.index)
        end
    end

    table.insert(objects, newObj)
    newObj.index = #objects
    newObj.season = season
    typeMap[weatherType] = newObj
    return newObj
end

-- FS25's base map doesn't author RAIN or HAIL weather objects for every season (winter has no
-- rain; hail exists only in spring). Profiles legitimately assign rain/hail in those seasons
-- (UK winter rain, hail across the year), so without an object that weight is unschedulable.
-- The engine permits these objects in any season (isRainAllowed is true during load) -- they
-- simply aren't authored -- so we clone real RAIN and HAIL objects into every season missing
-- them. After this, rain/hail schedule genuine weather instead of redirecting to a fallback.
function WeatherProfileSystem:injectMissingWeatherObjects()
    local weather = g_currentMission.environment.weather
    if not weather or not weather.weatherObjects then return end

    for season in pairs(weather.weatherObjects) do
        for _, wt in ipairs({ WeatherType.RAIN, WeatherType.HAIL }) do
            self:cloneWeatherObjectInto(weather, season, wt)
        end
    end
end

function WeatherProfileSystem:installWeatherOverrides()
    local weather = g_currentMission.environment.weather

    self:injectMissingWeatherObjects()

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
    if not md or md.rain == 0 then
        self.weightVariation = nil
        return
    end

    local roll = math.random(3)
    if roll == 1 then
        self.weightVariation = nil
        return
    end

    local swingFraction = 0.08 + math.random() * 0.04
    local delta = math.floor(md.rain * swingFraction + 0.5)
    if delta == 0 then
        self.weightVariation = nil
        return
    end

    local otherKeys = { "thunder", "snow", "hail", "sun", "partlyCloudy", "cloudy" }
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
        increaseRain = (roll == 2),
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
        rain         = md.rain,
        thunder      = md.thunder,
        snow         = md.snow,
        hail         = md.hail,
        sun          = md.sun,
        partlyCloudy = md.partlyCloudy,
        cloudy       = md.cloudy,
    }
    local variation = self.weightVariation
    if variation then
        if variation.increaseRain then
            weights.rain = weights.rain + variation.delta
            weights[variation.targetKey] = math.max(0, weights[variation.targetKey] - variation.delta)
        else
            weights.rain = math.max(0, weights.rain - variation.delta)
            weights[variation.targetKey] = weights[variation.targetKey] + variation.delta
        end
    end

    local typeToWeight = {
        [WeatherType.RAIN]             = weights.rain,
        [WeatherType.THUNDER]          = weights.thunder,
        [WeatherType.SNOW]             = weights.snow,
        [WeatherType.HAIL]             = weights.hail,
        [WeatherType.SUN]              = weights.sun,
        [WeatherType.PARTIALLY_CLOUDY] = weights.partlyCloudy,
        [WeatherType.CLOUDY]           = weights.cloudy,
    }

    -- Fallback chains: a weather type may have NO object in a given engine season (e.g. FS25
    -- winter has no RAIN or HAIL object -- winter precipitation is snow). Weight assigned to a
    -- type with no object would silently vanish, under-reporting that season. So any such
    -- weight is redirected to the first available type in its chain. Precip redirects to precip
    -- (rain<->snow<->hail) so the precipitation SHARE is preserved regardless of which precip
    -- object the season actually has. This makes profiles authored with rain in winter (ours
    -- or third-party) still produce winter precipitation.
    local FALLBACK_CHAINS = {
        [WeatherType.RAIN]             = { WeatherType.SNOW, WeatherType.HAIL },
        [WeatherType.THUNDER]          = { WeatherType.RAIN, WeatherType.SNOW, WeatherType.HAIL },
        [WeatherType.HAIL]             = { WeatherType.RAIN, WeatherType.SNOW },
        [WeatherType.SNOW]             = { WeatherType.RAIN, WeatherType.HAIL },
        [WeatherType.PARTIALLY_CLOUDY] = { WeatherType.CLOUDY },
        [WeatherType.CLOUDY]           = { WeatherType.PARTIALLY_CLOUDY },
        [WeatherType.SUN]              = {},
    }

    -- The scheduler picks an object from the weighted pool (frequency proportional to its
    -- pool copies), then runs it for a random minHours..maxHours taken from that object's
    -- variation. So measured HOURS of a type == poolShare(type) * avgDuration(type). The
    -- base game gives different types wildly different durations (long sun spells, short rain
    -- spells), which skews hours away from the weights. We neutralize that by forcing EVERY
    -- variation to the same duration range, so avgDuration is identical across types and
    -- cancels out: hours(type) becomes proportional to poolShare(type) == weight(type).
    -- With equal durations, pool copies are just the (redirected) weight.
    local minH = WeatherProfileSystem.SPELL_MIN_HOURS
    local maxH = WeatherProfileSystem.SPELL_MAX_HOURS

    for season, baseObjects in pairs(weather.weatherObjects) do
        -- First pass: normalize durations and record which weather types this season can schedule.
        local available = {}
        for _, obj in ipairs(baseObjects) do
            available[obj.weatherType] = true
            if obj.variations then
                for _, v in ipairs(obj.variations) do
                    v.minHours = minH
                    v.maxHours = maxH
                end
            end
        end

        -- Resolve each weighted type to an available type, redirecting via the fallback chain
        -- when its own object is missing. Weight with no available target is simply not added.
        local effectiveWeight = {}
        for wt, w in pairs(typeToWeight) do
            if w > 0 then
                local target = available[wt] and wt or nil
                if not target then
                    for _, alt in ipairs(FALLBACK_CHAINS[wt] or {}) do
                        if available[alt] then target = alt; break end
                    end
                end
                if target then
                    effectiveWeight[target] = (effectiveWeight[target] or 0) + w
                end
            end
        end

        local newWeighted = {}
        for _, obj in ipairs(baseObjects) do
            local weight = effectiveWeight[obj.weatherType] or 0
            if weight > 0 then
                for _ = 1, weight do
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

    -- Archive the just-completed agricultural year at the start of March (the FS25 year
    -- boundary). Running the reporting year March->February keeps the winter bucket
    -- (Dec/Jan/Feb) contiguous and complete before the accumulators reset; archiving in
    -- January instead would capture only December and split the rest into the next record.
    -- The completed year is labelled currentYear-1 since its growing season is the prior year.
    if month == 3 then
        self.historyCollector:archiveYear(g_currentMission.environment.currentYear - 1, self:getNormalScenario())
    end

    if month == 1 then
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
    local total = md.rain + md.thunder + md.snow + md.hail + md.sun + md.partlyCloudy + md.cloudy
    if total == 0 then return 0 end
    return (md.rain + md.thunder) / total
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
    -- Each forecast season holds one independent offset triple per constituent month, so
    -- the three months in a season show different forecast error rather than a shared bias.
    local function jitter(range)
        return {
            precipitation = (math.random() * 2 - 1) * range,
            sun           = (math.random() * 2 - 1) * range,
            cloudy        = (math.random() * 2 - 1) * range,
        }
    end
    local function seasonOffsets(range)
        local months = {}
        for m = 1, 3 do
            months[m] = jitter(range)
        end
        return months
    end
    -- Ranges: current season ±5%, next ±10%, season after ±20%
    self.forecastOffsets = { seasonOffsets(0.05), seasonOffsets(0.10), seasonOffsets(0.20) }
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

    -- Apply jitter per month, scaled to that month's normal baseline: swing = normal * fraction.
    -- Scaling to the baseline keeps small-value groups (e.g. 5% sun) from swinging to zero or
    -- negative, while larger groups (e.g. 55% precipitation) get proportionally larger wobble.
    local seasonOffsets = self.forecastOffsets[seasonIndex + 1]

    local monthData = {}
    -- The season summary is a roll-up of the per-month values (their average), not an
    -- independent computation, so the summary diff equals the mean of the per-month diffs.
    local jitteredAvg = { precipitation = 0, sun = 0, cloudy = 0 }
    local normalAvg   = { precipitation = 0, sun = 0, cloudy = 0 }

    for j, month in ipairs(targetMonths) do
        local scenario = scenarioForMonth(month)
        local groups  = self:getGroupPercentagesForMonths(scenario,       {month})
        local normal  = self:getGroupPercentagesForMonths(normalScenario, {month})
        local offsets = seasonOffsets[j] or { precipitation = 0, sun = 0, cloudy = 0 }

        local precipPct = math.max(0, groups.precipitation + normal.precipitation * offsets.precipitation)
        local sunPct    = math.max(0, groups.sun           + normal.sun           * offsets.sun)
        local cloudyPct = math.max(0, groups.cloudy        + normal.cloudy        * offsets.cloudy)
        -- Renormalize so the three groups still sum to 100 after independent jitter.
        local total = precipPct + sunPct + cloudyPct
        if total > 0 then
            precipPct = (precipPct / total) * 100
            sunPct    = (sunPct    / total) * 100
            cloudyPct = (cloudyPct / total) * 100
        end

        table.insert(monthData, {
            month             = month,
            isActual          = (seasonIndex == 0) and (j < currentPosInSeason),
            precipitation     = precipPct,
            sun               = sunPct,
            cloudy            = cloudyPct,
            precipitationDiff = precipPct - normal.precipitation,
            sunDiff           = sunPct    - normal.sun,
            cloudyDiff        = cloudyPct - normal.cloudy,
        })

        jitteredAvg.precipitation = jitteredAvg.precipitation + precipPct
        jitteredAvg.sun           = jitteredAvg.sun           + sunPct
        jitteredAvg.cloudy        = jitteredAvg.cloudy        + cloudyPct
        normalAvg.precipitation   = normalAvg.precipitation   + normal.precipitation
        normalAvg.sun             = normalAvg.sun             + normal.sun
        normalAvg.cloudy          = normalAvg.cloudy          + normal.cloudy
    end

    local monthCount = #targetMonths
    for _, grp in ipairs({"precipitation", "sun", "cloudy"}) do
        jitteredAvg[grp] = jitteredAvg[grp] / monthCount
        normalAvg[grp]   = normalAvg[grp]   / monthCount
    end

    return {
        seasonIndex       = seasonIndex,
        seasonDef         = WeatherProfileSystem.SEASONS[targetSeasonIdx],
        months            = monthData,
        precipitation     = jitteredAvg.precipitation,
        sun               = jitteredAvg.sun,
        cloudy            = jitteredAvg.cloudy,
        precipitationDiff = jitteredAvg.precipitation - normalAvg.precipitation,
        sunDiff           = jitteredAvg.sun           - normalAvg.sun,
        cloudyDiff        = jitteredAvg.cloudy        - normalAvg.cloudy,
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

    -- Per-month forecast offsets: 3 seasons x 3 months. Saves from the older one-triple-per-
    -- season format won't have the month nodes, so we leave forecastOffsets nil and let
    -- ensureForecastOffsets reroll in the new shape on first use.
    local offsetsKey = key .. ".forecastOffsets"
    if hasXMLProperty(xmlFile, offsetsKey) then
        local loaded = {}
        for i = 0, 2 do
            local seasonKey = string.format("%s.season(%d)", offsetsKey, i)
            if hasXMLProperty(xmlFile, seasonKey) then
                local months = {}
                for m = 0, 2 do
                    local monthKey = string.format("%s.month(%d)", seasonKey, m)
                    if hasXMLProperty(xmlFile, monthKey) then
                        months[m + 1] = {
                            precipitation = getXMLFloat(xmlFile, monthKey .. "#precipitation") or 0,
                            sun           = getXMLFloat(xmlFile, monthKey .. "#sun")           or 0,
                            cloudy        = getXMLFloat(xmlFile, monthKey .. "#cloudy")        or 0,
                        }
                    end
                end
                if #months == 3 then
                    loaded[i + 1] = months
                end
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
        for i, seasonOffsets in ipairs(self.forecastOffsets) do
            for m, offsets in ipairs(seasonOffsets) do
                local monthKey = string.format("%s.forecastOffsets.season(%d).month(%d)", key, i - 1, m - 1)
                setXMLFloat(xmlFile, monthKey .. "#precipitation", offsets.precipitation)
                setXMLFloat(xmlFile, monthKey .. "#sun",           offsets.sun)
                setXMLFloat(xmlFile, monthKey .. "#cloudy",        offsets.cloudy)
            end
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
            md and md.rain or 0, md and md.thunder or 0, md and md.snow or 0, md and md.hail or 0,
            md and md.sun or 0, md and md.partlyCloudy or 0, md and md.cloudy or 0),
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
