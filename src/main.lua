MoistureSystem = {}

MoistureSystem.dir = g_currentModDirectory
MoistureSystem.SaveKey = "MoistureSystem"

function MoistureSystem:loadMap()
    g_currentMission.MoistureSystem = self
    self.didLoadFromXML = false
    self.dryingInfoShown = false
    self.midHeight = 0
    self.currentMoisturePercent = 0
    self.timeSinceLastUpdate = 0
    self.updateInterval = 500
    self.syncInterval = 2000
    self.timeSinceLastSync = 0
    self.moistureDirty = false
    self.missionStarted = false

    self.settings = {
        weatherProfile = "ukwest",
        moistureLossMultiplier = 3.0,
        moistureGainMultiplier = 3.0,
        teddingMoistureReduction = 0.02,
        baleRotEnabled = true,
        baleRotRate = 1.0,
        baleExposureDecayRate = 1.0,
        qualityDecayMultiplier = 1.0,
        dryingSpeed = 0.01,
        sellDryingChargeRate = 1.0,
        showFieldMoisture = false,
        moistureMeterReporting = MoistureSettings.METER_REPORTING_BLINKING
    }

    g_currentMission.groundPropertyTracker = GroundPropertyTracker.new()

    g_currentMission.baleRottingSystem = BaleRottingSystem.new()

    g_currentMission.dryingSystem = DryingSystem.new()

    self.objectInfo = {}
    self.objectMoistureTimestamps = {}
    self.pendingObjectRequests = {}

    self.QUALITY_DECAY_RATE = 0.167

    -- Initialize LRU cache for getMoistureAtPosition
    self.moistureCache = {}
    self.moistureCacheOrder = {}
    self.moistureCacheMaxSize = 10

    self:loadFromXMLFile()

    if g_gui then
        MoistureSettings.addSettingsToMenu()
    end

    self:loadGUI()

    if g_addCheatCommands and g_currentMission:getIsServer() then
        addConsoleCommand("msSetMoisture", "Set Moisture", "consoleCommandSetMoisture", self)
        local wps = g_currentMission.WeatherProfileSystem
        addConsoleCommand("msWeatherDebug", "Dump active weather profile/scenario", "consoleCommandWeatherDebug", wps)
        addConsoleCommand("msSetScenario", "Force-set active weather scenario", "consoleCommandSetScenario", wps)
        addConsoleCommand("msListScenarios", "List scenarios for active profile", "consoleCommandListScenarios", wps)
    end
end

function MoistureSystem:consoleCommandSetMoisture(newMoisture)
    if not g_currentMission:getIsServer() then return end
    local newMoistureNum = tonumber(newMoisture)
    if newMoisture == nil or newMoistureNum == nil then
        return "Usage: msSetMoisture value[1-100]"
    end
    newMoistureNum = math.max(1, math.min(100, newMoistureNum)) / 100
    self.currentMoisturePercent = newMoistureNum
    self.moistureCache = {}
    self.moistureCacheOrder = {}
    self.moistureDirty = true
    return string.format("New moisture is %.3f", newMoistureNum)
end

function MoistureSystem:delete()
    if g_addCheatCommands then
        removeConsoleCommand("msSetMoisture")
        removeConsoleCommand("msWeatherDebug")
        removeConsoleCommand("msSetScenario")
        removeConsoleCommand("msListScenarios")
    end
end



function MoistureSystem:loadGUI()
    g_gui:loadProfiles(MoistureSystem.dir .. "src/gui/guiProfiles.xml")
    local gradesFrame = MoistureGuiGrades.new(g_i18n)
    g_gui:loadGui(MoistureSystem.dir .. "src/gui/MoistureGuiGrades.xml", "MoistureGuiGrades", gradesFrame, true)

    local pricesFrame = MoistureGuiPrices.new(g_i18n)
    g_gui:loadGui(MoistureSystem.dir .. "src/gui/MoistureGuiPrices.xml", "MoistureGuiPrices", pricesFrame, true)

    local calendarFrame = MoistureGuiCalendar.new(g_i18n)
    g_gui:loadGui(MoistureSystem.dir .. "src/gui/MoistureGuiCalendar.xml", "MoistureGuiCalendar", calendarFrame, true)

    self.moistureGui = MoistureGui:new(g_messageCenter, g_i18n, g_inputBinding)
    g_gui:loadGui(MoistureSystem.dir .. "src/gui/MoistureGui.xml", "MoistureGui", self.moistureGui)
end

function MoistureSystem:update(dt)
    if not g_currentMission:getIsServer() then return end

    self.timeSinceLastUpdate = self.timeSinceLastUpdate + dt

    -- Only update every updateInterval milliseconds
    if self.timeSinceLastUpdate >= self.updateInterval then
        self:updateMoistureLevel(self.timeSinceLastUpdate)
        self.timeSinceLastUpdate = 0
    end

    if g_currentMission.baleRottingSystem then
        g_currentMission.baleRottingSystem:update(dt)
    end

    SellingStationExtension.update()

    -- Sync to clients periodically (batched)
    self.timeSinceLastSync = self.timeSinceLastSync + dt
    if self.timeSinceLastSync >= self.syncInterval then
        self:syncToClients()
        self.timeSinceLastSync = 0
    end
