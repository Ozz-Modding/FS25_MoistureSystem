GroundPropertyTracker = {}
local GroundPropertyTracker_mt = Class(GroundPropertyTracker)

GroundPropertyTracker.GRID_SIZE = 2
GroundPropertyTracker.MIN_GRASS_MOISTURE = 0.05 -- 5% minimum moisture for grass
GroundPropertyTracker.MAX_GRASS_MOISTURE = 0.40 -- 40% maximum moisture for grass
GroundPropertyTracker.MIN_HAY_MOISTURE = 0.04   -- 4% minimum moisture for hay
GroundPropertyTracker.DRY_THRESHOLD = 0.10      -- 10% moisture converts grass to hay / hay to grass

GroundPropertyTracker.TEDDED_COOLDOWN_CYCLES = 10
GroundPropertyTracker.DELAYED_PROCESSING_CYCLES = 2
GroundPropertyTracker.WINDROWER_PROCESSING_CYCLES = 2

-- Rotting constants
GroundPropertyTracker.SLOW_ROT_EXPOSURE_TIME = 60 * 60 * 1000   -- 60 minutes (ms)
GroundPropertyTracker.NORMAL_ROT_EXPOSURE_TIME = 100 * 60 * 1000 -- 100 minutes (ms)
GroundPropertyTracker.DRYING_DECAY_RATE = 0.375
GroundPropertyTracker.ROT_REMOVAL_THRESHOLD = 10.0              -- liters removed when accumulator reached
-- ROT_ACCUMULATION_* are liters/sec at timescale 1; scaled by (updateDelta/1000)
GroundPropertyTracker.ROT_ACCUMULATION_MIN = 0.00075
GroundPropertyTracker.ROT_ACCUMULATION_MAX = 0.001875

function GroundPropertyTracker.new()
    local self = setmetatable({}, GroundPropertyTracker_mt)

    self.mission = g_currentMission
    self.isServer = self.mission:getIsServer()
    self.loadedGridSize = nil

    self.gridPiles = {}

    self.grassPiles = {}

    self.hayPiles = {}

    self.strawPiles = {}

    -- Buffer for tedded grid cells
    -- Value is number of update cycles remaining before moving to teddedGridCells
    self.teddedGridCellsBuffer = {}

    -- Track tedded grid cells (will apply additional moisture reduction)
    self.teddedGridCells = {}

    -- Track processed tedded cells with cooldown counter to prevent re-marking
    -- Value is number of update cycles remaining before cell can be marked again
    self.teddedGridCellsCooldown = {}

    -- Track processed mowed cells with cooldown counter to prevent re-marking
    -- Value is number of update cycles remaining before cell can be marked again
    self.recentMowedCells = {}

    -- Track cells that are designated as "hay cells" (recently converted to hay)
    -- Value is number of update cycles remaining
    self.hayCells = {}

    -- Track cells that are designated as "grass cells" (recently converted back to grass from hay)
    -- Value is number of update cycles remaining
    self.grassCells = {}

    -- Track moisture of grass being moved by tedder
    -- Key: "gridX_gridZ", Value: moisture value
    self.teddedGrassMoisture = {}

    -- Track grass rotting accumulators
    -- Key: "gridX_gridZ_fillType", Value: accumulated liters waiting for removal
    self.grassRotAccumulators = {}

    -- Track straw rotting accumulators
    -- Key: "gridX_gridZ_fillType", Value: accumulated liters waiting for removal
    self.strawRotAccumulators = {}

    -- Track pending windrower drops with volume-weighted moisture
    -- Key: getGridKey(gridX, gridZ, fillType), Value: { gridX, gridZ, fillType, volume, moistureSum, cyclesRemaining }
    self.windrowerPendingDrops = {}

    -- Track cells picked by windrower for cleanup verification
    -- Key: getGridKey(gridX, gridZ, fillType), Value: cycles remaining
    self.windrowerPickedCells = {}

    -- Client-side on-demand cache for pile moisture
    self.pileCache = {}
    self.pendingPileRequests = {}

    -- Memo: fillType index -> storage table (avoids re-running the is*FillType
    -- predicates for every pile touched in the hot path).
    self.storageByFillType = {}

    -- Amortized continuous-drying state.
    -- MoistureSystem feeds the global field moisture delta into dryingAccumulator
    -- each weather cycle (it is the same value for every pile). The cursor sweep
    -- applies, per pile, the accumulator growth since that pile was last visited:
    --   applied = dryingAccumulator - pile.lastAcc
    -- This is mathematically equivalent to applying the delta to every pile every
    -- cycle, but spreads the O(N) work across frames.
    self.dryingAccumulator = 0

    -- Amortized rain-exposure / rot state, same accumulator-clock pattern as
    -- dryingAccumulator. rainTimeAcc accrues game-ms spent raining; dryTimeAcc
    -- accrues game-ms spent dry. The sweep visit drains both per pile:
    --   rainSince = rainTimeAcc - pile.lastRainAcc   (exposure gained)
    --   drySince  = dryTimeAcc  - pile.lastDryAcc    (exposure decayed)
    -- so rain exposure + rotting fold into the SAME bounded per-frame visit as
    -- drying, replacing the old uncapped per-cycle walk of wetGrassKeys/wetStrawKeys.
    self.rainTimeAcc = 0
    self.dryTimeAcc = 0

    -- Cursor sweep snapshot. Two parallel arrays (key + kind) maintained
    -- incrementally: keys are appended as piles are created (queuePileUpdate) and
    -- swap-removed lazily as the cursor passes a slot whose pile is gone. The
    -- cursor advances a bounded number of slots per frame and wraps without a
    -- rebuild. inSweep tracks which keys are currently in the array so a pile
    -- isn't appended twice. A full rebuild (rebuildSweepSnapshot) is only used for
    -- bulk-load events that replace the storage tables wholesale (savegame load,
    -- grid-size conversion).
    self.sweepKeys = {}
    self.sweepKinds = {}
    self.inSweep = {}
    self.sweepLen = 0
    self.sweepPos = 1

    -- Internal 500ms cycle clock for the bounded active-set work (tedding,
    -- conversions, windrower, cooldown decrement). Kept separate from the
    -- per-frame sweep so the cycle-based cooldown counters keep their cadence.
    self.cycleTimer = 0

    -- Lightweight sweep metrics for the msSweepDebug console command. Cheap to
    -- maintain (a few integer increments per frame); reported on demand.
    self.sweepStats = {
        framesWithWork = 0,    -- frames where the sweep visited >= 1 pile
        pilesVisited = 0,      -- total pile visits since last completed sweep period
        lastPeriodPiles = 0,   -- pile visits in the last full sweep period
        lastPeriodFrames = 0,  -- frames the last full sweep period took
        periodPilesAccum = 0,  -- accumulator for the in-progress sweep period
        periodFramesAccum = 0, -- accumulator for the in-progress sweep period
        sweepCount = 0,        -- number of completed full sweep periods
        peakSnapshotLen = 0,   -- high-water mark of snapshot size (approx peak piles)
    }

    return self
end

-- Per-frame budget for the continuous-drying cursor sweep. Bounds worst-case
-- cost regardless of total pile count; the full-sweep period stretches as piles
-- grow, which is harmless because drying is slow.
GroundPropertyTracker.SWEEP_BUDGET = 64

-- Cadence of the bounded active-set work (matches the old updateInterval so the
-- cycle-based cooldown counters expire at the same wall-clock rate as before).
GroundPropertyTracker.CYCLE_INTERVAL = 500

-- Grid position helper
function GroundPropertyTracker:getGridPosition(x, z)
    local gridX = math.floor(x / GroundPropertyTracker.GRID_SIZE) * GroundPropertyTracker.GRID_SIZE +
        GroundPropertyTracker.GRID_SIZE / 2
    local gridZ = math.floor(z / GroundPropertyTracker.GRID_SIZE) * GroundPropertyTracker.GRID_SIZE +
        GroundPropertyTracker.GRID_SIZE / 2
    return gridX, gridZ
end

-- Grid key helper
function GroundPropertyTracker:getGridKey(gridX, gridZ, fillType)
    gridX, gridZ = self:getGridPosition(gridX, gridZ)
    return string.format("%d_%d_%d", gridX, gridZ, fillType)
end

-- Simple grid key helper
function GroundPropertyTracker:getSimpleGridKey(gridX, gridZ)
    gridX, gridZ = self:getGridPosition(gridX, gridZ)
    return string.format("%d_%d", gridX, gridZ)
end

-- Resolve a storage "kind" to the live storage table. Kept as a lookup off the
-- live self.* fields (not cached table identity) so storages can be reassigned
-- (delete/convertGridCells/readInitialClientState) without invalidating anything.
function GroundPropertyTracker:getStorageByKind(kind)
    if kind == "grass" then
        return self.grassPiles
    elseif kind == "hay" then
        return self.hayPiles
    elseif kind == "straw" then
        return self.strawPiles
    end
    return self.gridPiles
