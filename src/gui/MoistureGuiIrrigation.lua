---
-- MoistureGuiIrrigation
--
-- The diary IS the page, not a widget on it. Every card is rendered for the
-- currently selected farmland, so the player reads "today is rush, Thursday is
-- list price" off one screen without a click per day.
--
-- This is deliberately a different construction from every other tab in the
-- mod: a dropdown rather than a list for farmland selection, a fixed grid of
-- day cards rather than a SmoothList, and a full re-render of every card
-- whenever the farmland or the amount changes. The list-plus-detail shape of
-- MoistureGuiDrying is the local precedent but the wrong one -- that precedent
-- is for a page whose subject is the list.
---

MoistureGuiIrrigation = {}

local MoistureGuiIrrigation_mt = Class(MoistureGuiIrrigation, TabbedMenuFrameElement)

-- Card slots authored in the XML. The bookable window is at most twelve days
-- per month (FS25's longest month), and the month picker means only one month's
-- worth is ever on screen.
local NUM_DAY_CARDS = 12
local NUM_JOB_ROWS = 8
local BAR_WIDTH_PX = 202

-- How often the page refreshes itself while open, so a job's progress and the
-- diary stay current without closing and reopening the menu.
MoistureGuiIrrigation.REFRESH_INTERVAL = 1000

local COLOUR_CARD_IDLE     = { 0.17, 0.18, 0.15, 1 }
local COLOUR_CARD_SELECTED = { 0.40, 0.60, 0.08, 1 }
local ALPHA_CARD_DIMMED    = 0.45

-- Convert a pixel width the same way FS25 converts XML `px` values, so a
-- Lua-sized bar lines up with the XML-authored track at any resolution.
local function pxToNormX(px)
    return px / g_referenceScreenWidth * g_aspectScaleX
end

function MoistureGuiIrrigation.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiIrrigation_mt)
    self.l18n = l18n
    self.farmlandIds = {}
    self.monthDays = {}
    self.selectedFarmlandId = nil
    self.selectedDay = nil
    self.selectedBoostPp = IrrigationSystem.BOOST_STEP_PP
    self.monthOffset = 0
    self.timeSinceRefresh = 0
    return self
end

function MoistureGuiIrrigation:initialize()
    self.btnBack = {
        inputAction = InputAction.MENU_BACK,
    }
    -- The price rides on the button label rather than in a confirmation dialog.
    -- That is the mitigation, not a nicety: there is no cancellation and no
    -- refund, so the sum has to be inside the click target.
    self.btnBook = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("ms_action_irrigationBook"),
        callback = function() self:onClickBook() end,
        disabled = true,
    }
    self:setMenuButtonInfo({ self.btnBack, self.btnBook })
end

function MoistureGuiIrrigation:onGuiSetupFinished()
    MoistureGuiIrrigation:superClass().onGuiSetupFinished(self)

    -- One shared click callback; the card carries its own slot index.
    self.dayCards = {}
    for i = 1, NUM_DAY_CARDS do
        local card = self["dayCard" .. i]
        if card ~= nil then
            card.irrigationSlot = i
            self.dayCards[i] = card
        end
    end
end

function MoistureGuiIrrigation:onFrameOpen()
    MoistureGuiIrrigation:superClass().onFrameOpen(self)

    local irrigation = g_currentMission.irrigationSystem
    if irrigation ~= nil then
        -- Re-quote whenever the server answers, so a rejection cannot leave a
        -- stale price on the Book button.
        irrigation.onBookResultCallback = function(accepted, reason)
            self:onBookResult(accepted, reason)
        end
    end

    self.timeSinceRefresh = 0
    -- refreshAll rebuilds the farmland list itself; the month list is fixed for
    -- the session, so it only needs building once per open.
    self:rebuildMonthList()
    self:refreshAll()
end

function MoistureGuiIrrigation:onFrameClose()
    local irrigation = g_currentMission.irrigationSystem
    if irrigation ~= nil then
        irrigation.onBookResultCallback = nil
    end
    MoistureGuiIrrigation:superClass().onFrameClose(self)
end

function MoistureGuiIrrigation:update(dt)
    MoistureGuiIrrigation:superClass().update(self, dt)

    self.timeSinceRefresh = self.timeSinceRefresh + dt
    if self.timeSinceRefresh >= MoistureGuiIrrigation.REFRESH_INTERVAL then
        self.timeSinceRefresh = 0
        self:refreshAll()
    end
