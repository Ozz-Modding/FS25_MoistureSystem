MoistureGuiWeather = {}

local MoistureGuiWeather_mt = Class(MoistureGuiWeather, TabbedMenuFrameElement)

local SEASON_SUFFIXES = {"Spr", "Sum", "Fal", "Win"}
local SEASON_NAMES    = {"moistureSystem_gui_weather_season1",
                         "moistureSystem_gui_weather_season2",
                         "moistureSystem_gui_weather_season3",
                         "moistureSystem_gui_weather_season4"}

function MoistureGuiWeather.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiWeather_mt)
    self.l18n = l18n
    return self
end

function MoistureGuiWeather:initialize()
end

function MoistureGuiWeather:onGuiSetupFinished()
    MoistureGuiWeather:superClass().onGuiSetupFinished(self)
end

function MoistureGuiWeather:onFrameOpen()
    MoistureGuiWeather:superClass().onFrameOpen(self)
    self:updateWeather()
end

function MoistureGuiWeather:onFrameClose()
    MoistureGuiWeather:superClass().onFrameClose(self)
end

function MoistureGuiWeather:updateWeather()
    local wps = g_currentMission and g_currentMission.WeatherProfileSystem
    if not wps then return end

    local envLabel = self["weatherEnvLabel"]
    if envLabel then
        local profileId   = g_currentMission.MoistureSystem.settings.weatherProfile
        local profile     = wps.profiles[profileId]
        local profileName = profile and profile.displayName or profileId
        local scenarioId  = wps.activeScenarioId or "normal"
        envLabel:setText(profileName .. " / " .. scenarioId)
    end

    for i = 0, 2 do
        self:updateForecastPanel(i, wps)
    end
    for i = 1, 3 do
        self:updateHistoryPanel(i, wps)
    end
end

local function fmtPct(v)
    return string.format("%.0f%%", math.max(0, math.min(100, v)))
end

local function fmtDiff(v)
    if v >= 0 then return string.format(" +%.0f%%", v) end
    return string.format(" %.0f%%", v)
end

function MoistureGuiWeather:updateForecastPanel(seasonIndex, wps)
    local pn  = seasonIndex + 1
    local pfx = "fp" .. pn

    local data            = wps:getForecastData(seasonIndex)
    local currentSeasonIdx = wps:getCurrentSeasonIndex()
    local displaySeasonIdx = ((currentSeasonIdx - 1 + seasonIndex) % 4) + 1

    -- Season icon: show only the matching bitmap
    for si, suf in ipairs(SEASON_SUFFIXES) do
        local icon = self[pfx .. suf]
        if icon then icon:setVisible(si == displaySeasonIdx) end
    end

    local titleEl = self[pfx .. "Title"]
    if titleEl then
        titleEl:setText(g_i18n:getText(SEASON_NAMES[displaySeasonIdx]))
    end

    -- Summary row
    local function setSummary(key, grp)
        local pctEl  = self[pfx .. key .. "Pct"]
        local diffEl = self[pfx .. key .. "Diff"]
        if pctEl  then pctEl:setText(fmtPct(data[grp]))             end
        if diffEl then diffEl:setText(fmtDiff(data[grp .. "Diff"])) end
    end
    setSummary("Prec", "precipitation")
    setSummary("Sun",  "sun")
    setSummary("Cld",  "cloudy")

    -- Per-month rows
    for j = 1, 3 do
        local monthData = data.months[j]
        local mp        = pfx .. "M" .. j
        local lblEl     = self[mp .. "Lbl"]
        local precEl    = self[mp .. "Prec"]
        local precDEl   = self[mp .. "PrecD"]
        local sunEl     = self[mp .. "Sun"]
        local sunDEl    = self[mp .. "SunD"]
        local cldEl     = self[mp .. "Cld"]
        local cldDEl    = self[mp .. "CldD"]

        if monthData then
            local label = g_i18n:formatPeriod(MoistureGuiWeather.monthToPeriod(monthData.month), true)
            local alpha = monthData.isActual and 0.5 or 1.0
            if lblEl  then lblEl:setText(label);                                  lblEl:setAlpha(alpha)  end
            if precEl then precEl:setText(fmtPct(monthData.precipitation));       precEl:setAlpha(alpha) end
            if precDEl then precDEl:setText(fmtDiff(monthData.precipitationDiff)); precDEl:setAlpha(alpha) end
            if sunEl  then sunEl:setText(fmtPct(monthData.sun));                  sunEl:setAlpha(alpha)  end
            if sunDEl  then sunDEl:setText(fmtDiff(monthData.sunDiff));           sunDEl:setAlpha(alpha)  end
            if cldEl  then cldEl:setText(fmtPct(monthData.cloudy));               cldEl:setAlpha(alpha)  end
            if cldDEl  then cldDEl:setText(fmtDiff(monthData.cloudyDiff));        cldDEl:setAlpha(alpha)  end
        else
            if lblEl   then lblEl:setText("")   end
            if precEl  then precEl:setText("")  end
            if precDEl then precDEl:setText("") end
            if sunEl   then sunEl:setText("")   end
            if sunDEl  then sunDEl:setText("")  end
            if cldEl   then cldEl:setText("")   end
            if cldDEl  then cldDEl:setText("")  end
        end
    end
end

function MoistureGuiWeather:updateHistoryPanel(yearOffset, wps)
    local pfx = "hp" .. yearOffset

    local data    = wps:getHistoryData(yearOffset)
    local yearEl  = self[pfx .. "Year"]
    local statsEl = self[pfx .. "Stats"]
    local noDataEl = self[pfx .. "NoData"]

    if not data then
        if yearEl   then yearEl:setText("")        end
        if statsEl  then statsEl:setVisible(false) end
        if noDataEl then noDataEl:setVisible(true) end
        return
    end

    if yearEl   then yearEl:setText(tostring(data.year)) end
    if statsEl  then statsEl:setVisible(true)            end
    if noDataEl then noDataEl:setVisible(false)          end

    -- Annual summary
    local function setAnnual(key, grp)
        local pctEl  = self[pfx .. key .. "Pct"]
        local diffEl = self[pfx .. key .. "Diff"]
        if pctEl  then pctEl:setText(fmtPct(data.groups[grp]))       end
        if diffEl then diffEl:setText(fmtDiff(data.diffs[grp]))      end
    end
    setAnnual("Prec", "precipitation")
    setAnnual("Sun",  "sun")
    setAnnual("Cld",  "cloudy")

    -- Per-season rows
    for s = 1, 4 do
        local sp     = pfx .. "S" .. s
        local lblEl  = self[sp .. "Lbl"]
        local precEl = self[sp .. "Prec"]
        local sunEl  = self[sp .. "Sun"]
        local cldEl  = self[sp .. "Cld"]

        local seasonName = g_i18n:getText(SEASON_NAMES[s])
        if lblEl then lblEl:setText(seasonName) end

        if data.seasons and data.seasons[s] then
            local sg = data.seasons[s].groups
            if precEl then precEl:setText(fmtPct(sg.precipitation)) end
            if sunEl  then sunEl:setText(fmtPct(sg.sun))            end
            if cldEl  then cldEl:setText(fmtPct(sg.cloudy))         end
        else
            if precEl then precEl:setText("-") end
            if sunEl  then sunEl:setText("-")  end
            if cldEl  then cldEl:setText("-")  end
        end
    end
end

function MoistureGuiWeather.monthToPeriod(month)
    local p = month - 2
    if p <= 0 then p = p + 12 end
    return p
end
