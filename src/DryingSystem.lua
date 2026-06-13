DryingSystem = {}
local DryingSystem_mt = Class(DryingSystem)

DryingSystem.DEFAULT_DRYING_RATE = 0.01
DryingSystem.SILO_COST_RATIO = 0.7
DryingSystem.ACTIVATION_DISTANCE_BUFFER = 5

local PLAYER_CONTEXT = "PLAYER"

function DryingSystem.new()
    local self = setmetatable({}, DryingSystem_mt)
    self.activeDryers = {}
    self.activatables = {}
    self.shedBounds = {}
    self.placeableRadii = {}
    self.missionStarted = false
    return self
end

function DryingSystem:getPlaceableRadius(placeable)
    local cached = self.placeableRadii[placeable.uniqueId]
    if cached then return cached end

    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local found = false

    local function expandFromParallelogramAreas(areas)
        for _, area in ipairs(areas) do
            local startNode = area.start or area.startNode
            local widthNode = area.width or area.widthNode
            local heightNode = area.height or area.heightNode
            if startNode ~= nil and widthNode ~= nil and heightNode ~= nil then
                local sx, _, sz = localToLocal(startNode, placeable.rootNode, 0, 0, 0)
                local wx, _, wz = localToLocal(widthNode, placeable.rootNode, 0, 0, 0)
                local hx, _, hz = localToLocal(heightNode, placeable.rootNode, 0, 0, 0)
                local corners = { {sx, sz}, {wx, wz}, {hx, hz}, {wx + hx - sx, wz + hz - sz} }
                for _, c in ipairs(corners) do
                    minX = math.min(minX, c[1]); maxX = math.max(maxX, c[1])
                    minZ = math.min(minZ, c[2]); maxZ = math.max(maxZ, c[2])
                end
                found = true
            end
        end
    end

    if placeable.spec_clearAreas ~= nil and placeable.spec_clearAreas.areas ~= nil then
        expandFromParallelogramAreas(placeable.spec_clearAreas.areas)
    end
    if placeable.spec_leveling ~= nil and placeable.spec_leveling.levelAreas ~= nil then
        expandFromParallelogramAreas(placeable.spec_leveling.levelAreas)
    end
    if placeable.spec_placement ~= nil and placeable.spec_placement.testAreas ~= nil then
        for _, area in ipairs(placeable.spec_placement.testAreas) do
            if area.size ~= nil then
                local halfX = (area.size.x or 5) * 0.5
                local halfZ = (area.size.z or 5) * 0.5
                local cx = area.center ~= nil and area.center.x or 0
                local cz = area.center ~= nil and area.center.z or 0
                minX = math.min(minX, cx - halfX); maxX = math.max(maxX, cx + halfX)
                minZ = math.min(minZ, cz - halfZ); maxZ = math.max(maxZ, cz + halfZ)
                found = true
            end
        end
    end

    local radius
    if found then
        local sizeX = maxX - minX
        local sizeZ = maxZ - minZ
        radius = math.sqrt(sizeX * sizeX + sizeZ * sizeZ) * 0.5 + DryingSystem.ACTIVATION_DISTANCE_BUFFER
    else
        radius = 15 + DryingSystem.ACTIVATION_DISTANCE_BUFFER
    end

    self.placeableRadii[placeable.uniqueId] = radius
    return radius
end

function DryingSystem:registerActivatables()
    -- Remove activatables whose placeables no longer exist (e.g. sold silos)
    local toRemove = {}
    for placeableId, _ in pairs(self.activatables) do
        if self:getPlaceableByUniqueId(placeableId) == nil then
            table.insert(toRemove, placeableId)
        end
    end
    for _, placeableId in ipairs(toRemove) do
        self:removeActivatable(placeableId)
        self.activeDryers[placeableId] = nil
    end

    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_silo and placeable.spec_silo.storages then
            self:addActivatable(placeable)
        elseif self:isTipOcclusionBuilding(placeable) then
            self:addActivatable(placeable)
        end
    end
end

function DryingSystem:subscribe()
    g_messageCenter:subscribe(MessageType.FARM_PROPERTY_CHANGED, self.onFarmPropertyChanged, self)
end

function DryingSystem:unsubscribe()
    g_messageCenter:unsubscribe(MessageType.FARM_PROPERTY_CHANGED, self)
end

function DryingSystem:onFarmPropertyChanged()
    if not self.missionStarted then return end
    self:registerActivatables()
end

function DryingSystem:isTipOcclusionBuilding(placeable)
    if placeable.spec_silo then return false end
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

