SellingStationExtension = {}
SellingStationExtension.dryingChargeAccumulator = 0
SellingStationExtension.dryingChargeCountdown = 0
SellingStationExtension.dryingChargeFarmId = nil

function SellingStationExtension:addFillLevelFromTool(superFunc, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    if g_currentMission:getIsServer() and deltaFillLevel > 0 then
        local priceScale, dryingCharge = self:getQualityMultiplierForSale(fillTypeIndex, fillInfo, deltaFillLevel)

        if priceScale ~= nil and priceScale ~= 1.0 then
            if extraAttributes == nil then
                extraAttributes = {}
            end
            extraAttributes.priceScale = priceScale
        end

        if dryingCharge and dryingCharge > 0 then
            SellingStationExtension.dryingChargeAccumulator = SellingStationExtension.dryingChargeAccumulator + dryingCharge
            SellingStationExtension.dryingChargeCountdown = 30
            SellingStationExtension.dryingChargeFarmId = farmId
            g_farmManager:getFarmById(farmId):changeBalance(-dryingCharge, MoneyType.DRYING_CHARGE)
        end
    end

    return superFunc(self, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
end

function SellingStationExtension.update()
    if SellingStationExtension.dryingChargeCountdown > 0 then
        SellingStationExtension.dryingChargeCountdown = SellingStationExtension.dryingChargeCountdown - 1
        if SellingStationExtension.dryingChargeCountdown == 0 then
            local total = SellingStationExtension.dryingChargeAccumulator
            local farmId = SellingStationExtension.dryingChargeFarmId
            if total > 0 and farmId then
                g_currentMission:addMoneyChange(-total, farmId, MoneyType.DRYING_CHARGE, true)
            end
            SellingStationExtension.dryingChargeAccumulator = 0
            SellingStationExtension.dryingChargeFarmId = nil
        end
    end
end

function SellingStationExtension:getQualityMultiplierForSale(fillTypeIndex, fillInfo, deltaFillLevel)
    if CropValueMap == nil or CropValueMap.Data == nil then
        return nil, 0
    end

    local ms = g_currentMission.MoistureSystem
    local info = nil

    if fillInfo ~= nil and fillInfo.sourceUniqueId ~= nil then
        info = ms:getObjectInfo(fillInfo.sourceUniqueId, fillTypeIndex)
    end

    if info == nil then
        return 1, 0
    end

    local _, priceMultiplier = CropValueMap.getQualityGrade(fillTypeIndex, info.quality or 100)
    local priceScale = priceMultiplier or 1.0

    local dryingCharge = 0
    local _, idealMax = CropValueMap.getIdealRange(fillTypeIndex)
    if idealMax and info.moisture > idealMax then
        local overshoot = info.moisture - idealMax
        local chargeRate = ms.settings.sellDryingChargeRate or 1.0
        dryingCharge = chargeRate * overshoot * deltaFillLevel
    end

    return priceScale, dryingCharge
end

SellingStation.getQualityMultiplierForSale = SellingStationExtension.getQualityMultiplierForSale

SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(
    SellingStation.addFillLevelFromTool,
    SellingStationExtension.addFillLevelFromTool
)
