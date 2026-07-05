---
-- BaleRottingSystem
-- Manages bale rotting during rain with grace period and gradual drying
---

BaleRottingSystem = {}
local BaleRottingSystem_mt = Class(BaleRottingSystem)

BaleRottingSystem.UPDATE_INTERVAL_MS = 1000

-- Bale status constants
BaleRottingSystem.BALE_STATUS = {
    GETTING_WET = 1,
    DRYING = 2,
    ROTTING_SLOWLY = 3,
    ROTTING = 4,
    ROTTING_QUICKLY = 5
}

-- Rot rate tiers based on peak exposure
BaleRottingSystem.SLOW_ROT_RATE = 0.0000375  -- Slow volume loss per timescale unit
BaleRottingSystem.NORMAL_ROT_RATE = 0.000075 -- Normal volume loss per timescale unit
BaleRottingSystem.FAST_ROT_RATE = 0.00015    -- Fast volume loss per timescale unit

-- Thresholds for rot tiers (based on peak exposure time)
BaleRottingSystem.SLOW_ROT_THRESHOLD = 60 * 60 * 1000   -- 60 minutes
BaleRottingSystem.NORMAL_ROT_THRESHOLD = 100 * 60 * 1000 -- 100 minutes
BaleRottingSystem.FAST_ROT_THRESHOLD = 140 * 60 * 1000   -- 140 minutes

BaleRottingSystem.DECAY_RATE = 0.375                    -- Decay rate when dry (20min exposure / 53min = 0.375)

---
-- Create new BaleRottingSystem instance
-- @return BaleRottingSystem instance
---
function BaleRottingSystem.new()
    local self = setmetatable({}, BaleRottingSystem_mt)

    self.mission = g_currentMission
    self.isServer = self.mission:getIsServer()

    -- Track accumulated rain exposure time, peak exposure, and status
    -- { [uniqueId] = { exposure = timeMS, peakExposure = timeMS, status = BALE_STATUS constant } }
    -- exposure increments during rain, decrements slowly when dry
    -- peakExposure tracks highest exposure ever reached (determines rot rate tier)
    -- Persisted in save game (exposure and peakExposure, status computed on update)
    self.baleRainExposureTimes = {}

    -- Track last update time
    self.timeSinceLastUpdate = 0

    -- Client-side on-demand cache tracking
    self.baleDataTimestamps = {}
    self.pendingBaleRequests = {}

    return self
end

-- Engine teardown hook for mod event listeners. A fresh instance is created per
-- mission in MoistureSystem:loadMap, so we must unregister here or stale
-- instances would keep receiving update(dt) after a mission reload.
function BaleRottingSystem:deleteMap()
    removeModEventListener(self)
end

---
-- Update bale exposure time (accumulate or decay) and determine status
-- @param uniqueId: Bale unique ID
-- @param timescaledDt: Delta time in milliseconds (already timescaled)
-- @param isExposedToRain: Boolean - is bale currently exposed to precipitation
-- @param sunDryingMultiplier: Sunshine drying bonus (1.0-1.25)
-- @return Current exposure time in milliseconds, status string, peak exposure time
---
function BaleRottingSystem:updateBaleExposure(uniqueId, timescaledDt, isExposedToRain, sunDryingMultiplier)
    if not self.isServer then return 0, nil, 0 end

    local baleData = self.baleRainExposureTimes[uniqueId]
    local currentExposure = baleData and baleData.exposure or 0
    local peakExposure = baleData and baleData.peakExposure or 0

    local scaleFactor = g_currentMission.MoistureSystem:getScaleFactor()
    if isExposedToRain then
        -- Accumulate exposure during rain (cap at 2x fast rot threshold)
        currentExposure = math.min(currentExposure + timescaledDt * scaleFactor, self.FAST_ROT_THRESHOLD * 2)
        -- Track peak exposure
        peakExposure = math.max(peakExposure, currentExposure)
    else
        -- Only allow drying if NOT rotting yet (exposure < slow rot threshold)
        -- Once rotting starts, bale cannot dry back
        if currentExposure < self.SLOW_ROT_THRESHOLD then
            local decayRate = self.DECAY_RATE * (g_currentMission.MoistureSystem.settings.baleExposureDecayRate or 1.0)
            currentExposure = math.max(currentExposure - (timescaledDt * decayRate * sunDryingMultiplier * scaleFactor), 0)
        end
        -- If already rotting (>= slow rot threshold), exposure stays at current level
    end

    -- Determine status based on current state and peak exposure
    local status = nil
    if currentExposure > 0 then
        -- Once rotting threshold is reached, bale is always in a rotting state
        if currentExposure >= self.SLOW_ROT_THRESHOLD then
            -- Determine rot tier based on peak exposure
            if peakExposure >= self.FAST_ROT_THRESHOLD then
                status = self.BALE_STATUS.ROTTING_QUICKLY
            elseif peakExposure >= self.NORMAL_ROT_THRESHOLD then
                status = self.BALE_STATUS.ROTTING
            else
                status = self.BALE_STATUS.ROTTING_SLOWLY
            end
        else
            -- Below rotting threshold - can be getting wet or drying
            if isExposedToRain then
                status = self.BALE_STATUS.GETTING_WET
            else
                status = self.BALE_STATUS.DRYING
            end
        end
    end

    -- Store or remove tracking
    if currentExposure > 0 then
        self.baleRainExposureTimes[uniqueId] = {
            exposure = currentExposure,
            peakExposure = peakExposure,
            status = status
        }
    else
        self.baleRainExposureTimes[uniqueId] = nil
    end

    return currentExposure, status, peakExposure
