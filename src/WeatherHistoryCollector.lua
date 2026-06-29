WeatherHistoryCollector = {}

WeatherHistoryCollector.WEATHER_TYPES = {
    rain         = WeatherType.RAIN,
    thunder      = WeatherType.THUNDER,
    snow         = WeatherType.SNOW,
    hail         = WeatherType.HAIL,
    sun          = WeatherType.SUN,
    partlyCloudy = WeatherType.PARTIALLY_CLOUDY,
    cloudy       = WeatherType.CLOUDY,
}

WeatherHistoryCollector.GROUPS = {
    precipitation = {"rain", "thunder", "snow", "hail"},
    sun           = {"sun"},
    cloudy        = {"partlyCloudy", "cloudy"},
}

local GROUP_WEIGHT_KEYS = {
    rain = "precipitation", thunder = "precipitation",
    snow = "precipitation", hail = "precipitation",
    sun = "sun",
    partlyCloudy = "cloudy", cloudy = "cloudy",
}

local function newSeasonBucket()
    local t = {}
    for typeName, _ in pairs(WeatherHistoryCollector.WEATHER_TYPES) do
        t[typeName] = 0
    end
    return t
end

local function computeGroupsFromBucket(bucket)
    local totals = { precipitation = 0, sun = 0, cloudy = 0 }
    local grand = 0
    for groupName, typeNames in pairs(WeatherHistoryCollector.GROUPS) do
        for _, typeName in ipairs(typeNames) do
            local v = bucket[typeName] or 0
            totals[groupName] = totals[groupName] + v
            grand = grand + v
        end
    end
    if grand == 0 then return { precipitation = 0, sun = 0, cloudy = 0 } end
    return {
        precipitation = (totals.precipitation / grand) * 100,
        sun           = (totals.sun           / grand) * 100,
        cloudy        = (totals.cloudy        / grand) * 100,
    }
end

local function normalGroupsForMonths(normalScenario, months)
    if not normalScenario then return { precipitation = 0, sun = 0, cloudy = 0 } end
    local groupSums = { precipitation = 0, sun = 0, cloudy = 0 }
    local grand = 0
    for _, month in ipairs(months) do
        local md = normalScenario.months[month]
        if md then
            for wKey, groupName in pairs(GROUP_WEIGHT_KEYS) do
                local w = md[wKey] or 0
                groupSums[groupName] = groupSums[groupName] + w
                grand = grand + w
            end
        end
    end
    if grand == 0 then return { precipitation = 0, sun = 0, cloudy = 0 } end
    return {
        precipitation = (groupSums.precipitation / grand) * 100,
        sun           = (groupSums.sun           / grand) * 100,
        cloudy        = (groupSums.cloudy        / grand) * 100,
    }
end

local function diffGroups(actual, normal)
    return {
        precipitation = actual.precipitation - normal.precipitation,
        sun           = actual.sun           - normal.sun,
        cloudy        = actual.cloudy        - normal.cloudy,
    }
end

function WeatherHistoryCollector.new()
    local self = setmetatable({}, { __index = WeatherHistoryCollector })
    self.currentSeasonAccumulators = {}
    for s = 1, 4 do
        self.currentSeasonAccumulators[s] = newSeasonBucket()
    end
    self.yearHistory = {}
    return self
end

function WeatherHistoryCollector:install()
    -- Sample the active weather type once per game-hour rather than timing
    -- WeatherObject.activate->deactivate. Those hooks fire back-to-back (sub-second) at
    -- weather transitions and do NOT bracket how long the weather actually persists, so the
    -- old approach filled the buckets with meaningless ~1s slivers. Buckets now count hours;
    -- percentages are unaffected since computeGroupsFromBucket normalizes by the total.
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
end

function WeatherHistoryCollector:onHourChanged()
    if not g_currentMission:getIsServer() then return end

    local weather = g_currentMission.environment.weather

    -- Count the hour by the SCHEDULED weather object type. The weighted scheduler pool
    -- (weightedWeatherObjects, built from the XML weights) is what determines which object
    -- is active, so counting types makes the measured distribution converge on the weights:
    -- 40% rain weight -> ~40% rain objects scheduled -> ~40% rain hours measured.
    --
    -- We deliberately do NOT classify by getRainFallScale(): that value is rain *intensity*,
    -- lerped from the active object's preset and ramped over each transition (see RainUpdater).
    -- A light-rain object can peak near 0.1, so an intensity threshold under/over-counts the
    -- scheduled weather and would never match the weights.
    local reverseMap = WeatherHistoryCollector.TYPE_VALUE_TO_NAME
    if not reverseMap then
        reverseMap = {}
        for typeName, typeValue in pairs(WeatherHistoryCollector.WEATHER_TYPES) do
            reverseMap[typeValue] = typeName
        end
        WeatherHistoryCollector.TYPE_VALUE_TO_NAME = reverseMap
    end

    local weatherType = weather:getCurrentWeatherType()
    local typeName = reverseMap[weatherType]
    if not typeName then return end

    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local seasonIdx = 1
    for i, season in ipairs(WeatherProfileSystem.SEASONS) do
        for _, m in ipairs(season.months) do
            if m == month then seasonIdx = i; break end
        end
    end

    local bucket = self.currentSeasonAccumulators[seasonIdx]
    if bucket then
        bucket[typeName] = (bucket[typeName] or 0) + 1
    end
