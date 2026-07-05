MoistureGuiGrades = {}

local MoistureGuiGrades_mt = Class(MoistureGuiGrades, TabbedMenuFrameElement)

-- Bar constants
local NUM_SEGMENTS    = 50    -- number of bars drawn per curve
local BAR_HEIGHT_PX   = 100   -- max bar height in pixels (= 100% value)
local SEG_WIDTH_PX    = 20    -- width of each bar segment in pixels
local NUM_AXIS_LABELS = 6     -- moisture axis tick labels (set dynamically)

-- Bars grow upward from a floor at -128px, RELATIVE TO THEIR CHART CONTAINER
-- (chartYield / chartQuality in the XML). Both charts share the same relative
-- geometry; the container position is what places them on screen, so moving a
-- whole chart is a single XML container-position edit. Bar area: top -28, floor -128.
local BAR_FLOOR_PX = -128

-- Convert a pixel value to a normalised Y coordinate the SAME way FS25 converts
-- XML `px` values (GuiUtils.getNormalizedValue): px / referenceScreenHeight *
-- aspectScaleY. Using g_pixelSizeY (1/screenHeight) instead would make Lua-sized
-- bars mismatch the XML-authored axis gaps at non-reference resolutions.
local function pxToNormY(px)
    return px / g_referenceScreenHeight * g_aspectScaleY
end

-- Value → whole percent for stat labels
local function pct(v) return math.floor(v * 100 + 0.5) end

-- Zone colours (r, g, b, a)
local COL_WITHER  = { 0.75, 0.20, 0.08, 1.0 }  -- red-orange: extreme dry / wither risk
local COL_DRY     = { 0.85, 0.55, 0.10, 1.0 }  -- amber: dry-loss zone
local COL_IDEAL   = { 0.25, 0.75, 0.25, 1.0 }  -- green: ideal zone
local COL_WET     = { 0.20, 0.45, 0.85, 1.0 }  -- blue: wet-loss zone

local COL_WITHER_SW  = { 0.90, 0.25, 0.08, 1.0 }
local COL_DRY_SW     = { 0.85, 0.55, 0.10, 1.0 }
local COL_IDEAL_SW   = { 0.25, 0.75, 0.25, 1.0 }
local COL_WET_SW     = { 0.20, 0.45, 0.85, 1.0 }

function MoistureGuiGrades.new(l18n)
    local self = TabbedMenuFrameElement.new(nil, MoistureGuiGrades_mt)
    self.l18n  = l18n
    self.cropListData = nil   -- populated in buildCropList
    self.selectedIndex = nil
    return self
end

function MoistureGuiGrades:initialize()
end

function MoistureGuiGrades:onGuiSetupFinished()
    MoistureGuiGrades:superClass().onGuiSetupFinished(self)

    self.cropList:setDataSource(self)
    self.cropList:setDelegate(self)
end

function MoistureGuiGrades:onFrameOpen()
    MoistureGuiGrades:superClass().onFrameOpen(self)
    self:buildCropList()
    self:initLegendColours()
    self.cropList:reloadData()
    -- Restore selection or default to first crop
    if self.selectedIndex and self.cropListData and self.selectedIndex <= #self.cropListData then
        self.cropList:setSelectedItem(1, self.selectedIndex)
        self:showCropDetail(self.selectedIndex)
    elseif self.cropListData and #self.cropListData > 0 then
        self.selectedIndex = 1
        self.cropList:setSelectedItem(1, 1)
        self:showCropDetail(1)
    else
        self:hideDetail()
    end
end

function MoistureGuiGrades:onFrameClose()
    MoistureGuiGrades:superClass().onFrameClose(self)
end

function MoistureGuiGrades:buildCropList()
    local data = {}
    for fillTypeIndex, _ in pairs(CropValueMap.Data) do
        local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if ft then
            table.insert(data, { fillTypeIndex = fillTypeIndex, name = ft.title })
        end
    end
    table.sort(data, function(a, b) return a.name < b.name end)
    self.cropListData = data
end

-- ── SmoothList data source ───────────────────────────────────────────────────

