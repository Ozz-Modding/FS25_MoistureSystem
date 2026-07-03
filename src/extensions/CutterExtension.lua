MSCutterExtension = {}

-- Cache the midpoint of the ideal moisture range per fillType, populated lazily
MSCutterExtension.idealMoistureCache = {}

local function getIdealMoisture(fillType)
    local cached = MSCutterExtension.idealMoistureCache[fillType]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local lower, upper = CropValueMap.getIdealRange(fillType)
    if lower ~= nil then
        local ideal = (lower + upper) / 2
        MSCutterExtension.idealMoistureCache[fillType] = ideal
        return ideal
    end

    MSCutterExtension.idealMoistureCache[fillType] = false
    return nil
end

-- Hook: apply moisture-driven yield reduction before grain enters the tank.
-- Modifies lastMultiplierArea in-place so the yield is scaled at source.
-- Server-side only; coexists with onEndWorkAreaProcessing (quality stamping).
function MSCutterExtension:processCutterArea(superFunc, ...)
    if not self.isServer then
        return superFunc(self, ...)
    end

    local spec = self.spec_cutter
    if spec == nil then
        return superFunc(self, ...)
    end

    local result = superFunc(self, ...)

    if spec.workAreaParameters.lastMultiplierArea and spec.workAreaParameters.lastMultiplierArea > 0 then
        local workArea = self:getWorkAreaByIndex(1)
        if workArea ~= nil then
            local sx, _, sz = getWorldTranslation(workArea.start)
            local wx, _, wz = getWorldTranslation(workArea.width)
            local hx, _, hz = getWorldTranslation(workArea.height)
            local centerX = (sx + wx + hx) / 3
            local centerZ = (sz + wz + hz) / 3

            local moistureSystem = g_currentMission.MoistureSystem
            if moistureSystem ~= nil then
                local moisture = moistureSystem:getMoistureAtPosition(centerX, centerZ)
                if moisture ~= nil then
                    local fruitType = spec.workAreaParameters.lastFruitType
                    if fruitType ~= nil then
                        local fillType = g_fruitTypeManager:getFruitTypeByIndex(fruitType).fillType.index
                        if fillType ~= nil then
                            local isContract = false
                            local farmland = g_farmlandManager:getFarmlandAtWorldPosition(centerX, centerZ)
                            if farmland ~= nil then
                                isContract = g_missionManager:getIsMissionRunningOnFarmland(farmland)
                            end

                            if isContract then
                                local ideal = getIdealMoisture(fillType)
                                if ideal ~= nil then
                                    moisture = ideal
                                end
                            end

                            local multiplier = CropValueMap.getYieldMultiplier(fillType, moisture)

                            -- Fallback: when withering is disabled, floor yield at wither threshold
                            local ms = g_currentMission.MoistureSystem
                            if ms and not ms.settings.witheringEnabled then
                                local def = CropValueMap.getCropDef(fillType)
                                if def and def.witherThreshold and moisture < def.witherThreshold then
                                    multiplier = math.min(multiplier, WitheringSystem.FALLBACK_YIELD_FLOOR)
                                end
                            end

                            spec.workAreaParameters.lastMultiplierArea =
                                spec.workAreaParameters.lastMultiplierArea * multiplier
                        end
                    end
                end
            end
        end
    end

    return result
end

-- Extended to track moisture of harvested crops
function MSCutterExtension:onEndWorkAreaProcessing(superFunc, dt, hasProcessed)
    local result = superFunc(self, dt, hasProcessed)

    if not self.isServer then
        return result
    end

    local spec = self.spec_cutter
    if spec == nil then
        return result
    end

    local combineVehicle = spec.workAreaParameters.combineVehicle
    if combineVehicle == nil then
        return result
    end

    -- Check whether we're working on a contract farmland
    local isContract = false
    local workArea = self:getWorkAreaByIndex(1)
    if workArea ~= nil then
        local cx, _, cz = getWorldTranslation(workArea.start)
        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(cx, cz)
        if farmland ~= nil then
            isContract = g_missionManager:getIsMissionRunningOnFarmland(farmland)
        end
    end

    if spec.useWindrow then
        local lastLiters = spec.workAreaParameters.lastLiters or 0
        if lastLiters <= 0 then
            return result
        end

        local moisture, quality = MSCutterExtension.getMoistureAtWorkArea(self, spec)
        if moisture == nil then
            return result
        end

        local outputFillType = spec.workAreaParameters.lastOutputFillType or spec.currentOutputFillType
        if outputFillType == nil then
            return result
        end

        if isContract then
            local ideal = getIdealMoisture(outputFillType)
            if ideal ~= nil then
                moisture = ideal
                quality = nil
            end
        end

        MSCutterExtension.updateCombineMoisture(combineVehicle, lastLiters, moisture, outputFillType, quality)
    else
        local lastArea = spec.workAreaParameters.lastArea or 0
        local lastLiters = spec.workAreaParameters.lastLiters or 0

        if lastArea <= 0 and lastLiters <= 0 then
            return result
        end

        local fruitType = spec.workAreaParameters.lastFruitType
        if fruitType == nil then
            return result
        end

        local liters = g_fruitTypeManager:getFruitTypeAreaLiters(
            fruitType,
            spec.workAreaParameters.lastMultiplierArea,
            false
        ) + lastLiters

        if liters <= 0 then
            return result
        end

        local moisture = MSCutterExtension.getMoistureAtWorkArea(self, spec)
        if moisture == nil then
            return result
        end

        local fillType = g_fruitTypeManager:getFruitTypeByIndex(fruitType).fillType.index
        if fillType == nil then
            return result
        end

        if isContract then
            local ideal = getIdealMoisture(fillType)
            if ideal ~= nil then
                moisture = ideal
            end
        end

        MSCutterExtension.updateCombineMoisture(combineVehicle, liters, moisture, fillType)
    end

    return result
