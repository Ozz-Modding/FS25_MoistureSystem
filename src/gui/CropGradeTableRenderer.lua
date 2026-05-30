CropGradeTableRenderer = {}
CropGradeTableRenderer_mt = Class(CropGradeTableRenderer)

function CropGradeTableRenderer.new()
    local self = {}
    setmetatable(self, CropGradeTableRenderer_mt)
    self.data = {}
    return self
end

function CropGradeTableRenderer:setData(data)
    self.data = data
end

function CropGradeTableRenderer:getNumberOfSections()
    return 1
end

function CropGradeTableRenderer:getNumberOfItemsInSection(list, section)
    return #self.data
end

function CropGradeTableRenderer:getTitleForSectionHeader(list, section)
    return ""
end

function CropGradeTableRenderer:populateCellForItemInSection(list, section, index, cell)
    local cropData = self.data[index]

    cell:getAttribute("cropName"):setText(cropData.name)
    cell:getAttribute("gradeA1"):setText(cropData.gradeA1)
    cell:getAttribute("gradeA2"):setText(cropData.gradeA2)
    cell:getAttribute("gradeB1"):setText(cropData.gradeB1)
    cell:getAttribute("gradeB2"):setText(cropData.gradeB2)
    cell:getAttribute("gradeC1"):setText(cropData.gradeC1)
    cell:getAttribute("gradeC2"):setText(cropData.gradeC2)
    cell:getAttribute("gradeD1"):setText(cropData.gradeD1)
    cell:getAttribute("gradeD2"):setText(cropData.gradeD2)
end

function CropGradeTableRenderer:onListSelectionChanged(list, section, index)
end
