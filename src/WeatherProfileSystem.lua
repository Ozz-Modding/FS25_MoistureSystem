WeatherProfileSystem = {}

WeatherProfileSystem.modSettingsDir = g_currentModSettingsDirectory

WeatherProfileSystem.TEMPERATURE_OFFSET_SCALE = 1.0
WeatherProfileSystem.MOISTURE_CLAMP_SCALE = 1.0

-- All weather spells are normalized to this duration range (hours). Giving every weather
-- type the SAME duration range is what lets the XML weights map directly to measured time:
-- with equal durations, a type's share of hours == its share of scheduled events == its
-- share of pool copies == its weight. Short, uniform spells also give enough events per
-- (short) month for the ratios to converge. See rebuildWeatherWeights.
--
-- These are the FLOOR values, used verbatim on 1-day-per-period saves (24h/month) where
-- there isn't enough time in the month to afford longer spells without starving the ratio
-- convergence. On longer-day saves, getSpellHoursForMonth scales these up (see below) so
-- players get realistic multi-hour-to-day-long weather stints instead of a 2-5h chop that
-- never leaves a usable window to mow/dry/bale between rain.
WeatherProfileSystem.SPELL_MIN_HOURS = 2
WeatherProfileSystem.SPELL_MAX_HOURS = 5

-- Ceiling on scaled-up spell duration (hours). Even on very long months we cap stints here
-- so a single spell can't swallow most of the month and starve rarer weight categories of
-- any events at all.
WeatherProfileSystem.SPELL_MIN_HOURS_CAP = 12
WeatherProfileSystem.SPELL_MAX_HOURS_CAP = 18

-- Scales spell duration with how many real hours are in the current in-game month
-- (daysPerPeriod * 24). Most players run 3-5 day months; on those, favour long stints
-- (12-18h) so weather-dependent tasks (mowing/drying/baling) get a real window. On 1-day
-- months there's too little time in the month to spend on long spells without losing weight
-- fidelity, so it falls back to the base 2-5h range. Scales linearly in between and is
-- clamped to the floor/ceiling either way.
function WeatherProfileSystem:getSpellHoursForMonth()
    local daysPerPeriod = (g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local minH = math.max(WeatherProfileSystem.SPELL_MIN_HOURS, math.min(WeatherProfileSystem.SPELL_MIN_HOURS_CAP,
        WeatherProfileSystem.SPELL_MIN_HOURS * daysPerPeriod))
    local maxH = math.max(WeatherProfileSystem.SPELL_MAX_HOURS, math.min(WeatherProfileSystem.SPELL_MAX_HOURS_CAP,
        WeatherProfileSystem.SPELL_MAX_HOURS * daysPerPeriod))
    return minH, maxH
end

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

local BUILTIN_PROFILES = {
    "ukwest", "ukeast", "centraleurope", "mediterranean",
    "usmidwest", "uspnw", "eastasia", "brazilcentral", "brazilsouth",
}

function WeatherProfileSystem:loadProfiles()
    -- Files.new/getFiles cannot enumerate inside a zip archive, so built-in profiles
    -- are listed explicitly. The modSettings directory is always on the real filesystem.
    local profileDir = MoistureSystem.dir .. "xml/weatherProfiles/"
    for _, name in ipairs(BUILTIN_PROFILES) do
        self:loadProfileXML(profileDir .. name .. ".xml")
    end

    -- Also load any user-supplied profiles from modSettings (e.g.
    -- .../modSettings/FS25_MoistureSystem/). Files here override built-in
    -- profiles that share the same id, so users can customise without editing
    -- the mod itself.
    local userDir = WeatherProfileSystem.modSettingsDir
    if userDir then
        createFolder(userDir)
        local userFiles = Files.new(userDir)
        for _, entry in pairs(userFiles.files) do
            if not entry.isDirectory and entry.filename:sub(-4) == ".xml" then
                self:loadProfileXML(userDir .. entry.filename)
            end
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
                        tempMin = getXMLFloat(xmlFile, monthXmlKey .. "#tempMin"),
                        tempMax = getXMLFloat(xmlFile, monthXmlKey .. "#tempMax"),
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

    local hasNormal = false
    for _, scenario in ipairs(profile.scenarios) do
        if scenario.id == "normal" then
            hasNormal = true
            break
        end
    end
    if not hasNormal then
        print("[WeatherProfileSystem] Skipping profile '%s' (%s): no 'normal' scenario defined", id, path)
        delete(xmlFile)
        return
    end

    self.profiles[id] = profile
    delete(xmlFile)
end

function WeatherProfileSystem:onStartMission()
    local wps = g_currentMission.WeatherProfileSystem

    -- Inject the missing (winter rain, etc.) weather objects on EVERY peer, including clients.
    -- The server syncs weather instances by bare objectIndex/variationIndex (WeatherInstance:
    -- writeStream) with no type/name negotiation, so the weatherObjects pool must have identical
    -- indices on server and clients. Doing this server-only (as before) meant a client's winter
    -- pool had no rain object at the server's injected index -- when the server scheduled winter
    -- rain (e.g. sleeping into December) the client's getWeatherObjectByIndex returned nil and
    -- crashed on activate(), freezing the HUD. Injection is deterministic (see
    -- injectMissingWeatherObjects) so all peers arrive at the same indices.
    wps:injectMissingWeatherObjects()

    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, WeatherProfileSystem.onPeriodChanged, wps)
        wps:installWeatherOverrides()
        wps.historyCollector:install()
        wps:applyTemperatureToVariations(g_currentMission.environment.weather)
    end
