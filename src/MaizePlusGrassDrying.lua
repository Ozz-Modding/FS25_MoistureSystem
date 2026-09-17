---
-- MaizePlusGrassDrying
-- Bridges FS25_MaizePlus's multi-stage grass/alfalfa/clover windrow drying (5 stages for
-- grass, 4 for alfalfa/clover - see SharedGrassDryingStages in MaizePlus itself) onto our
-- own moisture-driven drying. When MaizePlus is loaded, a windrow's fill type advances
-- through its chain automatically as GroundPropertyTracker dries it, the same way plain
-- grass turns to hay today - just with extra steps in between.
--
-- Entirely a lookup layer over the SharedGrassDryingStages table MaizePlus exposes (fill
-- type NAMES + moisture thresholds); we only translate names <-> fillType indices and gate
-- everything on g_modIsLoaded, so this is a no-op with MaizePlus absent.
--
-- IMPORTANT: every FS25 mod's source() files run under their own private global table
-- (_G[modName], set up via setfenv in the engine's mod loader), not the real shared _G. That
-- table's metatable falls back to the real _G for READS, so engine globals like
-- g_fillTypeManager resolve fine from here - but a plain `SharedGrassDryingStages = {}`
-- written inside MaizePlus's own files lands on _G["FS25_MaizePlus"].SharedGrassDryingStages,
-- not on our shared read path. So we must reach into _G[MOD_NAME] explicitly below; a bare
-- `SharedGrassDryingStages` reference from this file would silently always be nil.
---

MaizePlusGrassDrying = {}

MaizePlusGrassDrying.MOD_NAME = "FS25_MaizePlus"

---Returns MaizePlus's SharedGrassDryingStages table, or nil if MaizePlus isn't loaded (or
---hasn't defined it - e.g. an older version without the grass-drying interface package).
local function getStagesModule()
    if g_modIsLoaded == nil or not g_modIsLoaded[MaizePlusGrassDrying.MOD_NAME] then
        return nil
    end

    local modEnv = _G[MaizePlusGrassDrying.MOD_NAME]
    if modEnv == nil then
        return nil
    end

    return modEnv.SharedGrassDryingStages
end

---True if MaizePlus is loaded and its stage data is available.
function MaizePlusGrassDrying.isActive()
    return getStagesModule() ~= nil
end

---True if fillType (index) is any stage of a MaizePlus drying chain (including the
---terminal dry stage).
function MaizePlusGrassDrying.isChainFillTypeIndex(fillType)
    local stages = getStagesModule()
    if stages == nil or fillType == nil then
        return false
    end

    local name = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    return name ~= nil and stages.isChainFillType(name)
end

---Given a fillType (index) that's a non-terminal chain stage, returns the moisture (0-1)
---below which it should advance, and the fillType index it advances to. Returns nil, nil if
---MaizePlus isn't active, fillType isn't a chain stage, or it's already the driest stage.
function MaizePlusGrassDrying.getNextStage(fillType)
    local stages = getStagesModule()
    if stages == nil or fillType == nil then
        return nil, nil
    end

    local name = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    if name == nil then
        return nil, nil
    end

    local exitMoisture, nextName = stages.getNextStage(name)
    if nextName == nil then
        return nil, nil
    end

    local nextFillType = g_fillTypeManager:getFillTypeIndexByName(nextName)
    if nextFillType == nil then
        return nil, nil
    end

    return exitMoisture, nextFillType
end

---True if fillType (index) is the "conditioned" stage of its MaizePlus chain (the fill type
---a mower with the conditioner on drops directly, skipping "wet").
function MaizePlusGrassDrying.isConditionedStage(fillType)
    local stages = getStagesModule()
    if stages == nil or fillType == nil then
        return false
    end

    local name = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    return name ~= nil and stages.isConditionedStage(name)
end

---Returns the immediate moisture knock-off (0-1 scale) MaizePlus defines for a conditioner
---pass, or 0 if MaizePlus isn't active or doesn't define one (older version without it).
---MaizePlus owns this value - see CONDITIONING_MOISTURE_REDUCTION in its
---sharedGrassDryingStages.lua - since the conditioner is their mechanic, we just consume it.
function MaizePlusGrassDrying.getConditioningMoistureReduction()
    local stages = getStagesModule()
    if stages == nil or stages.CONDITIONING_MOISTURE_REDUCTION == nil then
        return 0
    end
    return stages.CONDITIONING_MOISTURE_REDUCTION
end

-- Cache of every non-terminal chain stage's fillType index, rebuilt lazily on first use
-- (fillType indices aren't stable to compute before the fill type manager is populated).
local advanceableFillTypesCache = nil

---Returns an array of fillType indices for every MaizePlus chain stage that has a next
---stage (i.e. every stage except the driest one in each chain). Used where
---GroundPropertyTracker needs to enumerate "grass-kind types that can still advance",
---mirroring what it already gets from the game's TEDDER fill type converter.
function MaizePlusGrassDrying.getAdvanceableFillTypes()
    local stages = getStagesModule()
    if stages == nil then
        return {}
    end

    if advanceableFillTypesCache ~= nil then
        return advanceableFillTypesCache
    end

    local types = {}
    for _, chain in pairs(stages.CHAINS) do
        for _, stage in ipairs(chain) do
            if stage.exitMoisture ~= nil then
                local fillType = g_fillTypeManager:getFillTypeIndexByName(stage.fillType)
                if fillType ~= nil then
                    table.insert(types, fillType)
                end
            end
        end
    end

    advanceableFillTypesCache = types
    return types
end