function MoistureGuiGrades:getNumberOfSections()
    return 1
end

function MoistureGuiGrades:getNumberOfItemsInSection(list, section)
    return self.cropListData and #self.cropListData or 0
end

function MoistureGuiGrades:getTitleForSectionHeader(list, section)
    return ""
end

function MoistureGuiGrades:populateCellForItemInSection(list, section, index, cell)
    local entry = self.cropListData and self.cropListData[index]
    if entry then
        cell:getAttribute("cropName"):setText(entry.name)
    end
end

function MoistureGuiGrades:onListSelectionChanged(list, section, index)
    self.selectedIndex = index
    self:showCropDetail(index)
end

-- ── Detail panel ─────────────────────────────────────────────────────────────

function MoistureGuiGrades:hideDetail()
    self.noSelectionHint:setVisible(true)
    self.detailCropName:setVisible(false)
    for i = 1, NUM_SEGMENTS do
        local yb = self["yb" .. i]
        local qb = self["qb" .. i]
        if yb then yb:setVisible(false) end
        if qb then qb:setVisible(false) end
    end
    for i = 1, NUM_AXIS_LABELS do
        local lbl = self["axisLabel" .. i]
        if lbl then lbl:setText("") end
    end
    for _, id in ipairs({ "ybYTop", "ybYMid", "ybYBot", "qbYTop", "qbYMid", "qbYBot" }) do
        if self[id] then self[id]:setText("") end
    end
    self.statIdealRange:setText("")
    self.statYieldCurve:setText("")
    self.statQualityCurve:setText("")
    self.statWitherThresh:setText("")
end

function MoistureGuiGrades:showCropDetail(index)
    local entry = self.cropListData and self.cropListData[index]
    if not entry then
        self:hideDetail()
        return
    end

    local fillTypeIndex = entry.fillTypeIndex
    local def = CropValueMap.getCropDef(fillTypeIndex)
    if not def then
        self:hideDetail()
        return
    end

    self.noSelectionHint:setVisible(false)
    self.detailCropName:setVisible(true)
    self.detailCropName:setText(entry.name)

    -- Zoom the moisture axis to this crop's useful range and label the ticks
    local minM, maxM = self:getMoistureRange(def)
    self:setAxisLabels(minM, maxM)

    -- Populate both bars across the zoomed range
    self:populateBar("yb", fillTypeIndex, def, true,  minM, maxM)
    self:populateBar("qb", fillTypeIndex, def, false, minM, maxM)

    -- Stat labels: self-contained, yield/quality framed.
    -- idealMin/idealMax is the source of truth for the ideal band.
    self.statIdealRange:setText(string.format(
        g_i18n:getText("moistureSystem_gui_statIdealRange"),
        pct(def.idealMin), pct(def.idealMax)
    ))
    -- Dry side: yield takes the big hit, quality the small one
    self.statYieldCurve:setText(string.format(
        g_i18n:getText("moistureSystem_gui_statYieldCurve"),
        pct(1 - def.yieldLossMaxDry), pct(1 - def.qualityLossMaxDry)
    ))
    -- Wet side: quality takes the big hit, yield the small one
    self.statQualityCurve:setText(string.format(
        g_i18n:getText("moistureSystem_gui_statQualityCurve"),
        pct(1 - def.qualityLossMaxWet), pct(1 - def.yieldLossMaxWet)
    ))
    if def.witherThreshold then
        self.statWitherThresh:setText(string.format(
            g_i18n:getText("moistureSystem_gui_statWither"),
            pct(def.witherThreshold)
        ))
    else
        self.statWitherThresh:setText("")
    end
end

-- Moisture X-axis range for a crop: 0 up to the point where both curves have
-- fully flattened (the wet-side quality floor). Beyond that the data is flat, so
-- there's no value in rendering it — this keeps the chart zoomed to the useful window.
function MoistureGuiGrades:getMoistureRange(def)
    local maxM = def.qualityCurveFloor or 0.30
    -- Round up to the next whole percent so the axis ends on a clean tick.
    maxM = math.ceil(maxM * 100) / 100
    return 0.0, maxM
