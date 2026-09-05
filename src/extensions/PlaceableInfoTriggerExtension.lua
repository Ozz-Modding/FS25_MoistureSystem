---
-- PlaceableInfoTriggerExtension
-- Extends PlaceableInfoTrigger to display moisture information for placeables
---

MSPlaceableInfoTriggerExtension = {}

---
-- Show moisture data for placeables being looked at
-- Appended to PlaceableInfoTrigger.updateInfo
---
function MSPlaceableInfoTriggerExtension:updateInfo(info)
    -- Check if this placeable has moisture data
    if self.uniqueId == nil then
        return
    end
    
    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then
        return
    end
    
    -- Storage heap stores hold their grain as ground piles, not objectInfo — see
    -- StorageHeapExtension. Their own updateInfo already lists the fill levels; we add
    -- the moisture and quality behind them.
    if MSStorageHeapExtension.isStorageHeap(self) then
        MSPlaceableInfoTriggerExtension.appendStorageHeapInfo(self, info)
        return
    end

    -- A silo extension holds no moisture of its own: its grain is part of the parent
    -- silo's pool and is recorded under the parent's uniqueId (see getSiloStorages).
    -- Show the pool's figures so the extension doesn't read as empty when looked at.
    local source = moistureSystem:getParentSiloForExtension(self) or self

    moistureSystem:ensureObjectMoistureLoaded(source)

    local objectData = moistureSystem.objectInfo[source.uniqueId]
    if objectData == nil then
        return
    end

    for fillTypeName, info_data in pairs(objectData) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if fillType then
                table.insert(info, {
                    title = fillType.title .. " " .. g_i18n:getText("moistureSystem_moisture"),
                    text = string.format("%.1f%%", info_data.moisture * 100),
                    accentuate = false
                })
                if info_data.quality then
                    table.insert(info, {
                        title = fillType.title .. " " .. g_i18n:getText("moistureSystem_quality"),
                        text = MSPlayerHUDExtension.formatQualityText(info_data.quality, fillTypeName),
                        accentuate = false
                    })
                end
            end
        end
    end
end

---
-- Moisture and quality per crop for a storage heap store, weighted across its bays.
-- Silently shows nothing on a client until the pile request round-trips.
---
function MSPlaceableInfoTriggerExtension.appendStorageHeapInfo(placeable, info)
    for _, fillTypeIndex in ipairs(MSStorageHeapExtension.getStoredFillTypes(placeable)) do
        local stored = MSStorageHeapExtension.getStoredProperties(placeable, fillTypeIndex)
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

        if stored ~= nil and fillType ~= nil then
            table.insert(info, {
                title = fillType.title .. " " .. g_i18n:getText("moistureSystem_moisture"),
                text = string.format("%.1f%%", stored.moisture * 100),
                accentuate = false
            })
            table.insert(info, {
                title = fillType.title .. " " .. g_i18n:getText("moistureSystem_quality"),
                text = MSPlayerHUDExtension.formatQualityText(stored.quality,
                    g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)),
                accentuate = false
            })
        end
    end
end

PlaceableInfoTrigger.updateInfo = Utils.appendedFunction(
    PlaceableInfoTrigger.updateInfo,
    MSPlaceableInfoTriggerExtension.updateInfo
)
