---
-- PlayerHUDUpdateExtension
-- Extends PlayerHUDUpdater to display moisture information for fields and filltype piles
---

MSPlayerHUDExtension = {}

---
-- Hook into PlayerInputComponent to track where the player is looking for filltype detection
-- This ensures setCurrentRaycastFillTypeCoords is called with the player's look ray
---
function MSPlayerHUDExtension:updatePlayerInput()
    if not self.player.isOwner or g_inputBinding:getContextName() ~= PlayerInputComponent.INPUT_CONTEXT_NAME then
        return
    end

    local x, y, z, dirX, dirY, dirZ = self.player:getLookRay()

    if x == nil or y == nil or z == nil or dirX == nil or dirY == nil or dirZ == nil then
        return
    end

    self.player.hudUpdater:setCurrentRaycastFillTypeCoords(x, y, z, dirX, dirY, dirZ)
end

PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, MSPlayerHUDExtension.updatePlayerInput)

---
-- Appended to getFillLevelInformation to show moisture and grade on vehicle fill level HUD
-- After the original chain populates fillLevelData, we update infoText for fill types with moisture data
-- Result: "Wheat (12.1% D) ——— 78%" instead of "Wheat ——— 78%"
-- Note: receives (self, superFunc, display) because FillUnit is in a SpecializationUtil overwrite chain
---
function MSPlayerHUDExtension:getFillLevelInformationAppended(_, display)
    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil or self.uniqueId == nil then
        return
    end

    if display == nil or display.fillLevelData == nil then
        return
    end

    moistureSystem:ensureObjectMoistureLoaded(self)
    local objectData = moistureSystem.objectInfo[self.uniqueId]
    if objectData == nil then
        return
    end

    for _, data in ipairs(display.fillLevelData) do
        if data.isValid and data.fillType ~= nil and data.fillType ~= FillType.UNKNOWN then
            local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(data.fillType)
            if fillTypeName ~= nil then
                local infoEntry = objectData[fillTypeName]
                if infoEntry ~= nil then
                    local moistureText = MSPlayerHUDExtension.formatMoistureInfoText(data.fillType, infoEntry.moisture, infoEntry.quality)
                    if moistureText ~= nil then
                        if data.infoText ~= nil then
                            data.infoText = moistureText .. " " .. data.infoText
                        else
                            data.infoText = moistureText
                        end
                    end
                end
            end
        end
    end
end

FillUnit.getFillLevelInformation = Utils.appendedFunction(
    FillUnit.getFillLevelInformation,
    MSPlayerHUDExtension.getFillLevelInformationAppended
)

---
-- Format moisture info text for the fill level HUD (compact format)
-- @param fillTypeIndex: The filltype index
-- @param moisture: Moisture value (0-1 scale)
-- @return Formatted string like "12.1% D" or "12.1%" for non-graded types, or nil
---
function MSPlayerHUDExtension.formatMoistureInfoText(_, moisture, quality)
    if moisture == nil then
        return nil
    end

    local moistureText = string.format("%.1f%%", moisture * 100)
    if quality ~= nil then
        moistureText = moistureText .. " | " .. string.format("%d%%", math.floor(quality))
    end

    return moistureText
end

---
-- Format moisture value with grade for display
-- @param fillTypeIndex: The filltype index
-- @param moisture: Moisture value (0-1 scale)
-- @return Formatted string with moisture percentage and grade if applicable
---
function MSPlayerHUDExtension.formatMoistureText(moisture)
    return string.format("%.1f%%", moisture * 100)
end

function MSPlayerHUDExtension.formatQualityText(quality)
    if quality == nil then return nil end
    return string.format("%d%%", math.floor(quality))
end

