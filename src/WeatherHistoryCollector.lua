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
    wRain = "precipitation", wThunder = "precipitation",
    wSnow = "precipitation", wHail = "precipitation",
    wSun = "sun",
    wPartlyCloudy = "cloudy", wCloudy = "cloudy",
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
    self.currentWeatherType = nil
    self.currentWeatherSeason = nil
    self.currentWeatherStartTime = nil
    self.yearHistory = {}
    return self
end

function WeatherHistoryCollector:install()
    local reverseMap = {}
    for typeName, typeValue in pairs(WeatherHistoryCollector.WEATHER_TYPES) do
        reverseMap[typeValue] = typeName
    end

    local collector = self

    WeatherObject.activate = Utils.appendedFunction(
        WeatherObject.activate,
        function(self, instance, changeDuration)
            local typeName = reverseMap[self.weatherType]
            if typeName then
                local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
                local seasonIdx = 1
                for i, season in ipairs(WeatherProfileSystem.SEASONS) do
                    for _, m in ipairs(season.months) do
                        if m == month then seasonIdx = i; break end
                    end
                end
                collector.currentWeatherType = typeName
                collector.currentWeatherSeason = seasonIdx
                collector.currentWeatherStartTime = g_currentMission.time
            end
        end
    )

    WeatherObject.deactivate = Utils.appendedFunction(
        WeatherObject.deactivate,
        function(self, changeDuration)
            local typeName = collector.currentWeatherType
            local seasonIdx = collector.currentWeatherSeason
            if typeName and seasonIdx and collector.currentWeatherStartTime then
                local elapsed = (g_currentMission.time - collector.currentWeatherStartTime) / 1000
                if elapsed > 0 then
                    local bucket = collector.currentSeasonAccumulators[seasonIdx]
                    if bucket then
                        bucket[typeName] = (bucket[typeName] or 0) + elapsed
                    end
                end
            end
            collector.currentWeatherType = nil
            collector.currentWeatherSeason = nil
            collector.currentWeatherStartTime = nil
        end
    )
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
    self.currentWeatherType = nil
    self.currentWeatherSeason = nil
    self.currentWeatherStartTime = nil
end

function WeatherHistoryCollector:getHistoryData(yearOffset)
    return self.yearHistory[yearOffset]
end

function WeatherHistoryCollector:saveToXMLFile(xmlFile, key)
    local base = key .. ".weatherHistory"

    for s = 1, 4 do
        local sKey = string.format("%s.accumulators.season(%d)", base, s - 1)
        for typeName, seconds in pairs(self.currentSeasonAccumulators[s]) do
            setXMLFloat(xmlFile, sKey .. "#" .. typeName, seconds)
        end
    end

    if self.currentWeatherType   then setXMLString(xmlFile, base .. ".current#weatherType",   self.currentWeatherType)   end
    if self.currentWeatherSeason then setXMLInt(xmlFile,    base .. ".current#weatherSeason",  self.currentWeatherSeason) end
    if self.currentWeatherStartTime then setXMLFloat(xmlFile, base .. ".current#startTime",    self.currentWeatherStartTime) end

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

    local wt = getXMLString(xmlFile, base .. ".current#weatherType")
    if wt then self.currentWeatherType = wt end
    local ws = getXMLInt(xmlFile, base .. ".current#weatherSeason")
    if ws then self.currentWeatherSeason = ws end
    local st = getXMLFloat(xmlFile, base .. ".current#startTime")
    if st then self.currentWeatherStartTime = st end

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
