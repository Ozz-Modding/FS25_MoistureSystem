---
-- IrrigationSystem
--
-- The player books a contractor to raise a farmland's moisture by a chosen
-- amount. The boost accrues hour by hour while the contractor works, then
-- decays with the weather. Contractor time is scarce and shared; money is not
-- the binding constraint.
--
-- Registered as g_currentMission.irrigationSystem and ticked once per game hour
-- from MoistureSystem:onHourChanged. All simulation is server-side.
--
-- See docs/irrigation-spec.md for the design and the reasoning behind every
-- number in the tunables block.
---

IrrigationSystem = {}
local IrrigationSystem_mt = Class(IrrigationSystem)

-- ============================================================================
-- Tunables. Every balance number lives here; no magic numbers below this block.
-- Moisture/boost values are authored in PERCENTAGE POINTS (the units the player
-- sees), converted to the internal 0-1 scale at the point of use.
-- ============================================================================

-- Boost limits ---------------------------------------------------------------
IrrigationSystem.MAX_BOOST_PP      = 5.0    -- cap on accumulated boost
IrrigationSystem.BOOST_STEP_PP     = 0.5    -- selector increment

-- Pricing --------------------------------------------------------------------
IrrigationSystem.RATE_PER_HA_PP    = 40     -- currency per hectare per percentage point
IrrigationSystem.MINIMUM_CALLOUT   = 250    -- currency floor, before multipliers
IrrigationSystem.SHORT_NOTICE_MAX  = 1.35   -- multiplier when booked same-day
IrrigationSystem.SHORT_NOTICE_DAYS = 3      -- lead time at which it reaches 1.0

-- Job duration ---------------------------------------------------------------
IrrigationSystem.MIN_JOB_HOURS     = 2      -- floor; consumes 2 diary hours as well as charging

-- Contractor diary -----------------------------------------------------------
IrrigationSystem.DAILY_CAPACITY_H  = 10     -- working hours per day
IrrigationSystem.DAY_START_HOUR    = 6      -- on-site window opens
IrrigationSystem.DAY_END_HOUR      = 18     -- on-site window closes
IrrigationSystem.DIARY_FLOOR       = 0.12   -- committed fraction, far out
IrrigationSystem.DIARY_SPAN        = 0.73   -- extra committed today (FLOOR+SPAN = today)
IrrigationSystem.DIARY_TAU_DAYS    = 1.75   -- how fast commitment falls off with lead time
IrrigationSystem.DIARY_JITTER      = 0.30   -- per-day intrinsic spread, +/- fraction
IrrigationSystem.BOOKABLE_MONTHS   = 2      -- months bookable beyond the current one

-- Decay ----------------------------------------------------------------------
IrrigationSystem.DECAY_PP_PER_DAY  = 2.5    -- drain at DECAY_TEMP_REF, dry weather
IrrigationSystem.DECAY_TEMP_REF    = 15     -- degC at which the temp multiplier is 1.0
IrrigationSystem.DECAY_TEMP_MIN    = 0.5    -- multiplier floor (also covers sub-zero)
IrrigationSystem.DECAY_TEMP_MAX    = 2.5    -- multiplier ceiling
IrrigationSystem.GRACE_HOURS       = 6      -- full-strength hold after job completion
IrrigationSystem.DECAY_DPP_CAP     = 5      -- daysPerPeriod divisor cap

-- A boost that drains below this is deleted, so the table empties itself and
-- anyActiveBoosts clears on its own.
IrrigationSystem.PRUNE_THRESHOLD   = 0.001

-- Rejection reason codes, sent back to the requesting client (spec section 12).
IrrigationSystem.REJECT_SLOT_TAKEN         = 1
IrrigationSystem.REJECT_INSUFFICIENT_FUNDS = 2
IrrigationSystem.REJECT_NO_PERMISSION      = 3
IrrigationSystem.REJECT_PRICE_CHANGED      = 4
IrrigationSystem.REJECT_INVALID            = 5

function IrrigationSystem.new()
    local self = setmetatable({}, IrrigationSystem_mt)

    -- [farmlandId] = { value = 0.021, graceUntil = <monotonic hour stamp or nil> }
    self.boosts = {}
    -- [farmlandId] = { targetBoost, startDay, startHour, hours,
    --                  hoursWorked, price, paid, contractorIndex }
    self.jobs = {}
    -- Hours the player has booked, keyed "day:contractorIndex". Subtracted from
    -- the generated diary so the player's own bookings tighten it too.
    self.bookedHours = {}
    self.anyActiveBoosts = false

    self:ensureDiarySeed()

    return self
end

function IrrigationSystem:delete()
    g_messageCenter:unsubscribeAll(self)
    self:removeConsoleCommands()
end

-- ── settings accessors ───────────────────────────────────────────────────────

function IrrigationSystem:getSettings()
    local ms = g_currentMission ~= nil and g_currentMission.MoistureSystem or nil
    return ms ~= nil and ms.settings or nil
end

function IrrigationSystem:getContractorCount()
    local settings = self:getSettings()
    return settings ~= nil and settings.irrigationContractors or 1
end

function IrrigationSystem:getContractorCapacity()
    local settings = self:getSettings()
    return settings ~= nil and settings.irrigationContractorCapacity or 8
end

function IrrigationSystem:getCostMultiplier()
    local settings = self:getSettings()
    return settings ~= nil and settings.irrigationCostMultiplier or 1.0
end

-- Work rate follows the player's capacity setting rather than being authored:
-- a full day at full strength must deliver exactly the capacity in ha*pp.
function IrrigationSystem:getHaPpPerHour()
    return (self:getContractorCapacity() * IrrigationSystem.MAX_BOOST_PP) / IrrigationSystem.DAILY_CAPACITY_H