end

-- ── formatting ───────────────────────────────────────────────────────────────

local function fmtPp(pp)
    return string.format("%s%.1f%%", pp >= 0 and "+" or "", pp)
end

local function fmtMoney(value)
    return g_i18n:formatMoney(math.floor(value + 0.5), 0, true, true)
end

local function fmtHour(hour)
    return string.format("%02d:00", hour)
end

function MoistureGuiIrrigation:getDayLabel(day)
    local offset = day - g_currentMission.irrigationSystem:getToday()
    if offset == 0 then return g_i18n:getText("moistureSystem_gui_irrigation_today") end
    if offset == 1 then return g_i18n:getText("moistureSystem_gui_irrigation_tomorrow") end

    local env = g_currentMission.environment
    local period = env:getPeriodFromDay(day)
    local dayInPeriod = env:getDayInPeriodFromDay(day)
    return string.format("%s %d", g_i18n:formatPeriod(period, true), dayInPeriod)
end

-- ── selectors ────────────────────────────────────────────────────────────────

---
-- Only farmlands this farm owns that actually have a field. Yard and woodland
-- parcels have no getField() and are excluded: there is nothing to irrigate and
-- nothing to price the job on.
---
function MoistureGuiIrrigation:rebuildFarmlandList()
    local farmId = g_currentMission:getFarmId()
    self.farmlandIds = {}

    local texts = {}
    if farmId ~= nil and farmId ~= FarmManager.SPECTATOR_FARM_ID then
        local irrigation = g_currentMission.irrigationSystem
        for _, farmlandId in ipairs(g_farmlandManager:getOwnedFarmlandIdsByFarmId(farmId)) do
            local farmland = g_farmlandManager:getFarmlandById(farmlandId)
            if farmland ~= nil and farmland:getField() ~= nil then
                table.insert(self.farmlandIds, farmlandId)
                local label = string.format("%s - %s", farmland:getName(),
                    g_i18n:formatArea(farmland:getField():getAreaHa(), 1))
                local boost = irrigation ~= nil and irrigation:getBoost(farmlandId) * 100 or 0
                if boost > 0 then
                    label = string.format("%s (%s)", label, fmtPp(boost))
                end
                table.insert(texts, label)
            end
        end
    end

    if #texts == 0 then
        texts = { g_i18n:getText("moistureSystem_gui_irrigation_noFarmlands") }
        self.selectedFarmlandId = nil
    end

    local selectedIndex = 1
    for i, farmlandId in ipairs(self.farmlandIds) do
        if farmlandId == self.selectedFarmlandId then selectedIndex = i end
    end

    -- Rebuilt on every refresh so the per-farmland boost suffix stays current
    -- and a farmland bought or sold with the tab open appears or disappears.
    -- Only push the texts when they actually differ, so the once-a-second
    -- refresh does not fight the player's own arrow presses.
    local signature = table.concat(texts, "|")
    if self.farmlandSelectorSignature ~= signature then
        self.farmlandSelectorSignature = signature
        self.farmlandSelector:setTexts(texts)
    end
    self.farmlandSelector:setState(selectedIndex)
    self.selectedFarmlandId = self.farmlandIds[selectedIndex]
end

function MoistureGuiIrrigation:rebuildMonthList()
    local env = g_currentMission.environment
    local texts = {}
    for offset = 0, IrrigationSystem.BOOKABLE_MONTHS do
        local period = env.currentPeriod + offset
        while period > 12 do period = period - 12 end
        table.insert(texts, g_i18n:formatPeriod(period, false))
    end

    self.monthSelector:setTexts(texts)
    self.monthSelector:setState(self.monthOffset + 1)
end

function MoistureGuiIrrigation:onFarmlandChanged(state)
    self.selectedFarmlandId = self.farmlandIds[state]
    self:refreshAll()
end

function MoistureGuiIrrigation:onMonthChanged(state)
    self.monthOffset = state - 1
    self.selectedDay = nil
    self:refreshAll()
end

function MoistureGuiIrrigation:onAmountChanged(state)
    self.selectedBoostPp = state * IrrigationSystem.BOOST_STEP_PP
    self:refreshQuote()
    self:refreshDayCards()
end