end

-- Return the storage kind for a fillType. Memoized: the fillType->kind mapping is
-- static, so this keeps the is*FillType predicate calls out of the hot path.
function GroundPropertyTracker:getStorageKindForFillType(fillType)
    local cached = self.storageByFillType[fillType]
    if cached then
        return cached
    end

    local moistureSystem = g_currentMission.MoistureSystem
    local kind
    if moistureSystem:isGrassOnGroundFillType(fillType) then
        kind = "grass"
    elseif moistureSystem:isHayFillType(fillType) then
        kind = "hay"
    elseif moistureSystem:isStrawFillType(fillType) then
        kind = "straw"
    else
        kind = "grid"
    end

    self.storageByFillType[fillType] = kind
    return kind
end

-- Return storage table for a fillType.
function GroundPropertyTracker:getStorageForFillType(fillType)
    return self:getStorageByKind(self:getStorageKindForFillType(fillType))
end

function GroundPropertyTracker:delete()
    self.gridPiles = {}
    self.grassPiles = {}
    self.hayPiles = {}
    self.strawPiles = {}
    self.grassRotAccumulators = {}
    self.strawRotAccumulators = {}
    self.sweepKeys = {}
    self.sweepKinds = {}
    self.inSweep = {}
    self.sweepLen = 0
    self.sweepPos = 1
end

-- Engine teardown hook for mod event listeners. A fresh tracker is created per
-- mission in MoistureSystem:loadMap, so we must unregister here or stale
-- instances would keep receiving update(dt) after a mission reload.
function GroundPropertyTracker:deleteMap()
    removeModEventListener(self)
    self:delete()
end

-- Update local pile storage (server-side only)
-- Merges properties into existing pile or creates new entry
function GroundPropertyTracker:queuePileUpdate(key, properties, fillTypeIndex, gridX, gridZ)
    local storage = self:getStorageForFillType(fillTypeIndex)

    if storage[key] then
        -- Merge properties into existing pile (preserves server-only state like rainExposure)
        for propKey, propValue in pairs(properties) do
            storage[key].properties[propKey] = propValue
        end
    else
        -- Create new pile entry. Seed lastAcc / lastRainAcc / lastDryAcc to the
        -- current accumulators so the next sweep applies zero retroactive drying
        -- or exposure to a freshly-created pile.
        storage[key] = {
            properties = {},
            fillType = fillTypeIndex,
            gridX = gridX,
            gridZ = gridZ,
            lastAcc = self.dryingAccumulator,
            lastRainAcc = self.rainTimeAcc,
            lastDryAcc = self.dryTimeAcc
        }
        for propKey, propValue in pairs(properties) do
            storage[key].properties[propKey] = propValue
        end

        -- Add to the drying sweep snapshot incrementally (only the four swept
        -- storage kinds; gridPiles are not dried so they stay out of the sweep).
        local kind = self:getStorageKindForFillType(fillTypeIndex)
        if kind ~= "grid" then
            self:appendToSweep(key, kind)
        end
    end
end

-- Append a key to the sweep snapshot if it isn't already present. O(1).
function GroundPropertyTracker:appendToSweep(key, kind)
    if self.inSweep[key] then return end
    local n = self.sweepLen + 1
    self.sweepKeys[n] = key
    self.sweepKinds[n] = kind
    self.sweepLen = n
    self.inSweep[key] = true
    if n > self.sweepStats.peakSnapshotLen then
        self.sweepStats.peakSnapshotLen = n
    end
end

-- Calculate overlap area and dimensions between cell and bounding box
-- Returns: overlapArea, overlapWidthX, overlapDepthZ
function GroundPropertyTracker:calculateCellOverlap(cellX, cellZ, minX, maxX, minZ, maxZ)
    local halfSize = GroundPropertyTracker.GRID_SIZE / 2
    local cellMinX = cellX - halfSize
    local cellMaxX = cellX + halfSize
    local cellMinZ = cellZ - halfSize
    local cellMaxZ = cellZ + halfSize

    -- Calculate intersection rectangle
    local overlapMinX = math.max(cellMinX, minX)
    local overlapMaxX = math.min(cellMaxX, maxX)
    local overlapMinZ = math.max(cellMinZ, minZ)
    local overlapMaxZ = math.min(cellMaxZ, maxZ)

    -- Calculate overlap dimensions
    if overlapMinX < overlapMaxX and overlapMinZ < overlapMaxZ then
        local overlapWidth = overlapMaxX - overlapMinX
        local overlapDepth = overlapMaxZ - overlapMinZ
        return overlapWidth * overlapDepth, overlapWidth, overlapDepth
    end

    return 0, 0, 0
end

-- Get affected grid cells and overlap areas
function GroundPropertyTracker:getAffectedGridCells(sx, sz, wx, wz, hx, hz)
    local minX = math.min(sx, wx, hx)
    local maxX = math.max(sx, wx, hx)
    local minZ = math.min(sz, wz, hz)
    local maxZ = math.max(sz, wz, hz)

    -- Calculate grid boundaries
    local startGridX = math.floor(minX / GroundPropertyTracker.GRID_SIZE) * GroundPropertyTracker.GRID_SIZE
    local endGridX = math.floor(maxX / GroundPropertyTracker.GRID_SIZE) * GroundPropertyTracker.GRID_SIZE
    local startGridZ = math.floor(minZ / GroundPropertyTracker.GRID_SIZE) * GroundPropertyTracker.GRID_SIZE
    local endGridZ = math.floor(maxZ / GroundPropertyTracker.GRID_SIZE) * GroundPropertyTracker.GRID_SIZE

    -- Initialize return values
    local cells = {}
    local totalOverlapArea = 0

    for gx = startGridX, endGridX, GroundPropertyTracker.GRID_SIZE do
        for gz = startGridZ, endGridZ, GroundPropertyTracker.GRID_SIZE do
            local gridX, gridZ = self:getGridPosition(gx + GroundPropertyTracker.GRID_SIZE / 2,
                gz + GroundPropertyTracker.GRID_SIZE / 2)
            local overlapArea, overlapWidthX, overlapDepthZ = self:calculateCellOverlap(gridX, gridZ, minX, maxX, minZ,
                maxZ)

            if overlapArea > 0 then
                table.insert(cells, {
                    gridX = gridX,
                    gridZ = gridZ,
                    overlapArea = overlapArea,
                    overlapWidthX = overlapWidthX,
                    overlapDepthZ = overlapDepthZ
                })
                totalOverlapArea = totalOverlapArea + overlapArea
            end
        end
    end

    return cells, totalOverlapArea
end

---
-- Add a new dropped pile to tracking
-- Distributes properties across grid cells based on overlap area
-- @param sx, sz, wx, wz, hx, hz: Area coordinates (start, width, height corners)
-- @param fillType: The filltype index being dropped
-- @param volume: Volume in liters (used only for weighted averaging, not stored)
-- @param properties: Table of properties {moisture=0.18}
---
function GroundPropertyTracker:addPile(sx, sz, wx, wz, hx, hz, fillType, volume, properties)
    if not self.isServer then return end

    local moistureSystem = g_currentMission.MoistureSystem

    -- Only track fillTypes defined in CropValueMap or grass types
    if not moistureSystem:shouldTrackFillType(fillType) then return end

    -- Get all grid cells this drop affects with their overlap areas
    local affectedCells, totalOverlapArea = self:getAffectedGridCells(sx, sz, wx, wz, hx, hz)

    if #affectedCells == 0 or totalOverlapArea == 0 then return end

    -- Choose storage based on fillType
    local storage = self:getStorageForFillType(fillType)

    -- Distribute proportionally based on overlap area
    for _, cell in ipairs(affectedCells) do
        local proportion = cell.overlapArea / totalOverlapArea
        local volumeForCell = volume * proportion

        local key = self:getGridKey(cell.gridX, cell.gridZ, fillType)
        local pile = storage[key]

        if pile then
            -- Update existing pile with volume-weighted averaging
            local checkRadius = GroundPropertyTracker.GRID_SIZE / 2
            local existingVolume = DensityMapHeightUtil.getFillLevelAtArea(
                fillType,
                cell.gridX - checkRadius, cell.gridZ - checkRadius,
                cell.gridX + checkRadius, cell.gridZ - checkRadius,
                cell.gridX - checkRadius, cell.gridZ + checkRadius
            )

            local totalVolume = existingVolume + volumeForCell

            -- Calculate new properties with volume-weighted averaging
            local newProperties = {}
            for propKey, propValue in pairs(properties or {}) do
                local originalValue = pile.properties[propKey]
                if originalValue and totalVolume > 0 then
                    -- Volume-weighted average
                    newProperties[propKey] = (originalValue * existingVolume + propValue * volumeForCell) / totalVolume
                else
                    newProperties[propKey] = propValue
                end
            end

            self:queuePileUpdate(key, newProperties, fillType, cell.gridX, cell.gridZ)
        else
            self:queuePileUpdate(key, properties or {}, fillType, cell.gridX, cell.gridZ)
        end
    end