end

-- ── boosts ───────────────────────────────────────────────────────────────────

function IrrigationSystem:getBoost(farmlandId)
    local boost = self.boosts[farmlandId]
    return boost ~= nil and boost.value or 0
end

---
-- Set a farmland's boost outright. Values at or below the prune threshold
-- delete the record, which is what keeps anyActiveBoosts self-clearing.
-- @param farmlandId farmland id
-- @param value boost on the internal 0-1 scale
-- @param graceUntil monotonic hour stamp until which decay is held, or nil
---
function IrrigationSystem:setBoost(farmlandId, value, graceUntil)
    if value == nil or value <= IrrigationSystem.PRUNE_THRESHOLD then
        self.boosts[farmlandId] = nil
    else
        local boost = self.boosts[farmlandId]
        if boost == nil then
            boost = {}
            self.boosts[farmlandId] = boost
        end
        boost.value = math.min(1.0, value)
        boost.graceUntil = graceUntil
    end
    self:refreshActiveBoostFlag()
end

function IrrigationSystem:refreshActiveBoostFlag()
    self.anyActiveBoosts = next(self.boosts) ~= nil
end

-- ── diary seed ───────────────────────────────────────────────────────────────

---
-- The diary is generated from this seed, never stored, so the seed must be
-- created once and then survive every save. savegameIndex was rejected because
-- "Save As" moves it and would silently reshuffle the whole diary.
---
function IrrigationSystem:ensureDiarySeed()
    if self.diarySeed == nil then
        self.diarySeed = math.random(1, 1000000)
    end
    return self.diarySeed
end

-- ── savegame ─────────────────────────────────────────────────────────────────

function IrrigationSystem:saveToXMLFile(xmlFile, key)
    local base = key .. ".irrigation"
    setXMLInt(xmlFile, base .. "#diarySeed", self.diarySeed)

    local i = 0
    for farmlandId, boost in pairs(self.boosts) do
        local boostKey = string.format("%s.boost(%d)", base, i)
        setXMLInt(xmlFile, boostKey .. "#farmlandId", farmlandId)
        setXMLFloat(xmlFile, boostKey .. "#value", boost.value)
        if boost.graceUntil ~= nil then
            setXMLFloat(xmlFile, boostKey .. "#graceUntil", boost.graceUntil)
        end
        i = i + 1
    end

    local j = 0
    for farmlandId, job in pairs(self.jobs) do
        local jobKey = string.format("%s.job(%d)", base, j)
        setXMLInt(xmlFile, jobKey .. "#farmlandId", farmlandId)
        setXMLFloat(xmlFile, jobKey .. "#targetBoost", job.targetBoost)
        setXMLInt(xmlFile, jobKey .. "#startDay", job.startDay)
        setXMLInt(xmlFile, jobKey .. "#startHour", job.startHour)
        setXMLInt(xmlFile, jobKey .. "#hours", job.hours)
        setXMLInt(xmlFile, jobKey .. "#hoursWorked", job.hoursWorked)
        setXMLFloat(xmlFile, jobKey .. "#price", job.price)
        setXMLBool(xmlFile, jobKey .. "#paid", job.paid)
        setXMLInt(xmlFile, jobKey .. "#contractorIndex", job.contractorIndex)
        setXMLInt(xmlFile, jobKey .. "#farmId", job.farmId)
        j = j + 1
    end
end

---
-- Every read is nil-guarded and the whole section is optional, so a savegame
-- written before irrigation existed loads with both tables empty. That is the
-- correct pre-feature state: no migration, no version stamp.
---
function IrrigationSystem:loadFromXMLFile(xmlFile, key)
    local base = key .. ".irrigation"

    local seed = getXMLInt(xmlFile, base .. "#diarySeed")
    if seed ~= nil then
        self.diarySeed = seed
    end

    local i = 0
    while true do
        local boostKey = string.format("%s.boost(%d)", base, i)
        if not hasXMLProperty(xmlFile, boostKey) then break end

        local farmlandId = getXMLInt(xmlFile, boostKey .. "#farmlandId")
        local value = getXMLFloat(xmlFile, boostKey .. "#value")
        if farmlandId ~= nil and value ~= nil then
            self.boosts[farmlandId] = {
                value = value,
                graceUntil = getXMLFloat(xmlFile, boostKey .. "#graceUntil"),
            }
        end
        i = i + 1
    end

    local j = 0
    while true do
        local jobKey = string.format("%s.job(%d)", base, j)
        if not hasXMLProperty(xmlFile, jobKey) then break end

        local farmlandId = getXMLInt(xmlFile, jobKey .. "#farmlandId")
        if farmlandId ~= nil then
            local job = {
                targetBoost = getXMLFloat(xmlFile, jobKey .. "#targetBoost") or 0,
                startDay = getXMLInt(xmlFile, jobKey .. "#startDay") or 0,
                startHour = getXMLInt(xmlFile, jobKey .. "#startHour") or IrrigationSystem.DAY_START_HOUR,
                hours = getXMLInt(xmlFile, jobKey .. "#hours") or IrrigationSystem.MIN_JOB_HOURS,
                hoursWorked = getXMLInt(xmlFile, jobKey .. "#hoursWorked") or 0,
                price = getXMLFloat(xmlFile, jobKey .. "#price") or 0,
                paid = getXMLBool(xmlFile, jobKey .. "#paid") or false,
                contractorIndex = getXMLInt(xmlFile, jobKey .. "#contractorIndex") or 0,
                farmId = getXMLInt(xmlFile, jobKey .. "#farmId"),
            }
            self.jobs[farmlandId] = job
            self:reserveHours(job.startDay, job.contractorIndex, job.hours)
        end
        j = j + 1
    end

    self:refreshActiveBoostFlag()
