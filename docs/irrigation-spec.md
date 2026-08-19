# Field Irrigation — Implementation Spec

**Status: implemented.** This document is the design record, kept because it holds the reasoning
behind every number; the code is in `src/IrrigationSystem.lua`, `src/gui/MoistureGuiIrrigation.*`
and `src/events/Irrigation*.lua`. Every number was chosen deliberately; where a value looks
arbitrary, the reasoning is given inline so it is not "tidied" away.

**One deliberate departure from this spec.** The `hash01` generator in section 7 is affine in its
inputs end to end (two rounds of multiply-add mod a constant), so `hash01(seed, n+1)` differs from
`hash01(seed, n)` by a fixed constant. Contractors are folded in as exactly that `+1`, so every
contractor drew the same jitter shifted by the same amount — measured Pearson correlation 0.73
between contractor 0 and contractor 1, which makes the roster setting a near no-op on precisely the
same-day bookings it exists to help, and makes the best-of-N table in section 7 unreachable. The
shipped generator adds a nonlinear fold and keeps every intermediate product below 2^53 so the
result stays exact and identical on every peer. With it, the section 7 roster table reproduces to
within 0.15h. Nothing else in this document changed.

The player books a contractor, through a new tab in the Shift+M menu, to raise a farmland's
moisture by a chosen amount. The boost accrues hour by hour while the contractor works, then decays
with the weather. Contractor time is scarce and shared; money is not the binding constraint.

---

## 1. Vocabulary

Use these words in code, comments, UI and l10n. They are the whole model.

| Term | Meaning |
|---|---|
| **Boost** | The current additive moisture offset on a farmland, stored 0–1. A plain accumulator: jobs pour into it, decay drains it. |
| **Job** | The contractor's scheduled work on a farmland, before *or* during execution. |
| **Booking** | A **verb**, never a noun. The player books a job. There is no third record. |
| **Tunable** | An author-facing balance constant in the Lua block (§4). Not saved, not synced. |
| **Setting** | Player-facing state on `MoistureSystem.settings`. Saved, synced, permissioned. |
| **Farmland** | The unit irrigation is bought, applied and billed on. **All player-facing text says farmland, never field.** |

**On farmland vs field.** The engine binding is 1:1 — `Farmland.field` is a single slot
(`economy/Farmland.lua:77`) and `FieldManager` has no runtime field-creation path. But the player's
experience is not 1:1: ploughing a dividing line through a farmland leaves them with two things
they call fields inside one parcel. Irrigation is keyed by farmland id, wets the whole parcel, and
must say so.

---

## 2. Files

**New:**

- `src/IrrigationSystem.lua` — the subsystem: tunables, state, diary, pricing, hourly tick.
- `src/gui/MoistureGuiIrrigation.lua` + `.xml` — the new tab.
- `src/events/IrrigationBookRequestEvent.lua`
- `src/events/IrrigationBookResultEvent.lua`
- `src/events/IrrigationJobBookedEvent.lua`
- `src/events/IrrigationBoostUpdateEvent.lua` — hourly server→all boost push.

**Changed:**

- `src/main.lua` — construct the subsystem in `loadMap` (alongside the existing four, `:104-110`);
  tick it from `onHourChanged` (`:797`); extract `invalidateMoistureCache()`; inject the boost in
  `getMoistureAtPosition`; call irrigation save/load from `saveToXmlFile` (`:1042-1055`) and
  `loadFromXMLFile` (`:923-931`).
- `src/MoistureSettings.lua` — three new menu entries.
- `src/events/MoistureSettingsEvent.lua`, `src/events/InitialClientStateEvent.lua` — the three
  settings, plus irrigation initial state.
- `src/gui/MoistureGui.lua` — register the tab in `setupPages` (`:33`); reuse the already-loaded
  `grainDrying.dds` icon (`:34`).
- `src/extensions/I18NExtension.lua` — money type registration (§13).
- `src/extensions/PlayerHUDUpdateExtension.lua` — the boost breakout line (`:150`).
- `languages/l10n_*.xml` — all ten files (§17).

---

## 3. Architecture

`IrrigationSystem` is its own subsystem registered as `g_currentMission.irrigationSystem`, in the
style of `DryingSystem` / `BaleRottingSystem` / `WitheringSystem`. It is ticked once per game hour
from `MoistureSystem:onHourChanged`.

One deliberate wrinkle: `MoistureSystem:getMoistureAtPosition` calls **into** `IrrigationSystem` on
a hot path — traffic in the opposite direction to every other subsystem, which `MoistureSystem`
only calls out to. This is mitigated by an `anyActiveBoosts` boolean, so the hot path costs one
flag read when nobody is irrigating. Do not "fix" the direction by moving state into
`MoistureSystem`; the separation is what keeps the moisture sim ignorant of contractors.

All simulation is **server-side**, per the mod's standing rule. Clients receive boosts only so the
two display-only readers do not show a lie.

---

## 4. Tunables

A flat `SCREAMING_CASE` block at the top of `src/IrrigationSystem.lua`, grouped by comment banner.
House style, matching `WitheringSystem.BASE_CHANCE_PER_HOUR` and `GroundPropertyTracker`'s twelve.
No nesting — `IrrigationSystem.Config.decay.BASE_RATE` would be the only access pattern of its kind
in the mod. No `IRRIGATION_` prefix; the table name already namespaces them.

**Authored in percentage points, not the 0–1 internal scale.** `MAX_BOOST = 0.05` three lines above
`DECAY_PP_PER_DAY = 2.5` is a 100× error waiting to happen. Storage stays 0–1 per `CLAUDE.md`;
conversion happens at the point of use.

```lua
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
```

**`HA_PP_PER_HOUR` is derived, not authored** — it follows the player's capacity setting:

```lua
haPpPerHour = (irrigationContractorCapacity * MAX_BOOST_PP) / DAILY_CAPACITY_H
-- default: (8 * 5.0) / 10 = 4 ha*pp per hour
```

`DAILY_CAPACITY_H` stays authored: it is the working-window length, not a rate.

**Not XML, deliberately.** Weather profiles earn XML because they are regional content with nine
variants and a live modSettings override path. Irrigation economics is one global table of scalars
with no variants — XML would buy a loader, a schema, hostile-value validation and a sync question
in exchange for an authoring demand nobody has voiced. If that demand appears, the modSettings scan
already exists and these numbers can move without redesigning anything.

---

## 5. Settings