end

-- Get pile properties at world position
function GroundPropertyTracker:getPropertiesAtLocation(x, z, fillType)
    local moistureSystem = g_currentMission.MoistureSystem
    local storage = self:getStorageForFillType(fillType)
    local gridX, gridZ = self:getGridPosition(x, z)
    local key = self:getGridKey(gridX, gridZ, fillType)
    local pile = storage[key]

    if pile then
        return pile.properties
    end

    return nil
end

-- Mark area as tedded (buffered)
function GroundPropertyTracker:markAreaTedded(sx, sz, wx, wz, hx, hz)
    if not self.isServer then return end

    -- Calculate bounding box dimensions for diagnostics
    local minX = math.min(sx, wx, hx)
    local maxX = math.max(sx, wx, hx)
    local minZ = math.min(sz, wz, hz)
    local maxZ = math.max(sz, wz, hz)
    local widthX = maxX - minX
    local depthZ = maxZ - minZ

    local affectedCells = self:getAffectedGridCells(sx, sz, wx, wz, hx, hz)

    -- Determine which axis is lateral (width) by looking at bounding box shape
    -- The wider dimension of the bbox is the lateral dimension
    local lateralIsX = widthX > depthZ

    -- Require MORE THAN 50% of cell size (>1m for 2m cells) in the lateral dimension
    local lateralOverlapThreshold = GroundPropertyTracker.GRID_SIZE * 0.5 -- 1m for 2m cells

    local bufferedCount = 0
    local skippedCount = 0
    local belowThresholdCount = 0
    for _, cell in ipairs(affectedCells) do
        local gridKey = self:getSimpleGridKey(cell.gridX, cell.gridZ)

        if not self.teddedGridCellsCooldown[gridKey] and not self.teddedGridCellsBuffer[gridKey] and not self.teddedGridCells[gridKey] then
            -- Check overlap in the lateral (width) dimension specifically
            -- This filters out edge cells that are predominantly outside the working width
            local lateralOverlap = lateralIsX and cell.overlapWidthX or cell.overlapDepthZ

            -- Check if lateral dimension >50% of cell size
            if lateralOverlap > lateralOverlapThreshold then
                self.teddedGridCellsBuffer[gridKey] = GroundPropertyTracker.DELAYED_PROCESSING_CYCLES
                bufferedCount = bufferedCount + 1
            else
                belowThresholdCount = belowThresholdCount + 1
            end
        else
            skippedCount = skippedCount + 1
        end
    end
end

-- Mark area as mowed (cooldown)
function GroundPropertyTracker:markAreaMowed(sx, sz, wx, wz, hx, hz)
    if not self.isServer then return end

    -- Get all grid cells this area overlaps
    local affectedCells = self:getAffectedGridCells(sx, sz, wx, wz, hx, hz)

    -- Calculate cell area for overlap threshold check
    local cellArea = GroundPropertyTracker.GRID_SIZE * GroundPropertyTracker.GRID_SIZE
    local overlapThreshold = cellArea * 0.5

    -- Mark each cell as mowed with cooldown (skip drying for 4 seconds)
    for _, cell in ipairs(affectedCells) do
        -- Only mark cells where more than 50% is within the mowed area
        if cell.overlapArea > overlapThreshold then
            local gridKey = self:getSimpleGridKey(cell.gridX, cell.gridZ)

            -- Set cooldown to prevent drying for newly mowed grass
            if not self.recentMowedCells[gridKey] then
                self.recentMowedCells[gridKey] = GroundPropertyTracker.DELAYED_PROCESSING_CYCLES
            end
        end
    end
end

-- Add pending windrower drop with volume-weighted moisture/quality accumulation
function GroundPropertyTracker:addWindrowerDrop(sx, sz, wx, wz, hx, hz, fillType, volume, moisture, quality)
    if not self.isServer then return end

    local moistureSystem = g_currentMission.MoistureSystem
    if not moistureSystem:shouldTrackFillType(fillType) then return end

    quality = quality or moistureSystem:deriveQuality(fillType, moisture)

    local affectedCells, totalOverlapArea = self:getAffectedGridCells(sx, sz, wx, wz, hx, hz)
    if #affectedCells == 0 or totalOverlapArea == 0 then return end

    -- Distribute volume across cells based on overlap area
    for _, cell in ipairs(affectedCells) do
        local proportion = cell.overlapArea / totalOverlapArea
        local volumeForCell = volume * proportion

        local key = self:getGridKey(cell.gridX, cell.gridZ, fillType)

        if self.windrowerPendingDrops[key] then
            local pending = self.windrowerPendingDrops[key]
            pending.volume = pending.volume + volumeForCell
            pending.moistureSum = pending.moistureSum + (moisture * volumeForCell)
            pending.qualitySum = pending.qualitySum + (quality * volumeForCell)
            pending.cyclesRemaining = GroundPropertyTracker.WINDROWER_PROCESSING_CYCLES
        else
            self.windrowerPendingDrops[key] = {
                gridX = cell.gridX,
                gridZ = cell.gridZ,
                fillType = fillType,
                volume = volumeForCell,
                moistureSum = moisture * volumeForCell,
                qualitySum = quality * volumeForCell,
                cyclesRemaining = GroundPropertyTracker.WINDROWER_PROCESSING_CYCLES
            }
        end
    end
end

-- Mark cells picked up by windrower for deferred cleanup
function GroundPropertyTracker:markWindrowerPickup(sx, sz, wx, wz, hx, hz, fillType)
    if not self.isServer then return end

    local affectedCells = self:getAffectedGridCells(sx, sz, wx, wz, hx, hz)

    for _, cell in ipairs(affectedCells) do
        local key = self:getGridKey(cell.gridX, cell.gridZ, fillType)
        -- Mark for cleanup after slight delay
        self.windrowerPickedCells[key] = GroundPropertyTracker.WINDROWER_PROCESSING_CYCLES + 1
    end
end

-- Convert grass to hay in a cell
function GroundPropertyTracker:convertGrassToHayInCell(gridX, gridZ, grassFillType, hayFillType)
    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2

    -- Check if there's grass in this cell
    local grassVolume = DensityMapHeightUtil.getFillLevelAtArea(
        grassFillType,
        gridX - checkRadius, gridZ - checkRadius,
        gridX + checkRadius, gridZ - checkRadius,
        gridX - checkRadius, gridZ + checkRadius
    )

    if grassVolume > 0 then
        -- Get the moisture from the grass pile to transfer to hay
        local grassKey = self:getGridKey(gridX, gridZ, grassFillType)
        local grassMoisture = nil
        if self.grassPiles[grassKey] and self.grassPiles[grassKey].properties.moisture then
            grassMoisture = self.grassPiles[grassKey].properties.moisture
        end

        -- Convert grass to hay with buffer
        local halfSize = GroundPropertyTracker.GRID_SIZE / 2
        local buffer = halfSize * 0.2
        local sx = gridX - halfSize - buffer
        local sz = gridZ - halfSize - buffer
        local wx = gridX + halfSize + buffer
        local wz = gridZ - halfSize - buffer
        local hx = gridX - halfSize - buffer
        local hz = gridZ + halfSize + buffer

        DensityMapHeightUtil.changeFillTypeAtArea(sx, sz, wx, wz, hx, hz, grassFillType, hayFillType)

        -- Create hay pile with grass's moisture
        if grassMoisture then
            local hayKey = self:getGridKey(gridX, gridZ, hayFillType)
            local properties = { moisture = grassMoisture }

            self:queuePileUpdate(hayKey, properties, hayFillType, gridX, gridZ)
        end

        -- Check for remaining grass content and cleanup
        self:checkPileHasContent(gridX, gridZ, grassFillType)
    end
end

