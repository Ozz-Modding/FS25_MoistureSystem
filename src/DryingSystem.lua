DryingSystem = {}
local DryingSystem_mt = Class(DryingSystem)

DryingSystem.DEFAULT_DRYING_RATE = 0.01
DryingSystem.SILO_COST_RATIO = 0.7

function DryingSystem.new()
    local self = setmetatable({}, DryingSystem_mt)
    self.activeDryers = {}
    self.shedBounds = {}
    return self
end

-- Every silo/shed placeable owned by farmId that is eligible for drying.
function DryingSystem:getOwnedDryables(farmId)
    local result = {}
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable:getOwnerFarmId() == farmId then
            if placeable.spec_silo then
                table.insert(result, placeable)
            elseif placeable.spec_siloExtension then
                -- Extensions are part of their parent silo's pool, never dryable alone.
            elseif self:isTipOcclusionBuilding(placeable) then
                table.insert(result, placeable)
            end
        end
    end
    return result
end

function DryingSystem:isTipOcclusionBuilding(placeable)
    if placeable.spec_silo or placeable.spec_siloExtension then return false end
    local spec = placeable.spec_tipOcclusionAreas
    if spec == nil or spec.areas == nil or #spec.areas == 0 then return false end
    return true
end

function DryingSystem:getShedWorldBounds(placeable)
    local cached = self.shedBounds[placeable.uniqueId]
    if cached then return cached end

    local spec = placeable.spec_tipOcclusionAreas
    if spec == nil or spec.areas == nil or #spec.areas == 0 then return nil end

    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, area in pairs(spec.areas) do
        local cx, cz = area.center.x, area.center.z
        local sx, sz = area.size.x, area.size.z
        local x1, _, z1 = localToWorld(placeable.rootNode, cx + sx * 0.5, 0, cz + sz * 0.5)
        local x2, _, z2 = localToWorld(placeable.rootNode, cx - sx * 0.5, 0, cz + sz * 0.5)
        local x3, _, z3 = localToWorld(placeable.rootNode, cx + sx * 0.5, 0, cz - sz * 0.5)
        local x4, _, z4 = localToWorld(placeable.rootNode, cx - sx * 0.5, 0, cz - sz * 0.5)
        minX = math.min(minX, x1, x2, x3, x4)
        maxX = math.max(maxX, x1, x2, x3, x4)
        minZ = math.min(minZ, z1, z2, z3, z4)
        maxZ = math.max(maxZ, z1, z2, z3, z4)
    end

    local bounds = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
    self.shedBounds[placeable.uniqueId] = bounds
    return bounds
end

-- Liters per fill type across the silo and its extensions, plus the pooled total.
--
-- Aggregated, not per storage: the same crop can sit in several tanks, and moisture is
-- tracked once for the whole pool. Iterating storages directly listed a crop once per tank
-- in the drying menu ("Wheat 16%, Wheat 16%") and, worse, let drySilo apply the hourly
-- reduction once per tank.
function DryingSystem:getSiloFillLevels(placeable)
    local byFillType = {}
    local totalLiters = 0
    for _, storage in ipairs(MoistureSystem.getSiloStorages(placeable)) do
        for fillTypeIndex, fillLevel in pairs(storage.fillLevels) do
            if fillLevel > 0 then
                byFillType[fillTypeIndex] = (byFillType[fillTypeIndex] or 0) + fillLevel
                totalLiters = totalLiters + fillLevel
            end
        end
    end
    return byFillType, totalLiters
end

-- Per-crop moisture/idealMax/needsDrying for a silo, plus the silo's total stored liters.
function DryingSystem:getSiloCropStatus(placeable, ms)
    local statuses = {}
    local byFillType, totalLiters = self:getSiloFillLevels(placeable)
    for fillTypeIndex, _ in pairs(byFillType) do
        local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
        if idealMax then
            local info = ms:getObjectInfo(placeable.uniqueId, fillTypeIndex)
            if info and info.moisture then
                table.insert(statuses, {
                    fillTypeIndex = fillTypeIndex,
                    moisture = info.moisture,
                    idealMax = idealMax,
                    needsDrying = info.moisture > idealMax,
                })
            end
        end
    end
    return statuses, totalLiters
end