Three player-facing settings, all following `sellDryingChargeRate` exactly: `serverOnly = true`,
`permission = 'moistureSettings'`, added to `MoistureSettings.menuItems`, to `MoistureSettingsEvent`
(write/read/run), to `InitialClientStateEvent`, and to the savegame as nil-guarded reads under
`MoistureSystem.SaveKey .. ".settings#<name>"` so pre-feature saves load unchanged. **No new event,
no new permission.**

| Setting | Values | Default | Type in event |
|---|---|---|---|
| `irrigationCostMultiplier` | `{0.5, 1.0, 1.5, 2.0}`, shown `"0.5x".."2x"` | index 2 (1.0×) | `Float32` |
| `irrigationContractors` | `{1, 2, 3, 4, 5}` | index 1 (**one contractor**) | `Int32` |
| `irrigationContractorCapacity` | `{4, 8, 12, 16}` ha/day at full strength | index 2 (**8**) | `Int32` |

**The cost multiplier scales the whole quote, minimum callout included, applied last** — after the
short-notice multiplier. A "half price" setting that still charged a full-price minimum callout on
small fields would read as a bug. **Booked jobs keep their agreed price**: the accepted quote is
stored on the job record, so a mid-game change affects only future bookings.

**Capacity values are round in both units** — 4/8/12/16 ha is 10/20/30/40 acres — so
`g_i18n:getArea()` / `getAreaUnit()` render cleanly for imperial players with no second value set.
Default 8 reproduces exactly the behaviour every number in this spec was measured against
(`40 ha·pp/day ÷ 5pp cap = 4 ha·pp/hour`).

**Rejected settings, and why** — do not add them back without redoing the balance work:

- A **decay-rate or boost-cap** setting. Those change the *shape* of the mechanic the rest of this
  spec reasons about, not its difficulty.
- An **`irrigationEnabled` on/off switch.** Irrigation is opt-in by construction — a player who
  does not want it never books. This is unlike bale rot or withering, which happen *to* the player
  and therefore need an off switch.

**Currency needs no handling.** `I18N:formatMoney` (`Reference/FS25_Lua/I18N.lua:454`) swaps the
symbol with `moneyUnit` but **never converts the number**. The figures above are raw game-currency
values, correct as authored.

---

## 6. State and savegame

### Two tables, no state enum

```lua
self.boosts = {}   -- [farmlandId] = { value = 0.021, graceUntil = <hour stamp or nil> }
self.jobs   = {}   -- [farmlandId] = { targetBoost, startDay, startHour, hours,
                   --                  hoursWorked, price, paid, contractorIndex }
self.diarySeed        = <int 1..1000000>
self.anyActiveBoosts  = false
```

The forcing case was a farmland with a +2.1% boost still decaying from last month **and** a new job
booked for Thursday. Separating boost from job makes that one boost record plus one job record,
rather than one record trying to be both.

**No `state` field.** A job is *running* iff `hoursWorked > 0`, *pending* otherwise, and *gone* when
complete — deleted, having emptied itself into the boost.

**One pending job per farmland.** `jobs` is keyed by farmland id, not a list. Keeps the UI row
unambiguous and the additive top-up rule already lets the player re-book once one finishes. A queue
mostly buys the ability to overshoot the cap by accident.

**`job.startDay` is an `Environment.currentMonotonicDay`**, never `currentDay` — see §7.

**Boost values are 0–1**, matching the mod's existing convention. Percentage points appear only at
the GUI and the tunables block.

**Self-pruning.** A boost that drains below `0.001` is **deleted**, so the table empties itself and
`anyActiveBoosts` clears on its own.

### Savegame

Nested under the existing `MoistureSystem.SaveKey` in the single `MoistureSystem.xml`, with
`IrrigationSystem:saveToXMLFile(xmlFile, key)` / `loadFromXMLFile(xmlFile, key)` called from
`MoistureSystem:saveToXmlFile` / `loadFromXMLFile`. Indexed-element shape as `DryingSystem` uses
(`src/DryingSystem.lua:411`):

```
MoistureSystem.irrigation#diarySeed
MoistureSystem.irrigation.boost(i)  #farmlandId #value #graceUntil
MoistureSystem.irrigation.job(i)    #farmlandId #targetBoost #startDay #startHour
                                    #hours #hoursWorked #price #paid #contractorIndex
```

`hoursWorked` and `paid` persist so a save mid-ramp resumes exactly where it stopped. **`paid`
exists as a stored flag precisely so that billing once at booking cannot be repeated on reload** —
double-billing becomes structurally impossible rather than a thing to remember.

**Backward compatibility is free.** `loadFromXMLFile` already guards on `fileExists` and every read
is nil-guarded; an absent `irrigation` section leaves both tables empty, which is the correct
pre-feature state. No migration, no version stamp.

### Selling a farmland

Subscribe to `MessageType.FARMLAND_OWNER_CHANGED` (published from `economy/FarmlandManager.lua:335`
with `(farmlandId, farmId, loadFromSavegame)`). On a real ownership change, **delete both
`boosts[farmlandId]` and `jobs[farmlandId]`**. No refund of any kind — see §9.

Two guards, **both required**:

1. Ignore when the message's `loadFromSavegame` arg is true.
2. **Also ignore unless `g_currentMission.MoistureSystem.missionStarted` is true** (`src/main.lua:85`,
   set at `:770`). This closes a gap the first guard does not: `MoistureSystem:loadFromXMLFile` runs
   at `loadMap` (`:130`), long before `onStartMission`, so ownership restores during load can fire
   while our state is still half-built. Precedent: `CombineExtension.lua:25`,
   `FillVolumeExtension.lua:25`.

---

## 7. The contractor diary

### The model in one line

The diary is **generated, never stored**. A day's committed load is a pure function of *which* day
it is (its intrinsic character) and *how far away it is right now*, so it tightens on its own as it
approaches, and re-asking on the same day always gives the same answer. This is what satisfies the
"availability is state, not a dice roll" requirement.

### Capacity and window

| | Value |
|---|---|
| Daily capacity | **10 working hours** (`DAILY_CAPACITY_H`) |
| On-site window | **06:00 – 18:00** |
| Granularity | **whole hours everywhere**; job duration rounds **up** |

Commitments are placed from the **start** of the window: the contractor does their pre-existing
work first, then yours. A day with 4h committed gives the player a start time of **10:00**. This is
what turns an hour count into a displayable start/finish time.

Note honestly: with capacity (10h) below window length (12h), **the window never actually binds** —
capacity always runs out first. It is kept because it fixes start times and guarantees jobs never
run overnight. If `DAILY_CAPACITY_H` is ever tuned above 12, the window becomes a real second
constraint and the booking check must test both.

