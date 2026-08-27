---
-- DischargeableExtension
-- Tracks moisture when crops are discharged to ground
---

MSDischargeableExtension = {}

---
-- Extended to track moisture of discharged crops
-- @param superFunc: Original function
-- @param dischargeNode: The discharge node being used
-- @param emptyLiters: Amount to discharge
-- @return dischargedLiters, minDropReached, hasMinDropFillLevel
---
function MSDischargeableExtension:dischargeToGround(superFunc, dischargeNode, emptyLiters)
    -- Call original function
    local dischargedLiters, minDropReached, hasMinDropFillLevel = superFunc(self, dischargeNode, emptyLiters)

    -- Only track on server and if something was actually discharged
    -- Note: dischargedLiters is negative when discharging (e.g., -7 means 7 liters discharged)
    if not self.isServer or dischargedLiters == 0 then
        return dischargedLiters, minDropReached, hasMinDropFillLevel
    end

    local tracker = g_currentMission.groundPropertyTracker

    -- Get filltype
    local fillType = self:getDischargeFillType(dischargeNode)
    if fillType == nil then
        return dischargedLiters, minDropReached, hasMinDropFillLevel
    end

    -- Get moisture and quality from vehicle's fillType if available
    local moistureSystem = g_currentMission.MoistureSystem
    local moisture = nil
    local quality = nil

    if moistureSystem and self.uniqueId then
        local info = moistureSystem:getObjectInfo(self.uniqueId, fillType)
        if info then
            moisture = info.moisture
            quality = info.quality
        end
    end

    -- If no moisture data, use field moisture as fallback
    if moisture == nil then
        if moistureSystem == nil then
            return dischargedLiters, minDropReached, hasMinDropFillLevel
        end

        -- Get discharge position
        local info = dischargeNode.info
        local sx, _, sz = localToWorld(info.node, -info.width, 0, info.zOffset)
        local ex, _, ez = localToWorld(info.node, info.width, 0, info.zOffset)
        local centerX = (sx + ex) / 2
        local centerZ = (sz + ez) / 2

        moisture = moistureSystem:getMoistureAtPosition(centerX, centerZ)

        if moisture == nil then
            moisture = moistureSystem.currentMoisturePercent
        end

        quality = moistureSystem:deriveQuality(fillType, moisture)
    end

    -- Get discharge area coordinates
    local info = dischargeNode.info
    local sx, sy, sz = localToWorld(info.node, -info.width, 0, info.zOffset)
    local ex, ey, ez = localToWorld(info.node, info.width, 0, info.zOffset)

    -- Adjust Y to terrain if needed
    if info.limitToGround then
        sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz) + 0.1
        ey = getTerrainHeightAtWorldPos(g_terrainNode, ex, 0, ez) + 0.1
    else
        sy = sy + info.yOffset
        ey = ey + info.yOffset
    end

    -- Calculate center point for tracking
    local centerX = (sx + ex) / 2
    local centerZ = (sz + ez) / 2

    -- Calculate bounding box corners for tracking
    local length = info.length or 0
    local width = math.sqrt((ex - sx) ^ 2 + (ez - sz) ^ 2)

    -- Create corner coordinates for pile tracking
    -- Using simplified rectangle aligned with discharge direction
    local halfWidth = width / 2
    local halfLength = length / 2

    local corner1X = centerX - halfWidth
    local corner1Z = centerZ - halfLength
    local corner2X = centerX + halfWidth
    local corner2Z = centerZ - halfLength
    local corner3X = centerX - halfWidth
    local corner3Z = centerZ + halfLength

    -- Track the pile with moisture and quality
    -- Use absolute value since dischargedLiters is negative
    tracker:addPile(
        corner1X, corner1Z,
        corner2X, corner2Z,
        corner3X, corner3Z,
        fillType,
        math.abs(dischargedLiters),
        { moisture = moisture, quality = quality }
    )

    -- Clean up moisture tracking if vehicle is now empty of this fillType
    if not moistureSystem:hasFillType(self.uniqueId, fillType) then
        moistureSystem:setObjectMoisture(self.uniqueId, fillType, nil)
    end

    return dischargedLiters, minDropReached, hasMinDropFillLevel
end

-- Hook into Dischargeable specialization
Dischargeable.dischargeToGround = Utils.overwrittenFunction(
    Dischargeable.dischargeToGround,
    MSDischargeableExtension.dischargeToGround
)

