CropValueMap = {}

CropValueMap.Grades = {
    A = 1,
    B = 2,
    C = 3,
    D = 4
}

-- Per-crop dual-curve data. All moisture values on 0-1 scale.
-- Dry side: both yield and quality drop, yield is dominant.
-- Wet side: both yield and quality drop, quality is dominant.
local dataDefinitions = {
    ["WHEAT"] = {
        idealMin          = 0.11, idealMax          = 0.13,
        yieldCurveStart   = 0.10, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.45, qualityLossMaxDry = 0.15,
        qualityCurveStart = 0.14, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.40, yieldLossMaxWet   = 0.12,
        witherThreshold   = 0.03,
    },
    ["WINTERWHEAT"] = {
        idealMin          = 0.11, idealMax          = 0.13,
        yieldCurveStart   = 0.10, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.45, qualityLossMaxDry = 0.15,
        qualityCurveStart = 0.14, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.40, yieldLossMaxWet   = 0.12,
        witherThreshold   = 0.03,
    },
    -- Malting barley: high wet quality penalty (malting spec rejection risk)
    ["BARLEY"] = {
        idealMin          = 0.12, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.45, qualityLossMaxDry = 0.15,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.50, yieldLossMaxWet   = 0.10,
        witherThreshold   = 0.03,
    },
    ["WINTERBARLEY"] = {
        idealMin          = 0.12, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.45, qualityLossMaxDry = 0.15,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.50, yieldLossMaxWet   = 0.10,
        witherThreshold   = 0.03,
    },
    -- Canola: steep dry yield cliff at pod-fill; narrow ideal window
    ["CANOLA"] = {
        idealMin          = 0.08, idealMax          = 0.10,
        yieldCurveStart   = 0.07, yieldCurveFloor   = 0.03,
        yieldLossMaxDry   = 0.55, qualityLossMaxDry = 0.15,
        qualityCurveStart = 0.11, qualityCurveFloor = 0.18,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.10,
        witherThreshold   = 0.02,
    },
    -- Maize: harvested wet (18-22% field moisture is optimal); grade A reflects good combine condition, not storage spec
    ["MAIZE"] = {
        idealMin          = 0.18, idealMax          = 0.22,
        yieldCurveStart   = 0.16, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.55, qualityLossMaxDry = 0.12,
        qualityCurveStart = 0.23, qualityCurveFloor = 0.38,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.10,
        witherThreshold   = 0.03,
    },
    ["SILAGEMAIZE"] = {
        idealMin          = 0.18, idealMax          = 0.22,
        yieldCurveStart   = 0.16, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.55, qualityLossMaxDry = 0.12,
        qualityCurveStart = 0.23, qualityCurveFloor = 0.38,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.10,
        witherThreshold   = 0.03,
    },
    -- Soybean: relatively symmetric; high waterlogging sensitivity
    ["SOYBEAN"] = {
        idealMin          = 0.13, idealMax          = 0.16,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.50, qualityLossMaxDry = 0.18,
        qualityCurveStart = 0.17, qualityCurveFloor = 0.26,
        qualityLossMaxWet = 0.45, yieldLossMaxWet   = 0.15,
        witherThreshold   = 0.03,
    },
    -- Rice: water-dependent; high dry yield loss, low wet quality penalty
    ["RICE"] = {
        idealMin          = 0.12, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.04,
        yieldLossMaxDry   = 0.60, qualityLossMaxDry = 0.10,
        qualityCurveStart = 0.16, qualityCurveFloor = 0.24,
        qualityLossMaxWet = 0.20, yieldLossMaxWet   = 0.08,
        witherThreshold   = 0.02,
    },
    ["RICELONGGRAIN"] = {
        idealMin          = 0.12, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.04,
        yieldLossMaxDry   = 0.60, qualityLossMaxDry = 0.10,
        qualityCurveStart = 0.16, qualityCurveFloor = 0.24,
        qualityLossMaxWet = 0.20, yieldLossMaxWet   = 0.08,
        witherThreshold   = 0.02,
    },
    -- Sunflower: moderate dry, low wet quality sensitivity
    ["SUNFLOWER"] = {
        idealMin          = 0.11, idealMax          = 0.14,
        yieldCurveStart   = 0.09, yieldCurveFloor   = 0.04,
        yieldLossMaxDry   = 0.40, qualityLossMaxDry = 0.12,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.23,
        qualityLossMaxWet = 0.25, yieldLossMaxWet   = 0.08,
        witherThreshold   = 0.02,
    },
    -- Robust cereal archetype: Oat, Rye, Triticale, Spelt
    -- Moderate sensitivity both sides; dry ~65% as yield loss
    ["OAT"] = {
        idealMin          = 0.13, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.38, qualityLossMaxDry = 0.20,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.19,
        witherThreshold   = 0.03,
    },
    ["RYE"] = {
        idealMin          = 0.13, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.35, qualityLossMaxDry = 0.19,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.33, yieldLossMaxWet   = 0.18,
        witherThreshold   = 0.03,
    },
    ["TRITICALE"] = {
        idealMin          = 0.13, idealMax          = 0.14,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.36, qualityLossMaxDry = 0.19,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.34, yieldLossMaxWet   = 0.18,
        witherThreshold   = 0.03,
    },
    ["SPELT"] = {
        idealMin          = 0.12, idealMax          = 0.14,
        yieldCurveStart   = 0.10, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.37, qualityLossMaxDry = 0.20,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.19,
        witherThreshold   = 0.03,
    },
    -- Drought-tolerant grain archetype: Sorghum, Millet, Buckwheat
    -- Lower dry sensitivity; low witherThreshold (survives drier)
    -- Sorghum: most tolerant. Buckwheat: most sensitive of the three.
    ["SORGHUM"] = {
        idealMin          = 0.13, idealMax          = 0.14,
        yieldCurveStart   = 0.09, yieldCurveFloor   = 0.04,
        yieldLossMaxDry   = 0.28, qualityLossMaxDry = 0.19,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.32, yieldLossMaxWet   = 0.21,
        witherThreshold   = 0.02,
    },
    ["MILLET"] = {
        idealMin          = 0.13, idealMax          = 0.14,
        yieldCurveStart   = 0.09, yieldCurveFloor   = 0.04,
        yieldLossMaxDry   = 0.32, qualityLossMaxDry = 0.21,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.21,
        witherThreshold   = 0.02,
    },
    -- Buckwheat: most sensitive in drought-tolerant group (up to 70% loss severe drought)
    ["BUCKWHEAT"] = {
        idealMin          = 0.13, idealMax          = 0.14,
        yieldCurveStart   = 0.10, yieldCurveFloor   = 0.04,
        yieldLossMaxDry   = 0.45, qualityLossMaxDry = 0.30,
        qualityCurveStart = 0.15, qualityCurveFloor = 0.22,
        qualityLossMaxWet = 0.38, yieldLossMaxWet   = 0.25,
        witherThreshold   = 0.02,
    },
    -- Oilseed small archetype: Mustard, Poppy, Linseed
    -- Moderate both sides; dry ~70% as yield loss
    ["MUSTARD"] = {
        idealMin          = 0.08, idealMax          = 0.10,
        yieldCurveStart   = 0.07, yieldCurveFloor   = 0.03,
        yieldLossMaxDry   = 0.42, qualityLossMaxDry = 0.18,
        qualityCurveStart = 0.11, qualityCurveFloor = 0.18,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.15,
        witherThreshold   = 0.02,
    },
    ["POPPY"] = {
        idealMin          = 0.08, idealMax          = 0.10,
        yieldCurveStart   = 0.07, yieldCurveFloor   = 0.03,
        yieldLossMaxDry   = 0.42, qualityLossMaxDry = 0.18,
        qualityCurveStart = 0.11, qualityCurveFloor = 0.18,
        qualityLossMaxWet = 0.35, yieldLossMaxWet   = 0.15,
        witherThreshold   = 0.02,
    },
    ["LINSEED"] = {
        idealMin          = 0.09, idealMax          = 0.11,
        yieldCurveStart   = 0.08, yieldCurveFloor   = 0.03,
        yieldLossMaxDry   = 0.40, qualityLossMaxDry = 0.17,
        qualityCurveStart = 0.12, qualityCurveFloor = 0.19,
        qualityLossMaxWet = 0.33, yieldLossMaxWet   = 0.14,
        witherThreshold   = 0.02,
    },
    -- Legumes: PEA, GREENBEAN, BEANS
    ["PEA"] = {
        idealMin          = 0.13, idealMax          = 0.15,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.38, qualityLossMaxDry = 0.17,
        qualityCurveStart = 0.16, qualityCurveFloor = 0.24,
        qualityLossMaxWet = 0.38, yieldLossMaxWet   = 0.16,
        witherThreshold   = 0.03,
    },
    ["GREENBEAN"] = {
        idealMin          = 0.13, idealMax          = 0.15,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.38, qualityLossMaxDry = 0.17,
        qualityCurveStart = 0.16, qualityCurveFloor = 0.24,
        qualityLossMaxWet = 0.38, yieldLossMaxWet   = 0.16,
        witherThreshold   = 0.03,
    },
    ["BEANS"] = {
        idealMin          = 0.13, idealMax          = 0.15,
        yieldCurveStart   = 0.11, yieldCurveFloor   = 0.05,
        yieldLossMaxDry   = 0.38, qualityLossMaxDry = 0.17,
        qualityCurveStart = 0.16, qualityCurveFloor = 0.24,
        qualityLossMaxWet = 0.38, yieldLossMaxWet   = 0.16,
        witherThreshold   = 0.03,
    },
}