### The generator

```lua
local function hash01(seed, day)
    local h = (seed * 2654435761 + day * 40503) % 2147483647
    h = (h * 1103515245 + 12345) % 2147483647
    return h / 2147483647
end

-- per contractor, per day:
jitter         = (hash01(diarySeed, targetMonotonicDay * 8 + contractorIndex) - 0.5) * (2 * DIARY_JITTER)
meanCommitted  = DIARY_FLOOR + DIARY_SPAN * math.exp(-daysAhead / DIARY_TAU_DAYS)
committed      = math.clamp(meanCommitted + jitter, 0, 1)
committedHours = math.floor(DAILY_CAPACITY_H * committed + 0.5)
freeHours      = DAILY_CAPACITY_H - committedHours - bookedHours(contractorIndex, day)
startHour      = DAY_START_HOUR + committedHours + bookedHours(contractorIndex, day)
```

Use an **integer hash, never `math.random`** — the whole design rests on this being reproducible.
The `* 8 + contractorIndex` fold is safe because the index is always below 8.

`meanCommitted` is **shared by every contractor**; they differ only by their per-day jitter, which
is exactly what makes the best of N meaningfully freer than one.

The gradient **saturates at 12%** committed, so beyond ~5 days out every day looks the same. This
matters because the bookable window is variable in days — without saturation, a player on 12-day
months would see a month of implausibly empty diary.

Resulting shape at `DAILY_CAPACITY_H = 10`:

| Days ahead | Mean committed | Typical free hours |
|---|---|---|
| 0 (today) | 85% | 0 – 4.5h |
| 1 | 53% | 1.7 – 7.7h |
| 2 | 35% | 3.5 – 9.5h |
| 3 | 25% | 4.5 – 10h |
| 5+ | ~14% | 5.6 – 10h |

**Today, in practice (one contractor):** ~27% of days fully booked, ~32% with 0.5–2h free — visible
but under the minimum, so unbookable — and ~41% genuinely bookable. Roughly **two days in five you
can irrigate today**; when you can't, booking two days out always fixes it. A hard availability
floor was **rejected**: a fully booked day is a real event, not a freak one.

### The seed

A `diarySeed` integer (1..1,000,000) generated once at `IrrigationSystem` init and persisted (§6).
Rejected alternatives: `missionInfo.savegameIndex` moves on "Save As", silently reshuffling the
entire diary; a fixed constant gives every save on earth an identical diary; a runtime RNG fails
the stable-under-reload requirement outright.

### The roster

`irrigationContractors` (1–5, default 1) sets how many contractors exist. **Each has an independent
diary**, all from the same single `diarySeed`. Booked hours are tracked **per contractor per day**.

**One job uses exactly one contractor.** They never pool onto a field. Pooling was rejected because
it collapses the setting into a capacity dial — three contractors at 10 hours is arithmetically
identical to one at 30, obtainable by editing `DAILY_CAPACITY_H` with none of the machinery. Under
one-job-one-contractor the setting means what the capacity number cannot express: **how many jobs
can run at once**, which is the actual large-map problem.

**Assignment is automatic, tightest fit, and never shown:**

```
needed      = max(MIN_JOB_HOURS, ceil(fieldHa * boostPP / haPpPerHour))
assignedTo  = argmin(freeHours) over { c : freeHours(c) >= needed }   -- ties: lowest index
```

Tightest fit rather than most-free, so an exact-fit job does not consume a contractor who could
have taken a larger one. **Contractors are anonymous** — no names, no identities, nothing in the UI.
The job record carries `contractorIndex` for capacity accounting only.

**Auto-deriving the count from map size was rejected** — a 200-farmland map played solo by someone
farming three fields wants one contractor, not four.

What the roster actually buys (best-of-N free hours / share of days clearing the 2h minimum,
200k samples per cell, no player bookings):

| contractors | today | +1 day | +2 days | +3 days |
|---|---|---|---|---|
| 1 | 1.7h / 50% | 4.7h / 100% | 6.5h / 100% | 7.5h / 100% |
| 2 | 2.5h / 75% | 5.7h / 100% | 7.4h / 100% | 8.5h / 100% |
| 3 | 3.0h / 87% | 6.2h / 100% | 7.9h / 100% | 8.9h / 100% |
| 5 | 3.4h / 97% | 6.7h / 100% | 8.4h / 100% | 9.4h / 100% |

**The roster's effect on *whether* you can book is almost entirely same-day.** Beyond today it buys
**hours** (a higher boost ceiling on large fields) and **parallelism** (after you book one field the
others are still free) — the latter invisible to this table, which models one booking.

### Bookable window

**Current month plus the next two** (`BOOKABLE_MONTHS = 2`). Month picker, then day picker, with
days already past excluded — deliberately mirroring the existing Forecast tab, so a player who sees
July will be dry can book for it from May.

The window is **variable in days**: 3 at the default 1 day/month, up to 36 at 12 days/month.

**All day arithmetic uses `Environment.currentMonotonicDay`, never `currentDay`.** `currentDay` is
*rescaled* when the player changes days-per-month mid-game (`Environment.lua:412-414`);
`currentMonotonicDay` is not. Using `currentDay` would reshuffle the whole diary and misdate every
booked job the moment a player touches that setting.

### Contention

The player's own booked hours subtract from the same pool. Without this the diary is not a
constraint at all, merely a price modifier.

**One shared diary — one shared roster — per server.** Every farm competes for the same
contractors. Per-farm diaries would make the contractor a per-player resource generator, which is
the dice-roll feel rejected at charting wearing a different hat.

**Booking early locks hours in.** A job booked when a day was clear holds its hours in the `jobs`
record; the day tightening as it approaches cannot take them back. The reward for planning ahead
falls out of the model rather than being engineered in.

---

## 8. Booking: pricing, duration, and the moving ceiling

### Duration

```
neededHours = max(MIN_JOB_HOURS, ceil(fieldHa * boostPP / haPpPerHour))
```

Area is **`farmland:getField():getAreaHa()`** — the crop polygon (`field/Field.lua:159`, computed
from `MathUtil.getPolygon2DSize`), *not* `Farmland.areaInHa`, which is the purchasable parcel
including verges, tracks and woodland.

**`MIN_JOB_HOURS` consumes 2 diary hours as well as charging for them.** It is a callout, not an
accounting rule: a job needing 20 minutes of pumping occupies 2 of that contractor's 10 hours and
blocks other bookings accordingly. Charging for time that isn't occupied would be a fiction.

### Price