---
-- Extended to track moisture when discharging to vehicles/objects
-- @param superFunc: Original function
-- @param dischargeNode: The discharge node being used
-- @param emptyLiters: Amount to discharge
-- @param targetObjectId: The node ID of the vehicle/object being filled
-- @param targetFillUnitIndex: Fill unit index on target
-- @return dischargedLiters
---
function MSDischargeableExtension:dischargeToObject(superFunc, dischargeNode, emptyLiters, targetObject,
                                                    targetFillUnitIndex)
    -- Only track on server
    if not self.isServer then
        return superFunc(self, dischargeNode, emptyLiters, targetObject, targetFillUnitIndex)
    end

    -- This will be passed as extraAttributes to UnloadTrigger and then SellingStation
    if self.uniqueId ~= nil and dischargeNode.info ~= nil then
        dischargeNode.info.sourceUniqueId = self.uniqueId
        dischargeNode.info.sourceObject = self
    end

    local uniqueId = targetObject.uniqueId
    local targetPlaceable = targetObject.target ~= nil and targetObject.target.owningPlaceable or nil

    if uniqueId == nil and targetPlaceable ~= nil then
        uniqueId = targetPlaceable.uniqueId
    end
    local fillType = self:getDischargeFillType(dischargeNode)
    local farmId = self.ownerFarmId

    -- Get target fill level before discharge
    local targetCurrentLiters = 0
    if targetObject ~= nil and targetObject.getFillUnitFillLevel ~= nil then
        targetCurrentLiters = targetObject:getFillUnitFillLevel(targetFillUnitIndex)
        -- if targetObject.target ~= nil and targetObject.target:isa(UnloadingStation) then
    elseif targetObject.target ~= nil and targetObject.target.getFillLevel ~= nil then
        targetCurrentLiters = targetObject.target:getFillLevel(fillType, farmId)
    end

    -- A storage heap store (see StorageHeapExtension) keeps its grain as real material
    -- on the ground, so its moisture lives in GroundPropertyTracker piles rather than in
    -- objectInfo. Its bays announce arriving liters through a fill-level listener that
    -- fires inside superFunc below, but that listener is only told the fill type and the
    -- amount — the bracket tells it whose grain it is.
    --
    -- Bracket every discharge, not just those aimed at a storage heap: bays default to
    -- isExtension=true, so any station within its storageRadius can pull one into its
    -- target storages and route grain there. The listener only exists on bays, so setting
    -- this for a discharge that never reaches one costs a single field write.
    local isStorageHeapTarget = MSStorageHeapExtension.isStorageHeap(targetPlaceable)

    MSStorageHeapExtension.beginDeposit(self.uniqueId)

    -- Call original function
    local dischargedLiters = superFunc(self, dischargeNode, emptyLiters, targetObject, targetFillUnitIndex)

    MSStorageHeapExtension.endDeposit()

    -- Only track if something was actually discharged
    -- Note: dischargedLiters is negative when discharging (e.g., -7 means 7 liters discharged)
    if dischargedLiters == 0 then
        return dischargedLiters
    end

    local moistureSystem = g_currentMission.MoistureSystem
    if fillType == nil then
        return dischargedLiters
    end

    if targetObject == nil or uniqueId == nil then
        if not moistureSystem:hasFillType(self.uniqueId, fillType) then
            moistureSystem:setObjectMoisture(self.uniqueId, fillType, nil)
        end
        return dischargedLiters
    end

    if fillType == nil then
        return dischargedLiters
    end

    if not moistureSystem:shouldTrackFillType(fillType) then
        return dischargedLiters
    end

    -- The bay listener has already banked this grain as a ground pile, and the placeable
    -- holds no objectInfo of its own, so all that is left is emptying the source.
    if isStorageHeapTarget then
        if not moistureSystem:hasFillType(self.uniqueId, fillType) then
            moistureSystem:setObjectMoisture(self.uniqueId, fillType, nil)
        end
        return dischargedLiters
    end

    -- Transfer moisture to target using volume-weighted averaging
    -- Use absolute value since dischargedLiters is negative
    moistureSystem:transferObjectMoisture(
        self.uniqueId,
        uniqueId,
        math.abs(dischargedLiters),
        targetCurrentLiters,
        fillType
    )

    return dischargedLiters
end

Dischargeable.dischargeToObject = Utils.overwrittenFunction(
    Dischargeable.dischargeToObject,
    MSDischargeableExtension.dischargeToObject
)