-- Convert hay to grass in a cell
function GroundPropertyTracker:convertHayToGrassInCell(gridX, gridZ, hayFillType, grassFillType)
    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2

    -- Check if there's hay in this cell
    local hayVolume = DensityMapHeightUtil.getFillLevelAtArea(
        hayFillType,
        gridX - checkRadius, gridZ - checkRadius,
        gridX + checkRadius, gridZ - checkRadius,
        gridX - checkRadius, gridZ + checkRadius
    )

    if hayVolume > 0 then
        -- Get the moisture from the hay pile to transfer to grass
        local hayKey = self:getGridKey(gridX, gridZ, hayFillType)
        local hayMoisture = nil
        if self.hayPiles[hayKey] and self.hayPiles[hayKey].properties.moisture then
            hayMoisture = self.hayPiles[hayKey].properties.moisture
        end

        -- Convert hay to grass with buffer
        local halfSize = GroundPropertyTracker.GRID_SIZE / 2
        local buffer = halfSize * 0.2
        local sx = gridX - halfSize - buffer
        local sz = gridZ - halfSize - buffer
        local wx = gridX + halfSize + buffer
        local wz = gridZ - halfSize - buffer
        local hx = gridX - halfSize - buffer
        local hz = gridZ + halfSize + buffer

        DensityMapHeightUtil.changeFillTypeAtArea(sx, sz, wx, wz, hx, hz, hayFillType, grassFillType)

        -- Create grass pile with hay's moisture
        if hayMoisture then
            local grassKey = self:getGridKey(gridX, gridZ, grassFillType)
            local properties = { moisture = hayMoisture }

            self:queuePileUpdate(grassKey, properties, grassFillType, gridX, gridZ)
        end

        -- Check for remaining hay content and cleanup
        self:checkPileHasContent(gridX, gridZ, hayFillType)
    end
end

---
-- Feed the global field moisture delta produced by MoistureSystem into the
-- drying accumulator, and accrue elapsed game-ms into the rain/dry exposure
-- accumulators. All three are the same for every pile, so accumulating here and
-- draining lazily during the cursor sweep is equivalent to applying to every
-- pile every cycle. Called once per MoistureSystem weather cycle.
-- @param moistureDelta: field moisture delta for this cycle (0-1 scale)
-- @param rawDelta: wall-clock ms elapsed this cycle (pre-timescale)
---
function GroundPropertyTracker:feedMoistureDelta(moistureDelta, rawDelta)
    if not self.isServer then return end
    self.dryingAccumulator = self.dryingAccumulator + moistureDelta

    -- Accrue rain/dry exposure time (game-ms). Uses the rot system's own
    -- "raining" definition (rainfall intensity > 0.1), matching the original
    -- per-pile rain-exposure isRaining check now folded into tickRainExposureAndRot.
    local updateDelta = (rawDelta or 0) * g_currentMission:getEffectiveTimeScale()
    local isRaining = g_currentMission.environment.weather:getRainFallScale() > 0.1
    if isRaining then
        self.rainTimeAcc = self.rainTimeAcc + updateDelta
    else
        self.dryTimeAcc = self.dryTimeAcc + updateDelta
    end
end

---
-- Per-frame entry point (driven from MoistureSystem:update, which already runs
-- every frame on the server). Two cadences:
--   * the bounded active-set work (tedding, conversions, windrower, cooldowns)
--     runs on a 500ms internal clock to preserve the original cycle-counter
--     semantics;
--   * the O(N) drying + rain-exposure/rot sweep advances a fixed budget of piles
--     every frame so its per-frame cost is bounded regardless of pile count.
---
function GroundPropertyTracker:update(dt)
    if not self.isServer then return end

    self.cycleTimer = self.cycleTimer + dt
    if self.cycleTimer >= GroundPropertyTracker.CYCLE_INTERVAL then
        self:runCycleWork()
        self.cycleTimer = 0
    end

    self:runDryingSweep(GroundPropertyTracker.SWEEP_BUDGET)
end

-- Bounded active-set work; cost scales with active sets (tedded cells, pending
-- drops, cooldowns), not with total pile count.
function GroundPropertyTracker:runCycleWork()
    -- Copy tedded cells for this cycle and clear the table for next cycle
    local teddedCellsThisCycle = {}
    for gridKey, _ in pairs(self.teddedGridCells) do
        teddedCellsThisCycle[gridKey] = true
    end
    self.teddedGridCells = {}

    local processedThisCycle = {} -- Track cells we've already processed to avoid double-reduction

    local converter = g_fillTypeManager:getConverterDataByName("TEDDER")
    self:processHayConversions(converter)

    local moistureSystem = g_currentMission.MoistureSystem
    self:processTeddedCells(teddedCellsThisCycle, processedThisCycle, moistureSystem, converter)

    -- One-time tedding moisture reduction for existing grass piles in tedded
    -- cells (newly-created tedded piles already got it in processTeddedCells).
    self:applyTeddingToExistingPiles(teddedCellsThisCycle, processedThisCycle, converter)

    -- Rain exposure + rotting are no longer walked here; they're folded into the
    -- per-pile drying sweep (tickRainExposureAndRot) on the same bounded budget,
    -- draining the rain/dry time accumulators. This removes the old uncapped
    -- per-cycle walk of wetGrassKeys/wetStrawKeys (which grew to the full open-sky
    -- pile count during rain).

    -- Hay -> grass conversion bookkeeping (grassCells set is populated by the
    -- drying sweep when a hay pile rises back above DRY_THRESHOLD).
    self:processGrassConversions(converter)

    self:processWindrowerPendingDrops()

    self:decrementCooldownsAndBuffers()
end

---
-- Continuous-drying cursor sweep. Advances through the incrementally-maintained
-- snapshot of pile keys, applying the drying accumulated since each pile was last
-- visited. Bounded to `budget` slot examinations per call. The snapshot is NOT
-- rebuilt on wrap — new piles are appended in queuePileUpdate and gone piles are
-- swap-removed here as the cursor reaches their slot, so there is no O(N) burst.
---
function GroundPropertyTracker:runDryingSweep(budget)
    if self.sweepPos > self.sweepLen then
        self:onSweepWrapped()
        if self.sweepLen == 0 then
            return
        end
    end

    local acc = self.dryingAccumulator
    local examined = 0

    while examined < budget and self.sweepPos <= self.sweepLen do
        local key = self.sweepKeys[self.sweepPos]
        local kind = self.sweepKinds[self.sweepPos]

        local storage = self:getStorageByKind(kind)
        local pile = storage[key]

        examined = examined + 1

        if pile ~= nil then
            -- applyDryingToPile returns false if the pile rotted fully away (its
            -- storage entry is already removed); drop its sweep slot too.
            local alive = self:applyDryingToPile(key, pile, kind, acc)
            if alive then
                self.sweepPos = self.sweepPos + 1
            else
                self:removeSweepSlot(self.sweepPos)
            end
        else
            -- Pile gone: swap-remove this slot. The element pulled into this slot
            -- still needs examining, so the cursor stays put. Examining the stale
            -- slot already counted against the budget, so a run of removals can't
            -- burst beyond `budget` work per frame.
            self:removeSweepSlot(self.sweepPos)
        end
    end

    -- Update metrics for this frame's slice.
    local stats = self.sweepStats
    stats.periodFramesAccum = stats.periodFramesAccum + 1
    if examined > 0 then
        stats.framesWithWork = stats.framesWithWork + 1
        stats.pilesVisited = stats.pilesVisited + examined
        stats.periodPilesAccum = stats.periodPilesAccum + examined
    end
end

-- Cursor wrapped: roll the completed period's metrics into the "last period"
-- snapshot and reset the cursor. No rebuild (snapshot is maintained incrementally).
function GroundPropertyTracker:onSweepWrapped()
    local stats = self.sweepStats
    if stats.periodPilesAccum > 0 then
        stats.lastPeriodPiles = stats.periodPilesAccum
        stats.lastPeriodFrames = stats.periodFramesAccum
        stats.sweepCount = stats.sweepCount + 1
        stats.periodPilesAccum = 0
        stats.periodFramesAccum = 0
    end
    self.sweepPos = 1
end

-- Swap-remove a snapshot slot in O(1): move the last element into this slot,
-- shrink the array, and drop the removed key from the membership set.
function GroundPropertyTracker:removeSweepSlot(i)
    local n = self.sweepLen
    local removedKey = self.sweepKeys[i]

    if i ~= n then
        self.sweepKeys[i] = self.sweepKeys[n]
        self.sweepKinds[i] = self.sweepKinds[n]
    end
    self.sweepKeys[n] = nil
    self.sweepKinds[n] = nil
    self.sweepLen = n - 1
    self.inSweep[removedKey] = nil
end