-- Per-crop moisture/idealMax/needsDrying for a shed, aggregated by fillType across all
-- piles inside its bounds (a shed can have several piles of the same crop across grid
-- cells; the worst-case pile determines when that crop finishes drying).
function DryingSystem:getShedCropStatus(placeable)
    local bounds = self:getShedWorldBounds(placeable)
    if bounds == nil then return {}, 0 end

    local tracker = g_currentMission.groundPropertyTracker
    local allStorages = { tracker.gridPiles, tracker.grassPiles, tracker.hayPiles, tracker.strawPiles }
    local byFillType = {}
    local totalLiters = 0

    for _, storage in ipairs(allStorages) do
        for _, pile in pairs(storage) do
            if pile.gridX >= bounds.minX and pile.gridX <= bounds.maxX
                and pile.gridZ >= bounds.minZ and pile.gridZ <= bounds.maxZ then
                local _, idealMax = CropValueMap.getIdealRange(pile.fillType)
                if idealMax and pile.properties.moisture then
                    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2
                    local fillLevel = DensityMapHeightUtil.getFillLevelAtArea(
                        pile.fillType,
                        pile.gridX - checkRadius, pile.gridZ - checkRadius,
                        pile.gridX + checkRadius, pile.gridZ - checkRadius,
                        pile.gridX - checkRadius, pile.gridZ + checkRadius
                    )
                    if fillLevel > 0 then
                        totalLiters = totalLiters + fillLevel
                        local existing = byFillType[pile.fillType]
                        if existing == nil or pile.properties.moisture > existing.moisture then
                            byFillType[pile.fillType] = {
                                fillTypeIndex = pile.fillType,
                                moisture = pile.properties.moisture,
                                idealMax = idealMax,
                                needsDrying = pile.properties.moisture > idealMax,
                            }
                        end
                    end
                end
            end
        end
    end

    local statuses = {}
    for _, status in pairs(byFillType) do
        table.insert(statuses, status)
    end
    return statuses, totalLiters
end

function DryingSystem:hasNeedsDrying(cropStatuses)
    for _, status in ipairs(cropStatuses) do
        if status.needsDrying then return true end
    end
    return false
end

-- Shared with onHourChanged's actual drying loop so the GUI's ETA matches reality.
function DryingSystem:calculateEffectiveDryingRate(totalLiters, ms)
    local dryingRate = ms.settings.dryingSpeed or DryingSystem.DEFAULT_DRYING_RATE
    local t = math.min(1, math.max(0, (totalLiters - 10000) / 90000))
    local volumeMultiplier = 1.4 - 0.8 * t
    return dryingRate * volumeMultiplier * ms:getScaleFactor()
end

-- Hours until every crop in cropStatuses reaches its idealMax, at the current rate.
-- nil if nothing needs drying (rate would never be spent) or the rate is zero.
function DryingSystem:calculateETA(cropStatuses, totalLiters, ms)
    local maxOvershoot = 0
    for _, status in ipairs(cropStatuses) do
        if status.needsDrying then
            maxOvershoot = math.max(maxOvershoot, status.moisture - status.idealMax)
        end
    end
    if maxOvershoot <= 0 then return nil end

    local effectiveDryingRate = self:calculateEffectiveDryingRate(totalLiters, ms)
    if effectiveDryingRate <= 0 then return nil end

    return maxOvershoot / effectiveDryingRate
end

-- Builds the full Grain Drying tab list: every silo/shed farmId owns that currently
-- holds at least one CropValueMap-tracked crop (or is already drying), with crop
-- breakdown, drying state and ETA, computed fresh at call time.
function DryingSystem:buildDryingListEntries(farmId)
    local ms = g_currentMission.MoistureSystem
    local entries = {}

    for _, placeable in ipairs(self:getOwnedDryables(farmId)) do
        local isSilo = placeable.spec_silo ~= nil
        local cropStatuses, totalLiters
        if isSilo then
            cropStatuses, totalLiters = self:getSiloCropStatus(placeable, ms)
        else
            cropStatuses, totalLiters = self:getShedCropStatus(placeable)
        end

        local isDrying = self:isDrying(placeable.uniqueId)

        -- Skip silos/sheds with no tracked crop in them at all, unless a stray
        -- activeDryers entry means the player still needs to be able to stop it.
        if #cropStatuses > 0 or isDrying then
            table.sort(cropStatuses, function(a, b)
                local nameA = g_fillTypeManager:getFillTypeNameByIndex(a.fillTypeIndex) or ""
                local nameB = g_fillTypeManager:getFillTypeNameByIndex(b.fillTypeIndex) or ""
                return nameA < nameB
            end)

            local etaHours = nil
            if isDrying or self:hasNeedsDrying(cropStatuses) then
                etaHours = self:calculateETA(cropStatuses, totalLiters, ms)
            end

            table.insert(entries, {
                placeable = placeable,
                uniqueId = placeable.uniqueId,
                name = placeable:getName() or "?",
                isSilo = isSilo,
                isDrying = isDrying,
                cropStatuses = cropStatuses,
                etaHours = etaHours,
            })
        end
    end

    table.sort(entries, function(a, b) return a.name < b.name end)
    return entries