end

---
-- Set initial exposure time for a newly created bale
-- Used when bales are created with high moisture content
-- @param uniqueId: Bale unique ID
-- @param exposureTime: Initial exposure time in milliseconds
---
function BaleRottingSystem:setBaleInitialExposure(uniqueId, exposureTime)
    if not self.isServer then return end

    if self.baleRainExposureTimes[uniqueId] then
        return
    end

    local cappedExposure = math.min(exposureTime, self.SLOW_ROT_THRESHOLD * 0.99)

    self.baleRainExposureTimes[uniqueId] = {
        exposure = cappedExposure,
        peakExposure = cappedExposure,
        status = self.BALE_STATUS.GETTING_WET
    }
end

---
-- Main update loop - process all bales
-- @param dt: Delta time in milliseconds
---
function BaleRottingSystem:update(dt)
    if not self.isServer then return end

    -- Check if bale rotting is enabled
    if not g_currentMission.MoistureSystem.settings.baleRotEnabled then
        return
    end

    self.timeSinceLastUpdate = self.timeSinceLastUpdate + dt
    if self.timeSinceLastUpdate < self.UPDATE_INTERVAL_MS then
        return
    end

    -- Use accumulated time, not just last frame's dt
    local timescale = self.timeSinceLastUpdate * self.mission:getEffectiveTimeScale()
    local weather = self.mission.environment.weather
    local rainfall = weather:getRainFallScale()
    local snowfall = weather:getSnowFallScale()
    local hailfall = weather:getHailFallScale()

    local isRaining = rainfall > 0 or snowfall > 0 or hailfall > 0
    local indoorMask = self.mission.indoorMask
    local items = self.mission.itemSystem.itemByUniqueId
    local balesToDelete = {}

    -- Calculate sunshine drying bonus (up to 25% faster drying during daylight)
    local currentHour = self.mission.environment.currentHour
    local daylightStart = 6
    local daylightEnd = 20
    local isDaylight = currentHour >= daylightStart and currentHour < daylightEnd

    -- Process ALL tracked bales (even when not raining, for decay)
    -- Plus any rottable bales we encounter
    local balesToProcess = {}

    -- Add all currently tracked bales
    for uniqueId, _ in pairs(self.baleRainExposureTimes) do
        if items[uniqueId] then
            balesToProcess[uniqueId] = items[uniqueId]
        else
            -- Bale no longer exists, remove tracking
            self.baleRainExposureTimes[uniqueId] = nil
            end
    end

    -- Add any untracked rottable bales (if it's raining)
    if isRaining then
        for uniqueId, item in pairs(items) do
            if self:isBaleRottable(item) and not balesToProcess[uniqueId] then
                balesToProcess[uniqueId] = item
            end
        end
    end

    -- Process each bale
    for uniqueId, item in pairs(balesToProcess) do
        local x, _, z = getWorldTranslation(item.nodeId)

        -- Check if exposed to rain (outdoors, unwrapped, raining)
        local isIndoors = indoorMask:getIsIndoorAtWorldPosition(x, z)
        local isExposedToRain = isRaining and not isIndoors

        -- Calculate sun drying multiplier (1.0 to 1.25)
        -- Only apply bonus when: not raining, outdoors, and daylight
        local sunDryingMultiplier = 1.0
        if not isRaining and not isIndoors and isDaylight then
            sunDryingMultiplier = 1.25
        end

        -- Update exposure time (accumulate or decay)
        local exposureTime, status, peakExposure = self:updateBaleExposure(uniqueId, timescale, isExposedToRain,
            sunDryingMultiplier)

        -- Apply rotting if currently rotting (any tier)
        if status == self.BALE_STATUS.ROTTING_SLOWLY or status == self.BALE_STATUS.ROTTING or status == self.BALE_STATUS.ROTTING_QUICKLY then
            local rotLoss = self:calculateRotLoss(item, rainfall, snowfall, hailfall, timescale, peakExposure)
            local newFillLevel = math.max(item.fillLevel - rotLoss, 0)
            item:setFillLevel(newFillLevel)

            -- Mark for deletion if empty
            if item.fillLevel <= 0 then
                table.insert(balesToDelete, item)
            else
                -- If bale is in storage, raise dirty flag so clients get updated fill levels
                local storage = MSPlaceableObjectStorageExtension.findStorageForBale(item)
                if storage then
                    storage:raiseDirtyFlags(storage.spec_objectStorage.dirtyFlag)
                end
            end
        end
    end

    -- Delete empty bales
    for i = #balesToDelete, 1, -1 do
        local bale = balesToDelete[i]
        self.baleRainExposureTimes[bale.uniqueId] = nil

        -- Check if bale is in storage and remove it first
        local storage = MSPlaceableObjectStorageExtension.findStorageForBale(bale)
        if storage then
            MSPlaceableObjectStorageExtension.removeRottedBaleFromStorage(storage, bale)
        end

        bale:delete()
    end

    self.timeSinceLastUpdate = 0
end

---
-- Calculate volume loss for a bale
-- @param bale: Bale object
-- @param rainfall: Rain intensity (0-1)
-- @param snowfall: Snow intensity (0-1)
-- @param hailfall: Hail intensity (0-1)
-- @param timescale: Adjusted delta time
-- @param peakExposure: Peak exposure time in milliseconds (determines rot tier)
-- @return Volume loss in liters
---
function BaleRottingSystem:calculateRotLoss(bale, rainfall, snowfall, hailfall, timescale, peakExposure)
    -- Determine rot rate tier based on peak exposure
    local rotRate = self.SLOW_ROT_RATE -- Default to slow
    if peakExposure >= self.FAST_ROT_THRESHOLD then
        rotRate = self.FAST_ROT_RATE
    elseif peakExposure >= self.NORMAL_ROT_THRESHOLD then
        rotRate = self.NORMAL_ROT_RATE
    elseif peakExposure >= self.SLOW_ROT_THRESHOLD then
        rotRate = self.SLOW_ROT_RATE
    end

    -- Base calculation (aligned with MoistureSystem weather factors)
    local weatherFactor = rainfall + (snowfall * 0.55) + (hailfall * 0.5)

    -- If not currently exposed to weather, apply minimal internal decay rate (10% of normal)
    if weatherFactor == 0 then
        weatherFactor = 0.1
    end

    local baseLoss = weatherFactor * rotRate * timescale

    -- Apply settings multiplier
    local settingsMultiplier = g_currentMission.MoistureSystem.settings.baleRotRate or 1.0

    return baseLoss * settingsMultiplier * g_currentMission.MoistureSystem:getScaleFactor()
end

---
-- Check if a bale should be processed for rotting
-- @param item: Item to check
-- @return Boolean - true if rottable
---
function BaleRottingSystem:isBaleRottable(item)
    -- Must be a Bale object
    if g_currentMission.objectsToClassName[item] ~= "Bale" then
        return false
    end

    if item.fillLevel == nil or item.nodeId == 0 then
        return false
    end

    if item.wrappingState ~= 0 then
        return false
    end

    local rottableFillTypes = {
        [FillType.SILAGE] = true,
        [FillType.STRAW] = true
    }

    if rottableFillTypes[item.fillType] then
        return true
    end

    local converter = g_fillTypeManager:getConverterDataByName("TEDDER")
    for fromFillType, to in pairs(converter) do
        local targetFillType = to.targetFillTypeIndex
        -- Skip non-converting entries (where source and target are the same)
        if fromFillType ~= targetFillType then
            if item.fillType == targetFillType or item.fillType == fromFillType then
                return true
            end
        end
    end

    return false
end

---
-- Remove bale from tracking if it's not in a rotting state
-- Used when bale is wrapped and shouldn't get wetter
-- @param uniqueId: Bale unique ID
-- @return boolean: true if bale was removed, false if it's rotting and wasn't removed
---
function BaleRottingSystem:removeBaleIfNotRotting(uniqueId)
    if not self.isServer then return false end

    local baleData = self.baleRainExposureTimes[uniqueId]
    if not baleData then
        return true
    end

    if baleData.status < self.BALE_STATUS.ROTTING_SLOWLY then
        self.baleRainExposureTimes[uniqueId] = nil
        return true
    end

    return false
end

---
-- Clean up tracking when bale is deleted
-- @param bale: Bale being deleted
---
function BaleRottingSystem:onBaleDeleted(bale)
    if not self.isServer then return end
    if self.baleRainExposureTimes[bale.uniqueId] then
        self.baleRainExposureTimes[bale.uniqueId] = nil
    end
end

---
-- Save exposure times to XML
-- @param xmlFile: XML file handle
-- @param key: Base XML key
---
function BaleRottingSystem:saveToXMLFile(xmlFile, key)
    if not self.isServer then return end

    local i = 0
    for uniqueId, baleData in pairs(self.baleRainExposureTimes) do
        -- Only save if bale still exists
        if g_currentMission.itemSystem.itemByUniqueId[uniqueId] then
            local baleKey = string.format("%s.baleRotting.bale(%d)", key, i)
            setXMLString(xmlFile, baleKey .. "#uniqueId", uniqueId)
            setXMLInt(xmlFile, baleKey .. "#exposureTime", math.floor(baleData.exposure))
            setXMLInt(xmlFile, baleKey .. "#peakExposure", math.floor(baleData.peakExposure))
            i = i + 1
        end
    end
end

---
-- Load exposure times from XML
-- @param xmlFile: XML file handle
-- @param key: Base XML key
---
function BaleRottingSystem:loadFromXMLFile(xmlFile, key)
    if not self.isServer then return end

    local i = 0
    while true do
        local baleKey = string.format("%s.baleRotting.bale(%d)", key, i)

        if not hasXMLProperty(xmlFile, baleKey) then
            break
        end

        local uniqueId = getXMLString(xmlFile, baleKey .. "#uniqueId")
        local exposureTime = getXMLInt(xmlFile, baleKey .. "#exposureTime")
        local peakExposure = getXMLInt(xmlFile, baleKey .. "#peakExposure") or exposureTime

        -- Load ALL rotting data, even for bales in storage (they're deleted from itemSystem)
        -- Status will be computed on first update
        self.baleRainExposureTimes[uniqueId] = {
            exposure = exposureTime,
            peakExposure = peakExposure,
            status = self.BALE_STATUS.DRYING -- Default status until next update
        }

        i = i + 1
    end
end

-- Request bale rotting data from server (client-side, called by HUD)
function BaleRottingSystem:ensureBaleDataLoaded(bale)
    if g_currentMission:getIsServer() then return end
    if bale == nil or bale.uniqueId == nil then return end

    local uniqueId = bale.uniqueId
    local ts = self.baleDataTimestamps[uniqueId]
    if ts ~= nil and g_time - ts < 3000 then return end
    if self.pendingBaleRequests[uniqueId] then return end

    self.pendingBaleRequests[uniqueId] = true
    local objectId = NetworkUtil.getObjectId(bale)
    if objectId ~= nil then
        g_client:getServerConnection():sendEvent(BaleRottingRequestEvent.new(objectId))
    end
end

Bale.delete = Utils.prependedFunction(Bale.delete, function(self)
    if g_currentMission.baleRottingSystem then
        g_currentMission.baleRottingSystem:onBaleDeleted(self)
    end
end)