end

---
-- Update moisture level based on weather conditions
-- @param timescale: Time elapsed in milliseconds since last update
---
function MoistureSystem:updateMoistureLevel(delta)
    if not g_currentMission:getIsServer() then return end
    local scaledDelta = (delta * g_currentMission:getEffectiveTimeScale()) / 10000000
    local weather = g_currentMission.environment.weather

    -- Get current weather conditions
    local rainfall = weather:getRainFallScale()
    local snowfall = weather:getSnowFallScale()
    local hailfall = weather:getHailFallScale()
    local temperature = weather.temperatureUpdater.currentTemperature or 20
    local currentHour = g_currentMission.environment.currentHour

    -- Calculate moisture delta
    local moistureDelta = 0

    if rainfall > 0 or snowfall > 0 or hailfall > 0 then
        moistureDelta = (rainfall + (snowfall * 0.55) + (hailfall * 0.5)) * 0.009945 * scaledDelta *
            self.settings.moistureGainMultiplier
        self:adjustMoisture(moistureDelta)
    else
        -- Lose moisture from temperature (warmer = more loss)
        -- Only lose during daytime (6am-8pm) or reduced loss at night
        local daylightStart = 6
        local daylightEnd = 20
        local sunFactor = (currentHour >= daylightStart and currentHour < daylightEnd) and 1 or 0.33

        local rateFactor = 0
        if temperature >= 45 then
            rateFactor = temperature * 0.001024
        elseif temperature >= 35 then
            rateFactor = temperature * 0.00075096
        elseif temperature >= 25 then
            rateFactor = temperature * 0.00032424
        elseif temperature >= 15 then
            rateFactor = temperature * 0.0001024
        else
            rateFactor = temperature * 0.00004264
        end

        moistureDelta = moistureDelta - (rateFactor * scaledDelta * sunFactor * self.settings.moistureLossMultiplier)

        self:adjustMoisture(moistureDelta)
    end

    if g_currentMission.groundPropertyTracker then
        g_currentMission.groundPropertyTracker:updateGrassMoisture(moistureDelta, delta)
        g_currentMission.groundPropertyTracker:updateHayMoisture(moistureDelta)
        g_currentMission.groundPropertyTracker:updateStrawMoisture(moistureDelta, delta)
    end
end

---
-- Adjust current moisture level while respecting min/max clamps
-- @param delta: Amount to change moisture (can be positive or negative)
---
function MoistureSystem:adjustMoisture(delta)
    if not g_currentMission:getIsServer() then return end
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)

    local clamp = g_currentMission.WeatherProfileSystem:getClampForMonth(month)
    local minMoisture = clamp.min / 100
    local maxMoisture = clamp.max / 100

    -- Calculate 80% of range to leave headroom for terrain-based variation
    local rangeSize = maxMoisture - minMoisture
    local innerMin = minMoisture + (rangeSize * 0.1)
    local innerMax = maxMoisture - (rangeSize * 0.1)

    -- Apply delta and clamp to 80% of range
    local newMoisture = math.max(innerMin, math.min(innerMax, self.currentMoisturePercent + delta))

    if newMoisture ~= self.currentMoisturePercent then
        self.currentMoisturePercent = newMoisture
        self.moistureCache = {}
        self.moistureCacheOrder = {}
        self.moistureDirty = true
    end
end

function MoistureSystem:getMoistureAtPosition(x, z)
    -- Check cache first (round to 5m grid for better hit rate)
    local cacheKey = string.format("%d_%d", math.floor(x / 5) * 5, math.floor(z / 5) * 5)
    if self.moistureCache[cacheKey] ~= nil then
        return self.moistureCache[cacheKey]
    end

    local height = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)

    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local clamp = g_currentMission.WeatherProfileSystem:getClampForMonth(month)
    local minMoisture = clamp.min / 100
    local maxMoisture = clamp.max / 100

    local moistureLevel
    -- Higher elevation = lower moisture, lower elevation = higher moisture
    local heightRange = self.maxHeight - self.minHeight
    if heightRange > 0 then
        local heightDiff = height - self.midHeight

        local headroomAbove = maxMoisture - self.currentMoisturePercent
        local headroomBelow = self.currentMoisturePercent - minMoisture
        local maxAdjustmentUp = math.min(0.02, 0.8 * headroomAbove)
        local maxAdjustmentDown = math.min(0.02, 0.8 * headroomBelow)

        local heightFactor
        if heightDiff < 0 then
            -- Below midHeight: use distance to minHeight as range
            local rangeToMin = self.midHeight - self.minHeight
            heightFactor = rangeToMin > 0 and (heightDiff / rangeToMin) or 0
            moistureLevel = self.currentMoisturePercent - (heightFactor * maxAdjustmentUp)
        else
            -- Above midHeight: use distance to maxHeight as range
            local rangeToMax = self.maxHeight - self.midHeight
            heightFactor = rangeToMax > 0 and (heightDiff / rangeToMax) or 0
            moistureLevel = self.currentMoisturePercent - (heightFactor * maxAdjustmentDown)
        end

        moistureLevel = math.max(minMoisture, math.min(maxMoisture, moistureLevel))
    else
        moistureLevel = self.currentMoisturePercent
    end

    -- Store in cache with LRU eviction
    if #self.moistureCacheOrder >= self.moistureCacheMaxSize then
        local oldestKey = table.remove(self.moistureCacheOrder, 1)
        self.moistureCache[oldestKey] = nil
    end
    self.moistureCache[cacheKey] = moistureLevel
    table.insert(self.moistureCacheOrder, cacheKey)

    return moistureLevel
