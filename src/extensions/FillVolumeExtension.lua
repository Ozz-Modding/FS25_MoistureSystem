---
-- FillVolumeExtension
-- Tracks moisture when loading with buckets/shovels from ground piles
---

MSFillVolumeExtension = {}

---
-- Extended to track moisture when filling from ground piles
-- @param superFunc: Original function
-- @param fillUnitIndex: Fill unit being filled
-- @param fillLevelDelta: Amount filled
-- @param fillType: FillType being loaded (unused in original signature)
-- @param toolType: Tool type
-- @param fillPositionData: Position data
-- @param appliedDelta: Actually applied delta
---
function MSFillVolumeExtension:onFillUnitFillLevelChanged(superFunc, fillUnitIndex, fillLevelDelta, fillType, toolType,
                                                          fillPositionData, appliedDelta)
    -- Call original function first
    if superFunc ~= nil then
        superFunc(self, fillUnitIndex, fillLevelDelta, fillType, toolType, fillPositionData, appliedDelta)
    end

    if not g_currentMission.MoistureSystem.missionStarted then
        return
    end

    -- Skip if this is a combine - CutterExtension handles that
    if self.spec_combine ~= nil then
        return
    end

    if toolType == ToolType.TRIGGER then
        return
    end

    local moistureSystem = g_currentMission.MoistureSystem
    if not moistureSystem:shouldTrackFillType(fillType) then
        return
    end

    if not self.isServer or fillLevelDelta <= 0 then
        return
    end

    -- Try to get position from nodes
    local x, z
    if fillPositionData and fillPositionData.nodes and fillPositionData.nodes[1] then
        local wx, wy, wz = getWorldTranslation(fillPositionData.nodes[1].node)
        x = wx
        z = wz
    end

    if x == nil or z == nil then
        return
    end

    local tracker = g_currentMission.groundPropertyTracker

    local uniqueId = self.uniqueId
    if uniqueId == nil then
        return
    end

    -- Try to get moisture from tracked pile at pickup location
    local properties = tracker:getPilePropertiesAtPosition(x, z, fillType)
    local moisture = nil

    if properties and properties.moisture then
        moisture = properties.moisture
    else
        moisture = moistureSystem:getMoistureAtPosition(x, z)
    end

    if moisture == nil then
        moisture = moistureSystem.currentMoisturePercent
    end

    local currentLiters = self:getFillUnitFillLevel(fillUnitIndex) - fillLevelDelta
    local currentInfo = moistureSystem:getObjectInfo(uniqueId, fillType)
    local sourceQuality = (properties and properties.quality) or moistureSystem:deriveQuality(fillType, moisture)

    if currentInfo == nil or currentLiters <= 0 then
        moistureSystem:setObjectInfo(uniqueId, fillType, { moisture = moisture, quality = sourceQuality })
    else
        local totalLiters = currentLiters + fillLevelDelta
        local avgMoisture = (currentLiters * currentInfo.moisture + fillLevelDelta * moisture) / totalLiters
        local avgQuality = (currentLiters * (currentInfo.quality or 100) + fillLevelDelta * sourceQuality) / totalLiters
        moistureSystem:setObjectInfo(uniqueId, fillType, { moisture = avgMoisture, quality = avgQuality })
    end

    local gridX, gridZ = tracker:getGridPosition(x, z)
    tracker:checkPileHasContent(gridX, gridZ, fillType)
end

-- Hook into FillVolume specialization (used by buckets, shovels, augers, etc.)
if FillVolume ~= nil then
    FillVolume.onFillUnitFillLevelChanged = Utils.overwrittenFunction(
        FillVolume.onFillUnitFillLevelChanged,
        MSFillVolumeExtension.onFillUnitFillLevelChanged
    )
end
