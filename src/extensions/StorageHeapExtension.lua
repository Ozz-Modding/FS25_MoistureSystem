---
-- StorageHeapExtension
--
-- Support for the Highlands Fishing Pack's `placeableStorageHeap` specialization,
-- used by grain stores such as FS25_MultiBayGrainStore. Each bay is a `StorageHeap`
-- object that duck-types the Storage interface (getFillLevel/setFillLevel/...) so the
-- loading and unloading stations accept it, but it is not a Storage and the placeable
-- has no spec_silo — so none of our silo code sees it.
--
-- The important property is that a bay's fill level is *derived from the ground*:
-- StorageHeap:updateTotalFillLevel re-reads DensityMapHeightUtil.getFillLevelAtArea
-- over the bay every update and overwrites its fillLevels. The material is the source
-- of truth, not the number. The stations only queue liters, which StorageHeap:update
-- later drains with tipToGroundAroundLine to add or remove real material.
--
-- So we track these stores the way we track sheds: as GroundPropertyTracker piles
-- inside the bay areas. Tipping in from a trailer and scooping out with a loader
-- therefore already work through the normal ground paths. This file closes the two
-- gaps those paths don't cover — the grate (unloading station) and the pipe (loading
-- station) — by riding StorageHeap's fill-level-changed listener.
--
-- Grain piles are inert in GroundPropertyTracker (applyDryingToPile only handles
-- grass/hay/straw), so stored grain holds its moisture and does not rot, which is
-- what we want under a roof. Drying comes from DryingSystem's shed path, which
-- already classifies these placeables via spec_tipOcclusionAreas.
--
-- Note: do not call placeable:getIsFillTypeSupported() on one of these — the DLC's
-- implementation calls section:getIsFillTypeSupported on a plain table and errors.
---

MSStorageHeapExtension = {}

-- Set for the duration of any discharge so the fill-level listener, which is only told
-- (fillTypeIndex, delta), can find out whose grain just arrived. The listener fires
-- synchronously inside Dischargeable:dischargeToObject. It is set for every discharge
-- rather than only those aimed at a storage heap, because a bay defaults to
-- isExtension=true and so can be pulled into a *different* station's target storages --
-- tipping into a neighbouring silo can land grain in a bay.
MSStorageHeapExtension.depositSourceUniqueId = nil

---
-- PlaceableStorageHeap:onLoad aliases the namespaced spec table to this plain name,
-- so we never have to spell out "spec_pdlc_highlandsFishingPack.placeableStorageHeap".
---
function MSStorageHeapExtension.isStorageHeap(placeable)
    return placeable ~= nil and placeable.spec_placeableStorageHeap ~= nil
end

---
-- The bays of a storage heap placeable that have a usable ground area, cached on the
-- spec. A section whose StorageHeap failed to load has no storageHeap at all, and one
-- without area nodes never puts material on the ground, so both are skipped.
---
function MSStorageHeapExtension.getBays(placeable)
    local spec = placeable.spec_placeableStorageHeap
    if spec == nil then return nil end

    if spec.msBays == nil then
        spec.msBays = {}
        for _, section in ipairs(spec.sections or {}) do
            local heap = section.storageHeap
            if heap ~= nil and heap.area ~= nil and heap.area.isAvailable then
                table.insert(spec.msBays, heap)
            end
        end
    end

    return spec.msBays
end

---
-- World-space corners of a bay's ground area, in the (start, width, height) form
-- GroundPropertyTracker:addPile and DensityMapHeightUtil both use.
---
function MSStorageHeapExtension.getBayAreaCorners(heap)
    local sx, _, sz = getWorldTranslation(heap.area.start)
    local wx, _, wz = getWorldTranslation(heap.area.width)
    local hx, _, hz = getWorldTranslation(heap.area.height)
    return sx, sz, wx, wz, hx, hz
end