function MoistureGuiIrrigation:onClickDayCard(element)
    local slot = element ~= nil and element.irrigationSlot or nil
    local day = slot ~= nil and self.monthDays[slot] or nil
    if day == nil then return end

    self.selectedDay = day
    self:refreshAll()
end

-- ── rendering ────────────────────────────────────────────────────────────────

function MoistureGuiIrrigation:refreshAll()
    local irrigation = g_currentMission.irrigationSystem
    if irrigation == nil then return end

    self.monthDays = irrigation:getBookableDaysInMonth(self.monthOffset)

    -- Keep the selection inside the month on show; default to the first day.
    local stillVisible = false
    for _, day in ipairs(self.monthDays) do
        if day == self.selectedDay then stillVisible = true end
    end
    if not stillVisible then
        self.selectedDay = self.monthDays[1]
    end

    self:rebuildFarmlandList()
    self:refreshCurrentBoost()
    self:refreshAmountStepper()
    self:refreshDayCards()
    self:refreshQuote()
    self:refreshJobsPanel()
end

function MoistureGuiIrrigation:refreshCurrentBoost()
    local irrigation = g_currentMission.irrigationSystem
    local boost = 0
    if self.selectedFarmlandId ~= nil then
        boost = irrigation:getBoost(self.selectedFarmlandId) * 100
    end
    self.currentBoostValue:setText(string.format(
        g_i18n:getText("moistureSystem_gui_irrigation_currentBoost"), fmtPp(boost)))
end

function MoistureGuiIrrigation:getCeiling()
    local irrigation = g_currentMission.irrigationSystem
    if self.selectedFarmlandId == nil or self.selectedDay == nil then
        return 0, IrrigationSystem.CEILING_CONTRACTOR_HOURS
    end
    return irrigation:getBoostCeiling(self.selectedFarmlandId, self.selectedDay)
end

---
-- An arrow stepper rather than a button row or a slider: the ceiling MOVES as
-- the player moves between days, and the stepper is the only one of the three
-- with no invalid state to render -- it simply stops.
---
function MoistureGuiIrrigation:refreshAmountStepper()
    local step = IrrigationSystem.BOOST_STEP_PP
    local ceiling, reason = self:getCeiling()

    local texts = {}
    local steps = math.floor(ceiling / step + 1e-9)
    for i = 1, steps do
        table.insert(texts, fmtPp(i * step))
    end

    if #texts == 0 then
        self.selectedBoostPp = 0
        if self.amountStepperSteps ~= 0 then
            self.amountStepperSteps = 0
            self.amountStepper:setTexts({ "-" })
        end
        self.amountStepper:setState(1)
        self.amountStepper:setDisabled(true)
        self.amountLimitNote:setText("")
        return
    end

    self.selectedBoostPp = math.min(math.max(self.selectedBoostPp, step), steps * step)
    self.amountStepper:setDisabled(false)
    -- The page refreshes itself once a second; rebuilding the option list every
    -- tick would fight the player's own arrow presses, so only do it when the
    -- ceiling has actually moved.
    if self.amountStepperSteps ~= steps then
        self.amountStepperSteps = steps
        self.amountStepper:setTexts(texts)
    end
    self.amountStepper:setState(math.floor(self.selectedBoostPp / step + 0.5))

    -- Without the cause, a clamped selector looks broken.
    local key = reason == IrrigationSystem.CEILING_BOOST_CAP
        and "moistureSystem_gui_irrigation_limitCap"
        or "moistureSystem_gui_irrigation_limitHours"
    self.amountLimitNote:setText(string.format(g_i18n:getText(key), fmtPp(ceiling)))
end

function MoistureGuiIrrigation:refreshDayCards()
    local irrigation = g_currentMission.irrigationSystem

    for slot = 1, NUM_DAY_CARDS do
        local card = self.dayCards[slot]
        if card ~= nil then
            local day = self.monthDays[slot]
            card:setVisible(day ~= nil)
            if day ~= nil then
                self:renderDayCard(slot, day, irrigation)
            end
        end
    end
end

