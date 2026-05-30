MoistureGuiPrices = {}

local MoistureGuiPrices_mt = Class(MoistureGuiPrices, TabbedMenuFrameElement)

function MoistureGuiPrices.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiPrices_mt)
    self.l18n = l18n
    self.priceRenderer = QualityPriceTableRenderer.new()
    return self
end

function MoistureGuiPrices:initialize()
end

function MoistureGuiPrices:onGuiSetupFinished()
    MoistureGuiPrices:superClass().onGuiSetupFinished(self)

    self.qualityPriceTable:setDataSource(self.priceRenderer)
    self.qualityPriceTable:setDelegate(self.priceRenderer)
end

function MoistureGuiPrices:onFrameOpen()
    MoistureGuiPrices:superClass().onFrameOpen(self)
    self:updateTable()
end

function MoistureGuiPrices:onFrameClose()
    MoistureGuiPrices:superClass().onFrameClose(self)
end

function MoistureGuiPrices:updateTable()
    local tableData = {}

    if CropValueMap.QualityBands == nil then return end

    for fillTypeIndex, bands in pairs(CropValueMap.QualityBands) do
        local fillTypeTitle = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex).title

        local gradeA = string.format("%d+ (%d%%)", bands[1].minQuality, math.floor(bands[1].priceMultiplier * 100))
        local gradeB = string.format("%d-%d (%d%%)", bands[2].minQuality, bands[1].minQuality - 1, math.floor(bands[2].priceMultiplier * 100))
        local gradeC = string.format("%d-%d (%d%%)", bands[3].minQuality, bands[2].minQuality - 1, math.floor(bands[3].priceMultiplier * 100))
        local gradeD = string.format("0-%d (%d%%)", bands[3].minQuality - 1, math.floor(bands[4].priceMultiplier * 100))

        table.insert(tableData, {
            name = fillTypeTitle,
            gradeA = gradeA,
            gradeB = gradeB,
            gradeC = gradeC,
            gradeD = gradeD
        })
    end

    table.sort(tableData, function(a, b) return a.name < b.name end)

    self.priceRenderer:setData(tableData)
    self.qualityPriceTable:reloadData()
end