end

function DryingSystem:toggleDrying(placeable)
    if placeable == nil then return end

    local placeableId = placeable.uniqueId
    if self.activeDryers[placeableId] then
        self.activeDryers[placeableId] = nil
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_stopped"))
    else
        self.activeDryers[placeableId] = true
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_started"))
    end
end

function DryingSystem:isDrying(placeableId)
    return self.activeDryers[placeableId] ~= nil
end

function DryingSystem:setDryingState(placeableUniqueId, isActive)
    if isActive then
        self.activeDryers[placeableUniqueId] = true
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_started"))
    else
        self.activeDryers[placeableUniqueId] = nil
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_stopped"))
    end
end

function DryingSystem:onHourChanged()
    if not g_currentMission:getIsServer() then return end

    local ms = g_currentMission.MoistureSystem
    local dryingRate = ms.settings.dryingSpeed or DryingSystem.DEFAULT_DRYING_RATE
    local sellChargeRate = ms.settings.sellDryingChargeRate or 1.0

    local completedDryers = {}

    for placeableId, _ in pairs(self.activeDryers) do
        local placeable = self:getPlaceableByUniqueId(placeableId)
        if placeable == nil then
            table.insert(completedDryers, placeableId)
        elseif placeable.spec_silo then
            self:drySilo(placeable, ms, dryingRate, sellChargeRate, completedDryers)
        elseif self:isTipOcclusionBuilding(placeable) then
            self:dryShed(placeable, ms, dryingRate, sellChargeRate, completedDryers)
        else
            table.insert(completedDryers, placeableId)
        end
    end

    for _, placeableId in ipairs(completedDryers) do
        self.activeDryers[placeableId] = nil
        local placeable = self:getPlaceableByUniqueId(placeableId)
        if placeable ~= nil then
            local objectId = NetworkUtil.getObjectId(placeable)
            if objectId ~= nil then
                g_server:broadcastEvent(DryingToggleEvent.new(objectId, false))
            end
        end
    end
end

function DryingSystem:drySilo(placeable, ms, dryingRate, sellChargeRate, completedDryers)
    local farmId = placeable:getOwnerFarmId()

    local byFillType, totalLiters = self:getSiloFillLevels(placeable)

    if not self:siloNeedsDrying(placeable, ms) then
        table.insert(completedDryers, placeable.uniqueId)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_complete"))
    else
        local effectiveDryingRate = self:calculateEffectiveDryingRate(totalLiters, ms)

        -- The largest reduction any crop actually got this hour. On every hour but the
        -- last this equals effectiveDryingRate; on the last it is whatever was left
        -- before math.max clipped to idealMax.
        local appliedRate = 0

        for fillTypeIndex, _ in pairs(byFillType) do
            local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
            if idealMax then
                local info = ms:getObjectInfo(placeable.uniqueId, fillTypeIndex)
                if info and info.moisture > idealMax then
                    local newMoisture = math.max(idealMax, info.moisture - effectiveDryingRate)
                    appliedRate = math.max(appliedRate, info.moisture - newMoisture)
                    info.moisture = newMoisture
                end
            end
        end

        local objectId = NetworkUtil.getObjectId(placeable)
        if objectId ~= nil then
            g_server:broadcastEvent(ObjectMoistureResponseEvent.new(objectId, ms.objectInfo[placeable.uniqueId]))
        end

        -- Bill for the moisture actually removed. Charging the nominal rate made the last
        -- hour of a run cost a full hour for a fraction of a point of drying, which reads
        -- in game as "it charged me again and the number didn't move" (the GUI rounds to
        -- whole percent, so 13.4% and 13.0% both show as 13%).
        local hourlyCost = DryingSystem.SILO_COST_RATIO * sellChargeRate * appliedRate * totalLiters
        if hourlyCost > 0 then
            g_currentMission:addMoneyChange(-hourlyCost, farmId, MoneyType.DRYING_CHARGE, true)
            g_farmManager:getFarmById(farmId):changeBalance(-hourlyCost, MoneyType.DRYING_CHARGE)
        end

        if not self:siloNeedsDrying(placeable, ms) then
            table.insert(completedDryers, placeable.uniqueId)
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                g_i18n:getText("ms_drying_complete"))
        end
    end
