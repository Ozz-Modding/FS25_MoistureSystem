---
-- MoistureSystem - Calendar Frame
-- Displays monthly moisture ranges from the active WeatherProfileSystem scenario
--

MoistureGuiCalendar = {}

local MoistureGuiCalendar_mt = Class(MoistureGuiCalendar, TabbedMenuFrameElement)

function MoistureGuiCalendar.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiCalendar_mt)
    self.l18n = l18n
    self.monthCells = {}
    return self
end

function MoistureGuiCalendar:initialize()
    -- Initialize frame content here
end

function MoistureGuiCalendar:onGuiSetupFinished()
    MoistureGuiCalendar:superClass().onGuiSetupFinished(self)

    -- Map the month cells for easy access
    for i = 1, 12 do
        self.monthCells[i] = self["month" .. i]
    end

    -- Set month header texts using formatPeriod
    self:setMonthHeaders()
end

---
-- Set the month header texts
---
function MoistureGuiCalendar:setMonthHeaders()
    for month = 1, 12 do
        if self["monthHeader" .. month] then
            self["monthHeader" .. month]:setText(g_i18n:formatPeriod(month, true))
        end
    end
end

function MoistureGuiCalendar:onFrameOpen()
    MoistureGuiCalendar:superClass().onFrameOpen(self)
    self:updateCalendar()
end

function MoistureGuiCalendar:onFrameClose()
    MoistureGuiCalendar:superClass().onFrameClose(self)
end

---
-- Update the calendar display with current environment settings
---
function MoistureGuiCalendar:updateCalendar()
    if not g_currentMission or not g_currentMission.WeatherProfileSystem then
        return
    end

    local wps = g_currentMission.WeatherProfileSystem

    for period = 1, 12 do
        local month = MoistureSystem.periodToMonth(period)
        local clamp = wps:getClampForMonth(month)
        if self.monthCells[period] then
            local rangeText = string.format("%d-%d%%", math.floor(clamp.min), math.floor(clamp.max))
            self.monthCells[period]:setText(rangeText)
        end
    end

    local profile = wps.profiles[wps.activeProfileId]
    local profileName = profile and profile.displayName or wps.activeProfileId
    local scenarioName = wps.activeScenarioId

    if self.environmentLabel then
        self.environmentLabel:setText(string.format("%s / %s", profileName, scenarioName))
    end
end