end

-- ── booked-hours ledger ──────────────────────────────────────────────────────

local function bookedKey(day, contractorIndex)
    return day .. ":" .. contractorIndex
end

function IrrigationSystem:getBookedHours(day, contractorIndex)
    return self.bookedHours[bookedKey(day, contractorIndex)] or 0
end

function IrrigationSystem:reserveHours(day, contractorIndex, hours)
    local k = bookedKey(day, contractorIndex)
    self.bookedHours[k] = (self.bookedHours[k] or 0) + hours
end

-- ── decay ────────────────────────────────────────────────────────────────────

---
-- Percentage points a boost sheds in one game hour.
--
-- Linear, not exponential: exponential reproduces linear almost cell for cell
-- and costs the hard cutoff that makes "the boost is gone" legible.
--
-- The temperature term is deliberately COMPRESSED rather than coupled to the
-- field sim's own drying rate. That rate spans 30x between a cool month and a
-- hot one, which proportional coupling turns into a 30x spread in lifetime --
-- five hours in a mediterranean July, i.e. the boost dying faster than the job
-- takes to apply it, in exactly the month a player would pay for it.
--
-- The month length divides EXACTLY, not by the field sim's 1/dpp^0.7, so
-- lifetime measured in months is invariant to the player's month-length
-- setting. Diverging from the field sim here is deliberate: its exponent exists
-- to keep moisture chasing its clamp, which is a different job.
---
function IrrigationSystem:getDrainPpPerHour(temperature, daysPerPeriod)
    local tempMult = math.clamp(temperature / IrrigationSystem.DECAY_TEMP_REF,
        IrrigationSystem.DECAY_TEMP_MIN, IrrigationSystem.DECAY_TEMP_MAX)
    local divisor = math.min(daysPerPeriod, IrrigationSystem.DECAY_DPP_CAP)
    return (IrrigationSystem.DECAY_PP_PER_DAY / 24) * tempMult / divisor
end

---
-- Rain pauses decay; it does not top the boost up. Topping up would double
-- count, because rain already raises the base moisture the boost sits on.
-- Uses the same "is it raining" test as the rest of the mod.
---
function IrrigationSystem:getIsRaining()
    local weather = g_currentMission.environment.weather
    return weather:getRainFallScale() > 0.1
end

function IrrigationSystem:decayBoosts()
    local env = g_currentMission.environment
    local now = env:getMonotonicHour()
    local isRaining = self:getIsRaining()
    local temperature = env.weather.temperatureUpdater.currentTemperature or 20
    local drain = self:getDrainPpPerHour(temperature, env.daysPerPeriod or 1) / 100

    local pruned = false
    for farmlandId, boost in pairs(self.boosts) do
        local inGrace = boost.graceUntil ~= nil and now < boost.graceUntil
        if not inGrace and not isRaining then
            boost.value = math.max(0, boost.value - drain)
            if boost.value <= IrrigationSystem.PRUNE_THRESHOLD then
                self.boosts[farmlandId] = nil
                pruned = true
            end
        end
    end

    if pruned then
        self:refreshActiveBoostFlag()
    end
end

-- ── the contractor diary ─────────────────────────────────────────────────────
--
-- The diary is generated, never stored. A day's committed load is a pure
-- function of which day it is (its intrinsic character, from the seed) and how
-- far away it is right now, so it tightens on its own as it approaches and
-- re-asking on the same day always gives the same answer. That is what makes
-- availability state rather than a dice roll -- and what makes it identical on
-- every peer and across a reload.

local HASH_M = 2147483647

local function minstd(h)
    return (h * 48271) % HASH_M
end

---
-- Integer hash, deliberately not math.random: the whole design rests on this
-- being reproducible -- across a reload, and identically on every peer.
--
-- Two properties are load-bearing and easy to lose if this is "tidied":
--
-- 1. THE NONLINEAR FOLD. The spec's original two-round LCG was affine in its
--    inputs end to end, so hash01(s, n+1) was always hash01(s, n) plus a fixed
--    constant. Contractors, whose only difference is that +1 on the day fold,
--    therefore all drew the same jitter shifted by the same amount -- measured
--    Pearson 0.73 between contractor 0 and 1, which collapses the roster
--    setting into a no-op on exactly the same-day bookings it exists to help.
--    The fold below breaks that linearity; correlation measures under 0.006 and
--    the best-of-N table in spec section 7 reproduces.
--
-- 2. EVERY PRODUCT STAYS BELOW 2^53. Lua numbers are doubles, so a product
--    above that silently loses low bits. The multipliers are chosen so the
--    largest intermediate (HASH_M * 48271) is ~1.0e14 -- exact, hence identical
--    on every peer. Do not restore a larger multiplier.
---
function IrrigationSystem.hash01(seed, day)
    local h = (seed * 2654435761 + day * 40503) % HASH_M
    h = minstd(h)
    h = (h * (h % 4093 + 1) + 12345) % HASH_M
    h = minstd(h)
    return h / HASH_M
end

function IrrigationSystem:getToday()
    return g_currentMission.environment.currentMonotonicDay
end

---
-- Fraction of the working day a contractor already has committed, before the
-- player's own bookings. Shared by every contractor; they differ only by their
-- per-day jitter, which is exactly what makes the best of N meaningfully freer
-- than one. Saturates at DIARY_FLOOR so a player on long months does not see a
-- month of implausibly empty diary.
---
function IrrigationSystem:getMeanCommitted(daysAhead)
    return IrrigationSystem.DIARY_FLOOR +
        IrrigationSystem.DIARY_SPAN * math.exp(-daysAhead / IrrigationSystem.DIARY_TAU_DAYS)