end

function MoistureSystem:firstLoad()
    local month = MoistureSystem.periodToMonth(g_currentMission.environment.currentPeriod)
    local clamp = g_currentMission.WeatherProfileSystem:getClampForMonth(month)
    local startMoisture = clamp.max * 0.85
    self.currentMoisturePercent = startMoisture / 100
end

function MoistureSystem:setHeights()
    local heights = {}
    for _, farmland in pairs(g_farmlandManager.farmlands) do
        if farmland.showOnFarmlandsScreen and farmland.field ~= nil then
            local field = farmland.field
            local x, z = field:getCenterOfFieldWorldPosition()
            local height = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
            table.insert(heights, height)
        end
    end

    if #heights > 0 then
        table.sort(heights)

        -- Use median for midHeight
        local midIndex = math.ceil(#heights / 2)
        self.midHeight = heights[midIndex]

        -- Use full range (min and max) so heightFactor stays within [-1, 1]
        self.minHeight = heights[1]
        self.maxHeight = heights[#heights]
    else
        self.minHeight = 0
        self.maxHeight = 0
        self.midHeight = 0
    end
end

function MoistureSystem.periodToMonth(period)
    period = period + 2
    if period > 12 then
        period = period - 12
    end
    return period
end

function MoistureSystem:getObjectInfo(uniqueId, fillType)
    if uniqueId == nil or fillType == nil then
        return nil
    end

    if not self:shouldTrackFillType(fillType) then
        return nil
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    if fillTypeName == nil then
        return nil
    end

    local objectData = self.objectInfo[uniqueId]
    if objectData == nil then
        return nil
    end

    return objectData[fillTypeName]
end

function MoistureSystem:getObjectMoisture(uniqueId, fillType)
    local info = self:getObjectInfo(uniqueId, fillType)
    if info == nil then
        return nil
    end
    return info.moisture
end

function MoistureSystem:getObjectQuality(uniqueId, fillType)
    local info = self:getObjectInfo(uniqueId, fillType)
    if info == nil then
        return nil
    end
    return info.quality
end

---
-- Check if an object still has any of a specific fillType
-- @param uniqueId: The uniqueId of the object
-- @param fillType: FillType index to check
-- @return true if object has this fillType with fill level > 0
---
function MoistureSystem:hasFillType(uniqueId, fillType)
    if uniqueId == nil or fillType == nil then
        return false
    end

    if not self:shouldTrackFillType(fillType) then
        return false
    end

    local object = g_currentMission:getObjectByUniqueId(uniqueId)
    if object == nil then
        return false
    end

    if object.spec_silo then
        if object.spec_silo.storages then
            for _, storage in ipairs(object.spec_silo.storages) do
                local fillLevel = storage:getFillLevel(fillType)
                if fillLevel and fillLevel > 0 then
                    return true
                end
            end
        end
        return false
    end

    if object.spec_fillUnit == nil or object.spec_fillUnit.fillUnits == nil then
        return false
    end

    -- Check all fill units to see if any contain this fillType
    for _, fillUnit in pairs(object.spec_fillUnit.fillUnits) do
        if fillUnit.fillType == fillType and fillUnit.fillLevel > 0 then
            return true
        end
    end

    return false
end

function MoistureSystem:setObjectInfo(uniqueId, fillType, info)
    if not g_currentMission:getIsServer() then
        return
    end

    if uniqueId == nil or fillType == nil then
        return
    end

    if not self:shouldTrackFillType(fillType) then
        return
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    if fillTypeName == nil then
        return
    end

    if self.objectInfo[uniqueId] == nil then
        self.objectInfo[uniqueId] = {}
    end
    self.objectInfo[uniqueId][fillTypeName] = self:hasFillType(uniqueId, fillType) and info or nil

    if self.objectInfo[uniqueId] then
        for storedFillTypeName, storedInfo in pairs(self.objectInfo[uniqueId]) do
            if storedFillTypeName ~= fillTypeName and storedInfo ~= nil then
                local storedFillType = g_fillTypeManager:getFillTypeIndexByName(storedFillTypeName)
                if storedFillType and not self:hasFillType(uniqueId, storedFillType) then
                    self.objectInfo[uniqueId][storedFillTypeName] = nil
                end
            end
        end
    end
end

function MoistureSystem:setObjectMoisture(uniqueId, fillType, moisture)
    if moisture == nil then
        self:setObjectInfo(uniqueId, fillType, nil)
        return
    end

    local existing = self:getObjectInfo(uniqueId, fillType)
    if existing then
        existing.moisture = moisture
        self:setObjectInfo(uniqueId, fillType, existing)
    else
        local quality = self:deriveQuality(fillType, moisture)
        self:setObjectInfo(uniqueId, fillType, { moisture = moisture, quality = quality })
    end
end

function MoistureSystem:initializeQualityFromMoisture()
    for _, fillTypes in pairs(self.objectInfo) do
        for fillTypeName, info in pairs(fillTypes) do
            if info.quality == nil and info.moisture then
                local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
                if fillTypeIndex then
                    info.quality = self:deriveQuality(fillTypeIndex, info.moisture)
                end
            end
        end
    end

    if g_currentMission.groundPropertyTracker then
        local allStorages = {
            g_currentMission.groundPropertyTracker.gridPiles,
            g_currentMission.groundPropertyTracker.grassPiles,
            g_currentMission.groundPropertyTracker.hayPiles,
            g_currentMission.groundPropertyTracker.strawPiles
        }
        for _, storage in ipairs(allStorages) do
            for _, pile in pairs(storage) do
                if pile.properties.quality == nil and pile.properties.moisture then
                    pile.properties.quality = self:deriveQuality(pile.fillType, pile.properties.moisture)
                end
            end
        end
    end
end

function MoistureSystem:deriveQuality(fillType, moisture)
    if CropValueMap.Data == nil then
        return 100
    end
    local grade, multiplier = CropValueMap.getGrade(fillType, moisture)
    if multiplier then
        if grade == CropValueMap.Grades.A then
            return 100
        end
        return math.floor(multiplier * 100) - 1
    end

    local baseFillType = self:getBaseCropFillType(fillType)
    if baseFillType and baseFillType ~= fillType then
        grade, multiplier = CropValueMap.getGrade(baseFillType, moisture)
        if multiplier then
            if grade == CropValueMap.Grades.A then
                return 100
            end
            return math.floor(multiplier * 100) - 1
        end
    end

    return 100
end

function MoistureSystem:getBaseCropFillType(fillType)
    if self.swathFillTypes == nil then return nil end
    return self.swathFillTypes[fillType]
end

function MoistureSystem:transferObjectInfo(sourceId, targetId, sourceLiters, targetCurrentLiters, fillType)
    if sourceId == nil or targetId == nil or sourceLiters <= 0 or fillType == nil then
        return
    end

    if not self:shouldTrackFillType(fillType) then
        return
    end

    local sourceInfo = self:getObjectInfo(sourceId, fillType)
    local targetInfo = self:getObjectInfo(targetId, fillType)

    local sourceMoisture = sourceInfo and sourceInfo.moisture or nil
    local sourceQuality = sourceInfo and sourceInfo.quality or nil

    local targetMoisture = targetInfo and targetInfo.moisture or nil
    local targetQuality = targetInfo and targetInfo.quality or nil

    if sourceMoisture == nil and targetMoisture == nil then
        sourceMoisture = self.currentMoisturePercent
        sourceQuality = self:deriveQuality(fillType, sourceMoisture)
    elseif sourceMoisture == nil then
        return
    end

    if sourceQuality == nil then
        sourceQuality = self:deriveQuality(fillType, sourceMoisture)
    end

    if targetMoisture == nil or targetCurrentLiters <= 0 then
        self:setObjectInfo(targetId, fillType, { moisture = sourceMoisture, quality = sourceQuality })
    else
        if targetQuality == nil then
            targetQuality = self:deriveQuality(fillType, targetMoisture)
        end
        local totalLiters = targetCurrentLiters + sourceLiters
        local weightedMoisture = (targetCurrentLiters * targetMoisture) + (sourceLiters * sourceMoisture)
        local weightedQuality = (targetCurrentLiters * targetQuality) + (sourceLiters * sourceQuality)
        self:setObjectInfo(targetId, fillType, {
            moisture = weightedMoisture / totalLiters,
            quality = weightedQuality / totalLiters
        })
    end

    if not self:hasFillType(sourceId, fillType) then
        self:setObjectInfo(sourceId, fillType, nil)
    end
end

function MoistureSystem:transferObjectMoisture(sourceId, targetId, sourceLiters, targetCurrentLiters, fillType)
    self:transferObjectInfo(sourceId, targetId, sourceLiters, targetCurrentLiters, fillType)
end

---
-- Build the fillType -> classification cache from the TEDDER converter table.
-- Lazily called by the classification accessors so it works during savegame
-- load (before onStartMission).
---
function MoistureSystem:ensureFillTypeClassification()
    if self.fillTypeClass ~= nil then return end

    local class = {}
    local converter = g_fillTypeManager:getConverterDataByName("TEDDER")
    if converter ~= nil then
        for fromFillType, to in pairs(converter) do
            local targetFillType = to.targetFillTypeIndex
            if fromFillType ~= targetFillType then
                class[fromFillType] = "grass"
                class[targetFillType] = "hay"
            end
        end
    end
    self.fillTypeClass = class
end

---
-- Check if fillType is grass or grass windrow
-- @param fillType: The filltype index
-- @return true if grass type
---
function MoistureSystem:isGrassOnGroundFillType(fillType)
    self:ensureFillTypeClassification()
    return self.fillTypeClass[fillType] == "grass"
end

---
-- Check if fillType is a hay/dry grass type (converted grass)
-- @param fillType: The filltype index
-- @return true if hay/dry type
---
function MoistureSystem:isHayFillType(fillType)
    self:ensureFillTypeClassification()
    return self.fillTypeClass[fillType] == "hay"
end

---
-- Check if fillType is straw
-- @param fillType: The filltype index
-- @return true if straw type
---
function MoistureSystem:isStrawFillType(fillType)
    return fillType == FillType.STRAW
end

---
-- Check if fillType should be tracked (defined in CropValueMap or special types)
-- @param fillType: The filltype index
-- @return true if should be tracked
---
function MoistureSystem:shouldTrackFillType(fillType)
    if self:isGrassOnGroundFillType(fillType) then
        return true
    end

    if self:isStrawFillType(fillType) then
        return true
    end

    if CropValueMap.Data ~= nil and CropValueMap.Data[fillType] ~= nil then
        return true
    end

    if self:isSwathFillType(fillType) then
        return true
    end

    return false
end

function MoistureSystem:isSwathFillType(fillType)
    return self.swathFillTypes ~= nil and self.swathFillTypes[fillType] ~= nil
end

---
-- Get the default moisture for silo-loaded crops
-- Uses current field moisture as baseline
-- @return moisture level (0-1 scale)
---
function MoistureSystem:getDefaultMoisture()
    return self.currentMoisturePercent
end

function MoistureSystem:initializeSwathFillTypes()
    self.swathFillTypes = {}
    local converter = g_fruitTypeManager:getConverterDataByName("COMBINE_MOWER")
    if converter == nil then return end

    for fruitTypeIndex, conversion in pairs(converter) do
        local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        if fruitType and fruitType.fillType then
            self.swathFillTypes[conversion.fillTypeIndex] = fruitType.fillType.index
        end
    end
end

function MoistureSystem:onStartMission()
    CropValueMap.initialize()
    CropValueMap.initializeQualityBands()
    local ms = g_currentMission.MoistureSystem
    ms:initializeSwathFillTypes()
    ms:setHeights()
    ms.missionStarted = true

    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, MoistureSystem.onHourChanged, ms)
        ms:initializeQualityFromMoisture()
    end

    if g_currentMission.dryingSystem then
        g_currentMission.dryingSystem.missionStarted = true
        g_currentMission.dryingSystem:registerActivatables()
        g_currentMission.dryingSystem:subscribe()
    end


    if not ms.dryingInfoShown and g_dedicatedServer == nil then
        ms.dryingInfoShown = true
        Timer.createOneshot(100, function()
            InfoDialog.show(g_i18n:getText("ms_info_dryingUpdate"))
        end)
    end

    if g_currentMission:getIsServer() then
        -- Initialize mod on new game
        if not ms.didLoadFromXML then
            ms:firstLoad()
        else
            local loadedGridSize = g_currentMission.groundPropertyTracker.loadedGridSize
            if loadedGridSize ~= GroundPropertyTracker.GRID_SIZE then
                print(string.format(
                    "GroundPropertyTracker: Grid size changed from %d to %d, converting saved data...",
                    loadedGridSize, GroundPropertyTracker.GRID_SIZE
                ))
                g_currentMission.groundPropertyTracker:convertGridCells(loadedGridSize, GroundPropertyTracker.GRID_SIZE)
            end
        end

        -- Convert rotting bales in storage to live storage (after rotting data is loaded)
        MSPlaceableObjectStorageExtension.convertRottingBalesToLiveStorage()
    end
end

function MoistureSystem:onHourChanged()
    if not g_currentMission:getIsServer() then return end

    local decayMultiplier = self.settings.qualityDecayMultiplier or 1.0

    for _, fillTypes in pairs(self.objectInfo) do
        for fillTypeName, info in pairs(fillTypes) do
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if fillTypeIndex and info.moisture and info.quality then
                local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
                if idealMax and info.moisture > idealMax then
                    local overshoot = info.moisture - idealMax
                    local degradation = self.QUALITY_DECAY_RATE * overshoot * 100 * decayMultiplier
                    info.quality = math.max(0, info.quality - degradation)
                end
            end
        end
    end

    if g_currentMission.groundPropertyTracker then
        g_currentMission.groundPropertyTracker:degradeQuality(self.QUALITY_DECAY_RATE, decayMultiplier)
    end

    if g_currentMission.dryingSystem then
        g_currentMission.dryingSystem:onHourChanged()
    end
end

function MoistureSystem:loadFromXMLFile()
    if not g_currentMission:getIsServer() then return end

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory
    if savegameFolderPath == nil then
        savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(), g_currentMission.missionInfo.savegameIndex)
    end
    savegameFolderPath = savegameFolderPath .. "/"

    if fileExists(savegameFolderPath .. MoistureSystem.SaveKey .. ".xml") then
        local xmlFile = loadXMLFile(MoistureSystem.SaveKey, savegameFolderPath .. MoistureSystem.SaveKey .. ".xml")

        -- Load current moisture level
        local currentMoisture = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. "#currentMoisturePercent")
        if currentMoisture then
            self.currentMoisturePercent = currentMoisture
        end

        -- Load settings
        local weatherProfile = getXMLString(xmlFile, MoistureSystem.SaveKey .. ".settings#weatherProfile")
        if weatherProfile then
            self.settings.weatherProfile = weatherProfile
        end

        local lossMultiplier = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#moistureLossMultiplier")
        if lossMultiplier then
            self.settings.moistureLossMultiplier = lossMultiplier
        end

        local gainMultiplier = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#moistureGainMultiplier")
        if gainMultiplier then
            self.settings.moistureGainMultiplier = gainMultiplier
        end

        local teddingReduction = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#teddingMoistureReduction")
        if teddingReduction then
            self.settings.teddingMoistureReduction = teddingReduction
        end

        local baleRotEnabled = getXMLBool(xmlFile, MoistureSystem.SaveKey .. ".settings#baleRotEnabled")
        if baleRotEnabled ~= nil then
            self.settings.baleRotEnabled = baleRotEnabled
        end

        local baleRotRate = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#baleRotRate")
        if baleRotRate then
            self.settings.baleRotRate = baleRotRate
        end

        local baleExposureDecayRate = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#baleExposureDecayRate")
        if baleExposureDecayRate then
            self.settings.baleExposureDecayRate = baleExposureDecayRate
        end

        local qualityDecayMultiplier = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#qualityDecayMultiplier")
        if qualityDecayMultiplier then
            self.settings.qualityDecayMultiplier = qualityDecayMultiplier
        end


        local dryingSpeed = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#dryingSpeed")
        if dryingSpeed then
            self.settings.dryingSpeed = dryingSpeed
        end

        local sellDryingChargeRate = getXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#sellDryingChargeRate")
        if sellDryingChargeRate then
            self.settings.sellDryingChargeRate = sellDryingChargeRate
        end

        local showFieldMoisture = getXMLBool(xmlFile, MoistureSystem.SaveKey .. ".settings#showFieldMoisture")
        if showFieldMoisture ~= nil then
            self.settings.showFieldMoisture = showFieldMoisture
        end

        local moistureMeterReporting = getXMLInt(xmlFile, MoistureSystem.SaveKey .. ".settings#moistureMeterReporting")
        if moistureMeterReporting then
            self.settings.moistureMeterReporting = moistureMeterReporting
        end

        local dryingInfoShown = getXMLBool(xmlFile, MoistureSystem.SaveKey .. "#dryingInfoShown")
        if dryingInfoShown ~= nil then
            self.dryingInfoShown = dryingInfoShown
        end

        if g_currentMission.groundPropertyTracker then
            g_currentMission.groundPropertyTracker:loadFromXMLFile(xmlFile, MoistureSystem.SaveKey)
        end

        if g_currentMission.baleRottingSystem then
            g_currentMission.baleRottingSystem:loadFromXMLFile(xmlFile, MoistureSystem.SaveKey)
        end

        if g_currentMission.dryingSystem then
            g_currentMission.dryingSystem:loadFromXMLFile(xmlFile, MoistureSystem.SaveKey)
        end

        -- Load object info data (moisture + quality)
        local i = 0
        while true do
            local objectKey = string.format("%s.objectMoisture.object(%d)", MoistureSystem.SaveKey, i)
            if not hasXMLProperty(xmlFile, objectKey) then
                break
            end

            local uniqueId = getXMLString(xmlFile, objectKey .. "#uniqueId")

            if uniqueId then
                local j = 0
                while true do
                    local fillTypeKey = string.format("%s.fillType(%d)", objectKey, j)

                    if not hasXMLProperty(xmlFile, fillTypeKey) then
                        break
                    end

                    local fillTypeName = getXMLString(xmlFile, fillTypeKey .. "#name")
                    local moisture = getXMLFloat(xmlFile, fillTypeKey .. "#moisture")

                    if fillTypeName and moisture then
                        if self.objectInfo[uniqueId] == nil then
                            self.objectInfo[uniqueId] = {}
                        end
                        local quality = getXMLFloat(xmlFile, fillTypeKey .. "#quality")
                        self.objectInfo[uniqueId][fillTypeName] = { moisture = moisture, quality = quality }
                    end

                    j = j + 1
                end
            end

            i = i + 1
        end

        -- Load storage bale uniqueId mappings
        i = 0
        while true do
            local storageKey = string.format("%s.storageBales.bale(%d)", MoistureSystem.SaveKey, i)
            if not hasXMLProperty(xmlFile, storageKey) then
                break
            end

            local placeableId = getXMLString(xmlFile, storageKey .. "#placeableId")
            local objectIndex = getXMLInt(xmlFile, storageKey .. "#objectIndex") -- 0-based
            local uniqueId = getXMLString(xmlFile, storageKey .. "#uniqueId")

            if placeableId and objectIndex ~= nil and uniqueId then
                -- Store mapping to apply when loading storage (will be done by loadFromXMLFile override)
                if not self.pendingStorageBaleIds then
                    self.pendingStorageBaleIds = {}
                end
                if not self.pendingStorageBaleIds[placeableId] then
                    self.pendingStorageBaleIds[placeableId] = {}
                end
                self.pendingStorageBaleIds[placeableId][objectIndex] = uniqueId
            end

            i = i + 1
        end

        if g_currentMission.WeatherProfileSystem then
            g_currentMission.WeatherProfileSystem:loadFromXMLFile(xmlFile, MoistureSystem.SaveKey)
        end

        self.didLoadFromXML = true
        delete(xmlFile)
    end