function CropValueMap.initialize()
    CropValueMap.Data = {}

    for fillTypeName, def in pairs(dataDefinitions) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex ~= nil then
            CropValueMap.Data[fillTypeIndex] = def
        end
    end
end

-- Smooth linear interpolation between the ideal zone and the curve floor.
-- Returns a fraction [0, lossMax] of penalty.
local function curveFraction(moisture, curveStart, curveFloor, lossMax)
    if curveFloor >= curveStart then return 0 end
    local t = (curveStart - moisture) / (curveStart - curveFloor)
    t = math.max(0, math.min(1, t))
    return t * lossMax
end

-- Returns yield multiplier in [0, 1].
-- 1.0 only across the ideal band [idealMin, idealMax] (the source of truth).
-- Below idealMin: falls toward (1 - yieldLossMaxDry) (dominant dry loss).
-- Above idealMax: falls toward (1 - yieldLossMaxWet) (minor wet loss).
function CropValueMap.getYieldMultiplier(fillType, moisture)
    local def = CropValueMap.Data and CropValueMap.Data[fillType]
    if not def then return 1.0 end

    if moisture < def.idealMin then
        local loss = curveFraction(moisture, def.idealMin, def.yieldCurveFloor, def.yieldLossMaxDry)
        return 1.0 - loss
    elseif moisture > def.idealMax then
        local loss = curveFraction(-moisture, -def.idealMax, -def.qualityCurveFloor, def.yieldLossMaxWet)
        return 1.0 - loss
    end

    return 1.0