end

function IrrigationSystem:getCommittedHours(day, contractorIndex)
    local daysAhead = math.max(0, day - self:getToday())
    -- The * 8 fold is safe because the contractor index is always below 8.
    local jitter = (IrrigationSystem.hash01(self.diarySeed, day * 8 + contractorIndex) - 0.5)
        * (2 * IrrigationSystem.DIARY_JITTER)
    local committed = math.clamp(self:getMeanCommitted(daysAhead) + jitter, 0, 1)
    return math.floor(IrrigationSystem.DAILY_CAPACITY_H * committed + 0.5)
end

---
-- Hours this contractor has left on this day. Clamped at zero so lowering the
-- capacity setting below hours already booked shows no free time rather than
-- negative time -- consumed hours are never re-homed onto a surviving
-- contractor.
---
function IrrigationSystem:getFreeHours(day, contractorIndex)
    local used = self:getCommittedHours(day, contractorIndex) + self:getBookedHours(day, contractorIndex)
    return math.max(0, IrrigationSystem.DAILY_CAPACITY_H - used)
end

---
-- Commitments are placed from the start of the window: the contractor does
-- their pre-existing work first, then yours. This is what turns an hour count
-- into a displayable start time.
---
function IrrigationSystem:getStartHour(day, contractorIndex)
    return IrrigationSystem.DAY_START_HOUR
        + self:getCommittedHours(day, contractorIndex)
        + self:getBookedHours(day, contractorIndex)
end

---
-- The best any contractor has that day. This is the only figure the tab shows;
-- contractors stay invisible at every roster setting.
---
function IrrigationSystem:getBestFreeHours(day)
    local best = 0
    for c = 0, self:getContractorCount() - 1 do
        best = math.max(best, self:getFreeHours(day, c))
    end
    return best
end

---
-- The bookable window: the current month plus the next two, with days already
-- past excluded. Variable in days -- 3 at the default one day per month, up to
-- 36 at twelve.
---
function IrrigationSystem:getBookableDays()
    local env = g_currentMission.environment
    local daysPerPeriod = env.daysPerPeriod or 1
    local remainingThisMonth = daysPerPeriod - (env.currentDayInPeriod or 1) + 1
    local count = remainingThisMonth + IrrigationSystem.BOOKABLE_MONTHS * daysPerPeriod

    local today = self:getToday()
    local days = {}
    for i = 0, count - 1 do
        table.insert(days, today + i)
    end
    return days
end

---
-- The bookable days that fall inside monthOffset months from now (0 = the
-- current month). Drives the tab's month picker.
---
function IrrigationSystem:getBookableDaysInMonth(monthOffset)
    local env = g_currentMission.environment
    local daysPerPeriod = env.daysPerPeriod or 1
    local dayInPeriod = env.currentDayInPeriod or 1
    local today = self:getToday()

    local firstOffset, lastOffset
    if monthOffset <= 0 then
        firstOffset = 0
        lastOffset = daysPerPeriod - dayInPeriod
    else
        firstOffset = (daysPerPeriod - dayInPeriod + 1) + (monthOffset - 1) * daysPerPeriod
        lastOffset = firstOffset + daysPerPeriod - 1
    end

    local days = {}
    for i = firstOffset, lastOffset do
        table.insert(days, today + i)
    end
    return days
end

-- ── pricing, duration and the moving ceiling ─────────────────────────────────

---
-- Area is the crop polygon, NOT Farmland.areaInHa: that is the purchasable
-- parcel including verges, tracks and woodland, and can be far larger. Charging
-- on it would overcharge every ordinary player for ground irrigation cannot
-- help. The whole parcel does get wetted -- see spec section 18, this drift is
-- accepted deliberately and must not be "fixed" into an overcharge.
---
function IrrigationSystem:getFarmlandAreaHa(farmlandId)
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then return nil end
    local field = farmland:getField()
    if field == nil then return nil end
    return field:getAreaHa()
end

function IrrigationSystem:getJobHours(areaHa, boostPp)
    local needed = math.ceil(areaHa * boostPp / self:getHaPpPerHour())
    return math.max(IrrigationSystem.MIN_JOB_HOURS, needed)
end

function IrrigationSystem:getShortNoticeMultiplier(daysAhead)
    local lead = math.min(math.max(0, daysAhead), IrrigationSystem.SHORT_NOTICE_DAYS)
    return 1 + (IrrigationSystem.SHORT_NOTICE_MAX - 1) * (1 - lead / IrrigationSystem.SHORT_NOTICE_DAYS)
end

IrrigationSystem.CEILING_CONTRACTOR_HOURS = 1
IrrigationSystem.CEILING_BOOST_CAP        = 2

---
-- The largest boost this day can actually deliver on this farmland, and which
-- limit is binding.
--
-- There are no partial jobs: the selector is CLAMPED to what the day can
-- deliver, never truncated after the fact. maxFreeHours is the best any
-- contractor has, so the clamp guarantees the tightest-fit set is never empty.
--
-- A day is unbookable when this reaches zero, from either cause -- under the
-- minimum callout hours, or enough hours but a field too large for one step.
-- Those are the same thing from where the player sits, so one message covers
-- both, but it must state the reason rather than merely greying the day out.
---
function IrrigationSystem:getBoostCeiling(farmlandId, day)
    local areaHa = self:getFarmlandAreaHa(farmlandId)
    if areaHa == nil or areaHa <= 0 then return 0, IrrigationSystem.CEILING_CONTRACTOR_HOURS end

    local step = IrrigationSystem.BOOST_STEP_PP
    local freeHours = self:getBestFreeHours(day)
    local byHours = 0
    if freeHours >= IrrigationSystem.MIN_JOB_HOURS then
        byHours = math.floor(freeHours * self:getHaPpPerHour() / areaHa / step) * step
    end

    local byCap = IrrigationSystem.MAX_BOOST_PP - self:getBoost(farmlandId) * 100
    byCap = math.floor(byCap / step + 1e-9) * step

    if byHours <= byCap then
        return math.max(0, byHours), IrrigationSystem.CEILING_CONTRACTOR_HOURS
    end
    return math.max(0, byCap), IrrigationSystem.CEILING_BOOST_CAP