end

function MoistureSystem:saveToXmlFile()
    if not g_currentMission:getIsServer() then return end

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    if savegameFolderPath == nil then
        savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(),
            g_currentMission.missionInfo.savegameIndex .. "/")
    end

    local xmlFile = createXMLFile(MoistureSystem.SaveKey, savegameFolderPath .. MoistureSystem.SaveKey .. ".xml",
        MoistureSystem.SaveKey)

    local ms = g_currentMission.MoistureSystem

    -- Save current moisture level
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. "#currentMoisturePercent", ms.currentMoisturePercent)
    setXMLBool(xmlFile, MoistureSystem.SaveKey .. "#dryingInfoShown", ms.dryingInfoShown)

    -- Save settings
    setXMLString(xmlFile, MoistureSystem.SaveKey .. ".settings#weatherProfile", ms.settings.weatherProfile)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#moistureLossMultiplier", ms.settings
        .moistureLossMultiplier)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#moistureGainMultiplier", ms.settings
        .moistureGainMultiplier)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#teddingMoistureReduction", ms.settings
        .teddingMoistureReduction)
    setXMLBool(xmlFile, MoistureSystem.SaveKey .. ".settings#baleRotEnabled", ms.settings.baleRotEnabled)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#baleRotRate", ms.settings.baleRotRate)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#baleExposureDecayRate", ms.settings.baleExposureDecayRate)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#qualityDecayMultiplier", ms.settings.qualityDecayMultiplier)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#dryingSpeed", ms.settings.dryingSpeed)
    setXMLFloat(xmlFile, MoistureSystem.SaveKey .. ".settings#sellDryingChargeRate", ms.settings.sellDryingChargeRate)
    setXMLBool(xmlFile, MoistureSystem.SaveKey .. ".settings#showFieldMoisture", ms.settings.showFieldMoisture)
    setXMLInt(xmlFile, MoistureSystem.SaveKey .. ".settings#moistureMeterReporting", ms.settings.moistureMeterReporting)

    if g_currentMission.WeatherProfileSystem then
        g_currentMission.WeatherProfileSystem:saveToXMLFile(xmlFile, MoistureSystem.SaveKey)
    end

    if g_currentMission.groundPropertyTracker then
        g_currentMission.groundPropertyTracker:saveToXMLFile(xmlFile, MoistureSystem.SaveKey)
    end

    if g_currentMission.baleRottingSystem then
        g_currentMission.baleRottingSystem:saveToXMLFile(xmlFile, MoistureSystem.SaveKey)
    end

    if g_currentMission.dryingSystem then
        g_currentMission.dryingSystem:saveToXMLFile(xmlFile, MoistureSystem.SaveKey)
    end

    -- Save storage bale uniqueId mappings (can't save in storage XML due to schema restrictions)
    -- Only save bales that have rotting data
    local storageIndex = 0
    for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_objectStorage then
            local spec = placeable.spec_objectStorage
            if spec.storedObjects then
                for objectIndex, abstractObject in ipairs(spec.storedObjects) do
                    local baleUniqueId = nil
                    if abstractObject.baleObject then
                        baleUniqueId = abstractObject.baleObject.uniqueId
                    elseif abstractObject.baleAttributes and abstractObject.baleAttributes.uniqueId then
                        baleUniqueId = abstractObject.baleAttributes.uniqueId
                    end

                    -- Only save if bale has rotting data
                    if baleUniqueId and g_currentMission.baleRottingSystem.baleRainExposureTimes[baleUniqueId] then
                        local storageKey = string.format("%s.storageBales.bale(%d)", MoistureSystem.SaveKey, storageIndex)
                        setXMLString(xmlFile, storageKey .. "#placeableId", placeable.uniqueId)
                        setXMLInt(xmlFile, storageKey .. "#objectIndex", objectIndex - 1) -- 0-based for consistency
                        setXMLString(xmlFile, storageKey .. "#uniqueId", baleUniqueId)
                        storageIndex = storageIndex + 1
                    end
                end
            end
        end
    end

    -- Save object info data (moisture + quality)
    local i = 0
    for uniqueId, fillTypes in pairs(ms.objectInfo) do
        local objectKey = string.format("%s.objectMoisture.object(%d)", MoistureSystem.SaveKey, i)
        setXMLString(xmlFile, objectKey .. "#uniqueId", uniqueId)

        local j = 0
        for fillTypeName, info in pairs(fillTypes) do
            local fillTypeKey = string.format("%s.fillType(%d)", objectKey, j)

            setXMLString(xmlFile, fillTypeKey .. "#name", fillTypeName)
            setXMLFloat(xmlFile, fillTypeKey .. "#moisture", info.moisture)
            setXMLFloat(xmlFile, fillTypeKey .. "#quality", info.quality)

            j = j + 1
        end

        i = i + 1
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function MoistureSystem:syncToClients()
    if not g_currentMission:getIsServer() then return end

    if self.moistureDirty then
        g_server:broadcastEvent(MoistureUpdateEvent.new(self.currentMoisturePercent))
        self.moistureDirty = false
    end
end

-- Request object moisture data from server (client-side, called by HUD extensions)
function MoistureSystem:ensureObjectMoistureLoaded(object)
    if g_currentMission:getIsServer() then return end
    if object == nil or object.uniqueId == nil then return end

    local uniqueId = object.uniqueId
    local ts = self.objectMoistureTimestamps[uniqueId]
    if ts ~= nil and g_time - ts < 3000 then return end
    if self.pendingObjectRequests[uniqueId] then return end

    self.pendingObjectRequests[uniqueId] = true
    local objectId = NetworkUtil.getObjectId(object)
    if objectId ~= nil then
        g_client:getServerConnection():sendEvent(ObjectMoistureRequestEvent.new(objectId))
    end
end

function MoistureSystem:sendInitialClientState(connection, user, farm)
    connection:sendEvent(MSInitialClientStateEvent.new())
end

---
-- Write MoistureSystem state for initial client sync
-- @param streamId: Network stream ID
-- @param connection: Network connection
---
function MoistureSystem:writeInitialClientState(streamId, connection)
    streamWriteFloat32(streamId, self.currentMoisturePercent)
    streamWriteFloat32(streamId, self.settings.moistureLossMultiplier)
    streamWriteFloat32(streamId, self.settings.moistureGainMultiplier)
    streamWriteFloat32(streamId, self.settings.teddingMoistureReduction)
    streamWriteBool(streamId, self.settings.baleRotEnabled)
    streamWriteFloat32(streamId, self.settings.baleRotRate)
    streamWriteFloat32(streamId, self.settings.baleExposureDecayRate)
    streamWriteFloat32(streamId, self.settings.qualityDecayMultiplier)
    streamWriteFloat32(streamId, self.settings.dryingSpeed)
    streamWriteFloat32(streamId, self.settings.sellDryingChargeRate)
    streamWriteBool(streamId, self.settings.showFieldMoisture)
    streamWriteInt32(streamId, self.settings.moistureMeterReporting)
end

---
-- Read MoistureSystem state for initial client sync
-- @param streamId: Network stream ID
-- @param connection: Network connection
---
function MoistureSystem:readInitialClientState(streamId, connection)
    self.currentMoisturePercent = streamReadFloat32(streamId)
    self.settings.moistureLossMultiplier = streamReadFloat32(streamId)
    self.settings.moistureGainMultiplier = streamReadFloat32(streamId)
    self.settings.teddingMoistureReduction = streamReadFloat32(streamId)
    self.settings.baleRotEnabled = streamReadBool(streamId)
    self.settings.baleRotRate = streamReadFloat32(streamId)
    self.settings.baleExposureDecayRate = streamReadFloat32(streamId)
    self.settings.qualityDecayMultiplier = streamReadFloat32(streamId)
    self.settings.dryingSpeed = streamReadFloat32(streamId)
    self.settings.sellDryingChargeRate = streamReadFloat32(streamId)
    self.settings.showFieldMoisture = streamReadBool(streamId)
    self.settings.moistureMeterReporting = streamReadInt32(streamId)

    -- Clear moisture cache since we just got new data
    self.moistureCache = {}
    self.moistureCacheOrder = {}
end


function MoistureSystem.ShowMoistureGUI()
    if g_gui.currentGui == nil then
        -- g_currentMission.MoistureSystem:loadGUI() -- Useful when developing UI
        g_gui:showGui("MoistureGui")
    end
end

local function addPlayerActionEvents(self, superFunc, ...)
    superFunc(self, ...)
    local _, id = g_inputBinding:registerActionEvent(InputAction.MOISTURE_MENU, self,
        MoistureSystem.ShowMoistureGUI, false, true, false,
        true)
    g_inputBinding:setActionEventTextVisibility(id, false)

end


FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
    MoistureSystem.sendInitialClientState)
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, MoistureSystem.saveToXmlFile)
FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, MoistureSystem.onStartMission)
PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.overwrittenFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents, addPlayerActionEvents)
addModEventListener(MoistureSystem)