end

function MSCutterExtension.getMoistureAtWorkArea(cutter, spec)
    local moistureSystem = g_currentMission.MoistureSystem

    local workArea = cutter:getWorkAreaByIndex(1)
    if workArea == nil then
        return nil, nil
    end

    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    local centerX = (sx + wx + hx) / 3
    local centerZ = (sz + wz + hz) / 3

    if spec.useWindrow then
        local tracker = g_currentMission.groundPropertyTracker
        if tracker == nil then
            return nil, nil
        end

        local fillType = spec.currentInputFillType
        if fillType == nil then
            return nil, nil
        end

        local properties = tracker:getPilePropertiesAtPosition(centerX, centerZ, fillType)
        if properties and properties.moisture then
            return properties.moisture, properties.quality
        end

        return moistureSystem:getMoistureAtPosition(centerX, centerZ), nil
    else
        return moistureSystem:getMoistureAtPosition(centerX, centerZ), nil
    end
end

function MSCutterExtension.updateCombineMoisture(combineVehicle, newLiters, newMoisture, fillType, newQuality)
    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then
        return
    end

    if not moistureSystem:shouldTrackFillType(fillType) then
        return
    end

    local uniqueId = combineVehicle.uniqueId
    if uniqueId == nil then
        return
    end

    local spec = combineVehicle.spec_combine
    if spec == nil then
        return
    end

    local totalFillLevel = combineVehicle:getFillUnitFillLevel(spec.fillUnitIndex)
    local currentLiters = totalFillLevel - newLiters
    local currentInfo = moistureSystem:getObjectInfo(uniqueId, fillType)
    newQuality = newQuality or moistureSystem:deriveQuality(fillType, newMoisture)

    if currentInfo == nil or currentLiters <= 0.001 then
        moistureSystem:setObjectInfo(uniqueId, fillType, { moisture = newMoisture, quality = newQuality })
    else
        local totalLiters = totalFillLevel
        local avgMoisture = (currentLiters * currentInfo.moisture + newLiters * newMoisture) / totalLiters
        local avgQuality = (currentLiters * (currentInfo.quality or 100) + newLiters * newQuality) / totalLiters
        moistureSystem:setObjectInfo(uniqueId, fillType, { moisture = avgMoisture, quality = avgQuality })
    end
end

function MSCutterExtension.getCombineMoisture(combineVehicle, fillType)
    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then
        return nil
    end

    local uniqueId = combineVehicle.uniqueId
    if uniqueId == nil then
        return nil
    end

    return moistureSystem:getObjectMoisture(uniqueId, fillType)
end

function MSCutterExtension.resetCombineMoisture(combineVehicle, fillType)
    local moistureSystem = g_currentMission.MoistureSystem
    if moistureSystem == nil then
        return
    end

    local uniqueId = combineVehicle.uniqueId
    if uniqueId == nil then
        return
    end

    if fillType == nil then
        moistureSystem.objectInfo[uniqueId] = nil
    else
        moistureSystem:setObjectInfo(uniqueId, fillType, nil)
    end
end

Cutter.processCutterArea = Utils.overwrittenFunction(
    Cutter.processCutterArea,
    MSCutterExtension.processCutterArea
)

Cutter.onEndWorkAreaProcessing = Utils.overwrittenFunction(
    Cutter.onEndWorkAreaProcessing,
    MSCutterExtension.onEndWorkAreaProcessing
)