end

---
-- The whole price of a job. Nil when the farmland cannot be quoted at all.
-- Callers display this; the server recomputes it before accepting a booking and
-- never trusts a client's figures.
---
function IrrigationSystem:getQuote(farmlandId, boostPp, day)
    local areaHa = self:getFarmlandAreaHa(farmlandId)
    if areaHa == nil or areaHa <= 0 or boostPp <= 0 then return nil end

    local daysAhead = math.max(0, day - self:getToday())
    local rated = IrrigationSystem.RATE_PER_HA_PP * areaHa * boostPp
    local base = math.max(IrrigationSystem.MINIMUM_CALLOUT, rated)
    local shortNotice = self:getShortNoticeMultiplier(daysAhead)
    local costMultiplier = self:getCostMultiplier()
    local hours = self:getJobHours(areaHa, boostPp)
    local contractorIndex = self:findContractor(day, hours)
    local startHour = contractorIndex ~= nil and self:getStartHour(day, contractorIndex) or nil

    return {
        areaHa = areaHa,
        boostPp = boostPp,
        daysAhead = daysAhead,
        hours = hours,
        base = base,
        minimumApplied = rated < IrrigationSystem.MINIMUM_CALLOUT,
        shortNotice = shortNotice,
        shortNoticeCost = base * shortNotice - base,
        costMultiplier = costMultiplier,
        total = base * shortNotice * costMultiplier,
        contractorIndex = contractorIndex,
        startHour = startHour,
    }
end

---
-- Tightest fit rather than most-free, so an exact-fit job does not consume a
-- contractor who could have taken a larger one. Ties go to the lowest index.
-- Contractors are anonymous; the player never picks one.
---
function IrrigationSystem:findContractor(day, neededHours)
    local best, bestFree = nil, nil
    for c = 0, self:getContractorCount() - 1 do
        local free = self:getFreeHours(day, c)
        if free >= neededHours and (bestFree == nil or free < bestFree) then
            best, bestFree = c, free
        end
    end
    return best
end

-- ── booking ──────────────────────────────────────────────────────────────────