---
-- Attach our fill-level listener to every bay. Idempotent — called both from the
-- PlaceableSystem:addPlaceable hook (new placements and savegame loads) and from a
-- sweep at mission start, so a placeable can never be missed by load order.
---
function MSStorageHeapExtension.attach(placeable)
    if not MSStorageHeapExtension.isStorageHeap(placeable) then return end
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end

    local spec = placeable.spec_placeableStorageHeap
    if spec.msListenersAttached then return end
    spec.msListenersAttached = true

    for _, heap in ipairs(MSStorageHeapExtension.getBays(placeable) or {}) do
        if heap.addFillLevelChangedListeners ~= nil then
            heap:addFillLevelChangedListeners(function(fillTypeIndex, delta)
                MSStorageHeapExtension.onBayFillLevelChanged(placeable, heap, fillTypeIndex, delta)
            end)
        end
    end
end

---
-- Called by StorageHeap:setFillLevel, i.e. only for grain moving through the grate or
-- the pipe — never for loader work, which changes the ground directly and is already
-- covered by DischargeableExtension and FillVolumeExtension.
--
-- `delta` is the signed liter change for this bay. We only act on grain arriving:
-- removals are handled lazily by getStoredProperties, because at this point the
-- material is still on the ground (StorageHeap only queues the pick, and drains it in
-- a later update), so there is nothing to prune yet.
---
function MSStorageHeapExtension.onBayFillLevelChanged(placeable, heap, fillTypeIndex, delta)
    if delta <= 0 then return end

    local ms = g_currentMission.MoistureSystem
    local tracker = g_currentMission.groundPropertyTracker
    if ms == nil or tracker == nil then return end
    if not ms:shouldTrackFillType(fillTypeIndex) then return end

    local moisture, quality

    local sourceUniqueId = MSStorageHeapExtension.depositSourceUniqueId
    if sourceUniqueId ~= nil then
        local info = ms:getObjectInfo(sourceUniqueId, fillTypeIndex)
        if info ~= nil then
            moisture = info.moisture
            quality = info.quality
        end
    end

    -- Grain from an untracked source (a pre-mod load, or a filler we don't hook).
    -- Matches what transferObjectInfo does for the same case.
    if moisture == nil then
        moisture = ms:getDefaultMoisture()
    end
    if quality == nil then
        quality = ms:deriveQuality(fillTypeIndex, moisture)
    end

    -- addPile weights the incoming liters against the volume already in each cell,
    -- which it reads off the density map. The material we are announcing here has not
    -- landed yet (it drops on the bay's next update), so that read still returns the
    -- pre-deposit volume — exactly the weight we want.
    local sx, sz, wx, wz, hx, hz = MSStorageHeapExtension.getBayAreaCorners(heap)
    tracker:addPile(sx, sz, wx, wz, hx, hz, fillTypeIndex, delta, { moisture = moisture, quality = quality })

    placeable.spec_placeableStorageHeap.msPropertyCache = nil
end

---
-- The grid cells covering a bay, cached on the bay. Areas are fixed once placed, so
-- this only has to be walked once per bay rather than on every getStoredProperties call.
---
function MSStorageHeapExtension.getBayCells(heap)
    if heap.msCells == nil then
        local tracker = g_currentMission.groundPropertyTracker
        local sx, sz, wx, wz, hx, hz = MSStorageHeapExtension.getBayAreaCorners(heap)
        heap.msCells = tracker:getAffectedGridCells(sx, sz, wx, wz, hx, hz)
    end
    return heap.msCells
end

---
-- Bracket a discharge so onBayFillLevelChanged can attribute the arriving grain.
function MSStorageHeapExtension.beginDeposit(sourceUniqueId)
    MSStorageHeapExtension.depositSourceUniqueId = sourceUniqueId
end

function MSStorageHeapExtension.endDeposit()
    MSStorageHeapExtension.depositSourceUniqueId = nil
end

---
-- Volume-weighted moisture and quality of one crop across every bay, read from the
-- tracked piles that cover the bay areas. Returns nil when the store holds none of it.
--
-- Also prunes piles whose cell has been emptied — this is where grain taken out
-- through the pipe finally gets cleaned up, since the removal itself only queues a
-- pick and the material lingers for another update or two.
--
-- Uses getPilePropertiesAtPosition rather than a direct storage lookup so this works
-- on clients too (for the info trigger); on a client it returns nil until the pile
-- request round-trips.
---
function MSStorageHeapExtension.getStoredProperties(placeable, fillType)
    local tracker = g_currentMission.groundPropertyTracker
    if tracker == nil or fillType == nil then return nil end

    -- The pipe calls this every frame it runs, and a four-bay store is ~80 cells, each
    -- costing a density map read. Hold the answer briefly; a deposit clears it early.
    local spec = placeable.spec_placeableStorageHeap
    local cached = spec.msPropertyCache
    if cached ~= nil and cached.fillType == fillType and g_time - cached.timestamp < 500 then
        return cached.properties, cached.liters
    end

    local totalLiters, weightedMoisture, weightedQuality = 0, 0, 0
    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2

    for _, heap in ipairs(MSStorageHeapExtension.getBays(placeable) or {}) do
        -- A bay with liters still queued has material on its way to the ground (the drop
        -- happens on the bay's next update), so its cells can read as empty while holding
        -- a pile we have just created. Don't prune those, or a deposit erases itself.
        local canPrune = tracker.isServer and (heap.fillTypeIndexToDrop or 0) <= 0

        for _, cell in ipairs(MSStorageHeapExtension.getBayCells(heap)) do
            local liters = DensityMapHeightUtil.getFillLevelAtArea(
                fillType,
                cell.gridX - checkRadius, cell.gridZ - checkRadius,
                cell.gridX + checkRadius, cell.gridZ - checkRadius,
                cell.gridX - checkRadius, cell.gridZ + checkRadius
            )

            if liters > 0 then
                local properties = tracker:getPilePropertiesAtPosition(cell.gridX, cell.gridZ, fillType)
                if properties ~= nil and properties.moisture ~= nil then
                    totalLiters = totalLiters + liters
                    weightedMoisture = weightedMoisture + liters * properties.moisture
                    weightedQuality = weightedQuality + liters * (properties.quality or 100)
                end
            elseif canPrune then
                tracker:checkPileHasContent(cell.gridX, cell.gridZ, fillType)
            end
        end
    end

    local properties = nil
    if totalLiters > 0 then
        properties = {
            moisture = weightedMoisture / totalLiters,
            quality = weightedQuality / totalLiters,
        }
    end

    spec.msPropertyCache = {
        fillType = fillType,
        properties = properties,
        liters = totalLiters,
        timestamp = g_time,
    }

    return properties, totalLiters
end

---
-- The crops currently in the store, one per occupied bay (a bay holds a single fill
-- type at a time — StorageHeap clears fillTypes on every update and re-reads the
-- ground). fillTypeIndex is network-synced, so this is valid on clients.
---
function MSStorageHeapExtension.getStoredFillTypes(placeable)
    local fillTypes = {}
    local seen = {}

    for _, heap in ipairs(MSStorageHeapExtension.getBays(placeable) or {}) do
        local fillTypeIndex = heap.fillTypeIndex
        if fillTypeIndex ~= nil and fillTypeIndex ~= FillType.UNKNOWN and not seen[fillTypeIndex] then
            if heap:getFillLevel(fillTypeIndex) > 0 then
                seen[fillTypeIndex] = true
                table.insert(fillTypes, fillTypeIndex)
            end
        end
    end

    return fillTypes
end

-- Placeables reach the system in Placeable:finalizePlacement, after onLoad has built
-- the spec and set uniqueId, so appending here is enough for both fresh placements and
-- savegame loads.
PlaceableSystem.addPlaceable = Utils.appendedFunction(
    PlaceableSystem.addPlaceable,
    function(self, placeable)
        MSStorageHeapExtension.attach(placeable)
    end
)
