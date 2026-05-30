---
-- BalerExtension
-- Tracks moisture during pickup, initializes bale exposure based on moisture,
-- and cleans up pile tracking data
---

MSBalerExtension = {}

---
-- Extended to track moisture from ground piles and clean up pile data
-- Called after all work areas are processed
-- @param superFunc: Original function
-- @param dt: Delta time
-- @param hasProcessed: Whether work areas were processed
---
function MSBalerExtension:onEndWorkAreaProcessing(superFunc, dt, hasProcessed)
    -- Call original function first
    superFunc(self, dt, hasProcessed)

    -- Only track on server
    if not self.isServer then
        return
    end

    local spec = self.spec_baler
    if spec == nil then
        return
    end

    -- Check if we actually picked up something (accumulated across all work areas)
    local pickedUpLiters = spec.workAreaParameters.lastPickedUpLiters or 0
    if pickedUpLiters <= 0 then
        return
    end

    local moistureSystem = g_currentMission.MoistureSystem
    local tracker = g_currentMission.groundPropertyTracker
    if not moistureSystem or not tracker then
        return
    end

    -- Get the dominant fillType that was picked up
    local fillType = FillType.UNKNOWN
    local maxFillLevel = 0
    for ft, amount in pairs(spec.pickupFillTypes) do
        if amount > maxFillLevel then
            fillType = ft
            maxFillLevel = amount
        end
    end

    if fillType == FillType.UNKNOWN then
        return
    end

    -- Only track fillTypes we care about
    if not moistureSystem:shouldTrackFillType(fillType) then
        return
    end

    -- Get the primary work area to determine pickup location
    local workArea = self.spec_workArea.workAreas[1]
    if workArea == nil then
        return
    end

    -- Get work area coordinates
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)

    -- Get all affected cells in work area
    local affectedCells = tracker:getAffectedGridCells(sx, sz, wx, wz, hx, hz)
    
    local moisture = nil
    local totalVolume = 0
    local weightedMoistureSum = 0
    local weightedQualitySum = 0

    for _, cell in ipairs(affectedCells) do
        local cellProps = tracker:getPilePropertiesAtPosition(cell.gridX, cell.gridZ, fillType)
        if cellProps and cellProps.moisture then
            local checkRadius = GroundPropertyTracker.GRID_SIZE / 2
            local cellVolume = DensityMapHeightUtil.getFillLevelAtArea(
                fillType,
                cell.gridX - checkRadius, cell.gridZ - checkRadius,
                cell.gridX + checkRadius, cell.gridZ - checkRadius,
                cell.gridX - checkRadius, cell.gridZ + checkRadius
            )
            if cellVolume > 0 then
                weightedMoistureSum = weightedMoistureSum + (cellProps.moisture * cellVolume)
                weightedQualitySum = weightedQualitySum + ((cellProps.quality or 100) * cellVolume)
                totalVolume = totalVolume + cellVolume
            end
        end
    end
    
    local sourceQuality
    if totalVolume > 0 then
        moisture = weightedMoistureSum / totalVolume
        sourceQuality = weightedQualitySum / totalVolume
    else
        local centerX = (sx + wx + hx) / 3
        local centerZ = (sz + wz + hz) / 3
        moisture = moistureSystem:getMoistureAtPosition(centerX, centerZ)
    end

    if moisture == nil then
        return
    end

    -- Determine which fillUnit to track (buffer or main)
    local targetFillUnitIndex = spec.fillUnitIndex
    if spec.buffer and spec.buffer.fillUnitIndex then
        -- If baler has buffer, check which unit is actually filling
        local bufferLevel = self:getFillUnitFillLevel(spec.buffer.fillUnitIndex)
        local bufferCapacity = self:getFillUnitCapacity(spec.buffer.fillUnitIndex)
        if bufferLevel < bufferCapacity then
            targetFillUnitIndex = spec.buffer.fillUnitIndex
        end
    end

    local currentLiters = self:getFillUnitFillLevel(targetFillUnitIndex) - pickedUpLiters
    local currentInfo = moistureSystem:getObjectInfo(self.uniqueId, fillType)
    if not sourceQuality then
        sourceQuality = moistureSystem:deriveQuality(fillType, moisture)
    end

    if currentInfo == nil or currentLiters <= 0 then
        moistureSystem:setObjectInfo(self.uniqueId, fillType, { moisture = moisture, quality = sourceQuality })
    else
        local totalLiters = currentLiters + pickedUpLiters
        local avgMoisture = (currentLiters * currentInfo.moisture + pickedUpLiters * moisture) / totalLiters
        local avgQuality = (currentLiters * (currentInfo.quality or 100) + pickedUpLiters * sourceQuality) / totalLiters
        moistureSystem:setObjectInfo(self.uniqueId, fillType, { moisture = avgMoisture, quality = avgQuality })
    end

    -- Cleanup pile tracking data for all cells in work area (reuse affectedCells from above)
    for _, cell in ipairs(affectedCells) do
        tracker:checkPileHasContent(cell.gridX, cell.gridZ, fillType)
    end