end

function WeatherHistoryCollector:archiveYear(year, normalScenario)
    -- Annual aggregate by summing all season buckets
    local annualBucket = newSeasonBucket()
    for s = 1, 4 do
        for typeName, seconds in pairs(self.currentSeasonAccumulators[s]) do
            annualBucket[typeName] = (annualBucket[typeName] or 0) + seconds
        end
    end

    local annualGroups = computeGroupsFromBucket(annualBucket)
    local annualNormal = normalGroupsForMonths(normalScenario, {1,2,3,4,5,6,7,8,9,10,11,12})

    -- Per-season
    local seasons = {}
    for s = 1, 4 do
        local seasonMonths = WeatherProfileSystem.SEASONS[s].months
        local sGroups = computeGroupsFromBucket(self.currentSeasonAccumulators[s])
        local sNormal = normalGroupsForMonths(normalScenario, seasonMonths)
        seasons[s] = {
            groups = sGroups,
            diffs  = diffGroups(sGroups, sNormal),
        }
    end

    local entry = {
        year    = year,
        groups  = annualGroups,
        diffs   = diffGroups(annualGroups, annualNormal),
        seasons = seasons,
    }

    table.insert(self.yearHistory, 1, entry)
    if #self.yearHistory > 3 then
        table.remove(self.yearHistory)
    end

    -- Reset accumulators
    for s = 1, 4 do
        self.currentSeasonAccumulators[s] = newSeasonBucket()
    end
end

function WeatherHistoryCollector:getHistoryData(yearOffset)
    return self.yearHistory[yearOffset]
end

function WeatherHistoryCollector:saveToXMLFile(xmlFile, key)
    local base = key .. ".weatherHistory"

    for s = 1, 4 do
        local sKey = string.format("%s.accumulators.season(%d)", base, s - 1)
        for typeName, hours in pairs(self.currentSeasonAccumulators[s]) do
            setXMLFloat(xmlFile, sKey .. "#" .. typeName, hours)
        end
    end

    for i, entry in ipairs(self.yearHistory) do
        local eKey = string.format("%s.year(%d)", base, i - 1)
        setXMLInt(xmlFile, eKey .. "#year", entry.year)
        for groupName, pct in pairs(entry.groups) do
            setXMLFloat(xmlFile, eKey .. ".groups#" .. groupName, pct)
        end
        for groupName, diff in pairs(entry.diffs) do
            setXMLFloat(xmlFile, eKey .. ".diffs#" .. groupName, diff)
        end
        for s = 1, 4 do
            local sKey = string.format("%s.seasons.season(%d)", eKey, s - 1)
            if entry.seasons and entry.seasons[s] then
                for groupName, pct in pairs(entry.seasons[s].groups) do
                    setXMLFloat(xmlFile, sKey .. ".groups#" .. groupName, pct)
                end
                for groupName, diff in pairs(entry.seasons[s].diffs) do
                    setXMLFloat(xmlFile, sKey .. ".diffs#" .. groupName, diff)
                end
            end
        end
    end
end

function WeatherHistoryCollector:loadFromXMLFile(xmlFile, key)
    local base = key .. ".weatherHistory"
    if not hasXMLProperty(xmlFile, base) then return end

    for s = 1, 4 do
        local sKey = string.format("%s.accumulators.season(%d)", base, s - 1)
        if hasXMLProperty(xmlFile, sKey) then
            for typeName, _ in pairs(self.currentSeasonAccumulators[s]) do
                local val = getXMLFloat(xmlFile, sKey .. "#" .. typeName)
                if val then self.currentSeasonAccumulators[s][typeName] = val end
            end
        end
    end

    self.yearHistory = {}
    local i = 0
    while true do
        local eKey = string.format("%s.year(%d)", base, i)
        if not hasXMLProperty(xmlFile, eKey) then break end
        local year = getXMLInt(xmlFile, eKey .. "#year")
        if year then
            local entry = { year = year, groups = {}, diffs = {}, seasons = {} }
            for groupName, _ in pairs(WeatherHistoryCollector.GROUPS) do
                entry.groups[groupName] = getXMLFloat(xmlFile, eKey .. ".groups#" .. groupName) or 0
                entry.diffs[groupName]  = getXMLFloat(xmlFile, eKey .. ".diffs#"  .. groupName) or 0
            end
            for s = 1, 4 do
                local sKey = string.format("%s.seasons.season(%d)", eKey, s - 1)
                if hasXMLProperty(xmlFile, sKey) then
                    entry.seasons[s] = { groups = {}, diffs = {} }
                    for groupName, _ in pairs(WeatherHistoryCollector.GROUPS) do
                        entry.seasons[s].groups[groupName] = getXMLFloat(xmlFile, sKey .. ".groups#" .. groupName) or 0
                        entry.seasons[s].diffs[groupName]  = getXMLFloat(xmlFile, sKey .. ".diffs#"  .. groupName) or 0
                    end
                end
            end
            table.insert(self.yearHistory, entry)
        end
        i = i + 1
    end
end