```
base   = max(MINIMUM_CALLOUT, RATE_PER_HA_PP * fieldHa * boostPP)
sn     = 1 + (SHORT_NOTICE_MAX - 1) * (1 - min(daysAhead, SHORT_NOTICE_DAYS) / SHORT_NOTICE_DAYS)
total  = base * sn * irrigationCostMultiplier
```

Billed **once, at booking**, to `MoneyType.IRRIGATION` (§13), tracked by `job.paid`. There is no
per-hour billing, no cancellation and no refund, so nothing reopens this.

The short-notice ramp always fits the bookable window: the window is at minimum exactly 3 days and
grows from there, so on default settings the furthest bookable day is precisely the 1.0× day —
"book the far end of the window, pay list price". No scaling by month length, no special cases.

### There are no partial jobs

**The boost selector is clamped to what the day can actually deliver.** You ask for +1.0%, you pay
for +1.0%, you get +1.0%.

```
dayCeiling  = floor( maxFreeHours * haPpPerHour / fieldHa / BOOST_STEP_PP ) * BOOST_STEP_PP
selectorMax = min( dayCeiling, MAX_BOOST_PP - currentBoost )
```

`maxFreeHours` is the **best any contractor has** that day; the clamp then guarantees `needed` is
satisfiable by at least that one, so the tightest-fit set is never empty.

**Truncation** (ask for more, get less, confirm the gap) reaches the identical game state dressed
as a disappointment and needs a confirmation dialogue purely to stop it reading as a rip-off.
**Spill** (contractor returns tomorrow) was rejected as real complexity — a job with a gap in it,
tomorrow's capacity re-checked at booking time, a job record spanning days — for a case clamping
already handles. The gameplay is preserved exactly: a busy day means a smaller boost, so the choice
is "less water today" against "more water Thursday", expressed as a ceiling rather than a shortfall.

**A day is unbookable when `selectorMax` is 0**, from either cause — under 2 free hours, *or*
enough hours but a field too large for one 0.5% step (3 free hours on 40 ha is +0.3%). **One
player-facing message covers both**, because they are the same thing from where the player sits,
and **it must state the reason** — never merely grey the day out.

### Field size caps the boost, and that is kept

At the default capacity one contractor's completely free day is 40 ha·pp:

| field | max boost from one contractor's full day |
|---|---|
| 5 ha | +5.0% (reaches the cap) |
| 10 ha | +4.0% |
| 20 ha | +2.0% |
| 40 ha | +1.0% |

So above ~8 ha the +5.0% cap is **unreachable in a single booking**. Raising the work rate was
considered and **rejected**: field size mattering is the point, and it is what makes a large field
an expensive multi-day commitment rather than a bigger invoice for the same convenience. The table
scales with the capacity setting and is per contractor.

---

## 9. Job execution

Each game hour, on the server, for each job whose start time has arrived:

1. Add `targetBoost / hours` to `boosts[farmlandId].value` (creating the record if absent).
2. Increment `hoursWorked`.
3. When `hoursWorked >= hours`: set `boosts[farmlandId].graceUntil = now + GRACE_HOURS`, **delete
   the job**, and fire the completion notification (§15).

**The boost accrues hourly rather than landing atomically.** This makes duration visible, makes
late joiners correct by construction (a half-finished job has already banked its accrued boost),
and means decay never fights the ramp.

**Stacking is additive**, up to `MAX_BOOST_PP`. Re-irrigating tops up. **A top-up restarts the
grace period on the whole accumulated boost** — one `graceUntil` per farmland, not per job; per-job
grace tracking would turn the accumulator into a list.

**Interruptions:**

- **Mid-job farmland sale — no refund, not full, not pro-rata.** Cancellation does not exist, so
  refunding a sale makes selling a back-door cancel. The contractor's hours stay consumed. Both
  records are deleted (§6).
- **Harvesting, ploughing or cultivating mid-job does nothing at all.** Irrigation writes parcel
  moisture and is indifferent to crop state or growth stage. Stated so the implementation session
  does not go looking for an interaction that isn't there.
- **Lowering `irrigationContractors` or `irrigationContractorCapacity` mid-game**: jobs on a
  contractor who falls off the roster **run to completion normally**; clamp free hours to zero
  where capacity dropped below hours already booked. **Never re-home consumed hours onto a
  surviving contractor** — that would let the player move a setting to free hours they had already
  spent.

---

## 10. Decay

Per game hour, per farmland with a live boost, on the server:

```lua
if hoursSinceJobCompleted < GRACE_HOURS then
    -- boost holds at full strength; nothing drains
elseif not isRaining then                       -- getRainFallScale() > 0.1, per GroundPropertyTracker
    local temp     = weather.temperatureUpdater.currentTemperature or 20
    local tempMult = math.max(DECAY_TEMP_MIN,
                     math.min(DECAY_TEMP_MAX, temp / DECAY_TEMP_REF))
    local drainPP  = (DECAY_PP_PER_DAY / 24) * tempMult
                     / math.min(daysPerPeriod, DECAY_DPP_CAP)
    boost.value = math.max(0, boost.value - drainPP / 100)
end
```

**Linear, not exponential** — tested both; exponential at K=1.0 reproduces linear at K=0.5 almost
cell-for-cell, and the gentle tail costs the hard cutoff that makes "the boost is gone" legible.

**Rain pauses decay; it does not top the boost up.** Topping up would double-count — rain already
raises the base moisture the boost sits on. Worth ~15–25% of lifetime.

**Month length divides exactly** (`/ min(daysPerPeriod, 5)`), *not* by the field sim's
`1/dpp^0.7`. That makes lifetime-measured-in-months invariant to the player's month-length setting.
The field sim's exponent exists to keep moisture chasing its clamp, a different job, so diverging is
deliberate.

**Coupling decay to the field sim's existing drying rate was tested and rejected.** That rate spans
0.6 pp/day (ukwest Jan) to 18.6 (mediterranean Jul) — a 30× swing that proportional coupling turns
into a 30–40× swing in lifetime: 5 hours in mediterranean July (the boost dies faster than the job
takes to apply it, in exactly the month a player would pay for it) against 7.7 game days in ukwest
October. Inversely useful. An absolute base rate with a **compressed** temperature term makes the
hot/cool spread a number we choose (5×) rather than one inherited from a curve tuned for another job.

Resulting lifetimes of a +3% boost (game days; == months at the default `daysPerPeriod = 1`):

