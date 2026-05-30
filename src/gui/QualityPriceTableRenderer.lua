QualityPriceTableRenderer = {}
QualityPriceTableRenderer_mt = Class(QualityPriceTableRenderer)

function QualityPriceTableRenderer.new()
    local self = {}
    setmetatable(self, QualityPriceTableRenderer_mt)
    self.data = {}
    return self
end

function QualityPriceTableRenderer:setData(data)
    self.data = data
end

function QualityPriceTableRenderer:getNumberOfSections()
    return 1
end

function QualityPriceTableRenderer:getNumberOfItemsInSection(list, section)
    return #self.data
end

function QualityPriceTableRenderer:getTitleForSectionHeader(list, section)
    return ""
end

function QualityPriceTableRenderer:populateCellForItemInSection(list, section, index, cell)
    local cropData = self.data[index]

    cell:getAttribute("cropName"):setText(cropData.name)
    cell:getAttribute("gradeA"):setText(cropData.gradeA)
    cell:getAttribute("gradeB"):setText(cropData.gradeB)
    cell:getAttribute("gradeC"):setText(cropData.gradeC)
    cell:getAttribute("gradeD"):setText(cropData.gradeD)
end

function QualityPriceTableRenderer:onListSelectionChanged(list, section, index)
end