---
-- Show field moisture information when standing on a field
-- Appended to PlayerHUDUpdater.showFieldInfo
---
function MSPlayerHUDExtension:showFieldInfo(x, z)
    -- Initialize box on first use
    if self.moistureBox == nil then
        self.moistureBox = g_currentMission.hud.infoDisplay:createBox(InfoDisplayKeyValueBox)
    end

    local box = self.moistureBox
    if box == nil then return end

    box:clear()

    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then return end

    -- Only show if we're on farmable ground
    if self.fieldInfo.groundType == FieldGroundType.NONE then return end

    box:setTitle(g_i18n:getText("moistureSystem_fieldInfo"))

    -- Get current month for clamp ranges
    local currentMonth = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local environment = moistureSystem.settings.environment
    local clamp = MoistureClamp.Environments[environment].Months[currentMonth]

    -- Show expected range for this month/environment
    box:addLine(
        g_i18n:getText("moistureSystem_range"),
        string.format("%.0f%% - %.0f%%", clamp.Min, clamp.Max)
    )

    -- Show actual field moisture if setting is enabled
    if moistureSystem.settings.showFieldMoisture then
        local fieldMoisture = moistureSystem:getMoistureAtPosition(x, z)
        box:addLine(
            g_i18n:getText("moistureSystem_fieldInfo"),
            string.format("%.1f%%", fieldMoisture * 100)
        )
    end

    box:showNextFrame()
end

PlayerHUDUpdater.showFieldInfo = Utils.appendedFunction(PlayerHUDUpdater.showFieldInfo,
    MSPlayerHUDExtension.showFieldInfo)

---
-- Track raycast position for filltype lookup
---
function MSPlayerHUDExtension:setCurrentRaycastFillTypeCoords(x, y, z, dirX, dirY, dirZ)
    if x == nil or y == nil or z == nil then
        self.currentRaycastFillTypeCoords = nil
        return
    end

    -- Only update if coordinates changed
    if self.currentRaycastFillTypeCoords ~= nil then
        local curX, curY, curZ = unpack(self.currentRaycastFillTypeCoords)
        if curX == x and curY == y and curZ == z then
            return
        end
    end

    self.currentRaycastFillTypeCoords = { x, y, z }
end

PlayerHUDUpdater.setCurrentRaycastFillTypeCoords = MSPlayerHUDExtension.setCurrentRaycastFillTypeCoords

---
-- Show moisture information for filltype piles being looked at
---
function MSPlayerHUDExtension:showFillTypeInfo()
    if self.currentRaycastFillTypeCoords == nil then return end

    -- Initialize box on first use
    if self.fillTypeBox == nil then
        self.fillTypeBox = g_currentMission.hud.infoDisplay:createBox(InfoDisplayKeyValueBox)
    end

    local box = self.fillTypeBox
    if box == nil then return end

    local harvestTracker = g_currentMission.groundPropertyTracker
    if harvestTracker == nil then
        box:clear()
        return
    end

    local x, y, z = unpack(self.currentRaycastFillTypeCoords)

    -- Get filltype at this position (sample 2m x 2m area)
    local fillTypeIndex = DensityMapHeightUtil.getFillTypeAtArea(x, z, x - 1, z - 1, x + 1, z + 1)
    if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
        box:clear()
        return
    end

    -- Get pile properties from tracker
    local properties = harvestTracker:getPilePropertiesAtPosition(x, z, fillTypeIndex)
    if properties == nil then
        box:clear()
        return
    end

    local fillTypeName = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
    local moisture = properties.moisture

    box:clear()
    box:setTitle(fillTypeName)

    box:addLine(
        g_i18n:getText("moistureSystem_moisture"),
        MSPlayerHUDExtension.formatMoistureText(moisture)
    )
    if properties.quality then
        box:addLine(
            g_i18n:getText("moistureSystem_quality"),
            MSPlayerHUDExtension.formatQualityText(properties.quality)
        )
    end

    -- Show volume if available
    if properties.volume then
        box:addLine(
            g_i18n:getText("infohud_amount"),
            g_i18n:formatVolume(properties.volume, 0)
        )
    end

    box:showNextFrame()
end

PlayerHUDUpdater.showFillTypeInfo = MSPlayerHUDExtension.showFillTypeInfo