end

-- Returns quality value in [0, 100].
-- 100 only across the ideal band [idealMin, idealMax] (the source of truth).
-- Below idealMin: falls toward 100*(1 - qualityLossMaxDry) (minor dry loss).
-- Above idealMax: falls toward 100*(1 - qualityLossMaxWet) (dominant wet loss).
function CropValueMap.getQualityValue(fillType, moisture)
    local def = CropValueMap.Data and CropValueMap.Data[fillType]
    if not def then return 100 end

    if moisture < def.idealMin then
        local loss = curveFraction(moisture, def.idealMin, def.yieldCurveFloor, def.qualityLossMaxDry)
        return 100 * (1.0 - loss)
    elseif moisture > def.idealMax then
        local loss = curveFraction(-moisture, -def.idealMax, -def.qualityCurveFloor, def.qualityLossMaxWet)
        return 100 * (1.0 - loss)
    end

    return 100
end

-- Returns the ideal moisture window [idealMin, idealMax] for a fillType, or nil.
function CropValueMap.getIdealRange(fillType)
    local def = CropValueMap.Data and CropValueMap.Data[fillType]
    if not def then return nil end
    return def.idealMin, def.idealMax
end

-- Returns the wither threshold for a fillType, or nil if not tracked.
function CropValueMap.getWitherThreshold(fillType)
    local def = CropValueMap.Data and CropValueMap.Data[fillType]
    if not def then return nil end
    return def.witherThreshold
end

-- Returns the full curve definition for a fillType, or nil.
function CropValueMap.getCropDef(fillType)
    return CropValueMap.Data and CropValueMap.Data[fillType]
end

function CropValueMap.initializeQualityBands()
    CropValueMap.QualityBands = {}

    -- Grade thresholds derived from the wet-side quality curve shape.
    -- A: full quality (no wet penalty active), B: up to 20% loss, C: up to 40%, D: below that.
    local GRADE_A_MIN = 90
    local GRADE_B_MIN = 70
    local GRADE_C_MIN = 50

    for fillTypeIndex, def in pairs(CropValueMap.Data) do
        -- Price multipliers derived from the old band values, preserved for selling station compatibility.
        -- The wet-side dominant loss determines the D floor price.
        local dMultiplier = 1.0 - def.qualityLossMaxWet
        local cMultiplier = 1.0 - def.qualityLossMaxWet * 0.5
        local bMultiplier = 1.0 - def.qualityLossMaxWet * 0.2

        CropValueMap.QualityBands[fillTypeIndex] = {
            { minQuality = GRADE_A_MIN, grade = CropValueMap.Grades.A, priceMultiplier = 1.0 },
            { minQuality = GRADE_B_MIN, grade = CropValueMap.Grades.B, priceMultiplier = bMultiplier },
            { minQuality = GRADE_C_MIN, grade = CropValueMap.Grades.C, priceMultiplier = cMultiplier },
            { minQuality = 0,           grade = CropValueMap.Grades.D, priceMultiplier = dMultiplier },
        }
    end
end

function CropValueMap.getQualityGrade(fillType, quality)
    local bands = CropValueMap.QualityBands and CropValueMap.QualityBands[fillType]
    if not bands then return nil, nil end

    for _, band in ipairs(bands) do
        if quality >= band.minQuality then
            return band.grade, band.priceMultiplier
        end
    end
    return CropValueMap.Grades.D, bands[4].priceMultiplier
end
