MoistureGuiDrying = {}

local MoistureGuiDrying_mt = Class(MoistureGuiDrying, TabbedMenuFrameElement)

-- How often the list is rebuilt while the tab is open, so drying state/ETA stay
-- current without the player needing to close and reopen the menu.
MoistureGuiDrying.REFRESH_INTERVAL = 1000

function MoistureGuiDrying.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiDrying_mt)
    self.l18n = l18n
    self.entries = {}
    self.selectedIndex = nil
    self.lastSelectedUniqueId = nil
    self.timeSinceRefresh = 0
    return self
end

function MoistureGuiDrying:initialize()
    -- Text/callback fall through to MoistureGui's defaultMenuButtonInfoByActions /
    -- defaultButtonActionCallbacks for MENU_BACK, same as other tabs get by default.
    self.btnBack = {
        inputAction = InputAction.MENU_BACK,
    }
    self.btnToggleDrying = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("ms_action_startDrying"),
        callback = function() self:onClickToggleDrying() end,
        disabled = true,
    }
    self:setMenuButtonInfo({ self.btnBack, self.btnToggleDrying })
end

function MoistureGuiDrying:onGuiSetupFinished()
    MoistureGuiDrying:superClass().onGuiSetupFinished(self)

    self.dryingList:setDataSource(self)
    self.dryingList:setDelegate(self)
end

function MoistureGuiDrying:onFrameOpen()
    MoistureGuiDrying:superClass().onFrameOpen(self)
    self.timeSinceRefresh = 0
    self:refreshList()
end

function MoistureGuiDrying:onFrameClose()
    MoistureGuiDrying:superClass().onFrameClose(self)
end

function MoistureGuiDrying:update(dt)
    MoistureGuiDrying:superClass().update(self, dt)

    self.timeSinceRefresh = self.timeSinceRefresh + dt
    if self.timeSinceRefresh >= MoistureGuiDrying.REFRESH_INTERVAL then
        self.timeSinceRefresh = 0
        self:refreshList()
    end
end

function MoistureGuiDrying:getFarmId()
    return g_currentMission:getFarmId()
end

function MoistureGuiDrying:refreshList()
    local dryingSystem = g_currentMission.dryingSystem
    if dryingSystem == nil then return end

    local farmId = self:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        self.entries = {}
    else
        self.entries = dryingSystem:buildDryingListEntries(farmId)
    end

    self.dryingList:reloadData()

    -- Keep the selected row pointing at the same placeable across a rebuild;
    -- fall back to the first row so the toggle button is usable without a manual click.
    local newIndex = nil
    if self.lastSelectedUniqueId then
        for i, entry in ipairs(self.entries) do
            if entry.uniqueId == self.lastSelectedUniqueId then
                newIndex = i
                break
            end
        end
    end
    if newIndex == nil and #self.entries > 0 then
        newIndex = 1
    end

    self.selectedIndex = newIndex
    self.lastSelectedUniqueId = newIndex and self.entries[newIndex].uniqueId or nil
    if self.selectedIndex then
        self.dryingList:setSelectedItem(1, self.selectedIndex)
    end

    self:updateToggleButton()

    local isEmpty = #self.entries == 0
    if self.emptyHint then self.emptyHint:setVisible(isEmpty) end
    if self.dryingList then self.dryingList:setVisible(not isEmpty) end
end

-- ── SmoothList data source ───────────────────────────────────────────────────

function MoistureGuiDrying:getNumberOfSections()
    return 1
end

function MoistureGuiDrying:getNumberOfItemsInSection(list, section)
    return #self.entries
end

function MoistureGuiDrying:getTitleForSectionHeader(list, section)
    return ""
end

local function formatCropStatus(entry)
    if #entry.cropStatuses == 0 then
        return g_i18n:getText("moistureSystem_gui_drying_allIdeal")
    end

    local parts = {}
    for _, status in ipairs(entry.cropStatuses) do
        local name = g_fillTypeManager:getFillTypeByIndex(status.fillTypeIndex)
        name = name and name.title or "?"
        local marker = status.needsDrying and " *" or ""
        table.insert(parts, string.format("%s %d%%%s", name, math.floor(status.moisture * 100 + 0.5), marker))
    end
    return table.concat(parts, ", ")
end

local function formatEta(entry)
    if entry.etaHours == nil then
        return "-"
    elseif entry.etaHours < 10 then
        return string.format("%.1fh", entry.etaHours)
    else
        return string.format("%dh", math.ceil(entry.etaHours))
    end
end

function MoistureGuiDrying:populateCellForItemInSection(list, section, index, cell)
    local entry = self.entries[index]
    if entry == nil then return end

    cell:getAttribute("rowName"):setText(entry.name)
    cell:getAttribute("rowType"):setText(g_i18n:getText(
        entry.isSilo and "moistureSystem_gui_drying_typeSilo" or "moistureSystem_gui_drying_typeShed"))
    cell:getAttribute("rowState"):setText(g_i18n:getText(
        entry.isDrying and "moistureSystem_gui_drying_stateDrying" or "moistureSystem_gui_drying_stateIdle"))
    cell:getAttribute("rowCrops"):setText(formatCropStatus(entry))
    cell:getAttribute("rowEta"):setText(formatEta(entry))
end

function MoistureGuiDrying:onListSelectionChanged(list, section, index)
    self.selectedIndex = index
    local entry = self.entries[index]
    self.lastSelectedUniqueId = entry and entry.uniqueId
    self:updateToggleButton()
end

-- ── Toggle action ─────────────────────────────────────────────────────────────

function MoistureGuiDrying:getSelectedEntry()
    if self.selectedIndex == nil then return nil end
    return self.entries[self.selectedIndex]
end

function MoistureGuiDrying:canToggle(entry)
    if entry == nil then return false end
    return entry.isDrying or g_currentMission.dryingSystem:hasNeedsDrying(entry.cropStatuses)
end

function MoistureGuiDrying:updateToggleButton()
    local entry = self:getSelectedEntry()

    self.btnToggleDrying.text = g_i18n:getText(
        entry ~= nil and entry.isDrying and "ms_action_stopDrying" or "ms_action_startDrying")
    self.btnToggleDrying.disabled = not self:canToggle(entry)
    self:setMenuButtonInfoDirty()
end

function MoistureGuiDrying:onClickToggleDrying()
    local entry = self:getSelectedEntry()
    if entry == nil or not self:canToggle(entry) then return end

    local placeable = entry.placeable
    if g_currentMission:getIsServer() then
        g_currentMission.dryingSystem:toggleDrying(placeable)
    else
        local objectId = NetworkUtil.getObjectId(placeable)
        if objectId ~= nil then
            g_client:getServerConnection():sendEvent(DryingToggleEvent.new(objectId))
        end
    end

    self:refreshList()
end