function IrrigationSystem:getIsDayBookable(day)
    local today = self:getToday()
    if day < today then return false end
    local days = self:getBookableDays()
    return day <= days[#days]
end

---
-- Book a contractor. Server-side only: this is the sole place hours are
-- consumed and money leaves the account, so it validates everything itself
-- rather than trusting a caller.
--
-- @param skipPayment true only for the force-book console command
-- @return accepted, reasonCode
---
function IrrigationSystem:bookJob(farmlandId, boostPp, day, farmId, skipPayment)
    if self.jobs[farmlandId] ~= nil then
        -- One pending job per farmland; the additive top-up rule already lets
        -- the player re-book once this one finishes.
        return false, IrrigationSystem.REJECT_SLOT_TAKEN
    end

    if not self:getIsDayBookable(day) then
        return false, IrrigationSystem.REJECT_INVALID
    end

    local areaHa = self:getFarmlandAreaHa(farmlandId)
    if areaHa == nil or areaHa <= 0 then
        return false, IrrigationSystem.REJECT_INVALID
    end

    if g_farmlandManager:getFarmlandOwner(farmlandId) ~= farmId then
        return false, IrrigationSystem.REJECT_INVALID
    end

    local step = IrrigationSystem.BOOST_STEP_PP
    local ceiling = self:getBoostCeiling(farmlandId, day)
    if boostPp < step or boostPp > ceiling + 1e-9 then
        return false, IrrigationSystem.REJECT_INVALID
    end

    local quote = self:getQuote(farmlandId, boostPp, day)
    if quote == nil then
        return false, IrrigationSystem.REJECT_INVALID
    end
    if quote.contractorIndex == nil then
        -- The clamp above should make this unreachable; it is the last line of
        -- defence against a double-booked contractor, so it stays.
        return false, IrrigationSystem.REJECT_SLOT_TAKEN
    end

    local paid = false
    if not skipPayment then
        local farm = g_farmManager:getFarmById(farmId)
        if farm == nil or farm:getBalance() < quote.total then
            return false, IrrigationSystem.REJECT_INSUFFICIENT_FUNDS
        end
        g_currentMission:addMoneyChange(-quote.total, farmId, MoneyType.IRRIGATION, true)
        farm:changeBalance(-quote.total, MoneyType.IRRIGATION)
        paid = true
    end

    self.jobs[farmlandId] = {
        targetBoost = boostPp / 100,
        startDay = day,
        startHour = quote.startHour,
        hours = quote.hours,
        hoursWorked = 0,
        price = quote.total,
        paid = paid,
        contractorIndex = quote.contractorIndex,
        farmId = farmId,
    }
    self:reserveHours(day, quote.contractorIndex, quote.hours)

    return true, nil, quote
end

-- ── job execution ────────────────────────────────────────────────────────────

---
-- The boost accrues hourly rather than landing atomically. That makes duration
-- visible, makes late joiners correct by construction (a half-finished job has
-- already banked its accrued boost), and means decay never fights the ramp.
---
function IrrigationSystem:runJobs()
    local env = g_currentMission.environment
    local day, hour = env.currentMonotonicDay, env.currentHour
    local now = env:getMonotonicHour()

    for farmlandId, job in pairs(self.jobs) do
        local hasStarted = day > job.startDay or (day == job.startDay and hour >= job.startHour)
        if hasStarted and job.hoursWorked < job.hours then
            local wasFirstHour = job.hoursWorked == 0
            local share = job.targetBoost / job.hours
            self:setBoost(farmlandId, self:getBoost(farmlandId) + share,
                self.boosts[farmlandId] ~= nil and self.boosts[farmlandId].graceUntil or nil)
            job.hoursWorked = job.hoursWorked + 1

            if wasFirstHour then
                self:notifyJobStarted(farmlandId, job)
            end

            if job.hoursWorked >= job.hours then
                -- One graceUntil per farmland, not per job: a top-up restarts
                -- grace on the whole accumulated boost.
                local boost = self.boosts[farmlandId]
                if boost ~= nil then
                    boost.graceUntil = now + IrrigationSystem.GRACE_HOURS
                end
                self.jobs[farmlandId] = nil
                self:notifyJobFinished(farmlandId, job)
            end
        end
    end
end

function IrrigationSystem:onHourChanged()
    if not g_currentMission:getIsServer() then return end

    self:runJobs()
    self:decayBoosts()
    -- Once for the whole sweep, not once per farmland: cache keys are
    -- positions, so an entry can never be served for the wrong farmland and
    -- staleness across time is the only failure mode.
    self:invalidateMoistureCache()
    self:broadcastBoosts()
end

-- ── selling a farmland ───────────────────────────────────────────────────────

---
-- No refund of any kind, not full and not pro-rata: cancellation does not
-- exist, so refunding a sale would make selling a back-door cancel. The
-- contractor's hours stay consumed.
--
-- Two guards, both required. loadFromSavegame alone is not enough:
-- MoistureSystem:loadFromXMLFile runs at loadMap, long before onStartMission,
-- so ownership restores during load can fire while our state is half-built.
---
function IrrigationSystem:onFarmlandOwnerChanged(farmlandId, _farmId, loadFromSavegame)
    if loadFromSavegame then return end

    local ms = g_currentMission.MoistureSystem
    if ms == nil or not ms.missionStarted then return end

    self.boosts[farmlandId] = nil
    self.jobs[farmlandId] = nil
    self:refreshActiveBoostFlag()
end

-- ── notifications ────────────────────────────────────────────────────────────

function IrrigationSystem:getFarmlandName(farmlandId)
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    return farmland ~= nil and farmland:getName() or tostring(farmlandId)
end

---
-- Targeting is by farm, evaluated ON ARRIVAL rather than at booking time: a
-- player can switch farms mid-game, and deciding at booking would keep telling
-- them about the farm they left while saying nothing about the one they joined.
-- Other farms are never notified of anything.
---
function IrrigationSystem:sendJobNotification(farmId, text)
    if farmId ~= nil then
        self.pendingNotifications = self.pendingNotifications or {}
        table.insert(self.pendingNotifications, { farmId = farmId, text = text })
    end
    if g_currentMission:getFarmId() == farmId then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
    end
end

function IrrigationSystem:notifyJobStarted(farmlandId, job)
    self:sendJobNotification(job.farmId, string.format(
        g_i18n:getText("ms_irrigation_started"),
        self:getFarmlandName(farmlandId), job.targetBoost * 100, job.hours))
end

function IrrigationSystem:notifyJobFinished(farmlandId, job)
    -- This job's delivered amount, not the farmland's total boost, which may be
    -- higher after a top-up.
    self:sendJobNotification(job.farmId, string.format(
        g_i18n:getText("ms_irrigation_complete"),
        self:getFarmlandName(farmlandId), job.targetBoost * 100))
end

-- ── multiplayer ──────────────────────────────────────────────────────────────

---
-- The tab's single entry point for booking. On single-player or a listen-server
-- host this is a direct call with no event at all, matching how toggleDrying()
-- is called directly for the server player.
---
function IrrigationSystem:requestBooking(farmlandId, boostPp, day, expectedPrice)
    if g_currentMission:getIsServer() then
        local accepted, reason = self:handleBookRequest(
            farmlandId, boostPp, day, g_currentMission:getFarmId(), nil, expectedPrice)
        self:onBookResult(accepted, reason)
        return accepted, reason
    end

    g_client:getServerConnection():sendEvent(
        IrrigationBookRequestEvent.new(farmlandId, boostPp, day, expectedPrice))
    return nil
end

---
-- Server-side acceptance. The client computed a quote to draw its screen; this
-- recomputes from the server's own diary and prices and books only if the two
-- agree. A slot going during the network hop is expected traffic, not an error.
---
function IrrigationSystem:handleBookRequest(farmlandId, boostPp, day, farmId, connection, expectedPrice)
    if farmId == nil or farmId == FarmlandManager.NO_OWNER_FARM_ID then
        return false, IrrigationSystem.REJECT_INVALID
    end

    -- HIRE_ASSISTANT rather than MANAGE_CONTRACTING, which reads closer by name
    -- but is bound to the base game's NPC contract system. This is already the
    -- permission for spending farm money on someone else's labour.
    if not g_currentMission:getHasPlayerPermission(Farm.PERMISSION.HIRE_ASSISTANT, connection, farmId) then
        return false, IrrigationSystem.REJECT_NO_PERMISSION
    end

    local quote = self:getQuote(farmlandId, boostPp, day)
    if quote == nil then
        return false, IrrigationSystem.REJECT_INVALID
    end

    -- Never silently correct: money must not leave the account at a price the
    -- player did not see. A rounding-width tolerance only.
    if expectedPrice ~= nil and math.abs(expectedPrice - quote.total) > 1 then
        return false, IrrigationSystem.REJECT_PRICE_CHANGED
    end

    local accepted, reason = self:bookJob(farmlandId, boostPp, day, farmId)
    if not accepted then
        return false, reason
    end

    local job = self.jobs[farmlandId]
    if g_server ~= nil then
        g_server:broadcastEvent(IrrigationJobBookedEvent.new(
            farmlandId, day, job.hours, job.contractorIndex, farmId, job))
    end

    return true, nil
end

---
-- Called on the requester with the server's verdict. The tab re-quotes off the
-- back of this, so a stale screen cannot leave a price on the Book button that
-- the server has already refused.
---
function IrrigationSystem:onBookResult(accepted, reason)
    self.lastBookResult = { accepted = accepted, reason = reason, time = g_time }
    if self.onBookResultCallback ~= nil then
        self.onBookResultCallback(accepted, reason)
    end
end

---
-- Client-side: a booking landed somewhere on the server. Every client consumes
-- the hours so its diary tightens; only the booking farm gets the job record.
---
function IrrigationSystem:onJobBooked(farmlandId, day, hours, contractorIndex, farmId, job)
    self:reserveHours(day, contractorIndex, hours)

    if farmId == g_currentMission:getFarmId() then
        self.jobs[farmlandId] = {
            targetBoost = job.targetBoost,
            startDay = day,
            startHour = job.startHour,
            hours = hours,
            hoursWorked = 0,
            price = 0,
            paid = true,
            contractorIndex = contractorIndex,
            farmId = farmId,
        }
    end
end

---
-- Client-side: replace the whole boost table from the hourly push and bin the
-- moisture cache. Binning it is load-bearing, not hygiene: without it the sync
-- lands but the meter still shows the old figure.
---
function IrrigationSystem:applyBoostUpdate(boosts)
    self.boosts = boosts or {}
    self:refreshActiveBoostFlag()
    self:invalidateMoistureCache()

    -- A client can tell a job has finished without being told: the record
    -- carries when it starts and how long it runs, and the server has already
    -- banked everything it delivered into the boost above.
    local now = g_currentMission.environment:getMonotonicHour()
    for farmlandId, job in pairs(self.jobs) do
        if now >= job.startDay * 24 + job.startHour + job.hours then
            self.jobs[farmlandId] = nil
        end
    end
end

---
-- Initial state rides the existing MSInitialClientStateEvent -- no new event.
-- Exactly three items: non-zero boosts, the diary seed (which regenerates the
-- whole roster's diary for the entire bookable range for free), and booked
-- hours per day per contractor. Whose farm booked what is not sent.
---
function IrrigationSystem:writeClientState(streamId)
    local count = 0
    for _ in pairs(self.boosts) do count = count + 1 end
    streamWriteUIntN(streamId, count, 12)
    for farmlandId, boost in pairs(self.boosts) do
        streamWriteUIntN(streamId, farmlandId, g_farmlandManager.numberOfBits)
        streamWriteFloat32(streamId, boost.value)
    end

    streamWriteInt32(streamId, self.diarySeed)

    -- Only days still inside the bookable window can be quoted, so only those
    -- need their consumed hours.
    local days = self:getBookableDays()
    local firstDay, lastDay = days[1], days[#days]
    local reservations = {}
    for c = 0, self:getContractorCount() - 1 do
        for day = firstDay, lastDay do
            local hours = self:getBookedHours(day, c)
            if hours > 0 then
                table.insert(reservations, { day = day, contractorIndex = c, hours = hours })
            end
        end
    end

    streamWriteUIntN(streamId, #reservations, 12)
    for _, r in ipairs(reservations) do
        streamWriteInt32(streamId, r.day)
        streamWriteUIntN(streamId, r.contractorIndex, 3)
        streamWriteUIntN(streamId, r.hours, 5)
    end
end

function IrrigationSystem:readClientState(streamId)
    self.boosts = {}
    local count = streamReadUIntN(streamId, 12)
    for _ = 1, count do
        local farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
        self.boosts[farmlandId] = { value = streamReadFloat32(streamId) }
    end
    self:refreshActiveBoostFlag()

    self.diarySeed = streamReadInt32(streamId)

    self.bookedHours = {}
    local reservationCount = streamReadUIntN(streamId, 12)
    for _ = 1, reservationCount do
        local day = streamReadInt32(streamId)
        local contractorIndex = streamReadUIntN(streamId, 3)
        local hours = streamReadUIntN(streamId, 5)
        self:reserveHours(day, contractorIndex, hours)
    end

    self:invalidateMoistureCache()
end

-- ── console commands ─────────────────────────────────────────────────────────

function IrrigationSystem:registerConsoleCommands()
    addConsoleCommand("msIrrigationDebug", "Dump irrigation boosts and jobs",
        "consoleCommandIrrigationDebug", self)
    addConsoleCommand("msIrrigationDiary", "Dump contractor diary for a day",
        "consoleCommandIrrigationDiary", self)
    addConsoleCommand("msIrrigationBook", "Force-book an irrigation job, unpaid",
        "consoleCommandIrrigationBook", self)
    addConsoleCommand("msIrrigationSetBoost", "Set a farmland's irrigation boost directly",
        "consoleCommandIrrigationSetBoost", self)
end

function IrrigationSystem:removeConsoleCommands()
    removeConsoleCommand("msIrrigationDebug")
    removeConsoleCommand("msIrrigationDiary")
    removeConsoleCommand("msIrrigationBook")
    removeConsoleCommand("msIrrigationSetBoost")
end

local function describeFarmland(self, farmlandId)
    local boost = self.boosts[farmlandId]
    local job = self.jobs[farmlandId]
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    local name = farmland ~= nil and farmland:getName() or "?"

    local parts = { string.format("farmland %d (%s):", farmlandId, name) }
    if boost ~= nil then
        table.insert(parts, string.format(" boost %.2f%%", boost.value * 100))
        table.insert(parts, string.format(" graceUntil %s", tostring(boost.graceUntil)))
    else
        table.insert(parts, " boost none")
    end
    if job ~= nil then
        table.insert(parts, string.format(
            " job +%.2f%% day %d %02d:00 %dh (%d worked) price %d contractor %d paid %s",
            job.targetBoost * 100, job.startDay, job.startHour, job.hours,
            job.hoursWorked, job.price, job.contractorIndex, tostring(job.paid)))
    else
        table.insert(parts, " job none")
    end
    return table.concat(parts)
end

function IrrigationSystem:consoleCommandIrrigationDebug(farmlandIdArg)
    if not g_currentMission:getIsServer() then return "Server only" end

    if farmlandIdArg ~= nil then
        local farmlandId = tonumber(farmlandIdArg)
        if farmlandId == nil then return "Usage: msIrrigationDebug [farmlandId]" end
        return describeFarmland(self, farmlandId)
    end

    local seen, lines = {}, {}
    for farmlandId in pairs(self.boosts) do seen[farmlandId] = true end
    for farmlandId in pairs(self.jobs) do seen[farmlandId] = true end

    local ids = {}
    for farmlandId in pairs(seen) do table.insert(ids, farmlandId) end
    table.sort(ids)
    for _, farmlandId in ipairs(ids) do
        table.insert(lines, describeFarmland(self, farmlandId))
    end

    if #lines == 0 then return "No irrigated farmlands" end
    table.insert(lines, 1, string.format("diarySeed %d", self.diarySeed))
    return table.concat(lines, "\n")
end

function IrrigationSystem:consoleCommandIrrigationDiary(daysAheadArg)
    if not g_currentMission:getIsServer() then return "Server only" end

    local daysAhead = tonumber(daysAheadArg) or 0
    local day = self:getToday() + math.max(0, math.floor(daysAhead))

    local lines = {
        string.format("diarySeed %d, day %d (+%d), capacity %dh",
            self.diarySeed, day, day - self:getToday(), IrrigationSystem.DAILY_CAPACITY_H),
    }
    for c = 0, self:getContractorCount() - 1 do
        table.insert(lines, string.format(
            "  contractor %d: free %dh, committed %dh, booked %dh, starts %02d:00",
            c, self:getFreeHours(day, c), self:getCommittedHours(day, c),
            self:getBookedHours(day, c), self:getStartHour(day, c)))
    end
    return table.concat(lines, "\n")
end

function IrrigationSystem:consoleCommandIrrigationBook(farmlandIdArg, boostPpArg, daysAheadArg)
    if not g_currentMission:getIsServer() then return "Server only" end

    local farmlandId = tonumber(farmlandIdArg)
    local boostPp = tonumber(boostPpArg)
    local daysAhead = tonumber(daysAheadArg) or 0
    if farmlandId == nil or boostPp == nil then
        return "Usage: msIrrigationBook <farmlandId> <boostPP> <daysAhead>"
    end

    local day = self:getToday() + math.max(0, math.floor(daysAhead))
    local farmId = g_farmlandManager:getFarmlandOwner(farmlandId)
    local ok, reason = self:bookJob(farmlandId, boostPp, day, farmId, true)
    if not ok then
        return string.format("Rejected (reason %d)", reason or 0)
    end

    local job = self.jobs[farmlandId]
    return string.format("Booked farmland %d: +%.1f%% on day %d at %02d:00, %dh, contractor %d",
        farmlandId, boostPp, day, job.startHour, job.hours, job.contractorIndex)
end

function IrrigationSystem:consoleCommandIrrigationSetBoost(farmlandIdArg, boostPpArg)
    if not g_currentMission:getIsServer() then return "Server only" end

    local farmlandId = tonumber(farmlandIdArg)
    local boostPp = tonumber(boostPpArg)
    if farmlandId == nil or boostPp == nil then
        return "Usage: msIrrigationSetBoost <farmlandId> <boostPP>"
    end

    boostPp = math.clamp(boostPp, 0, IrrigationSystem.MAX_BOOST_PP)
    self:setBoost(farmlandId, boostPp / 100)
    self:invalidateMoistureCache()

    return string.format("farmland %d boost set to %.2f%%", farmlandId, boostPp)
end

---
-- Hourly server-to-all push of every live boost, plus any notifications queued
-- this hour. Display-only on the client: all simulation stays server-side.
---
function IrrigationSystem:broadcastBoosts()
    if g_server == nil then
        self.pendingNotifications = nil
        return
    end

    local hasNotifications = self.pendingNotifications ~= nil and #self.pendingNotifications > 0

    -- Once the last boost has decayed away, clients still need one final empty
    -- push to learn it is gone -- but only one. After that there is nothing to
    -- say until something is irrigated again.
    if not self.anyActiveBoosts and not hasNotifications and self.sentEmptyBoostPush then
        self.pendingNotifications = nil
        return
    end
    self.sentEmptyBoostPush = not self.anyActiveBoosts

    g_server:broadcastEvent(IrrigationBoostUpdateEvent.new(self.boosts, self.pendingNotifications))
    self.pendingNotifications = nil
end

function IrrigationSystem:invalidateMoistureCache()
    local ms = g_currentMission ~= nil and g_currentMission.MoistureSystem or nil
    if ms ~= nil and ms.invalidateMoistureCache ~= nil then
        ms:invalidateMoistureCache()
    end
end