-- Console command: report drying-sweep throughput so the amortization can be
-- validated against the live (multiplayer) pile load.
function GroundPropertyTracker:consoleCommandSweepDebug()
    if not self.isServer then
        return "msSweepDebug is server-side only"
    end

    local function count(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    local grass = count(self.grassPiles)
    local hay = count(self.hayPiles)
    local straw = count(self.strawPiles)
    local grid = count(self.gridPiles)
    local total = grass + hay + straw + grid

    -- Wet piles: those carrying rain exposure (rainExposure or peakRainExposure
    -- > 0), counted on demand. Rain exposure + rotting are now handled inside the
    -- bounded drying sweep (tickRainExposureAndRot), so this is purely diagnostic
    -- and no longer drives any per-cycle walk.
    local function countWet(storage)
        local n = 0
        for _, pile in pairs(storage) do
            if (pile.properties.rainExposure or 0) > 0 or (pile.properties.peakRainExposure or 0) > 0 then
                n = n + 1
            end
        end
        return n
    end
    local wetGrass = countWet(self.grassPiles)
    local wetStraw = countWet(self.strawPiles)

    local weather = g_currentMission.environment.weather
    local isRaining = weather:getRainFallScale() > 0.1

    local stats = self.sweepStats
    -- Estimate full-sweep period in seconds from the last completed period
    -- (frames * assumed ~16.6ms/frame is unreliable; report frames instead).
    local lastPeriodPiles = stats.lastPeriodPiles
    local lastPeriodFrames = stats.lastPeriodFrames
    local avgPerFrame = lastPeriodFrames > 0 and (lastPeriodPiles / lastPeriodFrames) or 0

    local lines = {
        string.format("Piles:     total=%d (grass=%d hay=%d straw=%d grid=%d)",
            total, grass, hay, straw, grid),
        string.format("Snapshot:  len=%d pos=%d budget=%d peak=%d",
            self.sweepLen, self.sweepPos, GroundPropertyTracker.SWEEP_BUDGET, stats.peakSnapshotLen),
        string.format("WetPiles:  grass=%d straw=%d (raining=%s) -- folded into bounded sweep",
            wetGrass, wetStraw, tostring(isRaining)),
        string.format("ExpoAcc:   rain=%.0f dry=%.0f", self.rainTimeAcc, self.dryTimeAcc),
        string.format("LastSweep: %d piles over %d frames (%.1f piles/frame avg)",
            lastPeriodPiles, lastPeriodFrames, avgPerFrame),
        string.format("Totals:    %d sweeps completed, %d frames did work",
            stats.sweepCount, stats.framesWithWork),
        string.format("Drying:    accumulator=%.5f", self.dryingAccumulator),
    }
    for _, line in ipairs(lines) do print(line) end
    return table.concat(lines, " | ")
end

-- Full rebuild of the sweep snapshot from current pile storages. Only for
-- bulk-load events that replace the storage tables wholesale (savegame load,
-- grid-size conversion) — steady-state add/remove is handled incrementally by
-- appendToSweep / removeSweepSlot, so this is NOT called on cursor wrap.
function GroundPropertyTracker:rebuildSweepSnapshot()
    local keys = self.sweepKeys
    local kinds = self.sweepKinds
    local inSweep = self.inSweep
    local n = 0

    -- Clear the membership set; repopulated below.
    for k in pairs(inSweep) do inSweep[k] = nil end

    for key in pairs(self.grassPiles) do
        n = n + 1
        keys[n] = key
        kinds[n] = "grass"
        inSweep[key] = true
    end
    for key in pairs(self.hayPiles) do
        n = n + 1
        keys[n] = key
        kinds[n] = "hay"
        inSweep[key] = true
    end
    for key in pairs(self.strawPiles) do
        n = n + 1
        keys[n] = key
        kinds[n] = "straw"
        inSweep[key] = true
    end

    -- Trim any stale trailing entries from a previous, longer snapshot.
    for i = n + 1, self.sweepLen do
        keys[i] = nil
        kinds[i] = nil
    end

    self.sweepLen = n
    self.sweepPos = 1

    if n > self.sweepStats.peakSnapshotLen then
        self.sweepStats.peakSnapshotLen = n
    end
end

-- Apply accumulated drying to a single pile during the sweep. Per-kind clamps
-- and threshold-conversion marking mirror the original bulk loops. Rain exposure
-- and rotting (grass/straw) are folded into the same visit via
-- tickRainExposureAndRot, draining the rain/dry time accumulators. Returns false
-- if the pile was removed (rotted away), so the caller can drop it from the sweep.
function GroundPropertyTracker:applyDryingToPile(key, pile, kind, acc)
    local moisture = pile.properties.moisture
    if moisture == nil then
        pile.lastAcc = acc
        return true
    end

    if kind == "grass" then
        local gridKey = self:getSimpleGridKey(pile.gridX, pile.gridZ)

        -- Freshly-mowed grass is held out of drying. Advance lastAcc without
        -- applying, so this cycle's delta is dropped (matching the original
        -- per-cycle `continue`) rather than accumulating into a catch-up jump
        -- when the cooldown clears. Rain exposure still ticks (it did before too).
        if self.recentMowedCells[gridKey] then
            pile.lastAcc = acc
            return self:tickRainExposureAndRot(key, pile, self.grassRotAccumulators)
        end

        local applied = acc - (pile.lastAcc or acc)
        pile.lastAcc = acc

        if applied ~= 0 then
            local newMoisture = moisture + applied
            newMoisture = math.max(GroundPropertyTracker.MIN_GRASS_MOISTURE,
                math.min(GroundPropertyTracker.MAX_GRASS_MOISTURE, newMoisture))

            if newMoisture <= GroundPropertyTracker.DRY_THRESHOLD then
                self.hayCells[gridKey] = 10
            end

            if newMoisture ~= moisture then
                pile.properties.moisture = newMoisture
            end
        end

        return self:tickRainExposureAndRot(key, pile, self.grassRotAccumulators)
    elseif kind == "hay" then
        local applied = acc - (pile.lastAcc or acc)
        pile.lastAcc = acc
        if applied ~= 0 then
            local newMoisture = math.max(GroundPropertyTracker.MIN_HAY_MOISTURE, moisture + applied)

            if newMoisture > GroundPropertyTracker.DRY_THRESHOLD then
                local gridKey = self:getSimpleGridKey(pile.gridX, pile.gridZ)
                self.grassCells[gridKey] = 10
            end

            if newMoisture ~= moisture then
                pile.properties.moisture = newMoisture
            end
        end
        return true
    elseif kind == "straw" then
        local applied = acc - (pile.lastAcc or acc)
        pile.lastAcc = acc
        if applied ~= 0 then
            -- No max clamp; straw can get very wet.
            local newMoisture = math.max(0, moisture + applied)
            if newMoisture ~= moisture then
                pile.properties.moisture = newMoisture
            end
        end

        return self:tickRainExposureAndRot(key, pile, self.strawRotAccumulators)
    end

    return true
end

-- One-time tedding moisture reduction applied to existing grass piles whose cell
-- was tedded this cycle (split out of the former applyMoistureToGrassPiles loop;
-- drying itself is now handled by the accumulator sweep).
--
-- Iterates the (small) tedded-cell set rather than all grass piles, deriving
-- candidate pile keys from the converter's source fill types, so cost scales with
-- tedded cells × converter entries — not with total pile count.
function GroundPropertyTracker:applyTeddingToExistingPiles(teddedCellsThisCycle, processedThisCycle, converter)
    local reduction = g_currentMission.MoistureSystem.settings.teddingMoistureReduction

    for gridKey, _ in pairs(teddedCellsThisCycle) do
        if not self.recentMowedCells[gridKey] and not processedThisCycle[gridKey] then
            local gridX, gridZ = gridKey:match("([^_]+)_([^_]+)")
            gridX = tonumber(gridX)
            gridZ = tonumber(gridZ)

            for fromFillType, to in pairs(converter) do
                if fromFillType ~= to.targetFillTypeIndex then
                    local key = self:getGridKey(gridX, gridZ, fromFillType)
                    local pile = self.grassPiles[key]

                    if pile and pile.properties.moisture then
                        local newMoisture = pile.properties.moisture - reduction
                        newMoisture = math.max(GroundPropertyTracker.MIN_GRASS_MOISTURE,
                            math.min(GroundPropertyTracker.MAX_GRASS_MOISTURE, newMoisture))

                        self.teddedGridCellsCooldown[gridKey] = GroundPropertyTracker.TEDDED_COOLDOWN_CYCLES
                        self.teddedGridCells[gridKey] = nil

                        if newMoisture <= GroundPropertyTracker.DRY_THRESHOLD then
                            self.hayCells[gridKey] = 10
                        end

                        pile.properties.moisture = newMoisture
                    end
                end
            end
        end
    end
end

-- Process TEDDER conversions for hay/grasses
function GroundPropertyTracker:processHayConversions(converter)
    for fromFillType, to in pairs(converter) do
        local targetFillType = to.targetFillTypeIndex
        if fromFillType == targetFillType then
            continue
        end

        for gridKey, _ in pairs(self.hayCells) do
            local gridX, gridZ = gridKey:match("([^_]+)_([^_]+)")
            gridX = tonumber(gridX)
            gridZ = tonumber(gridZ)

            self:convertGrassToHayInCell(gridX, gridZ, fromFillType, targetFillType)
        end
    end
end