function MoistureGuiIrrigation:renderDayCard(slot, day, irrigation)
    local prefix = "dayCard" .. slot
    local freeHours = irrigation:getBestFreeHours(day)

    self[prefix .. "Label"]:setText(self:getDayLabel(day))
    self[prefix .. "Hours"]:setText(string.format(
        g_i18n:getText("moistureSystem_gui_irrigation_freeHours"), freeHours))

    -- The bar against daily capacity is what makes the near/far gradient
    -- legible: a row of cards filling left to right IS the commitment curve.
    local fraction = math.min(1, freeHours / IrrigationSystem.DAILY_CAPACITY_H)
    self[prefix .. "BarFill"]:setSize(pxToNormX(math.max(1, BAR_WIDTH_PX * fraction)), nil)

    local ceiling = 0
    if self.selectedFarmlandId ~= nil then
        ceiling = irrigation:getBoostCeiling(self.selectedFarmlandId, day)
    end
    local bookable = ceiling >= IrrigationSystem.BOOST_STEP_PP

    self[prefix .. "Boost"]:setVisible(bookable)
    self[prefix .. "Price"]:setVisible(bookable)
    self[prefix .. "Note"]:setVisible(not bookable)

    if bookable then
        local boostPp = math.min(self.selectedBoostPp, ceiling)
        if boostPp < IrrigationSystem.BOOST_STEP_PP then boostPp = ceiling end
        local quote = irrigation:getQuote(self.selectedFarmlandId, boostPp, day)

        self[prefix .. "Boost"]:setText(string.format(
            g_i18n:getText("moistureSystem_gui_irrigation_upTo"), fmtPp(ceiling)))
        self[prefix .. "Price"]:setText(quote ~= nil and fmtMoney(quote.total) or "")
    else
        -- Dimmed, but the real free-hours figure above still shows. Never a
        -- silent grey-out.
        self[prefix .. "Note"]:setText(g_i18n:getText("moistureSystem_gui_irrigation_unbookableShort"))
    end

    -- Always present, reading "list price" on far days rather than going blank:
    -- a premium shown only when charged reads as a penalty, while a premium
    -- against a stated list price reads as a discount for planning.
    local shortNotice = irrigation:getShortNoticeMultiplier(day - irrigation:getToday())
    if shortNotice > 1.001 then
        self[prefix .. "Premium"]:setText(string.format(
            g_i18n:getText("moistureSystem_gui_irrigation_rush"),
            math.floor((shortNotice - 1) * 100 + 0.5)))
    else
        self[prefix .. "Premium"]:setText(g_i18n:getText("moistureSystem_gui_irrigation_listPrice"))
    end

    local card = self.dayCards[slot]
    card:setAlpha(bookable and 1.0 or ALPHA_CARD_DIMMED)

    local colour = day == self.selectedDay and COLOUR_CARD_SELECTED or COLOUR_CARD_IDLE
    self[prefix .. "Bg"]:setImageColor(nil, colour[1], colour[2], colour[3], colour[4])
end

local QUOTE_LINE_IDS = {
    "quoteWork", "quoteOnSite", "quoteRate", "quoteShortNotice", "quoteCostSetting", "quoteTotal",
}

function MoistureGuiIrrigation:setQuoteLinesVisible(visible)
    for _, id in ipairs(QUOTE_LINE_IDS) do
        self[id .. "Label"]:setVisible(visible)
        self[id .. "Value"]:setVisible(visible)
    end
    self.quoteResult:setVisible(visible)
end

---
-- Both unbookable paths route through here. Keeping them together is the point:
-- when they were separate, the second one left the footer reading
-- "Book - <price>" and clickable over a quote panel that already said the day
-- was unbookable, and the click then did nothing at all.
---
function MoistureGuiIrrigation:showUnbookable(reason)
    self:setQuoteLinesVisible(false)
    self.quoteUnbookable:setVisible(true)
    self.quoteUnbookable:setText(self:getUnbookableReason(reason))
    self.btnBook.disabled = true
    self.btnBook.text = g_i18n:getText("ms_action_irrigationBook")
    self:setMenuButtonInfoDirty()
end