DryingSystem.SHED_CHECK_INTERVAL = 5000

function DryingSystem:shedHasWetPiles(placeable)
    local id = placeable.uniqueId
    local now = g_time or 0
    local cache = self.shedWetCache
    if cache == nil then
        cache = {}
        self.shedWetCache = cache
    end
    local entry = cache[id]
    if entry and (now - entry.time) < DryingSystem.SHED_CHECK_INTERVAL then
        return entry.result
    end

    local result = self:checkShedHasWetPiles(placeable)
    cache[id] = { time = now, result = result }
    return result
end

function DryingSystem:checkShedHasWetPiles(placeable)
    local bounds = self:getShedWorldBounds(placeable)
    if bounds == nil then return false end

    local tracker = g_currentMission.groundPropertyTracker
    local allStorages = { tracker.gridPiles, tracker.grassPiles, tracker.hayPiles, tracker.strawPiles }
    for _, storage in ipairs(allStorages) do
        for _, pile in pairs(storage) do
            if pile.gridX >= bounds.minX and pile.gridX <= bounds.maxX
                and pile.gridZ >= bounds.minZ and pile.gridZ <= bounds.maxZ then
                local _, idealMax = CropValueMap.getIdealRange(pile.fillType)
                if idealMax and pile.properties.moisture and pile.properties.moisture > idealMax then
                    return true
                end
            end
        end
    end
    return false
end

function DryingSystem:addActivatable(placeable)
    if self.activatables[placeable.uniqueId] then return end
    local activatable = DryingActivatable.new(self, placeable)
    self.activatables[placeable.uniqueId] = activatable
    g_currentMission.activatableObjectsSystem:addActivatable(activatable)
end

function DryingSystem:removeActivatable(placeableId)
    local activatable = self.activatables[placeableId]
    if activatable == nil then return end
    g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
    self.activatables[placeableId] = nil
    self.shedBounds[placeableId] = nil
    self.placeableRadii[placeableId] = nil
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
    end
end

function DryingSystem:drySilo(placeable, ms, dryingRate, sellChargeRate, completedDryers)
    local farmId = placeable:getOwnerFarmId()

    local totalLiters = 0
    for _, storage in ipairs(placeable.spec_silo.storages) do
        for _, fillLevel in pairs(storage.fillLevels) do
            if fillLevel > 0 then
                totalLiters = totalLiters + fillLevel
            end
        end
    end

    if not self:siloNeedsDrying(placeable, ms) then
        table.insert(completedDryers, placeable.uniqueId)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("ms_drying_complete"))
    else
        local volumeFactor = math.max(1, totalLiters / 10000)
        local effectiveDryingRate = dryingRate / volumeFactor

        for _, storage in ipairs(placeable.spec_silo.storages) do
            for fillTypeIndex, fillLevel in pairs(storage.fillLevels) do
                if fillLevel > 0 then
                    local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
                    if idealMax then
                        local info = ms:getObjectInfo(placeable.uniqueId, fillTypeIndex)
                        if info and info.moisture > idealMax then
                            info.moisture = math.max(idealMax, info.moisture - effectiveDryingRate)
                        end
                    end
                end
            end
        end

        local objectId = NetworkUtil.getObjectId(placeable)
        if objectId ~= nil then
            g_server:broadcastEvent(ObjectMoistureResponseEvent.new(objectId, ms.objectInfo[placeable.uniqueId]))
        end

        local hourlyCost = DryingSystem.SILO_COST_RATIO * sellChargeRate * effectiveDryingRate * totalLiters
        g_currentMission:addMoneyChange(-hourlyCost, farmId, MoneyType.DRYING_CHARGE, true)
        g_farmManager:getFarmById(farmId):changeBalance(-hourlyCost, MoneyType.DRYING_CHARGE)

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

    local volumeFactor = math.max(1, totalLiters / 10000)
    local effectiveDryingRate = dryingRate / volumeFactor

    for _, entry in ipairs(pilesToDry) do
        entry.pile.properties.moisture = math.max(entry.idealMax, entry.pile.properties.moisture - effectiveDryingRate)
    end

    local farmId = placeable:getOwnerFarmId()
    local hourlyCost = DryingSystem.SILO_COST_RATIO * sellChargeRate * effectiveDryingRate * totalLiters
    g_currentMission:addMoneyChange(-hourlyCost, farmId, MoneyType.DRYING_CHARGE, true)
    g_farmManager:getFarmById(farmId):changeBalance(-hourlyCost, MoneyType.DRYING_CHARGE)
end