-- Handle tedded cells and create grass piles
function GroundPropertyTracker:processTeddedCells(teddedCellsThisCycle, processedThisCycle, moistureSystem, converter)
    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2

    for gridKey, _ in pairs(teddedCellsThisCycle) do
        local gridX, gridZ = gridKey:match("([^_]+)_([^_]+)")
        gridX = tonumber(gridX)
        gridZ = tonumber(gridZ)

        if self.recentMowedCells[gridKey] then
            continue
        end

        for fromFillType, to in pairs(converter) do
            local targetFillType = to.targetFillTypeIndex
            if fromFillType == targetFillType then
                continue
            end
            if fromFillType then
                local key = self:getGridKey(gridX, gridZ, fromFillType)
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fromFillType)

                if not self.grassPiles[key] then
                    local existingVolume = DensityMapHeightUtil.getFillLevelAtArea(
                        fromFillType,
                        gridX - checkRadius, gridZ - checkRadius,
                        gridX + checkRadius, gridZ - checkRadius,
                        gridX - checkRadius, gridZ + checkRadius
                    )

                    if existingVolume > 0 then
                        local baseMoisture
                        if self.teddedGrassMoisture[gridKey] then
                            baseMoisture = self.teddedGrassMoisture[gridKey]
                            self.teddedGrassMoisture[gridKey] = nil
                        else
                            baseMoisture = moistureSystem:getMoistureAtPosition(gridX, gridZ)
                        end

                        local teddedMoisture = baseMoisture -
                            g_currentMission.MoistureSystem.settings.teddingMoistureReduction
                        teddedMoisture = math.max(GroundPropertyTracker.MIN_GRASS_MOISTURE,
                            math.min(GroundPropertyTracker.MAX_GRASS_MOISTURE, teddedMoisture))

                        local properties = { moisture = teddedMoisture }

                        self:queuePileUpdate(key, properties, fromFillType, gridX, gridZ)

                        processedThisCycle[gridKey] = true
                        self.teddedGridCellsCooldown[gridKey] = GroundPropertyTracker.TEDDED_COOLDOWN_CYCLES
                        self.teddedGridCells[gridKey] = nil -- Clear from teddedGridCells after processing
                    end
                end
            end
        end
    end
end

-- Per-pile rain exposure update + rot tick, called from the drying sweep for
-- grass and straw piles. Drains the global rain/dry time accumulators since this
-- pile was last visited and applies the net exposure change in one step:
--   exposure += (rainTimeAcc - lastRainAcc)              -- time spent raining
--   exposure -= (dryTimeAcc  - lastDryAcc) * DECAY_RATE  -- time spent dry
-- This is equivalent to the old per-cycle tick (which added/decayed a fixed
-- updateDelta each 500ms while iterating the whole wet set), but folds into the
-- same bounded per-frame sweep visit as drying, so there is no uncapped walk.
-- @param rotAccumulators: self.grassRotAccumulators or self.strawRotAccumulators
-- @return false if the pile was fully removed (rotted away), true otherwise.
function GroundPropertyTracker:tickRainExposureAndRot(key, pile, rotAccumulators)
    local rainSince = self.rainTimeAcc - (pile.lastRainAcc or self.rainTimeAcc)
    local drySince = self.dryTimeAcc - (pile.lastDryAcc or self.dryTimeAcc)
    pile.lastRainAcc = self.rainTimeAcc
    pile.lastDryAcc = self.dryTimeAcc

    local rainExposure = pile.properties.rainExposure or 0
    local peakRainExposure = pile.properties.peakRainExposure or 0

    local scaleFactor = g_currentMission.MoistureSystem:getScaleFactor()

    -- Apply accrued rain time (gain) then accrued dry time (decay). If a sweep
    -- window straddles a weather transition both can be > 0 in one visit; we apply
    -- gain-then-decay. This is exact for the common rain->dry case (pile gets wet,
    -- then dries) and introduces at most min(rainSince,drySince)*DECAY_RATE of
    -- error for the rarer dry->rain case — a few seconds of exposure within a
    -- ~sweep-period window, negligible against the 60-100 min rot thresholds and
    -- non-cumulative (each visit re-reads the true accumulators).
    if rainSince > 0 then
        rainExposure = rainExposure + rainSince * scaleFactor
        if rainExposure > peakRainExposure then
            peakRainExposure = rainExposure
        end
    end
    if drySince > 0 then
        rainExposure = math.max(0, rainExposure - (drySince * GroundPropertyTracker.DRYING_DECAY_RATE * scaleFactor))

        -- Once a pile crosses SLOW_ROT_EXPOSURE_TIME its peak stays elevated
        -- forever (rot is permanent). Below that threshold, peak follows the
        -- decaying current exposure so the pile can settle back to dry.
        if rainExposure < GroundPropertyTracker.SLOW_ROT_EXPOSURE_TIME and
            peakRainExposure < GroundPropertyTracker.SLOW_ROT_EXPOSURE_TIME then
            peakRainExposure = rainExposure
        end
    end

    pile.properties.rainExposure = rainExposure
    pile.properties.peakRainExposure = peakRainExposure

    local rotLevel = 0
    if peakRainExposure >= GroundPropertyTracker.NORMAL_ROT_EXPOSURE_TIME then
        rotLevel = 2
    elseif peakRainExposure >= GroundPropertyTracker.SLOW_ROT_EXPOSURE_TIME then
        rotLevel = 1
    end

    if rotLevel > 0 then
        -- Rot accrues over total elapsed time since last visit (rain + dry), as
        -- the original did (it ran every cycle regardless of current rain state
        -- once peak crossed the threshold).
        local elapsed = rainSince + drySince
        if elapsed > 0 then
            if not rotAccumulators[key] then
                rotAccumulators[key] = 0
            end

            local baseAmount = GroundPropertyTracker.ROT_ACCUMULATION_MIN +
                math.random() * (GroundPropertyTracker.ROT_ACCUMULATION_MAX - GroundPropertyTracker.ROT_ACCUMULATION_MIN)

            local rotMultiplier = rotLevel == 2 and 1.4 or 1.0
            rotAccumulators[key] = rotAccumulators[key] + baseAmount * rotMultiplier * (elapsed / 1000) * scaleFactor

            if rotAccumulators[key] >= GroundPropertyTracker.ROT_REMOVAL_THRESHOLD then
                return self:removeRottedPileVolume(key, pile, rotAccumulators)
            end
        end
    else
        rotAccumulators[key] = nil
    end

    return true
end

-- Remove ROT_REMOVAL_THRESHOLD liters from a rotting pile's density-map area.
-- Shared by grass and straw rot. Returns false if the pile is now empty (caller
-- should drop it from the sweep), true otherwise.
function GroundPropertyTracker:removeRottedPileVolume(key, pile, rotAccumulators)
    local gridX = pile.gridX
    local gridZ = pile.gridZ
    local halfSize = GroundPropertyTracker.GRID_SIZE / 2

    if not self:checkPileHasContent(gridX, gridZ, pile.fillType) then
        rotAccumulators[key] = nil
        return false
    end

    local sx = gridX - halfSize
    local sz = gridZ - halfSize
    local sy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, sx, 0, sz)

    local wx = gridX + halfSize
    local wz = gridZ - halfSize
    local wy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, wx, 0, wz)

    local hx = gridX - halfSize
    local hz = gridZ + halfSize
    local hy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, hx, 0, hz)

    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByAreaDimensions(
        sx, sy, sz, wx, wy, wz, hx, hy, hz, true
    )

    local removed = DensityMapHeightUtil.tipToGroundAroundLine(
        nil,
        -GroundPropertyTracker.ROT_REMOVAL_THRESHOLD,
        pile.fillType,
        lsx, lsy, lsz,
        lex, ley, lez,
        2,
        nil,
        nil,
        false,
        nil
    )

    if removed ~= 0 then
        rotAccumulators[key] = 0
        return self:checkPileHasContent(gridX, gridZ, pile.fillType)
    end

    return true
end

-- Decrement cooldowns and buffers
function GroundPropertyTracker:decrementCooldownsAndBuffers()
    for gridKey, counter in pairs(self.teddedGridCellsBuffer) do
        self.teddedGridCellsBuffer[gridKey] = counter - 1
        if self.teddedGridCellsBuffer[gridKey] <= 0 then
            self.teddedGridCellsBuffer[gridKey] = nil
            self.teddedGridCells[gridKey] = true
        end
    end

    for gridKey, counter in pairs(self.teddedGridCellsCooldown) do
        self.teddedGridCellsCooldown[gridKey] = counter - 1
        if self.teddedGridCellsCooldown[gridKey] <= 0 then
            self.teddedGridCellsCooldown[gridKey] = nil
        end
    end

    for gridKey, counter in pairs(self.recentMowedCells) do
        self.recentMowedCells[gridKey] = counter - 1
        if self.recentMowedCells[gridKey] <= 0 then
            self.recentMowedCells[gridKey] = nil
        end
    end

    for gridKey, counter in pairs(self.hayCells) do
        self.hayCells[gridKey] = counter - 1
        if self.hayCells[gridKey] <= 0 then
            self.hayCells[gridKey] = nil
        end
    end