```
  profile           Jan   Feb   Mar   Apr   May   Jun   Jul   Aug   Sep   Oct   Nov   Dec
  ukwest            3.3   3.0   2.4   2.0   1.6   1.4   1.3   1.5   2.4   3.5   4.0   3.6
  ukeast            3.1   2.7   2.3   2.0   1.5   1.4   1.3   1.4   2.1   3.0   3.3   3.2
  centraleurope     3.3   3.0   2.5   2.0   1.7   1.4   1.3   1.4   1.9   2.9   3.5   3.5
  mediterranean     2.4   2.2   1.8   1.4   1.1   0.9   0.8   0.8   1.4   2.0   2.5   2.5
  usmidwest         3.4   3.2   2.7   2.2   1.6   1.4   1.2   1.2   1.6   2.7   3.3   3.4
  uspnw             3.4   3.0   2.3   1.8   1.4   1.2   0.9   0.9   1.5   3.2   4.0   3.8
  eastasia          2.8   2.4   2.0   1.5   1.4   1.5   1.4   1.3   1.4   2.0   2.7   2.8
  brazilcentral     1.6   1.4   1.2   1.0   1.0   0.9   0.9   0.8   1.0   1.2   1.4   1.5
  brazilsouth       1.4   1.4   1.4   1.5   1.8   2.0   1.8   1.7   1.7   1.5   1.5   1.5
```

The model is reproducible: `.scratch/irrigation/prototypes/PROTOTYPE-decay-curve-sim.py`
(gitignored — it lives with the design map, not the mod).

---

## 11. Moisture injection and the cache

### Injection point

**One block at the end of `MoistureSystem:getMoistureAtPosition`, outside *both* height branches**,
immediately before the cache store:

```lua
local irrigation = g_currentMission.irrigationSystem
if irrigation ~= nil and irrigation.anyActiveBoosts then
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    local boost = irrigation.boosts[farmlandId]
    if boost ~= nil then
        moistureLevel = math.min(1.0, moistureLevel + boost.value)
    end
end
```

**Do not add it "after the clamp".** The month clamp lives *inside* `if heightRange > 0`; the
`else` branch (`src/main.lua:346`) returns with no clamp at all, so "after the clamp" would silently
skip the flat-map path. Adding it after the whole height block gives both paths identical treatment.

### Not clamped to the profile; clamped to 1.0

**The boost is deliberately not subject to the month's `moistureMax`.** In a hot dry August the
ceiling is low, so clamping would eat most of what the player bought with no way to tell before
booking that it would be wasted — irrigation would be useless in exactly the months it is wanted.

The `math.min(1.0, …)` is future-proofing only: at the +5.0pp cap against a ~40% wettest profile
clamp the realistic worst case is ~45%, so it never bites in normal play. It exists so that raising
`MAX_BOOST_PP` later cannot produce a nonsense value.

**Nothing downstream needs changing** — verified, not assumed:

- `CropValueMap.curveFraction` clamps `t` to `[0,1]`, so `getQualityValue` and `getYieldMultiplier`
  **saturate** above the band rather than running away. Over-watering costs grade, as intended, and
  is bounded.
- `WitheringSystem` (`:144`, `:180`) only tests `moisture >= witherThreshold`. Higher is trivially
  safe.
- `GroundPropertyTracker` (`:1089`) re-clamps to `MIN_GRASS_MOISTURE` / `MAX_GRASS_MOISTURE`.

### The whole parcel is wetted

`getMoistureAtPosition` is called at arbitrary positions — verges, grass strips, yard — not only on
the crop polygon. Since the boost is keyed by farmland, **the entire parcel gets it, and no
field-boundary test is added**: the parcel is what the player buys and pays for, the field dominates
its area anyway, and a boundary test on the hot path costs more than the incoherence it removes.

Consequence: irrigation also keeps **grass** damp, so it makes hay harder to dry. That is a downside
the player absorbs, not a balance surface.

### Cache

The cache is **10 entries** (`src/main.lua:128`), keyed on a 5m-rounded position, **FIFO not LRU**,
and already discarded wholesale in `adjustMoisture` (`:300`) on most weather ticks.

Extract that two-line wipe into **`MoistureSystem:invalidateMoistureCache()`** and have
`IrrigationSystem` call it **once at the end of its hourly sweep** — not once per farmland. Keys are
positions, so an entry can never be served for the wrong farmland; staleness across *time* is the
only failure mode. Putting the farmland id in the key, or bypassing the cache for irrigated
farmlands, is machinery for ten values.

### Lookup cost

`FarmlandManager:getFarmlandIdAtWorldPosition` (`economy/FarmlandManager.lua:290`) is a coordinate
transform plus `getBitVectorMapPoint` — no iteration, no allocation. With `anyActiveBoosts`, the
cost when nobody is irrigating is **one boolean read**. No id memoisation, no second cache.

---

## 12. Multiplayer

### Cancellation does not exist

**A booked job cannot be cancelled.** Once the server accepts, the money is gone and the job runs.
Deliberate: the diary is the scarce resource, and free cancellation would let a player hold slots
against other farms at no cost.

### Events

| Event | Direction | Payload |
|---|---|---|
| `IrrigationBookRequestEvent` | client → server | farmland id, target boost (pp), day, start hour |
| `IrrigationBookResultEvent` | server → **requester only** | accepted flag; on reject, a reason code |
| `IrrigationJobBookedEvent` | server → **all** | farmland id, day, hours consumed, contractor index, farm id |
| `IrrigationBoostUpdateEvent` | server → all, hourly | farmland id + float per irrigated parcel |

Three single-purpose events rather than `DryingToggleEvent`'s "one event, direction inferred from a
nil field" shape. That works for a toggle, which cannot fail; booking *can* fail, so the reply must
carry an outcome the request never has. On single-player or a listen-server host the request path is
a **direct call, no event**, matching how `toggleDrying()` is called directly for the server player.

`IrrigationJobBookedEvent` carries the **contractor index** — without it a client cannot tell
whether 6 consumed hours are one contractor's afternoon or six contractors' first hour, and its
diary misrenders.

### Farmland ids go on the wire directly

`CLAUDE.md`'s rule against sending `uniqueId` **does not apply**. Farmland ids are assigned from map
XML and are identical on every peer; the base game sends them itself
(`economy/FarmlandStateEvent.lua`):

```lua
streamWriteUIntN(streamId, self.id, g_farmlandManager.numberOfBits)
```

Use exactly that, including `g_farmlandManager.numberOfBits` rather than a hardcoded width. Farm ids
use `FarmManager.FARM_ID_SEND_NUM_BITS`. `NetworkUtil.getObjectId` is not involved.

### Server authority and rejection

The client computes a quote to display; the server recomputes from its own diary and prices and
**never** trusts the client's figures. Because the diary is shared, a slot can go during the network
hop — expected traffic, not an error.

