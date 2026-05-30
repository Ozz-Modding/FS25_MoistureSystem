MoistureGuiGrades = {}

local MoistureGuiGrades_mt = Class(MoistureGuiGrades, TabbedMenuFrameElement)

function MoistureGuiGrades.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiGrades_mt)
    self.l18n = l18n
    self.cropGradeRenderer = CropGradeTableRenderer.new()
    return self
end

function MoistureGuiGrades:initialize()
end

function MoistureGuiGrades:onGuiSetupFinished()
    MoistureGuiGrades:superClass().onGuiSetupFinished(self)

    self.cropGradeTable:setDataSource(self.cropGradeRenderer)
    self.cropGradeTable:setDelegate(self.cropGradeRenderer)
end

function MoistureGuiGrades:onFrameOpen()
    MoistureGuiGrades:superClass().onFrameOpen(self)
    self:updateTable()
end

function MoistureGuiGrades:onFrameClose()
    MoistureGuiGrades:superClass().onFrameClose(self)
end

function MoistureGuiGrades:updateTable()
    local tableData = {}

    for fillTypeIndex, ranges in pairs(CropValueMap.Data) do
        local fillTypeTitle = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex).title

        local gradeData = {
            [CropValueMap.Grades.A] = {},
            [CropValueMap.Grades.B] = {},
            [CropValueMap.Grades.C] = {},
            [CropValueMap.Grades.D] = {}
        }

        for _, range in ipairs(ranges) do
            local lowerPercent = math.floor(range.lower * 100)
            local upperPercent = math.floor(range.upper * 100)
            local qualityValue
            if range.grade == CropValueMap.Grades.A then
                qualityValue = 100
            else
                qualityValue = math.floor(range.multiplier * 100) - 1
            end

            local rangeText
            if #gradeData[range.grade] == 0 then
                rangeText = string.format("%d-%d%% \u{2192} Q%d", lowerPercent, upperPercent, qualityValue)
            else
                rangeText = string.format("%d-%d%%", lowerPercent, upperPercent)
            end

            table.insert(gradeData[range.grade], rangeText)
        end

        table.insert(tableData, {
            name = fillTypeTitle,
            gradeA1 = gradeData[CropValueMap.Grades.A][1] or "-",
            gradeA2 = gradeData[CropValueMap.Grades.A][2] or "",
            gradeB1 = gradeData[CropValueMap.Grades.B][1] or "-",
            gradeB2 = gradeData[CropValueMap.Grades.B][2] or "",
            gradeC1 = gradeData[CropValueMap.Grades.C][1] or "-",
            gradeC2 = gradeData[CropValueMap.Grades.C][2] or "",
            gradeD1 = gradeData[CropValueMap.Grades.D][1] or "-",
            gradeD2 = gradeData[CropValueMap.Grades.D][2] or ""
        })
    end

    table.sort(tableData, function(a, b) return a.name < b.name end)

    self.cropGradeRenderer:setData(tableData)
    self.cropGradeTable:reloadData()
end