function DryingSystem:siloNeedsDrying(placeable, ms)
    for _, storage in ipairs(placeable.spec_silo.storages) do
        for fillTypeIndex, fillLevel in pairs(storage.fillLevels) do
            if fillLevel > 0 then
                local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
                if idealMax then
                    local info = ms:getObjectInfo(placeable.uniqueId, fillTypeIndex)
                    if info and info.moisture > idealMax then
                        return true
                    end
                end
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

-- Activatable class for silo drying interaction
DryingActivatable = {}
local DryingActivatable_mt = Class(DryingActivatable)

function DryingActivatable.new(dryingSystem, placeable)
    local self = setmetatable({}, DryingActivatable_mt)
    self.dryingSystem = dryingSystem
    self.placeable = placeable
    self.activateText = g_i18n:getText("ms_action_startDrying")
    self.actionEventId = nil
    return self
end

function DryingActivatable:delete()
    self.dryingSystem:removeActivatable(self.placeable.uniqueId)
end

function DryingActivatable:getIsActivatable()
    if self.placeable == nil or self.placeable.rootNode == nil then return false end
    if not entityExists(self.placeable.rootNode) then
        self:delete()
        return false
    end
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then return false end
    if g_localPlayer:getCurrentVehicle() ~= nil then return false end

    local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)

    if self.dryingSystem:isTipOcclusionBuilding(self.placeable) then
        if not self:isPlayerInsideShed(px, pz) then return false end
        if not self.dryingSystem:isDrying(self.placeable.uniqueId) and not self.dryingSystem:shedHasWetPiles(self.placeable) then return false end
    else
        local tx, _, tz = getWorldTranslation(self.placeable.rootNode)
        if tx == nil then return false end
        local activationRadius = self.dryingSystem:getPlaceableRadius(self.placeable)
        if MathUtil.vector2Length(px - tx, pz - tz) > activationRadius then
            return false
        end

        local ms = g_currentMission.MoistureSystem
        local objectData = ms.objectInfo[self.placeable.uniqueId]
        if not objectData then return false end

        local hasMoisture = false
        for _, info in pairs(objectData) do
            if info.moisture then
                hasMoisture = true
                break
            end
        end
        if not hasMoisture then return false end
    end

    if self.dryingSystem:isDrying(self.placeable.uniqueId) then
        self.activateText = g_i18n:getText("ms_action_stopDrying")
    else
        self.activateText = g_i18n:getText("ms_action_startDrying")
    end

    return true
end

function DryingActivatable:isPlayerInsideShed(px, pz)
    local bounds = self.dryingSystem:getShedWorldBounds(self.placeable)
    if bounds == nil then return false end
    return px >= bounds.minX and px <= bounds.maxX and pz >= bounds.minZ and pz <= bounds.maxZ
end

function DryingActivatable:getDistance(x, _, z)
    if self.placeable == nil or self.placeable.rootNode == nil then return math.huge end
    if not entityExists(self.placeable.rootNode) then
        self:delete()
        return math.huge
    end
    local tx, _, tz = getWorldTranslation(self.placeable.rootNode)
    if tx == nil then return math.huge end
    return MathUtil.vector2Length(x - tx, z - tz)
end

function DryingActivatable:registerCustomInput(inputContext)
    if inputContext ~= PLAYER_CONTEXT then
        return
    end

    local _, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.MOISTURE_START_DRYING,
        self,
        self.onKeybindPressed,
        false,
        true,
        false,
        true
    )

    if actionEventId ~= nil and actionEventId ~= "" then
        self.actionEventId = actionEventId
        g_inputBinding:setActionEventText(actionEventId, self.activateText)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
        g_inputBinding:setActionEventTextVisibility(actionEventId, true)
    end
end

function DryingActivatable:removeCustomInput()
    g_inputBinding:removeActionEventsByTarget(self)
    self.actionEventId = nil
end

function DryingActivatable:onKeybindPressed()
    if self.placeable == nil then return end

    if g_currentMission:getIsServer() then
        self.dryingSystem:toggleDrying(self.placeable)
    else
        g_client:getServerConnection():sendEvent(DryingToggleEvent.new(self.placeable.uniqueId))
    end

    if self.actionEventId then
        if self.dryingSystem:isDrying(self.placeable.uniqueId) then
            g_inputBinding:setActionEventText(self.actionEventId, g_i18n:getText("ms_action_stopDrying"))
        else
            g_inputBinding:setActionEventText(self.actionEventId, g_i18n:getText("ms_action_startDrying"))
        end
    end
end

function DryingActivatable:run()
    self:onKeybindPressed()
end