end

-- Shallow+selective deep copy of a weather-object variation. We must NOT share variation
-- tables between the source season's object and the injected winter copy, because we write
-- minTemperature/maxTemperature in place when applying profile temps; sharing would corrupt
-- the source object. Sub-tables (rain/clouds/wind settings) are read-only as far as we're
-- concerned, so they can be shared by reference.
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

    -- Pick the source deterministically: lowest season number first, then the first object of
    -- the type in ipairs order. injectMissingWeatherObjects runs on BOTH server and clients, and
    -- the clone's variations (hence variationIndex space) must be byte-identical on every peer --
    -- WeatherInstance is synced by bare objectIndex/variationIndex with no name negotiation, so a
    -- differing source (different variation count) would make getWeatherObjectByIndex/
    -- getVariationByIndex return nil on the other end and crash on activate(). pairs() order is
    -- not guaranteed stable across peers, so we must sort.
    local sortedSeasons = {}
    for s in pairs(weather.weatherObjects) do table.insert(sortedSeasons, s) end
    table.sort(sortedSeasons)

    local source
    for _, s in ipairs(sortedSeasons) do
        if s ~= season then
            for _, obj in ipairs(weather.weatherObjects[s]) do
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

    -- Sort seasons so the clone/append order is identical on server and clients (see
    -- cloneWeatherObjectInto). Within a season, indices are independent of other seasons, but
    -- keeping the whole pass deterministic avoids any peer-order surprise.
    local sortedSeasons = {}
    for season in pairs(weather.weatherObjects) do table.insert(sortedSeasons, season) end
    table.sort(sortedSeasons)

    for _, season in ipairs(sortedSeasons) do
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
            if instance and instance.startDay and g_currentMission.MoistureSystem.settings.overrideWeather then
                local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
                local temps = g_currentMission.WeatherProfileSystem:getTemperatureForMonth(month)
                local variation = self.variations and self.variations[instance.variationIndex]
                if temps and variation then
                    if temps.tempMin ~= nil then variation.minTemperature = temps.tempMin end
                    if temps.tempMax ~= nil then variation.maxTemperature = temps.tempMax end
                end
            end
            superFunc(self, instance, changeDuration)
        end
    )
end

