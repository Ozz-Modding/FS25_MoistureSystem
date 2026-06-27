MoistureGuiWeather = {}

local MoistureGuiWeather_mt = Class(MoistureGuiWeather, TabbedMenuFrameElement)

local SEASON_ICONS = {
    "gui.icon_ingameMenu_calendarSpring",
    "gui.icon_ingameMenu_calendarSummer",
    "gui.icon_ingameMenu_calendarAutumn",
    "gui.icon_ingameMenu_calendarWinter",
}

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
    if v >= 0 then
        return string.format("+%.0f%%", v)
    end
    return string.format("%.0f%%", v)
end

function MoistureGuiWeather:updateForecastPanel(seasonIndex, wps)
    local panel = self["forecastPanel" .. (seasonIndex + 1)]
    if not panel then return end

    local data = wps:getForecastData(seasonIndex)

    local currentSeasonIdx = wps:getCurrentSeasonIndex()
    local displaySeasonIdx = ((currentSeasonIdx - 1 + seasonIndex) % 4) + 1

    if panel.seasonIcon then
        panel.seasonIcon:setImageSlice(nil, SEASON_ICONS[displaySeasonIdx])
    end
    if panel.seasonTitle then
        panel.seasonTitle:setText(g_i18n:getText("moistureSystem_gui_weather_season" .. displaySeasonIdx))
    end

    for _, grp in ipairs({"precipitation", "sun", "cloudy"}) do
        local pctEl  = panel[grp .. "Pct"]
        local diffEl = panel[grp .. "Diff"]
        if pctEl  then pctEl:setText(fmtPct(data[grp]))             end
        if diffEl then diffEl:setText(fmtDiff(data[grp .. "Diff"])) end
    end

    for j = 1, 3 do
        local monthEl   = panel["month" .. j]
        local monthData = data.months[j]
        if monthEl and monthData then
            local label   = g_i18n:formatPeriod(MoistureGuiWeather.monthToPeriod(monthData.month), true)
            local content = string.format("%s  %s / %s / %s",
                label,
                fmtPct(monthData.precipitation),
                fmtPct(monthData.sun),
                fmtPct(monthData.cloudy))
            monthEl:setText(content)
            monthEl:setAlpha(monthData.isActual and 0.5 or 1.0)
        end
    end
end

function MoistureGuiWeather:updateHistoryPanel(yearOffset, wps)
    local panel = self["historyPanel" .. yearOffset]
    if not panel then return end

    local data = wps:getHistoryData(yearOffset)

    local statsBlock  = panel.statsBlock
    local noDataLabel = panel.noDataLabel

    if not data then
        if panel.yearLabel  then panel.yearLabel:setText("")  end
        if statsBlock       then statsBlock:setVisible(false) end
        if noDataLabel      then noDataLabel:setVisible(true) end
        for s = 1, 4 do
            local el = panel["season" .. s .. "Label"]
            if el then el:setText("") end
        end
        return
    end

    if panel.yearLabel then
        panel.yearLabel:setText(tostring(data.year))
    end
    if statsBlock  then statsBlock:setVisible(true)  end
    if noDataLabel then noDataLabel:setVisible(false) end

    local sb = statsBlock or panel
    if sb.precipitationPct  then sb.precipitationPct:setText(fmtPct(data.groups.precipitation))       end
    if sb.precipitationDiff then sb.precipitationDiff:setText(fmtDiff(data.diffs.precipitation))      end
    if sb.sunPct            then sb.sunPct:setText(fmtPct(data.groups.sun))                           end
    if sb.sunDiff           then sb.sunDiff:setText(fmtDiff(data.diffs.sun))                          end
    if sb.cloudyPct         then sb.cloudyPct:setText(fmtPct(data.groups.cloudy))                     end
    if sb.cloudyDiff        then sb.cloudyDiff:setText(fmtDiff(data.diffs.cloudy))                    end

    for s = 1, 4 do
        local el = panel["season" .. s .. "Label"]
        if el then
            local seasonName = g_i18n:getText("moistureSystem_gui_weather_season" .. s)
            if data.seasons and data.seasons[s] then
                local sg = data.seasons[s].groups
                el:setText(string.format("%s: %s / %s / %s",
                    seasonName,
                    fmtPct(sg.precipitation),
                    fmtPct(sg.sun),
                    fmtPct(sg.cloudy)))
            else
                el:setText(seasonName .. ": -")
            end
        end
    end
end

function MoistureGuiWeather.monthToPeriod(month)
    local p = month - 2
    if p <= 0 then p = p + 12 end
    return p
end