**On any mismatch the server rejects and books nothing. It never silently corrects** — money must
not leave the account at a price the player did not see. Reason codes:

| reason | meaning |
|---|---|
| `SLOT_TAKEN` | capacity went during the hop — the common case, and also any roster-level clash |
| `INSUFFICIENT_FUNDS` | checked server-side at acceptance |
| `NO_PERMISSION` | see below |
| `PRICE_CHANGED` | the cost multiplier setting changed mid-flight |
| `INVALID` | unowned farmland, no field, boost above cap — malformed or stale client |

The GUI re-quotes on reject.

**Which contractor gets a job is the server's decision.** The client sends farmland, boost, day and
start hour; the server runs tightest fit and assigns. The client never names a contractor, so there
is no new way to disagree and no extra reason code.

Server-side capacity validation is **load-bearing**, not belt-and-braces: it is the only thing
preventing a double-booked contractor.

### Permission

```lua
g_currentMission:getHasPlayerPermission(Farm.PERMISSION.HIRE_ASSISTANT, connection, farmId)
```

Chosen over `MANAGE_CONTRACTING`, which reads closer by name but is bound to the base game's NPC
contract system. `HIRE_ASSISTANT` is already the permission for *spending farm money on someone
else's labour*. This departs from `DryingToggleEvent`, which has no check — justified because drying
toggles a placeable the farm already owns, while irrigation moves money out.

### Initial state and ongoing sync

**Initial state rides the existing `MSInitialClientStateEvent`** — no new event. Exactly three items:

1. **Boosts** — farmland id + float, only for non-zero boosts. Sparse, usually empty.
2. **`diarySeed`** — one integer, which regenerates the entire roster's diary for the whole bookable
   range for free.
3. **Booked hours** — day + contractor index + hours consumed, for booked days in the bookable
   window. The one genuinely un-derivable piece, since player bookings consume the same pool. **Whose
   farm booked it is not sent** — the diary shows how many hours are free, not who took them.

**Other farms' jobs are never synced.** A client needs only its own farm's pending job to render its
tab.

**Ongoing:** the hourly boost push (server→all, boost values only, ~50 bytes per game hour) and
`IrrigationJobBookedEvent` on booking. **On receiving a boost update the client must bin its own
moisture cache**, exactly as `MoistureUpdateEvent:run` already does — without that the sync lands
but the meter still shows the old figure. Load-bearing, not hygiene.

**Clients must generate diaries for exactly the server's contractor count**, which reaches them as a
setting through the normal settings path — a client generating five when the server has one would
quote slots the server rejects.

**Late joiners mid-job are correct by construction**: the hourly ramp has already banked accrued
boost into `boosts`, and remaining hours arrive through the normal push. No replay, no special case.

---

## 13. Money type

Register a dedicated **`MoneyType.IRRIGATION`**, stat name **`irrigation`**. `PURCHASE_WATER` exists
but is the same finance row as livestock drinking troughs, and irrigation is a recurring seasonal
expense the player is meant to weigh against crop revenue — it cannot be weighed if it is invisible.

Four coupled pieces, in `src/extensions/I18NExtension.lua`:

```lua
-- 1. finance row -- REQUIRED GUARD, do not copy the existing dryingCharge line verbatim
if FinanceStats.statNameToIndex["irrigation"] == nil then
    table.insert(FinanceStats.statNames, "irrigation")
    FinanceStats.statNameToIndex["irrigation"] = #FinanceStats.statNames
end

-- 2. the money type
MoneyType.IRRIGATION = MoneyType.register("irrigation", "ms_ui_irrigation")

-- 3. NOT superstition: MoneyType.reset() (MoneyType.lua:48-51) rewinds the module-private
--    counter to LAST_ID. Without this bump, a reset rewinds below the mod's id and the next
--    registration collides.
MoneyType.LAST_ID = MoneyType.LAST_ID + 1

-- 4. BOTH keys go in MSI18NExtension.texts. FinanceStats.new calls
--    g_i18n:getText("finance_" .. statName) with NO modEnv (FinanceStats.lua:78), so a mod
--    l10n key cannot resolve without the whitelist redirect. Hence two keys, identical text.
```

The guard in step 1 matters because `FinanceStats` is a base-game class living for the whole
process while `extraSourceFiles` re-execute on every mission load — returning to the menu and
loading a second save would otherwise append the row again. (The existing `dryingCharge` line has
this bug; it is pre-existing and out of scope, so fix it there separately, but **do not propagate
it**.)

**The stat name is effectively permanent**: `FinanceStats:saveToXMLFile` writes one XML attribute
per stat name, so renaming later silently zeroes a player's history.

---

## 14. The Irrigation tab

New frame `MoistureGuiIrrigation` (`.lua` + `.xml`), registered in `MoistureGui:setupPages`
(`src/gui/MoistureGui.lua:33`), reusing the already-loaded `grainDrying.dds` icon (`:34`) so the
icon can be swapped by dropping in a file, with no code change.

Rough layout is in `.scratch/irrigation/prototypes/PROTOTYPE-irrigation-tab.html` — a throwaway on a
1400×750 canvas (the real `uiInGameMenuFrame` content area) driven by the actual generator and
pricing formulae. It carries three rejected alternatives (list+detail, wizard, inline expand) for
reference.

### Layout — diary first

The **day cards are the page**, not a widget inside it.

```
[ farmland dropdown ]  [ current boost ]        [ Jul ][ Aug ][ Sep ]
+--------+--------+--------+--------+--------+
| Today  | Tomorr | Jul 3  | Jul 4  |  ...   |   <- one card per bookable day
| 2h     | 6h     | 8h     | 9h     |        |   free hours = headline figure
| ##     | ######  ...                           proportional bar vs capacity
| +0.5%  | +2.0%  | +2.5%  | +2.5%  |        |   largest boost those hours buy
| L826   | L714   | L649   | L612   |        |   price for that boost
| +35%   | +23%   | +12%   | list   |        |   premium line, always present
+--------+--------+--------+--------+--------+
  [ amount stepper + quote + Book button ]   [ jobs panel ]
```

**Every card is rendered for the currently selected farmland**, which is the decisive property: the
player reads "today £826 rush / three days out £612 list" off one screen, without a click per day.
The list-plus-detail shape of `MoistureGuiDrying` was rejected despite being the local precedent —
that precedent is for a page whose subject is *the list*, and irrigation's subject is the **diary**.