---
-- Call showFillTypeInfo in update loop
-- Appended to PlayerHUDUpdater.update
---
function MSPlayerHUDExtension:update(dt, x, y, z, rotY)
    self:showFillTypeInfo()
    self:showObjectMoistureInfo()
end

PlayerHUDUpdater.update = Utils.appendedFunction(PlayerHUDUpdater.update, MSPlayerHUDExtension.update)

---
-- Show moisture data for any object with stored moisture data
-- This catches silos, auger wagons, and other objects not covered by specific show methods
---
function MSPlayerHUDExtension:showObjectMoistureInfo()
    -- Only show if we have a valid object
    if self.object == nil or self.object.uniqueId == nil then
        return
    end

    -- Skip if this is a vehicle/pallet that already shows info via their specific methods
    if self.isVehicle or self.isPallet then
        return
    end

    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then
        return
    end

    moistureSystem:ensureObjectMoistureLoaded(self.object)
    local objectData = moistureSystem.objectInfo[self.object.uniqueId]
    if objectData == nil then
        return
    end

    -- Initialize box on first use
    if self.objectMoistureBox == nil then
        self.objectMoistureBox = g_currentMission.hud.infoDisplay:createBox(InfoDisplayKeyValueBox)
    end

    local box = self.objectMoistureBox
    if box == nil then
        return
    end

    box:clear()

    -- Try to get a meaningful title
    local title = "Object"
    if self.object.getName ~= nil then
        title = self.object:getName()
    elseif self.object.configFileName ~= nil then
        title = self.object.configFileName:match("([^/]+)%.xml$") or "Object"
    end

    box:setTitle(title)

    local hasData = false
    for fillTypeName, infoEntry in pairs(objectData) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if fillType then
                box:addLine(
                    fillType.title .. " " .. g_i18n:getText("moistureSystem_moisture"),
                    MSPlayerHUDExtension.formatMoistureText(infoEntry.moisture)
                )
                if infoEntry.quality then
                    box:addLine(
                        fillType.title .. " " .. g_i18n:getText("moistureSystem_quality"),
                        MSPlayerHUDExtension.formatQualityText(infoEntry.quality)
                    )
                end
                hasData = true
            end
        end
    end

    if hasData then
        box:showNextFrame()
    end
end

PlayerHUDUpdater.showObjectMoistureInfo = MSPlayerHUDExtension.showObjectMoistureInfo

---
-- Show moisture data for vehicles/objects being looked at
-- Appended to PlayerHUDUpdater.showVehicleInfo
---
function MSPlayerHUDExtension:showVehicleInfo(vehicle)
    if vehicle == nil or vehicle.uniqueId == nil then
        return
    end

    local moistureSystem = g_currentMission.MoistureSystem
    moistureSystem:ensureObjectMoistureLoaded(vehicle)
    local objectData = moistureSystem.objectInfo[vehicle.uniqueId]
    if objectData == nil then
        return
    end

    local box = self.objectBox
    if box == nil then
        return
    end

    -- Add moisture data for each fillType stored in this object
    for fillTypeName, infoEntry in pairs(objectData) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if fillType then
                box:addLine(
                    fillType.title .. " " .. g_i18n:getText("moistureSystem_moisture"),
                    MSPlayerHUDExtension.formatMoistureText(infoEntry.moisture)
                )
                if infoEntry.quality then
                    box:addLine(
                        fillType.title .. " " .. g_i18n:getText("moistureSystem_quality"),
                        MSPlayerHUDExtension.formatQualityText(infoEntry.quality)
                    )
                end
            end
        end
    end
end

PlayerHUDUpdater.showVehicleInfo = Utils.appendedFunction(PlayerHUDUpdater.showVehicleInfo,
    MSPlayerHUDExtension.showVehicleInfo)

