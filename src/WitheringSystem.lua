WitheringSystem = {}
local WitheringSystem_mt = Class(WitheringSystem)

-- Per-hour base wither chance at the threshold boundary.
-- Chance grows linearly as moisture drops further below threshold.
WitheringSystem.BASE_CHANCE_PER_HOUR = 0.3   -- 30% at threshold
WitheringSystem.MAX_CHANCE_PER_HOUR  = 1   -- 100% at zero moisture

-- Patch attempts per hectare per successful roll, scaled by drought depth.
WitheringSystem.BASE_ATTEMPTS_PER_HA = 3
WitheringSystem.MAX_ATTEMPTS_PER_HA  = 6

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

-- Returns per-hour chance and normalised drought depth t (0..1) for a moisture value.
local function witherChance(moisture, threshold)
    if moisture >= threshold then return 0, 0 end
    local depth = threshold - moisture
    local t = math.min(1, depth / threshold)
    local chance = WitheringSystem.BASE_CHANCE_PER_HOUR +
        t * (WitheringSystem.MAX_CHANCE_PER_HOUR - WitheringSystem.BASE_CHANCE_PER_HOUR)
    return chance, t
end

-- Number of patch attempts for this drought depth t (0..1) and field area.
local function patchAttempts(t, areaHa)
    local perHa = WitheringSystem.BASE_ATTEMPTS_PER_HA +
        t * (WitheringSystem.MAX_ATTEMPTS_PER_HA - WitheringSystem.BASE_ATTEMPTS_PER_HA)
    return math.max(1, math.floor(perHa * areaHa + 0.5))
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

-- Draw a rough disc via a centre square plus 4 diagonal corner squares.
-- radius controls overall size; each sub-square is roughly radius in extent.
local function drawDisc(modifier, filter, witheredState, cx, cz, radius)
    local half = radius * 0.5
    -- offsets for the 4 surrounding squares (NE, NW, SE, SW)
    local offsets = {
        { half,  half},
        {-half,  half},
        { half, -half},
        {-half, -half},
    }
    -- centre square
    modifier:setParallelogramWorldCoords(
        cx - half, cz - half,
        cx + half, cz - half,
        cx - half, cz + half,
        DensityCoordType.POINT_POINT_POINT
    )
    modifier:executeSet(witheredState, filter)
    -- corner squares
    for _, o in ipairs(offsets) do
        local sx = cx + o[1] - half * 0.5
        local sz = cz + o[2] - half * 0.5
        modifier:setParallelogramWorldCoords(
            sx,          sz,
            sx + half,   sz,
            sx,          sz + half,
            DensityCoordType.POINT_POINT_POINT
        )
        modifier:executeSet(witheredState, filter)
    end
end

-- Compute the AABB of a field from its polygon nodes.
local function getFieldBounds(field)
    local points = field:getPolygonPoints()
    if points == nil or #points == 0 then return nil end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, node in ipairs(points) do
        local wx, _, wz = getWorldTranslation(node)
        if wx < minX then minX = wx end
        if wx > maxX then maxX = wx end
        if wz < minZ then minZ = wz end
        if wz > maxZ then maxZ = wz end
    end
    return minX, maxX, minZ, maxZ
end

-- Wither one randomly-placed disc patch anywhere within the field's AABB.
function WitheringSystem:witherPatchAtField(field, fruitTypeIndex, witherThreshold)
    local entry = self:getModifierForFruitType(fruitTypeIndex)
    if entry == nil then return end

    local minX, maxX, minZ, maxZ = getFieldBounds(field)
    if minX == nil then return end

    local px = minX + math.random() * (maxX - minX)
    local pz = minZ + math.random() * (maxZ - minZ)

    -- Resample moisture at the patch location; skip if locally wetter than threshold.
    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem then
        local localMoisture = moistureSystem:getMoistureAtPosition(px, pz)
        if localMoisture ~= nil and localMoisture >= witherThreshold then return end
    end

    -- Radius varies 4–10m for natural-looking variety.
    local radius = 4 + math.random() * 6

    drawDisc(entry.modifier, entry.filter, entry.witheredState, px, pz, radius)
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

        local chance, t = witherChance(moisture, def.witherThreshold)
        if math.random() < chance then
            local scale = moistureSystem:getScaleFactor()
            local attempts = patchAttempts(t, field:getAreaHa() * scale)
            for _ = 1, attempts do
                self:witherPatchAtField(field, fruitTypeIndex, def.witherThreshold)
            end
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
