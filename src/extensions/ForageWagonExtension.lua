---
-- ForageWagonExtension
-- Tracks moisture when picking up fillType from ground
-- and cleans up pile data after pickup
---

MSForageWagonExtension = {}

---
-- Extended to track moisture from ground piles and clean up pile data
-- @param superFunc: Original function
-- @param dt: Delta time
-- @param hasProcessed: Whether work areas were processed
---
function MSForageWagonExtension:onEndWorkAreaProcessing(superFunc, dt, hasProcessed)
    local result = superFunc(self, dt)

    if not self.isServer then
        return result
    end

    local spec = self.spec_forageWagon
    if spec == nil then
        return result
    end

    -- Check if we actually picked up something
    local pickupLiters = spec.workAreaParameters.lastPickupLiters or 0
    if pickupLiters <= 0 then
        return result
    end

    -- Get the fillType that was picked up
    local fillType = spec.workAreaParameters.forcedFillType
    if fillType == nil or fillType == FillType.UNKNOWN then
        return result
    end

    local moistureSystem = g_currentMission.MoistureSystem
    local tracker = g_currentMission.groundPropertyTracker
    if not moistureSystem:shouldTrackFillType(fillType) then
        return result
    end

    -- Get work area to determine pickup location
    local workArea = self:getWorkAreaByIndex(spec.workAreaIndex)
    if workArea == nil then
        return result
    end

    -- Calculate center of work area
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)

    local centerX = (sx + wx + hx) / 3
    local centerZ = (sz + wz + hz) / 3

    -- Try to get moisture from tracked pile
    local properties = tracker:getPilePropertiesAtPosition(centerX, centerZ, fillType)
    local moisture = nil

    if properties and properties.moisture then
        moisture = properties.moisture
    else
        -- No pile tracked, use field moisture as fallback
        moisture = moistureSystem:getMoistureAtPosition(centerX, centerZ)
    end

    if moisture == nil then
        return result
    end

    -- Get current fill level before adding (need to subtract what was just added)
    local currentLiters = self:getFillUnitFillLevel(spec.fillUnitIndex) - pickupLiters

    -- Get vehicle uniqueId
    local uniqueId = self.uniqueId
    if uniqueId == nil then
        return result
    end

    local currentInfo = moistureSystem:getObjectInfo(uniqueId, fillType)
    local sourceQuality = (properties and properties.quality) or moistureSystem:deriveQuality(fillType, moisture)

    if currentInfo == nil or currentLiters <= 0 then
        moistureSystem:setObjectInfo(uniqueId, fillType, { moisture = moisture, quality = sourceQuality })
    else
        local totalLiters = currentLiters + pickupLiters
        local avgMoisture = (currentLiters * currentInfo.moisture + pickupLiters * moisture) / totalLiters
        local avgQuality = (currentLiters * (currentInfo.quality or 100) + pickupLiters * sourceQuality) / totalLiters
        moistureSystem:setObjectInfo(uniqueId, fillType, { moisture = avgMoisture, quality = avgQuality })
    end

    tracker:checkPileHasContent(centerX, centerZ, fillType)

    return result
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
function MSForageWagonExtension:onFillUnitFillLevelChanged(superFunc, fillUnitIndex, fillLevelDelta, fillTypeIndex,
                                                           toolType, fillPositionData, appliedDelta)
    superFunc(self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta)

    if not self.isServer then
        return
    end

    local spec = self.spec_forageWagon
    if spec == nil or fillUnitIndex ~= spec.fillUnitIndex then
        return
    end

    -- Clear moisture when tank is emptied
    local fillLevel = self:getFillUnitFillLevel(fillUnitIndex)
    if fillLevel <= 0.001 then
        local moistureSystem = g_currentMission.MoistureSystem
        if moistureSystem then
            moistureSystem:setObjectMoisture(self.uniqueId, fillTypeIndex, nil)
        end
    end
end

ForageWagon.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    ForageWagon.onEndWorkAreaProcessing,
    MSForageWagonExtension.onEndWorkAreaProcessing
)

ForageWagon.onFillUnitFillLevelChanged = Utils.overwrittenFunction(
    ForageWagon.onFillUnitFillLevelChanged,
    MSForageWagonExtension.onFillUnitFillLevelChanged
)