Farmland selection is therefore a **dropdown, not a list** — the one deliberate departure from the
mod's existing tab shapes. The page needs **no `SmoothList`**: the selector is a `multiTextOption`,
the day cards are a generated row of panels, the jobs panel is a short generated list. This is a
different construction from every existing tab; budget for it.

Changing farmland or amount **re-renders every card** (each carries a farmland-dependent price).
Cheap — at most 36 — but the card is not a static widget.

The list excludes farmlands the farm does not own and those whose `getField()` is nil (yard and
woodland parcels). Source: `FarmlandManager:getOwnedFarmlandIdsByFarmId(farmId)`.

### Day cards

Top to bottom: day label (`Today` / `Tomorrow` / `Jul 3`), **free hours as the headline**, a
proportional bar against `DAILY_CAPACITY_H`, the per-farmland line (`up to +2.5%` / price), then the
premium line.

The bar is what makes the near/far gradient legible — a row of cards filling left to right *is* the
`meanCommitted` curve, so the player infers "book further out, get more" without being told.

**The premium line is always present**, reading `list price` on far days rather than being blank. A
premium shown only when charged reads as a penalty; shown against a stated list price it reads as a
discount for planning, which is the behaviour the ramp is buying.

**Unbookable days are dimmed but still show their real free-hours figure**, with the card body
replaced by the shared short message. Selecting one is a no-op on the card but fills the quote area
with the long form **naming the cause** (`Only 1h free — a job needs at least 2h` / `4h free covers
less than 0.5% on 14.7 ha`). Never merely greyed.

**Contractors stay invisible** at every roster setting — one figure per day, the best any of them
has.

### Amount stepper

`◀ +2.5% ▶`, `BOOST_STEP_PP` increments, clamped per §8. An **arrow stepper**, not a button row or
slider, because the ceiling **moves as the player moves between days** and the stepper is the only
one of the three with no invalid state to render: it simply stops. On a 14.7 ha field a button row
would be nine-tenths greyed; a slider's range would change length under the player's thumb. It is
also the FS25 house control (`multiTextOption`), so it is gamepad-native.

Beneath it, one grey line states the ceiling **and why**: `max +2.5% on this day — limited by
contractor hours` vs `— limited by the +5.0% cap`. Without the cause, a clamped selector looks broken.

### Quote

Six lines, in order:

1. Work — `2.5% over 4.3 ha`
2. On site — `Thursday, 11:00–14:00 (3h)`
3. `Contractor rate` **or** `Minimum callout` — the label changes when the floor binds, so a small
   field's price stops looking arbitrary
4. `Short notice +35%` as its own money line, when it applies
5. `Cost setting 1.5x`, when not 1×
6. **Total**

Then a final line showing what is actually being bought: `+1.0% → +3.5%`. No shortfall line — there
are no partial jobs.

### No confirmation dialog

**The Book button books.** There is no cancellation and no refund, so a stray click is unrecoverable
spend — this was raised as a risk and the decision taken anyway, because the full quote is already
on screen at the moment of the click and a dialog would restate what the player is looking at.

**The mitigation is part of the decision, not a nicety: the price rides on the button label** —
`Book — £612`, updating live with day, amount and both settings. The sum is inside the click target,
which is where a confirmation dialog was going to put it anyway.

No `YesNoDialog` wiring; `IrrigationBookRequestEvent` fires straight from the button press.

### Jobs panel

Beside the quote, listing every farmland with a boost or a booked job: name, and either
`job Thursday 11:00` or `+2.5% · 1.0d`. Whole-farm state at a glance without paging the dropdown.
**It is the only place decay time remaining appears**, so it is not optional decoration. Empty
state: `Nothing irrigated.`

---

## 15. Notification and HUD

### Two notifications, and only two

Job **start** and job **finish**, via the mod's existing pattern:

```lua
g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
```

- start — `Halstead Farmland: irrigation started, +2.0% over 4h`
- finish — `Halstead Farmland: irrigation complete, +2.0%`

Name from `Farmland:getName()`. **The noun is farmland, never field.** The finish figure is **this
job's delivered amount**, not the farmland's total boost, which may be higher after a top-up —
phrase the string so that reads correctly.

**Decay-to-zero deliberately gets no notification.** It is the only bad news irrigation has, but at
mediterranean's 0.8-day lifetimes a player holding three farmlands would get ~3 per game day, every
day — the volume that trains a player to dismiss the mod's notifications wholesale, including the
two that matter. The countdown lives in the jobs panel instead.

### Targeting: by farm, evaluated on arrival

The server tags each start/finish message with the **farm id that owns the job**; each client
compares it against **its own current farm at the moment the message arrives**.

Deciding this at booking time is wrong: a player can switch farms mid-game and would keep hearing
about the farm they left while hearing nothing from the one they joined. Comparing on arrival
handles both directions with no subscription list. These are hourly events, so they ride the hourly
boost push — one farm id on the wire, no new event.

**Other farms are never notified.** Their jobs are not synced, so a cross-farm message could say no
more than "someone booked something". They learn the honest way: fewer free hours on the day cards.

### HUD

The field-info box already appends a moisture line (`PlayerHUDUpdateExtension.lua:150`), which after
§11 silently includes the boost.

- **The existing line keeps showing the total.** The number is the real moisture.
- **Add a second line only when that farmland has a live boost**, breaking out how much was bought
  (`Irrigation: +2.0%`). Absent entirely at zero boost, so the non-irrigating player sees no change.

**The handheld moisture meter shows the total only**, no breakout. It is a single-line blinking
warning or notification (`HandToolMoistureMeter.lua:187-194`) with no room for a second line, and it
reads ground moisture at a point — the total *is* the honest answer to what it asks.

### No map indicator

`Farmland:getIndicatorPosition` and `FarmlandHotspot` exist, so it would be cheap. Rejected anyway:
the mod has never placed a hotspot, so it is a whole new surface, and irrigation wets the **whole
parcel** so a field-shaped marker would be slightly lying. The in-world answer already exists at the
point of use.

---

## 16. Console commands

In the style of the existing `msWeatherDebug` / `msSetScenario` (see the table in `CLAUDE.md`),
server-side:

| Command | Description |
|---|---|
| `msIrrigationDebug [farmlandId]` | Print a farmland's boost, `graceUntil`, and pending job; with no argument, every irrigated farmland |
| `msIrrigationDiary [daysAhead]` | Dump free/committed hours per contractor for that day, plus the seed |
| `msIrrigationBook <farmlandId> <boostPP> <daysAhead>` | Force-book, skipping payment and permission — for testing the ramp without waiting on money |

---

## 17. Localisation