end

---
-- Extended to initialize BaleRottingSystem based on bale moisture at creation
-- @param superFunc: Original function
-- @param baleFillType: Fill type of the bale
-- @param fillLevel: Fill level of the bale
-- @param baleServerId: Server ID of the bale
-- @param baleTime: Time value for bale animation
-- @param xmlFilename: XML filename for the bale
-- @param ownerFarmId: Owner farm ID
-- @param variationId: Variation ID
-- @param loadFromSavegame: Whether loading from savegame
-- @return boolean indicating if bale was created successfully
---
function MSBalerExtension:createBale(superFunc, baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId,
                                     variationId, loadFromSavegame)
    local wasCreated = superFunc(self, baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId,
        variationId, loadFromSavegame)

    if not self.isServer or not wasCreated then
        return wasCreated
    end

    local moistureSystem = g_currentMission.MoistureSystem
    if not moistureSystem then
        return wasCreated
    end

    if not moistureSystem:shouldTrackFillType(baleFillType) then
        return wasCreated
    end

    local spec = self.spec_baler
    if spec == nil or spec.bales == nil or #spec.bales == 0 then
        return wasCreated
    end

    local baleInfo = spec.bales[#spec.bales]
    if baleInfo == nil or baleInfo.baleObject == nil then
        return wasCreated
    end

    local bale = baleInfo.baleObject
    local vehicleMoisture = moistureSystem:getObjectMoisture(self.uniqueId, baleFillType)

    if vehicleMoisture ~= nil and bale.uniqueId then
        -- Store moisture on the bale object for later use during fermentation (grass types only)
        if moistureSystem:isGrassOnGroundFillType(baleFillType) then
            moistureSystem:setObjectMoisture(bale.uniqueId, baleFillType, vehicleMoisture)
        end
        
        local initialExposure = 0

        if vehicleMoisture >= 0.25 then
            initialExposure = 0.65 * BaleRottingSystem.SLOW_ROT_THRESHOLD
        elseif vehicleMoisture >= 0.20 then
            initialExposure = 0.55 * BaleRottingSystem.SLOW_ROT_THRESHOLD
        elseif vehicleMoisture >= 0.15 then
            initialExposure = 0.35 * BaleRottingSystem.SLOW_ROT_THRESHOLD
        end

        if initialExposure > 0 then
            g_currentMission.baleRottingSystem:setBaleInitialExposure(bale.uniqueId, initialExposure)
        end
    end

    return wasCreated
end

---
-- Extended to cleanup moisture tracking when fillUnit is emptied
-- @param superFunc: Original function
-- @param fillUnitIndex: Fill unit index
-- @param fillLevelDelta: Amount of fill level change
-- @param fillTypeIndex: Fill type index
-- @param toolType: Tool type
-- @param fillPositionData: Fill position data
-- @param appliedDelta: Applied delta
---
function MSBalerExtension:onFillUnitFillLevelChanged(superFunc, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType,
                                                     fillPositionData, appliedDelta)
    -- Call original
    if superFunc ~= nil then
        superFunc(self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta)
    end

    if not self.isServer then
        return
    end

    local spec = self.spec_baler
    if spec == nil then
        return
    end

    -- Check both main and buffer fillUnits
    local isMainUnit = (fillUnitIndex == spec.fillUnitIndex)
    local isBufferUnit = spec.buffer and (fillUnitIndex == spec.buffer.fillUnitIndex)

    if not isMainUnit and not isBufferUnit then
        return
    end

    -- Clear moisture when unit is emptied
    local fillLevel = self:getFillUnitFillLevel(fillUnitIndex)
    if fillLevel <= 0.001 then
        local moistureSystem = g_currentMission.MoistureSystem
        if moistureSystem then
            moistureSystem:setObjectMoisture(self.uniqueId, fillTypeIndex, nil)
        end
    end
end

-- Hook into Baler specialization
Baler.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    Baler.onEndWorkAreaProcessing,
    MSBalerExtension.onEndWorkAreaProcessing
)

Baler.createBale = Utils.overwrittenFunction(
    Baler.createBale,
    MSBalerExtension.createBale
)

Baler.onFillUnitFillLevelChanged = Utils.overwrittenFunction(
    Baler.onFillUnitFillLevelChanged,
    MSBalerExtension.onFillUnitFillLevelChanged
)