end

-- isYield = true for yield bar, false for quality bar.
-- The bar's Y-axis auto-zooms to the data's own range so small variations
-- (e.g. a 15% quality drop) are clearly visible, rather than squashed against
-- a fixed 0-100% scale. Returns floorValue used, so the caller can label the axis.
function MoistureGuiGrades:populateBar(prefix, fillTypeIndex, def, isYield, minM, maxM)
    local barBottomY = pxToNormY(BAR_FLOOR_PX)

    -- Pass 1: sample every segment's value, track the minimum
    local values = {}
    local minValue = 1.0
    for i = 1, NUM_SEGMENTS do
        local frac = (i - 0.5) / NUM_SEGMENTS
        local m = minM + frac * (maxM - minM)
        local value
        if isYield then
            value = CropValueMap.getYieldMultiplier(fillTypeIndex, m)
        else
            value = CropValueMap.getQualityValue(fillTypeIndex, m) / 100.0
        end
        values[i] = { v = value, m = m }
        if value < minValue then minValue = value end
    end

    -- Y-axis floor: round the minimum down to the nearest 5%, then drop a further
    -- 5% buffer so the shortest bars (e.g. wither zone) still read as visible bars
    -- rather than flat slivers sitting on the baseline.
    local floorValue = math.floor(minValue * 20) / 20 - 0.05
    floorValue = math.max(0.0, math.min(floorValue, 0.85))
    local span = 1.0 - floorValue

    -- Pass 2: place bars scaled into [floorValue, 1.0]
    for i = 1, NUM_SEGMENTS do
        local seg = self[prefix .. i]
        if not seg then break end

        local norm = (values[i].v - floorValue) / span   -- 0 at floor, 1 at 100%
        local h = math.max(pxToNormY(2), norm * pxToNormY(BAR_HEIGHT_PX))
        -- Segment is top-anchored; shift down so its bottom edge stays at the floor
        -- (Y is negative/down, so + moves the top up).
        seg:setSize(nil, h)
        seg:setPosition(nil, barBottomY + h)
        seg:setVisible(true)

        local col = self:getZoneColour(values[i].m, def)
        seg:setImageColor(nil, col[1], col[2], col[3], col[4])
    end

    -- Y-axis labels: floor at bottom, 100% at top, midpoint between
    local top = self[prefix .. "YTop"]
    local mid = self[prefix .. "YMid"]
    local bot = self[prefix .. "YBot"]
    if top then top:setText("100%") end
    if mid then mid:setText(string.format("%d%%", pct((floorValue + 1.0) / 2))) end
    if bot then bot:setText(string.format("%d%%", pct(floorValue))) end
end

-- Set the moisture axis tick labels for the active [minM, maxM] range.
function MoistureGuiGrades:setAxisLabels(minM, maxM)
    for i = 1, NUM_AXIS_LABELS do
        local lbl = self["axisLabel" .. i]
        if lbl then
            local frac = (i - 1) / (NUM_AXIS_LABELS - 1)
            local m = minM + frac * (maxM - minM)
            lbl:setText(string.format("%d%%", pct(m)))
        end
    end
end

-- Colour zones are keyed off idealMin/idealMax (the source of truth for the
-- ideal band) so the green zone on the chart exactly matches the stated range.
function MoistureGuiGrades:getZoneColour(m, def)
    if def.witherThreshold and m < def.witherThreshold then
        return COL_WITHER
    elseif m < def.idealMin then
        return COL_DRY
    elseif m <= def.idealMax then
        return COL_IDEAL
    else
        return COL_WET
    end
end

-- Set legend swatch colours on open (done once; colours are constants)
function MoistureGuiGrades:initLegendColours()
    local function setSwatch(id, col)
        local el = self[id]
        if el then el:setImageColor(nil, col[1], col[2], col[3], col[4]) end
    end
    setSwatch("lgWither", COL_WITHER_SW)
    setSwatch("lgDry",    COL_DRY_SW)
    setSwatch("lgIdeal",  COL_IDEAL_SW)
    setSwatch("lgWet",    COL_WET_SW)
end