end

function DryingSystem:dryShed(placeable, ms, dryingRate, sellChargeRate, completedDryers)
    local bounds = self:getShedWorldBounds(placeable)
    if bounds == nil then
        table.insert(completedDryers, placeable.uniqueId)
        return
    end

    local tracker = g_currentMission.groundPropertyTracker
    local totalLiters = 0
    local pilesToDry = {}

    local allStorages = { tracker.gridPiles, tracker.grassPiles, tracker.hayPiles, tracker.strawPiles }
    for _, storage in ipairs(allStorages) do
        for _, pile in pairs(storage) do
            if pile.gridX >= bounds.minX and pile.gridX <= bounds.maxX
                and pile.gridZ >= bounds.minZ and pile.gridZ <= bounds.maxZ then
                local _, idealMax = CropValueMap.getIdealRange(pile.fillType)
                if idealMax and pile.properties.moisture and pile.properties.moisture > idealMax then
                    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2
                    local fillLevel = DensityMapHeightUtil.getFillLevelAtArea(
                        pile.fillType,
                        pile.gridX - checkRadius, pile.gridZ - checkRadius,
                        pile.gridX + checkRadius, pile.gridZ - checkRadius,
                        pile.gridX - checkRadius, pile.gridZ + checkRadius
                    )
                    if fillLevel > 0 then
                        totalLiters = totalLiters + fillLevel
                        table.insert(pilesToDry, { pile = pile, idealMax = idealMax })
                    end
                end
            end
        end
    end

    if #pilesToDry == 0 then
        table.insert(completedDryers, placeable.uniqueId)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_complete"))
        return
    end

    local effectiveDryingRate = self:calculateEffectiveDryingRate(totalLiters, ms)

    -- See drySilo: the largest reduction actually applied, so the final clipped hour is
    -- not billed as a full one.
    local appliedRate = 0
    for _, entry in ipairs(pilesToDry) do
        local newMoisture = math.max(entry.idealMax, entry.pile.properties.moisture - effectiveDryingRate)
        appliedRate = math.max(appliedRate, entry.pile.properties.moisture - newMoisture)
        entry.pile.properties.moisture = newMoisture
    end

    local farmId = placeable:getOwnerFarmId()
    local hourlyCost = DryingSystem.SILO_COST_RATIO * sellChargeRate * appliedRate * totalLiters
    if hourlyCost > 0 then
        g_currentMission:addMoneyChange(-hourlyCost, farmId, MoneyType.DRYING_CHARGE, true)
        g_farmManager:getFarmById(farmId):changeBalance(-hourlyCost, MoneyType.DRYING_CHARGE)
    end

    -- Notice completion in the hour the last pile reaches its ideal, the way drySilo
    -- already does. Without this the shed burned a further hour before reporting done.
    -- pilesToDry held every pile above ideal, so re-reading it is enough.
    for _, entry in ipairs(pilesToDry) do
        if entry.pile.properties.moisture > entry.idealMax then
            return
        end
    end

    table.insert(completedDryers, placeable.uniqueId)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
        g_i18n:getText("ms_drying_complete"))
end

function DryingSystem:siloNeedsDrying(placeable, ms)
    for fillTypeIndex, _ in pairs(self:getSiloFillLevels(placeable)) do
        local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
        if idealMax then
            local info = ms:getObjectInfo(placeable.uniqueId, fillTypeIndex)
            if info and info.moisture > idealMax then
                return true
            end
        end
    end
    return false
end

function DryingSystem:getPlaceableByUniqueId(uniqueId)
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable.uniqueId == uniqueId then
            return placeable
        end
    end
    return nil
end

function DryingSystem:saveToXMLFile(xmlFile, key)
    local i = 0
    for placeableId, _ in pairs(self.activeDryers) do
        local dryerKey = string.format("%s.activeDryers.dryer(%d)", key, i)
        setXMLString(xmlFile, dryerKey .. "#placeableId", placeableId)
        i = i + 1
    end
end

function DryingSystem:loadFromXMLFile(xmlFile, key)
    local i = 0
    while true do
        local dryerKey = string.format("%s.activeDryers.dryer(%d)", key, i)
        if not hasXMLProperty(xmlFile, dryerKey) then
            break
        end
        local placeableId = getXMLString(xmlFile, dryerKey .. "#placeableId")
        if placeableId then
            self.activeDryers[placeableId] = true
        end
        i = i + 1
    end
end