function MoistureGuiIrrigation:refreshQuote()
    local irrigation = g_currentMission.irrigationSystem
    local ceiling, reason = self:getCeiling()

    if self.selectedFarmlandId == nil or self.selectedDay == nil
        or ceiling < IrrigationSystem.BOOST_STEP_PP then
        self:showUnbookable(reason)
        return
    end

    local boostPp = math.min(self.selectedBoostPp, ceiling)
    local quote = irrigation:getQuote(self.selectedFarmlandId, boostPp, self.selectedDay)
    -- No contractor means no start time to show. The ceiling above should make
    -- that unreachable, but the server is the authority on the diary and this
    -- screen can be a network hop behind it.
    if quote ~= nil and quote.contractorIndex == nil then quote = nil end
    if quote == nil then
        self:showUnbookable(IrrigationSystem.CEILING_CONTRACTOR_HOURS)
        return
    end

    self.quoteUnbookable:setVisible(false)
    self:setQuoteLinesVisible(true)

    self.quoteWorkLabel:setText(g_i18n:getText("moistureSystem_gui_irrigation_work"))
    self.quoteWorkValue:setText(string.format("%s %s %s", fmtPp(boostPp),
        g_i18n:getText("moistureSystem_gui_irrigation_over"),
        g_i18n:formatArea(quote.areaHa, 1)))

    self.quoteOnSiteLabel:setText(g_i18n:getText("moistureSystem_gui_irrigation_onSite"))
    self.quoteOnSiteValue:setText(string.format("%s, %s-%s (%dh)",
        self:getDayLabel(self.selectedDay), fmtHour(quote.startHour),
        fmtHour(quote.startHour + quote.hours), quote.hours))

    -- The label changes when the floor binds, so a small field's price stops
    -- looking arbitrary.
    self.quoteRateLabel:setText(g_i18n:getText(quote.minimumApplied
        and "moistureSystem_gui_irrigation_minimumCallout"
        or "moistureSystem_gui_irrigation_contractorRate"))
    self.quoteRateValue:setText(fmtMoney(quote.base))

    local hasPremium = quote.shortNoticeCost > 0.5
    self.quoteShortNoticeLabel:setVisible(hasPremium)
    self.quoteShortNoticeValue:setVisible(hasPremium)
    if hasPremium then
        self.quoteShortNoticeLabel:setText(string.format(
            g_i18n:getText("moistureSystem_gui_irrigation_shortNotice"),
            math.floor((quote.shortNotice - 1) * 100 + 0.5)))
        self.quoteShortNoticeValue:setText(fmtMoney(quote.shortNoticeCost))
    end

    local hasCostSetting = math.abs(quote.costMultiplier - 1.0) > 0.001
    self.quoteCostSettingLabel:setVisible(hasCostSetting)
    self.quoteCostSettingValue:setVisible(hasCostSetting)
    if hasCostSetting then
        self.quoteCostSettingLabel:setText(string.format(
            g_i18n:getText("moistureSystem_gui_irrigation_costSetting"), quote.costMultiplier))
        self.quoteCostSettingValue:setText(fmtMoney(quote.total - quote.base * quote.shortNotice))
    end

    self.quoteTotalLabel:setText(g_i18n:getText("moistureSystem_gui_irrigation_total"))
    self.quoteTotalValue:setText(fmtMoney(quote.total))

    -- What is actually being bought. No shortfall line: there are no partial jobs.
    local current = irrigation:getBoost(self.selectedFarmlandId) * 100
    self.quoteResult:setText(string.format("%s %s %s", fmtPp(current), "->", fmtPp(current + boostPp)))

    self.btnBook.disabled = false
    self.btnBook.text = string.format(g_i18n:getText("ms_action_irrigationBookPrice"), fmtMoney(quote.total))
    self:setMenuButtonInfoDirty()
end

function MoistureGuiIrrigation:getUnbookableReason(reason)
    if self.selectedFarmlandId == nil then
        return g_i18n:getText("moistureSystem_gui_irrigation_noFarmlands")
    end

    local irrigation = g_currentMission.irrigationSystem
    if reason == IrrigationSystem.CEILING_JOB_PENDING then
        return g_i18n:getText("moistureSystem_gui_irrigation_unbookableJobPending")
    end

    if reason == IrrigationSystem.CEILING_BOOST_CAP then
        return string.format(g_i18n:getText("moistureSystem_gui_irrigation_unbookableCap"),
            fmtPp(IrrigationSystem.MAX_BOOST_PP))
    end

    local freeHours = self.selectedDay ~= nil and irrigation:getBestFreeHours(self.selectedDay) or 0
    if freeHours < IrrigationSystem.MIN_JOB_HOURS then
        return string.format(g_i18n:getText("moistureSystem_gui_irrigation_unbookableHours"),
            freeHours, IrrigationSystem.MIN_JOB_HOURS)
    end

    local areaHa = irrigation:getFarmlandAreaHa(self.selectedFarmlandId) or 0
    return string.format(g_i18n:getText("moistureSystem_gui_irrigation_unbookableTooLarge"),
        freeHours, fmtPp(IrrigationSystem.BOOST_STEP_PP), g_i18n:formatArea(areaHa, 1))
