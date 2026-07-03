WitheringSystem = {}
local WitheringSystem_mt = Class(WitheringSystem)

-- Per-hour base wither chance at the threshold boundary.
-- Chance grows linearly as moisture drops further below threshold.
WitheringSystem.BASE_CHANCE_PER_HOUR = 0.02   -- 2% at threshold
WitheringSystem.MAX_CHANCE_PER_HOUR  = 0.15   -- 15% at zero moisture

-- Fallback penalties applied when witheringEnabled = false and moisture < witherThreshold.
-- Applied inside getYieldMultiplier / getQualityValue via the CropValueMap override in main.lua.
WitheringSystem.FALLBACK_YIELD_FLOOR   = 0.10  -- yield floored to 10%
WitheringSystem.FALLBACK_QUALITY_FLOOR = 0     -- quality at minimum

function WitheringSystem.new()
    local self = setmetatable({}, WitheringSystem_mt)
    self.isServer = g_currentMission:getIsServer()
    -- Cache of DensityMapModifier+filter per fruitTypeIndex.
    self.modifierCache = {}
    return self
end

function WitheringSystem:delete()
    self.modifierCache = {}
end

-- Returns the per-hour wither chance for a given moisture deficit below threshold.
-- moisture: current field moisture (0-1)
-- threshold: crop's witherThreshold
local function witherChance(moisture, threshold)
    if moisture >= threshold then return 0 end
    local depth = threshold - moisture  -- 0..threshold
    local t = math.min(1, depth / threshold)
    return WitheringSystem.BASE_CHANCE_PER_HOUR +
        t * (WitheringSystem.MAX_CHANCE_PER_HOUR - WitheringSystem.BASE_CHANCE_PER_HOUR)
end

-- Build or retrieve the DensityMapModifier+filter for a fruitTypeIndex.
-- Returns nil if this fruit type has no terrainDataPlaneId or no witheredState.
function WitheringSystem:getModifierForFruitType(fruitTypeIndex)
    local cached = self.modifierCache[fruitTypeIndex]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil or desc.terrainDataPlaneId == nil or desc.witheredState == nil then
        self.modifierCache[fruitTypeIndex] = false
        return nil
    end

    local modifier = DensityMapModifier.new(
        desc.terrainDataPlaneId,
        desc.startStateChannel,
        desc.numStateChannels,
        g_terrainNode
    )
    modifier:setPolygonRoundingMode(DensityRoundingMode.NEAREST)

    -- Filter: only affect non-zero, non-withered cells (living crop)
    local filter = DensityMapFilter.new(
        desc.terrainDataPlaneId,
        desc.startStateChannel,
        desc.numStateChannels
    )
    filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    local entry = { modifier = modifier, filter = filter, witheredState = desc.witheredState }
    self.modifierCache[fruitTypeIndex] = entry
    return entry
end

-- Apply withering to a small random cell within a field's bounding box.
-- Uses parallelogram (point-point-point) on a 10m × 10m patch.
function WitheringSystem:witherPatchAtField(field, fruitTypeIndex)
    local entry = self:getModifierForFruitType(fruitTypeIndex)
    if entry == nil then return end

    local cx, cz = field:getCenterOfFieldWorldPosition()
    -- Random offset within ±20m of centre to spread wither patches
    local ox = (math.random() - 0.5) * 40
    local oz = (math.random() - 0.5) * 40

    local px = cx + ox
    local pz = cz + oz
    local patchSize = 10

    entry.modifier:setParallelogramWorldCoords(
        px,              pz,
        px + patchSize,  pz,
        px,              pz + patchSize,
        DensityCoordType.POINT_POINT_POINT
    )
    entry.modifier:executeSet(entry.witheredState, entry.filter)
end

-- Called once per game hour from MoistureSystem:onHourChanged.
-- For each field, reads moisture at its centre; if below the crop's witherThreshold,
-- rolls a probabilistic check and withers a patch.
function WitheringSystem:onHourChanged()
    if not self.isServer then return end

    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then return end

    local fieldManager = g_fieldManager
    if fieldManager == nil then return end

    for _, field in pairs(fieldManager.fields) do
        local state = field:getFieldState()
        if state == nil or not state.isValid then continue end

        local fruitTypeIndex = state.fruitTypeIndex
        if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then continue end

        -- Only track crops in CropValueMap
        local def = CropValueMap.getCropDef(
            g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex).fillType.index
        )
        if def == nil or def.witherThreshold == nil then continue end

        local cx, cz = field:getCenterOfFieldWorldPosition()
        local moisture = moistureSystem:getMoistureAtPosition(cx, cz)
        if moisture == nil or moisture >= def.witherThreshold then continue end

        local chance = witherChance(moisture, def.witherThreshold)
        if math.random() < chance then
            self:witherPatchAtField(field, fruitTypeIndex)
        end
    end
end

-- Apply severe flat fallback penalties for a crop below witherThreshold when
-- withering is disabled. Returns adjusted yield multiplier and quality value.
-- Called from CropValueMap lookup wrappers when the setting is off.
function WitheringSystem.applyFallbackPenalties(yieldMultiplier, qualityValue, moisture, def)
    if moisture < def.witherThreshold then
        yieldMultiplier = math.min(yieldMultiplier, WitheringSystem.FALLBACK_YIELD_FLOOR)
        qualityValue = math.min(qualityValue, WitheringSystem.FALLBACK_QUALITY_FLOOR)
    end
    return yieldMultiplier, qualityValue
end