end

-- Process pending windrower drops after delay
function GroundPropertyTracker:processWindrowerPendingDrops()
    if not self.isServer then return end

    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2

    for key, pending in pairs(self.windrowerPendingDrops) do
        pending.cyclesRemaining = pending.cyclesRemaining - 1

        if pending.cyclesRemaining <= 0 then
            local avgMoisture = pending.moistureSum / pending.volume
            local avgQuality = pending.qualitySum / pending.volume

            local existingVolume = DensityMapHeightUtil.getFillLevelAtArea(
                pending.fillType,
                pending.gridX - checkRadius, pending.gridZ - checkRadius,
                pending.gridX + checkRadius, pending.gridZ - checkRadius,
                pending.gridX - checkRadius, pending.gridZ + checkRadius
            )

            if existingVolume > 0 then
                local storage = self:getStorageForFillType(pending.fillType)
                local pile = storage[key]

                local finalMoisture, finalQuality
                if pile then
                    local totalVolume = existingVolume + pending.volume
                    local existingMoisture = pile.properties.moisture or avgMoisture
                    local existingQuality = pile.properties.quality or avgQuality
                    finalMoisture = (existingMoisture * existingVolume + avgMoisture * pending.volume) / totalVolume
                    finalQuality = (existingQuality * existingVolume + avgQuality * pending.volume) / totalVolume
                else
                    finalMoisture = avgMoisture
                    finalQuality = avgQuality
                end

                self:queuePileUpdate(key, { moisture = finalMoisture, quality = finalQuality }, pending.fillType, pending.gridX, pending.gridZ)
            end

            self.windrowerPendingDrops[key] = nil
        end
    end

    -- Process picked cells cleanup
    for key, counter in pairs(self.windrowerPickedCells) do
        self.windrowerPickedCells[key] = counter - 1

        if self.windrowerPickedCells[key] <= 0 then
            -- Extract gridX, gridZ, fillType from key
            local gridX, gridZ, fillType = key:match("([^_]+)_([^_]+)_([^_]+)")
            gridX = tonumber(gridX)
            gridZ = tonumber(gridZ)
            fillType = tonumber(fillType)

            -- Check if pile still has content
            self:checkPileHasContent(gridX, gridZ, fillType)

            -- Remove from tracking
            self.windrowerPickedCells[key] = nil
        end
    end
end