---
-- Show moisture data for pallets being looked at
-- Appended to PlayerHUDUpdater.showPalletInfo
---
function MSPlayerHUDExtension:showPalletInfo(pallet)
    if pallet == nil or pallet.uniqueId == nil then
        return
    end

    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then
        return
    end

    moistureSystem:ensureObjectMoistureLoaded(pallet)
    local objectData = moistureSystem.objectInfo[pallet.uniqueId]
    if objectData == nil then
        return
    end

    local box = self.objectBox
    if box == nil then
        return
    end

    -- Add moisture data for each fillType stored in this object
    for fillTypeName, infoEntry in pairs(objectData) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if fillType then
                box:addLine(
                    fillType.title .. " " .. g_i18n:getText("moistureSystem_moisture"),
                    MSPlayerHUDExtension.formatMoistureText(infoEntry.moisture)
                )
                if infoEntry.quality then
                    box:addLine(
                        fillType.title .. " " .. g_i18n:getText("moistureSystem_quality"),
                        MSPlayerHUDExtension.formatQualityText(infoEntry.quality)
                    )
                end
            end
        end
    end
end

PlayerHUDUpdater.showPalletInfo = Utils.appendedFunction(PlayerHUDUpdater.showPalletInfo,
    MSPlayerHUDExtension.showPalletInfo)

---
-- Show rain exposure for bales being looked at
-- Appended to PlayerHUDUpdater.showBaleInfo
---
function MSPlayerHUDExtension:showBaleInfo(bale)
    if bale == nil or bale.uniqueId == nil then
        return
    end

    local box = self.objectBox
    if box == nil then
        return
    end

    -- Show rain exposure time and status if tracked
    local baleRottingSystem = g_currentMission.baleRottingSystem
    if baleRottingSystem ~= nil then
        baleRottingSystem:ensureBaleDataLoaded(bale)
        local baleData = baleRottingSystem.baleRainExposureTimes[bale.uniqueId]
        if baleData ~= nil and baleData.exposure > 0 then
            -- Only show exposure % if not rotting yet
            local isRotting = (baleData.status == BaleRottingSystem.BALE_STATUS.ROTTING_SLOWLY or
                baleData.status == BaleRottingSystem.BALE_STATUS.ROTTING or
                baleData.status == BaleRottingSystem.BALE_STATUS.ROTTING_QUICKLY)
            if not isRotting then
                local exposurePercent = (baleData.exposure / baleRottingSystem.SLOW_ROT_THRESHOLD) * 100
                box:addLine(
                    g_i18n:getText("moistureSystem_rainExposure"),
                    string.format("%.0f%%", exposurePercent)
                )
            end

            -- Show status (pre-computed in update loop)
            local statusTextMap = {
                [BaleRottingSystem.BALE_STATUS.GETTING_WET] = "moistureSystem_baleGettingWet",
                [BaleRottingSystem.BALE_STATUS.ROTTING_SLOWLY] = "moistureSystem_baleRottingSlowly",
                [BaleRottingSystem.BALE_STATUS.ROTTING] = "moistureSystem_baleRotting",
                [BaleRottingSystem.BALE_STATUS.ROTTING_QUICKLY] = "moistureSystem_baleRottingQuickly",
                [BaleRottingSystem.BALE_STATUS.DRYING] = "moistureSystem_baleDrying"
            }

            if baleData.status and statusTextMap[baleData.status] then
                local statusText = g_i18n:getText(statusTextMap[baleData.status])
                box:addLine(
                    g_i18n:getText("moistureSystem_baleStatus"),
                    statusText
                )
            end
        end
    end
end

PlayerHUDUpdater.showBaleInfo = Utils.appendedFunction(PlayerHUDUpdater.showBaleInfo,
    MSPlayerHUDExtension.showBaleInfo)

---
-- Clean up boxes on delete
-- Appended to PlayerHUDUpdater.delete
---
function MSPlayerHUDExtension:delete()
    if self.moistureBox ~= nil then
        g_currentMission.hud.infoDisplay:destroyBox(self.moistureBox)
    end
    if self.fillTypeBox ~= nil then
        g_currentMission.hud.infoDisplay:destroyBox(self.fillTypeBox)
    end
end

PlayerHUDUpdater.delete = Utils.appendedFunction(PlayerHUDUpdater.delete, MSPlayerHUDExtension.delete)