-- Write profile temperatures onto every variation of every weather object, per season.
-- WeatherForecast reads variation.minTemperature/maxTemperature directly from the object
-- pool (bypassing activate()), so forecast items that haven't activated yet show stale
-- XML values unless we stamp them here. We use a representative middle month per season.
-- The current season uses the active scenario (the year's actual weather character).
-- Other seasons use the normal scenario — they belong to a different year whose scenario
-- hasn't been rolled yet, and normal is the best neutral assumption.
-- The activate() hook still applies the exact current-month temps at the moment of
-- activation, so live and near-term spells stay accurate.
local SEASON_REPR_MONTH = { [1] = 4, [2] = 7, [3] = 10, [4] = 1 }  -- spring/summer/autumn/winter

function WeatherProfileSystem:applyTemperatureToVariations(weather)
    if not g_currentMission.MoistureSystem.settings.overrideWeather then return end
    local currentSeason = g_currentMission.environment.currentVisualSeason
    local normalScenario = self:getNormalScenario()
    for season, objects in pairs(weather.weatherObjects) do
        local month = SEASON_REPR_MONTH[season]
        if month then
            local temps
            if season == currentSeason then
                temps = self:getTemperatureForMonth(month)
            elseif normalScenario then
                local md = normalScenario.months[month]
                if md then temps = { tempMin = md.tempMin, tempMax = md.tempMax } end
            end
            if temps and (temps.tempMin ~= nil or temps.tempMax ~= nil) then
                for _, obj in ipairs(objects) do
                    for _, variation in ipairs(obj.variations or {}) do
                        if temps.tempMin ~= nil then variation.minTemperature = temps.tempMin end
                        if temps.tempMax ~= nil then variation.maxTemperature = temps.tempMax end
                    end
                end
            end
        end
    end
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
    if not g_currentMission.MoistureSystem.settings.overrideWeather then return end
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
    local minH, maxH = self:getSpellHoursForMonth()

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
    local weather = g_currentMission.environment.weather
    weather:rebuild()
    self:applyTemperatureToVariations(weather)
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

-- Fallback moisture clamps used when weather override is disabled. Values are intentionally
-- wider than any individual profile's normal scenario to accommodate map-baked weather variation.
WeatherProfileSystem.FALLBACK_MOISTURE = {
    [1]  = { moistureMin = 12, moistureMax = 50 },
    [2]  = { moistureMin = 12, moistureMax = 48 },
    [3]  = { moistureMin = 9, moistureMax = 42 },
    [4]  = { moistureMin =  7, moistureMax = 36 },
    [5]  = { moistureMin =  5, moistureMax = 32 },
    [6]  = { moistureMin =  4, moistureMax = 28 },
    [7]  = { moistureMin =  3, moistureMax = 28 },
    [8]  = { moistureMin =  3, moistureMax = 26 },
    [9]  = { moistureMin =  5, moistureMax = 30 },
    [10] = { moistureMin =  7, moistureMax = 36 },
    [11] = { moistureMin = 9, moistureMax = 44 },
    [12] = { moistureMin = 12, moistureMax = 50 },
}

function WeatherProfileSystem:getMonthData(month)
    if not g_currentMission.MoistureSystem.settings.overrideWeather then
        return WeatherProfileSystem.FALLBACK_MOISTURE[month]
    end
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

function WeatherProfileSystem:getTemperatureForMonth(month)
    local md = self:getMonthData(month)
    if not md then return {} end
    return { tempMin = md.tempMin, tempMax = md.tempMax }
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
        self:applyTemperatureToVariations(env.weather)
    end
end

-- Reload weather objects from the map's XML, discarding all runtime mutations.
-- Mirrors the engine's gsWeatherReload console command.
function WeatherProfileSystem:reloadWeatherObjects(weather)
    local xmlFile = XMLFile.load("weather", weather.owner.xmlFilename)
    if not xmlFile then return end
    for _, objects in pairs(weather.weatherObjects) do
        for _, obj in ipairs(objects) do
            obj:delete()
        end
    end
    weather.weatherObjects = {}
    weather.rainUpdater:reset()
    weather:load(xmlFile, "environment")
    xmlFile:delete()
end

-- Apply or remove weather override. Called when the setting is toggled from the UI or via
-- network event. Rebuilds the weather pool in the appropriate direction and resets the
-- current forecast so the change takes effect immediately.
function WeatherProfileSystem:applyWeatherOverride(enabled)
    if not g_currentMission:getIsServer() then return end
    local weather = g_currentMission.environment.weather
    if not weather then return end

    if enabled then
        self:injectMissingWeatherObjects()
        local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
        self:rollWeightVariation(month)
        weather:rebuild()
        self:applyTemperatureToVariations(weather)
    else
        self:reloadWeatherObjects(weather)
        weather:updateAvailableWeatherObjects()
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
    local overrideWeather = g_currentMission.MoistureSystem.settings.overrideWeather
    local clamp = self:getClampForMonth(month)
    local lines = {
        string.format("WeatherControl: %s", overrideWeather and "ON" or "OFF"),
        string.format("Month:    %d", month),
        string.format("Clamp:    min %.0f%%  max %.0f%%", clamp.min, clamp.max),
    }
    if overrideWeather then
        local scenario = self:getActiveScenario()
        local temps = self:getTemperatureForMonth(month)
        local md = self:getMonthData(month)
        local weight = scenario and scenario.weight or 0
        table.insert(lines, 1, string.format("Profile:  %s", g_currentMission.MoistureSystem.settings.weatherProfile))
        table.insert(lines, 2, string.format("Scenario: %s (weight %.1f)", self.activeScenarioId, weight))
        table.insert(lines, 3, string.format("NextYear: %s", self.nextYearScenarioId or "none"))
        table.insert(lines, string.format("Weights:  rain=%d thunder=%d snow=%d hail=%d sun=%d partCloud=%d cloudy=%d",
            md and md.rain or 0, md and md.thunder or 0, md and md.snow or 0, md and md.hail or 0,
            md and md.sun or 0, md and md.partlyCloudy or 0, md and md.cloudy or 0))
        table.insert(lines, string.format("Temp: min %s  max %s",
            temps.tempMin ~= nil and string.format("%.1f°C", temps.tempMin) or "engine",
            temps.tempMax ~= nil and string.format("%.1f°C", temps.tempMax) or "engine"))
    else
        table.insert(lines, "(clamp from built-in fallback table; profile/scenario inactive)")
    end
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

-- Re-inject immediately after every Weather:load(...) (map-defined base objects, or a later
-- reloadWeatherObjects() call), not just once from onStartMission. onStartMission fires only
-- after the whole mission -- including the savegame's persisted weather.forecastItems queue --
-- has already loaded. Career loads resolve each forecast instance's objectIndex against
-- whatever the pool contains AT THAT MOMENT; since our injected RAIN/HAIL clones didn't exist
-- yet, any saved instance pointing at one fails to resolve (observed in logs as "WeatherObject
-- 'HAIL' not defined for 'environment.weather.forecast.instance(N)'") and gets replaced with a
-- short regenerated filler -- the "10 minutes left" symptom after every save/load. Hooking
-- Weather.load directly (installed once, at file scope, before any mission ever loads) instead
-- of loadMap/onStartMission guarantees the pool is complete the instant it exists, before any
-- caller -- including forecast resolution -- can act on it. cloneWeatherObjectInto is idempotent
-- (skips types already present), so repeated calls across reloadWeatherObjects() are harmless.
Weather.load = Utils.appendedFunction(Weather.load, function(weather)
    local wps = g_currentMission and g_currentMission.WeatherProfileSystem
    if wps then
        wps:injectMissingWeatherObjects()
    end
end)

addModEventListener(WeatherProfileSystem)