-- Process hay -> grass conversion for cells the drying sweep flagged (grassCells
-- is populated when a hay pile's moisture rises back above DRY_THRESHOLD).
-- Hay/grass moisture itself is now applied by the drying sweep; this only handles
-- the density-map fill type conversion and its cooldown decrement.
function GroundPropertyTracker:processGrassConversions(converter)
    for fromFillType, to in pairs(converter) do
        local targetFillType = to.targetFillTypeIndex
        if fromFillType == targetFillType then
            continue
        end

        for gridKey, _ in pairs(self.grassCells) do
            local gridX, gridZ = gridKey:match("([^_]+)_([^_]+)")
            gridX = tonumber(gridX)
            gridZ = tonumber(gridZ)

            self:convertHayToGrassInCell(gridX, gridZ, targetFillType, fromFillType)
        end
    end

    for gridKey, counter in pairs(self.grassCells) do
        self.grassCells[gridKey] = counter - 1
        if self.grassCells[gridKey] <= 0 then
            self.grassCells[gridKey] = nil
        end
    end
end

-- Check pile content and remove tracking if empty
function GroundPropertyTracker:checkPileHasContent(gridX, gridZ, fillType)
    local moistureSystem = g_currentMission.MoistureSystem
    local checkRadius = GroundPropertyTracker.GRID_SIZE / 2
    local volume = DensityMapHeightUtil.getFillLevelAtArea(
        fillType,
        gridX - checkRadius, gridZ - checkRadius,
        gridX + checkRadius, gridZ - checkRadius,
        gridX - checkRadius, gridZ + checkRadius
    )

    if volume <= 0 then
        local key = self:getGridKey(gridX, gridZ, fillType)
        local storage = self:getStorageForFillType(fillType)
        if storage[key] then
            storage[key] = nil
        end
        return false
    end

    return true
end

-- Get pile properties at a position
-- On server: direct storage lookup
-- On client: on-demand request with local cache
function GroundPropertyTracker:getPilePropertiesAtPosition(x, z, fillType)
    local gridX, gridZ = self:getGridPosition(x, z)
    local key = self:getGridKey(gridX, gridZ, fillType)

    if not self.isServer then
        -- Client: check cache, request from server if stale/missing
        local cached = self.pileCache[key]
        local isFresh = cached ~= nil and g_time - cached.timestamp < 3000

        if not isFresh and not self.pendingPileRequests[key] then
            self.pendingPileRequests[key] = true
            g_client:getServerConnection():sendEvent(PilePropertyRequestEvent.new(gridX, gridZ, fillType))
        end

        if cached ~= nil and cached.moisture ~= nil then
            return { moisture = cached.moisture, quality = cached.quality }
        end
        return nil
    end

    -- Server: direct storage lookup
    local storage = self:getStorageForFillType(fillType)
    local pile = storage[key]
    if pile then
        return pile.properties
    end
    return nil
end

-- Convert grid cell sizing when GRID_SIZE changes
function GroundPropertyTracker:convertGridCells(fromSize, toSize)
    if not self.isServer then return end
    if fromSize == toSize then return end

    -- Temporary storage for new cells with volume tracking
    local newCells = {} -- [key] = { gridX, gridZ, fillType, isGrass, contributions[] }

    -- Collect all existing piles
    local oldPiles = {}

    for key, pile in pairs(self.gridPiles) do
        table.insert(oldPiles, {
            gridX = pile.gridX,
            gridZ = pile.gridZ,
            fillType = pile.fillType,
            properties = pile.properties,
            isGrass = false
        })
    end

    for key, pile in pairs(self.grassPiles) do
        table.insert(oldPiles, {
            gridX = pile.gridX,
            gridZ = pile.gridZ,
            fillType = pile.fillType,
            properties = pile.properties,
            isGrass = true
        })
    end

    for key, pile in pairs(self.hayPiles) do
        table.insert(oldPiles, {
            gridX = pile.gridX,
            gridZ = pile.gridZ,
            fillType = pile.fillType,
            properties = pile.properties,
            isHay = true
        })
    end

    for key, pile in pairs(self.strawPiles) do
        table.insert(oldPiles, {
            gridX = pile.gridX,
            gridZ = pile.gridZ,
            fillType = pile.fillType,
            properties = pile.properties,
            isStraw = true
        })
    end

    -- Clear existing storage
    self.gridPiles = {}
    self.grassPiles = {}
    self.hayPiles = {}
    self.strawPiles = {}

    -- Process each old pile
    for _, oldPile in ipairs(oldPiles) do
        -- Calculate the area covered by the old grid cell
        local halfOldSize = fromSize / 2
        local minX = oldPile.gridX - halfOldSize
        local maxX = oldPile.gridX + halfOldSize
        local minZ = oldPile.gridZ - halfOldSize
        local maxZ = oldPile.gridZ + halfOldSize

        -- Find all new grid cells that overlap this old area
        local startGridX = math.floor(minX / toSize) * toSize
        local endGridX = math.floor(maxX / toSize) * toSize
        local startGridZ = math.floor(minZ / toSize) * toSize
        local endGridZ = math.floor(maxZ / toSize) * toSize

        for gx = startGridX, endGridX, toSize do
            for gz = startGridZ, endGridZ, toSize do
                -- Get new grid center (aligned to new grid size)
                local newGridX = gx + toSize / 2
                local newGridZ = gz + toSize / 2

                -- Check if there's actually material here
                local checkRadius = toSize / 2
                local volume = DensityMapHeightUtil.getFillLevelAtArea(
                    oldPile.fillType,
                    newGridX - checkRadius, newGridZ - checkRadius,
                    newGridX + checkRadius, newGridZ - checkRadius,
                    newGridX - checkRadius, newGridZ + checkRadius
                )

                if volume > 0 then
                    local newKey = self:getGridKey(newGridX, newGridZ, oldPile.fillType)

                    if not newCells[newKey] then
                        newCells[newKey] = {
                            gridX = newGridX,
                            gridZ = newGridZ,
                            fillType = oldPile.fillType,
                            isGrass = oldPile.isGrass,
                            isHay = oldPile.isHay,
                            isStraw = oldPile.isStraw,
                            contributions = {}
                        }
                    end

                    -- Add this old pile's contribution
                    table.insert(newCells[newKey].contributions, {
                        volume = volume,
                        properties = oldPile.properties
                    })
                end
            end
        end
    end

    -- Create final piles from accumulated contributions
    for key, cell in pairs(newCells) do
        local storage
        if cell.isGrass then
            storage = self.grassPiles
        elseif cell.isHay then
            storage = self.hayPiles
        elseif cell.isStraw then
            storage = self.strawPiles
        else
            storage = self.gridPiles
        end

        storage[key] = {
            gridX = cell.gridX,
            gridZ = cell.gridZ,
            fillType = cell.fillType,
            properties = {}
        }

        -- Calculate volume-weighted average of properties from all contributions
        local totalVolume = 0
        local weightedProperties = {}

        for _, contribution in ipairs(cell.contributions) do
            totalVolume = totalVolume + contribution.volume
            for propKey, propValue in pairs(contribution.properties) do
                if not weightedProperties[propKey] then
                    weightedProperties[propKey] = 0
                end
                weightedProperties[propKey] = weightedProperties[propKey] + (propValue * contribution.volume)
            end
        end

        -- Calculate final averaged properties
        if totalVolume > 0 then
            for propKey, weightedValue in pairs(weightedProperties) do
                storage[key].properties[propKey] = weightedValue / totalVolume
            end
        end
    end

    -- Storages were rebuilt wholesale; rebuild the sweep snapshot to match.
    self:rebuildSweepSnapshot()
end

function GroundPropertyTracker:degradeQuality(decayRate, decayMultiplier)
    if not self.isServer then return end

    -- Only gridPiles can hold CropValueMap fill types (crops), which is the only
    -- thing quality grading / sell price uses. grass/hay/straw fill types have no
    -- CropValueMap entry, so getIdealRange returns nil and they were already
    -- no-ops here — skip them entirely to keep this hourly walk off those (much
    -- larger) tables.
    local allStorages = { self.gridPiles }

    for _, storage in ipairs(allStorages) do
        for _, pile in pairs(storage) do
            if pile.properties.moisture and pile.properties.quality then
                local _, idealMax = CropValueMap.getIdealRange(pile.fillType)
                if idealMax and pile.properties.moisture > idealMax then
                    local overshoot = pile.properties.moisture - idealMax
                    local degradation = decayRate * overshoot * 100 * decayMultiplier * g_currentMission.MoistureSystem:getScaleFactor()
                    pile.properties.quality = math.max(0, pile.properties.quality - degradation)
                end
            end
        end
    end
end

-- Save tracked piles to XML
function GroundPropertyTracker:saveToXMLFile(xmlFile, key)
    if not self.isServer then return end

    setXMLInt(xmlFile, key .. "#gridSize", GroundPropertyTracker.GRID_SIZE)

    -- First pass: collect all piles without modifying tables
    local candidatePiles = {}
    for _, pile in pairs(self.gridPiles) do
        table.insert(candidatePiles, pile)
    end
    for _, pile in pairs(self.grassPiles) do
        table.insert(candidatePiles, pile)
    end
    for _, pile in pairs(self.hayPiles) do
        table.insert(candidatePiles, pile)
    end
    for _, pile in pairs(self.strawPiles) do
        table.insert(candidatePiles, pile)
    end

    -- Second pass: verify content and build final list (safe to modify source tables now)
    local validatedPiles = {}
    for _, pile in ipairs(candidatePiles) do
        if self:checkPileHasContent(pile.gridX, pile.gridZ, pile.fillType) then
            table.insert(validatedPiles, pile)
        end
    end

    -- Group piles by fillType
    local pilesByFillType = {}
    for _, pile in ipairs(validatedPiles) do
        local fillTypeName = pile.fillTypeName or g_fillTypeManager:getFillTypeNameByIndex(pile.fillType)
        if not pilesByFillType[fillTypeName] then
            pilesByFillType[fillTypeName] = {}
        end
        table.insert(pilesByFillType[fillTypeName], pile)
    end

    -- Save each fillType group
    local groupIndex = 0
    for fillTypeName, piles in pairs(pilesByFillType) do
        local groupKey = string.format("%s.piles(%d)", key, groupIndex)
        setXMLString(xmlFile, groupKey .. "#type", fillTypeName)

        for i, pile in ipairs(piles) do
            local pileKey = string.format("%s.p(%d)", groupKey, i - 1)

            -- Combine location into single attribute
            local location = string.format("%d,%d", math.floor(pile.gridX), math.floor(pile.gridZ))
            setXMLString(xmlFile, pileKey .. "#l", location)

            if pile.properties.moisture then
                local roundedMoisture = math.floor(pile.properties.moisture * 1000 + 0.5) / 1000
                setXMLString(xmlFile, pileKey .. "#m", string.format("%.3f", roundedMoisture))
            end

            if pile.properties.quality then
                setXMLFloat(xmlFile, pileKey .. "#q", pile.properties.quality)
            end
        end

        groupIndex = groupIndex + 1
    end
end

-- Load tracked piles from XML
function GroundPropertyTracker:loadFromXMLFile(xmlFile, key)
    if not self.isServer then return end

    self.loadedGridSize = getXMLInt(xmlFile, key .. "#gridSize") or 5

    local groupIndex = 0
    while true do
        local groupKey = string.format("%s.piles(%d)", key, groupIndex)
        if not hasXMLProperty(xmlFile, groupKey) then
            break
        end

        local fillTypeName = getXMLString(xmlFile, groupKey .. "#type")
        if fillTypeName then
            local fillType = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if fillType then
                local pileIndex = 0
                while true do
                    local pileKey = string.format("%s.p(%d)", groupKey, pileIndex)
                    if not hasXMLProperty(xmlFile, pileKey) then
                        break
                    end

                    local location = getXMLString(xmlFile, pileKey .. "#l")
                    local moisture = getXMLFloat(xmlFile, pileKey .. "#m")
                    local quality = getXMLFloat(xmlFile, pileKey .. "#q")

                    if location then
                        local gridX, gridZ = location:match("([^,]+),([^,]+)")
                        gridX = tonumber(gridX)
                        gridZ = tonumber(gridZ)

                        if gridX and gridZ then
                            local pile = {
                                fillType = fillType,
                                fillTypeName = fillTypeName,
                                gridX = gridX,
                                gridZ = gridZ,
                                properties = {}
                            }

                            if moisture then
                                pile.properties.moisture = moisture
                                pile.properties.quality = quality
                            end

                            local gridKey = self:getGridKey(gridX, gridZ, fillType)
                            local storage = self:getStorageForFillType(fillType)
                            storage[gridKey] = pile
                        end
                    end

                    pileIndex = pileIndex + 1
                end
            end
        end

        groupIndex = groupIndex + 1
    end

    -- Storages were just populated from the savegame; build the sweep snapshot.
    self:rebuildSweepSnapshot()
end

---
-- Write ground pile data for initial client sync
-- @param streamId: Network stream ID
-- @param connection: Network connection
---
function GroundPropertyTracker:writeInitialClientState(streamId, connection)
    local function writePiles(storage)
        local count = 0
        for _ in pairs(storage) do
            count = count + 1
        end
        streamWriteInt32(streamId, count)

        for _, pile in pairs(storage) do
            streamWriteInt32(streamId, pile.fillType)
            streamWriteFloat32(streamId, pile.gridX)
            streamWriteFloat32(streamId, pile.gridZ)
            streamWriteFloat32(streamId, pile.properties.moisture or 0)
            streamWriteFloat32(streamId, pile.properties.quality or 100)
        end
    end

    -- Write all storage types in order
    writePiles(self.gridPiles)
    writePiles(self.grassPiles)
    writePiles(self.hayPiles)
    writePiles(self.strawPiles)
end

---
-- Read ground pile data for initial client sync
-- @param streamId: Network stream ID
-- @param connection: Network connection
---
function GroundPropertyTracker:readInitialClientState(streamId, connection)
    local function readPiles(storage)
        local count = streamReadInt32(streamId)

        for _ = 1, count do
            local fillType = streamReadInt32(streamId)
            local gridX = streamReadFloat32(streamId)
            local gridZ = streamReadFloat32(streamId)
            local moisture = streamReadFloat32(streamId)
            local quality = streamReadFloat32(streamId)

            local pile = {
                fillType = fillType,
                fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType),
                gridX = gridX,
                gridZ = gridZ,
                properties = { moisture = moisture, quality = quality }
            }

            local gridKey = self:getGridKey(gridX, gridZ, fillType)
            storage[gridKey] = pile
        end
    end

    -- Clear and read all storage types in order
    self.gridPiles = {}
    self.grassPiles = {}
    self.hayPiles = {}
    self.strawPiles = {}

    readPiles(self.gridPiles)
    readPiles(self.grassPiles)
    readPiles(self.hayPiles)
    readPiles(self.strawPiles)
end
