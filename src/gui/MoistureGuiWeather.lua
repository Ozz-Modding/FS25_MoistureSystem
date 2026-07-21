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
        envLabel:setText(profileName)
    end

    local overrideWeather = g_currentMission.MoistureSystem.settings.overrideWeather
    local panelRow = self["forecastPanelRow"]
    local disabledLabel = self["forecastDisabledLabel"]
    if panelRow      then panelRow:setVisible(overrideWeather)      end
    if disabledLabel then disabledLabel:setVisible(not overrideWeather) end

    if overrideWeather then
        for i = 0, 2 do
            self:updateForecastPanel(i, wps)
        end
    end
    for panelIndex = 1, 3 do
        self:updateHistoryPanel(panelIndex, wps)
    end
end

local function fmtDiff(v)
    if v >= 0 then return string.format(" +%.0f%%", v) end
    return string.format(" %.0f%%", v)
end

-- The three weather groups are floats that sum to ~100, but rounding each independently
-- can yield 99% or 101%. Round them together with the largest-remainder method so the
-- displayed integers always sum to exactly 100 (when the inputs do).
local function roundGroupsTo100(precipitation, sun, cloudy)
    local values = { precipitation, sun, cloudy }
    local floors, remainders, sumFloors = {}, {}, 0
    for i, v in ipairs(values) do
        local f = math.floor(v)
        floors[i] = f
        remainders[i] = v - f
        sumFloors = sumFloors + f
    end
    -- Distribute the leftover units to the largest fractional remainders.
    local leftover = math.floor(precipitation + sun + cloudy + 0.5) - sumFloors
    for _ = 1, leftover do
        local bestIdx, bestRem = 1, -1
        for i = 1, 3 do
            if remainders[i] > bestRem then
                bestRem = remainders[i]
                bestIdx = i
            end
        end
        floors[bestIdx] = floors[bestIdx] + 1
        remainders[bestIdx] = -1  -- don't pick the same bucket twice
    end
    return floors[1], floors[2], floors[3]
end

local function fmtPctInt(v)
    return string.format("%d%%", v)
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

    -- Summary row. Round the three groups together so they sum to exactly 100%.
    local precPct, sunPct, cldPct = roundGroupsTo100(data.precipitation, data.sun, data.cloudy)
    local summaryPct = { Prec = precPct, Sun = sunPct, Cld = cldPct }
    local function setSummary(key, grp)
        local pctEl  = self[pfx .. key .. "Pct"]
        local diffEl = self[pfx .. key .. "Diff"]
        if pctEl  then pctEl:setText(fmtPctInt(summaryPct[key]))    end
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
            local mPrec, mSun, mCld = roundGroupsTo100(monthData.precipitation, monthData.sun, monthData.cloudy)
            if lblEl  then lblEl:setText(label);                                  lblEl:setAlpha(alpha)  end
            if precEl then precEl:setText(fmtPctInt(mPrec));                      precEl:setAlpha(alpha) end
            if precDEl then precDEl:setText(fmtDiff(monthData.precipitationDiff)); precDEl:setAlpha(alpha) end
            if sunEl  then sunEl:setText(fmtPctInt(mSun));                        sunEl:setAlpha(alpha)  end
            if sunDEl  then sunDEl:setText(fmtDiff(monthData.sunDiff));           sunDEl:setAlpha(alpha)  end
            if cldEl  then cldEl:setText(fmtPctInt(mCld));                        cldEl:setAlpha(alpha)  end
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

-- panelIndex is the GUI column, 1 (leftmost) to 3 (rightmost). Display oldest-to-newest
-- left-to-right, so the rightmost panel holds the most recently completed year
-- (yearOffset 1). yearOffset = 4 - panelIndex maps panel 3->offset 1, panel 1->offset 3;
-- when fewer than 3 years exist the empty panels fall on the left.
function MoistureGuiWeather:updateHistoryPanel(panelIndex, wps)
    local pfx = "hp" .. panelIndex
    local yearOffset = 4 - panelIndex

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

    if yearEl   then yearEl:setText(string.format(g_i18n:getText("moistureSystem_gui_weather_yearLabel"), data.year)) end
    if statsEl  then statsEl:setVisible(true)            end
    if noDataEl then noDataEl:setVisible(false)          end

    -- Annual summary. Round the three groups together so they sum to exactly 100%.
    local annPrec, annSun, annCld =
        roundGroupsTo100(data.groups.precipitation, data.groups.sun, data.groups.cloudy)
    local annualPct = { Prec = annPrec, Sun = annSun, Cld = annCld }
    local function setAnnual(key, grp)
        local pctEl  = self[pfx .. key .. "Pct"]
        local diffEl = self[pfx .. key .. "Diff"]
        if pctEl  then pctEl:setText(fmtPctInt(annualPct[key]))      end
        if diffEl then diffEl:setText(fmtDiff(data.diffs[grp]))      end
    end
    setAnnual("Prec", "precipitation")
    setAnnual("Sun",  "sun")
    setAnnual("Cld",  "cloudy")

    -- Per-season rows
    for s = 1, 4 do
        local sp      = pfx .. "S" .. s
        local lblEl   = self[sp .. "Lbl"]
        local precEl  = self[sp .. "Prec"]
        local precDEl = self[sp .. "PrecD"]
        local sunEl   = self[sp .. "Sun"]
        local sunDEl  = self[sp .. "SunD"]
        local cldEl   = self[sp .. "Cld"]
        local cldDEl  = self[sp .. "CldD"]

        local seasonName = g_i18n:getText(SEASON_NAMES[s])
        if lblEl then lblEl:setText(seasonName) end

        if data.seasons and data.seasons[s] then
            local sg = data.seasons[s].groups
            local sd = data.seasons[s].diffs
            local sPrec, sSun, sCld = roundGroupsTo100(sg.precipitation, sg.sun, sg.cloudy)
            if precEl  then precEl:setText(fmtPctInt(sPrec))             end
            if precDEl then precDEl:setText(fmtDiff(sd.precipitation))   end
            if sunEl   then sunEl:setText(fmtPctInt(sSun))               end
            if sunDEl  then sunDEl:setText(fmtDiff(sd.sun))              end
            if cldEl   then cldEl:setText(fmtPctInt(sCld))               end
            if cldDEl  then cldDEl:setText(fmtDiff(sd.cloudy))           end
        else
            if precEl  then precEl:setText("-") end
            if precDEl then precDEl:setText("") end
            if sunEl   then sunEl:setText("-")  end
            if sunDEl  then sunDEl:setText("")  end
            if cldEl   then cldEl:setText("-")  end
            if cldDEl  then cldDEl:setText("")  end
        end
    end
end

function MoistureGuiWeather.monthToPeriod(month)
    local p = month - 2
    if p <= 0 then p = p + 12 end
    return p
end