All ten `languages/l10n_*.xml`.

**Settings** (each with a `_tooltip`):
`setting_moisture_irrigationCostMultiplier`, `setting_moisture_irrigationContractors`,
`setting_moisture_irrigationContractorCapacity`

**Money type** — both keys, identical text, for the reason in §13:
`ms_ui_irrigation`, `finance_irrigation`

**Notifications:** `ms_irrigation_started`, `ms_irrigation_complete`

**HUD:** `moistureSystem_irrigationInfo`

**Tab:** the tab title; column and section headings; `list price`; `Minimum callout`;
`Contractor rate`; `Short notice`; the cost-setting line; `Total`; the shared unbookable-day short
message plus a long form per cause (too few hours / field too large); the ceiling-reason line in
both forms (contractor hours / boost cap); the `Book — <price>` button label; the jobs-panel empty
state `Nothing irrigated.`; day labels `Today` / `Tomorrow`.

---

## 18. Deliberate non-decisions

Record these as decided. They will each look like an oversight to a fresh reader.

### Economics are flat and global — no regional variation

Irrigation constants are **not** keyed by weather profile, and `IrrigationSystem` never reads the
profile id for economics (only for decay's temperature and rain inputs). There is no
`PROFILE_OVERRIDES` table and no `<irrigation>` element in the profile XML.

**Aridity already charges the player twice**, in the currency that binds: a boost lasts 0.8 game
days in mediterranean against 3.5 in ukwest, so the arid player rebooks ~4× as often — and because
decay is absolute and pricing exactly linear in `ha·pp`, that rebooking converts directly into
*contractor hours consumed per hectare held*. A regional price multiplier would be a third charge
for the same fact, and the only one whose cause the player cannot see anywhere in the UI.

**Drought-scenario diary tightening was rejected too** — same double-charge on the time axis, and it
would cost the diary its purity as a function of one seed. The drought dial is the two player
settings, turned down by choice.

### Charged area can drift below wetted area

The job is costed and timed on `Field:getAreaHa()` — the map author's crop polygon, fixed at load —
while §11 wets the **whole parcel**. A player who ploughs extra farmable ground inside their parcel
gets it irrigated free, consuming no extra contractor hours.

**Accepted.** The alternative basis, `Farmland.areaInHa`, is the purchase parcel including verges,
tracks and woodland, and can be far larger than the crop polygon — it would overcharge every
ordinary player for ground irrigation cannot help, to close a loophole few will find. **Do not
"fix" this into an overcharge.**

### Withering gets no special case

`WitheringSystem` sees boosted moisture on exactly the same terms as every other consumer.

`witherThreshold` is only **0.02–0.03**, and mediterranean drought's July inner range is 1.4–4.6%,
so a **+2.0pp** boost clears drought outright — the +5.0% cap is a *grading* lever, not a drought
one. What holds the line is **contractor hours, not money**: holding a 10 ha field above the
threshold in mediterranean July costs 37.5 ha·pp/day ≈ **9.4 of a contractor's 10 hours**, about
£1,200 per game day. **One contractor covers one 10 ha field and nothing else.** Gaps in cover
wither at 30–100%/hour, so there is no cheap half-measure.

Excluding withering at the chokepoint would mean *adding* a special case asserting the ground is
wetter but the crop doesn't notice — incoherent, and it breaks the single-injection-point design the
rest of this spec rests on. Drought protection is the feature's headline selling point.

**Grass is not in `CropValueMap`** and never withers, so parcel-wide wetting has no drought loophole
there.

**State outright in any player-facing documentation: `irrigationContractors` × `irrigationContractorCapacity`
is the drought difficulty dial** — ~10 ha of drought-proof land at the 1/8 default, ~100 ha at 5/16.
Raising either is a balance change, not a convenience one, and the default of one contractor is a
deliberate choice rather than a conservative placeholder.

### The withering-disabled fallback, looked at and left

When `witheringEnabled` is off, two floors substitute for field damage:
`src/extensions/CutterExtension.lua:72` floors yield to 10% and `src/main.lua:587` floors quality —
both evaluated from moisture read *at harvest*, neither cumulative. A single cheap booking timed to
harvest day therefore cancels a 90% yield loss on that path.

Pre-existing property of the fallback, not something irrigation introduces. Making it stateful would
mean giving it the history tracking the real system has. **We looked and chose not to act** — recorded
so it is not rediscovered as a bug.

---

## 19. Out of scope

Not part of this feature. Each returns only as a separate effort.

- Visual water, sprinkler models, particle effects. This is a pure data operation.
- Player-owned irrigation equipment, pivots, purchasable machinery.
- Water source or volume simulation — no drawing from rivers, no per-litre water cost. Flagged as
  the most likely creep vector: a mod that models moisture this carefully will attract "but where
  does the water come from".
- AI/helper worker integration.
- Any direct manipulation of yield or growth stage. Those follow indirectly, via withering
  protection and harvest grading, and only via moisture.
- **The base sim's sub-zero drying bug.** `rate_factor` in `src/main.lua:250-261` is
  `temp × positive_coefficient`, so below 0 °C it returns negative and the field sim *gains*
  moisture in freezing dry weather (usmidwest Jan/Feb/Dec at −0.4/−0.3/−0.3 pp/day). A real defect
  in the existing weather sim. Irrigation decay is immune via `DECAY_TEMP_MIN` and its zero clamp.
- **The unguarded `FinanceStats.statNames` insert** at `src/extensions/I18NExtension.lua:5`. See §13
  — the irrigation registration is specified *with* the guard, so this spec does not propagate the
  bug, but fixing the `dryingCharge` line is its own change.

---

## 20. Suggested implementation order

Each step is independently testable; moisture only starts moving at step 4.

1. **Tunables block, state tables, savegame round-trip.** Subsystem registered, hourly tick wired,
   nothing does anything yet. Verify a pre-feature save loads clean.
2. **Diary generator** plus the `msIrrigationDiary` console command. Verify stability under reload
   and the distribution table in §7.
3. **Pricing, duration, clamping, tightest-fit assignment**, plus `msIrrigationBook`. Verify the
   field-size table in §8.
4. **Job ramp, decay, injection, cache invalidation.** Now moisture moves — verify against the
   lifetime table in §10.
5. **Money type and the three settings.** Verify the finance row appears and survives a menu round
   trip.
6. **The tab.**
7. **Notifications and the HUD line.**
8. **Multiplayer events**, then test on a dedicated server: two clients quoting the same slot, a
   late joiner mid-job, and a client switching farms mid-job.
9. **Localisation** across all ten files.