end

---
-- Every farmland this farm has a boost or a booked job on. This is the ONLY
-- place the remaining decay time appears, so it is not optional decoration.
---
function MoistureGuiIrrigation:refreshJobsPanel()
    local irrigation = g_currentMission.irrigationSystem
    local farmId = g_currentMission:getFarmId()

    local rows = {}
    for _, farmlandId in ipairs(self.farmlandIds) do
        local farmland = g_farmlandManager:getFarmlandById(farmlandId)
        local job = irrigation.jobs[farmlandId]
        local boost = irrigation:getBoost(farmlandId)

        if farmland ~= nil and (job ~= nil or boost > 0) then
            local value
            if job ~= nil and job.hoursWorked < job.hours then
                value = string.format("%s %s", self:getDayLabel(job.startDay), fmtHour(job.startHour))
            else
                value = string.format("%s %s %s", fmtPp(boost * 100), "-",
                    string.format(g_i18n:getText("moistureSystem_gui_irrigation_daysLeft"),
                        self:getRemainingDays(boost)))
            end
            table.insert(rows, { name = farmland:getName(), value = value })
        end
    end

    for i = 1, NUM_JOB_ROWS do
        local nameEl, valueEl = self["jobRow" .. i .. "Name"], self["jobRow" .. i .. "Value"]
        local row = rows[i]
        nameEl:setVisible(row ~= nil)
        valueEl:setVisible(row ~= nil)
        if row ~= nil then
            nameEl:setText(row.name)
            valueEl:setText(row.value)
        end
    end

    self.jobsEmpty:setVisible(#rows == 0)
    if #rows == 0 then
        self.jobsEmpty:setText(g_i18n:getText("moistureSystem_gui_irrigation_jobsEmpty"))
    end

    -- farmId is read only to keep the panel farm-scoped; other farms' jobs are
    -- never synced in the first place.
    if farmId == FarmManager.SPECTATOR_FARM_ID then
        self.jobsEmpty:setVisible(true)
    end
end

function MoistureGuiIrrigation:getRemainingDays(boostValue)
    local irrigation = g_currentMission.irrigationSystem
    local env = g_currentMission.environment
    local temperature = env.weather.temperatureUpdater.currentTemperature or 20
    local drainPerHour = irrigation:getDrainPpPerHour(temperature, env.daysPerPeriod or 1)
    if drainPerHour <= 0 then return 0 end
    return (boostValue * 100) / drainPerHour / 24
end

-- ── booking ──────────────────────────────────────────────────────────────────

function MoistureGuiIrrigation:onClickBook()
    if self.btnBook.disabled then return end

    local irrigation = g_currentMission.irrigationSystem
    local ceiling = self:getCeiling()
    local boostPp = math.min(self.selectedBoostPp, ceiling)
    if boostPp < IrrigationSystem.BOOST_STEP_PP then return end

    local quote = irrigation:getQuote(self.selectedFarmlandId, boostPp, self.selectedDay)
    if quote == nil then return end

    irrigation:requestBooking(self.selectedFarmlandId, boostPp, self.selectedDay, quote.total)
    self:refreshAll()
end

function MoistureGuiIrrigation:onBookResult(accepted, reason)
    if not accepted then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(MoistureGuiIrrigation.REJECT_TEXTS[reason]
                or "moistureSystem_gui_irrigation_rejectInvalid"))
    end
    -- Re-quote either way: on reject the diary has moved, on accept the hours
    -- have been consumed.
    self:refreshAll()
end

MoistureGuiIrrigation.REJECT_TEXTS = {
    [IrrigationSystem.REJECT_SLOT_TAKEN]         = "moistureSystem_gui_irrigation_rejectSlotTaken",
    [IrrigationSystem.REJECT_INSUFFICIENT_FUNDS] = "moistureSystem_gui_irrigation_rejectFunds",
    [IrrigationSystem.REJECT_NO_PERMISSION]      = "moistureSystem_gui_irrigation_rejectPermission",
    [IrrigationSystem.REJECT_PRICE_CHANGED]      = "moistureSystem_gui_irrigation_rejectPrice",
    [IrrigationSystem.REJECT_INVALID]            = "moistureSystem_gui_irrigation_rejectInvalid",
}
