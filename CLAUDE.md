# FS25_MoistureSystem

FS25 mod (Lua + XML) that adds moisture simulation, crop quality grading, bale rotting, grass drying, and silo drying to Farming Simulator 25.

## How to talk to me

Write like a person explaining something to a colleague, not like a design document.

- **Plain words.** Say "the price changes" not "a pricing delta is surfaced". Say "who's allowed to book" not "permission gating semantics".
- **Ask one thing at a time, and say what it means.** When you ask me to choose, describe each option by what actually happens in the game, not by its technical name. I should be able to answer without knowing the code.
- **Short.** If a question needs three paragraphs of setup, you haven't understood it well enough to ask it yet. Cut the setup, ask the question.
- **Don't pad.** No restating what I just said, no listing the options you already ruled out, no summarising your own summary.
- **Recommend, then explain.** Lead with what you think we should do and why in one line. I'll ask if I want the reasoning.
- **Answer the question I asked.** If I ask "how does X work", don't also tell me about Y.

## Architecture

`src/main.lua` — core `MoistureSystem` object, registered as a mod event listener. Entry point for field moisture simulation, `adjustMoisture`, and savegame persistence.

`src/WeatherProfileSystem.lua` — loaded alongside main. Owns monthly moisture clamps, rainfall weight overrides, and per-month temperature ranges. Registered as `g_currentMission.WeatherProfileSystem`. Installs hooks on `Weather.updateAvailableWeatherObjects` (appended) and `WeatherObject.activate` (overwritten).

`src/data/CropValueMap.lua` — static table mapping fill type names to moisture→grade bands. Grade A windows (moisture % range, 0–100 scale):
- Wheat/WinterWheat: 11–13%
- Barley/WinterBarley: 12–14%
- Canola/Mustard/Poppy: 8–10%
- Maize: 18–22% (field harvest moisture — not storage spec; always dried post-harvest)
- Soybean: 13–16%
- Oat/Rye/Triticale/Buckwheat/Millet/Sorghum: 13–14%
- Rice/LongGrainRice: 12–14%
- Sunflower: 11–14%

`src/MoistureSettings.lua` — in-game settings menu, including the weather profile picker. Calls `populateWeatherProfileSetting()` at build time to fill values from loaded profiles.

`src/BaleRottingSystem.lua`, `src/DryingSystem.lua`, `src/GroundPropertyTracker.lua` — self-contained subsystems, each registered on `g_currentMission`.

`src/extensions/` — appended functions on vanilla FS25 specializations (Combine, Baler, Tedder, etc.) to hook moisture tracking into harvest/processing events.

`src/extensions/StorageHeapExtension.lua` — support for the Highlands Fishing Pack's
`placeableStorageHeap` specialization, used by grain stores like FS25_MultiBayGrainStore.
These are a hybrid: you tip into a grate or draw from a pipe, but the grain itself sits in
the bays as **real density-map-height material**.

The load-bearing fact is that `StorageHeap:updateTotalFillLevel` re-reads
`DensityMapHeightUtil.getFillLevelAtArea` over the bay every update and overwrites its
`fillLevels` — the material is the source of truth, not the number. The stations only queue
liters, which `StorageHeap:update` later drains via `tipToGroundAroundLine`. So we track
these stores as **GroundPropertyTracker piles**, like sheds, not as silos:

- Tipping in from a trailer and scooping out with a loader already work through the normal
  ground paths (`DischargeableExtension`, `FillVolumeExtension`).
- The grate and the pipe don't touch the ground directly, so they are bridged here — the
  grate via `StorageHeap:addFillLevelChangedListeners` (which reports only fill type and
  liters, hence the `beginDeposit`/`endDeposit` bracket in `DischargeableExtension` to say
  whose grain arrived), the pipe via `getStoredProperties` in `LoadingStationExtension`.
  That bracket wraps *every* discharge, not just ones aimed at a storage heap: a bay's
  `isExtension` defaults to **true** in `StorageHeap:load`, so any station within its
  `storageRadius` can pull the bay into its target storages and route grain into it.
  `UnloadingStation:addFillLevelFromTool` then picks a storage by `pairs()` order, so
  which one receives is arbitrary and can differ between sessions.
- Drying is free: these placeables already pass `DryingSystem:isTipOcclusionBuilding`
  because `simplePlaceable` includes the `tipOcclusionAreas` spec.
- Grain piles are inert in the tracker (`applyDryingToPile` only handles grass/hay/straw),
  so stored grain holds its moisture and doesn't rot — correct under a roof.

Two traps: a bay with `fillTypeIndexToDrop > 0` has material still in flight, so its cells
can read as empty while holding a pile we just created — never prune those. And do not call
`placeable:getIsFillTypeSupported()`; the DLC's implementation calls
`section:getIsFillTypeSupported` on a plain table and errors.

Decrypted DLC source for reference: `objects/StorageHeap.lua` and
`placeables/specializations/PlaceableStorageHeap.lua` inside `highlandsFishingPack.dlc`.

`src/events/` — multiplayer network events. All simulation runs server-side only; no new sync events were added for WeatherProfileSystem.

`src/gui/` — tabbed menu frames (Shift+M). `MoistureGuiCalendar` shows monthly clamp ranges from the active scenario. `MoistureGuiWeather` shows the weather Forecast (per-month group %, with per-month forecast error/jitter) and History (per-season group % vs. normal, newest year rightmost) tabs.

`xml/weatherProfiles/` — one XML per region. Loaded at `loadMap()`.

`src/IrrigationSystem.lua` — field irrigation. The player books a contractor, through the
Irrigation tab, to raise a farmland's moisture by a chosen amount; the boost accrues hour by hour
while the contractor works, then decays with the weather. Registered as
`g_currentMission.irrigationSystem`, ticked once per game hour from `MoistureSystem:onHourChanged`.
Contractor time is the scarce resource, not money; the reasoning behind each tunable lives in the
comments beside it in the tunables block at the top of the file.

Three things about it are load-bearing and easy to break:

- **The contractor diary is generated, never stored.** A day's committed load is a pure function of
  `diarySeed` and how far away the day is, so it tightens as it approaches and gives the same answer
  on every peer and after a reload. The seed itself is *derived* from the map id and savegame
  index, not rolled with `math.random`, so it is stable even before the savegame has ever been
  written with an `<irrigation>` section; a stored seed still wins on load.
  All day arithmetic uses `Environment.currentMonotonicDay`, never `currentDay` (which is rescaled when the player changes month length).
- **`hash01` needs its nonlinear fold.** The original two-round LCG was affine end to end, so
  `hash01(s, n+1)` was always `hash01(s, n)` plus a constant — contractors, who differ only by that
  `+1`, drew the same jitter shifted (measured Pearson 0.73), collapsing the roster setting into a
  no-op. The fold breaks that; every product also stays under 2^53 so the result is exact, hence
  identical on every peer. See the comment on the function.
- **The boost is injected at one place**, the end of `getMoistureAtPosition`, outside *both* height
  branches (the flat-map `else` path has no clamp, so "after the clamp" would skip it). It is
  clamped only to 1.0, never to the month's `moistureMax`. `anyActiveBoosts` keeps the hot path at
  one boolean read when nobody is irrigating.

## Silo extensions

**Never read `placeable.spec_silo.storages` directly — use `MoistureSystem.getSiloStorages(placeable)`.**

A silo extension is a placeable of its own holding a bare `Storage`. It has no loading or
unloading station, no pipe and no trigger, so grain can only reach or leave it through the
*parent* silo's stations. `PlaceableSiloExtension:onFinalizePlacement` registers its storage
into `unloadingStation.targetStorages` / `loadingStation.sourceStorages` of every compatible
station in range — but **never** into `spec_silo.storages`, which only ever holds the silo's
own tanks.

`UnloadingStation:addFillLevelFromTool` then picks a tank by `pairs()` order, so tipped grain
can land wholly inside an extension. Reading `spec_silo.storages` made that grain invisible:
`hasFillType` returned false and pruned the moisture record the instant it was written, and
`DryingSystem` saw the silo as empty so it never appeared in the drying list (issue #87).

Because the stations pool every storage when filling and draining, the player sees silo plus
extensions as one heap — so we track it as one, keyed on the **parent silo's** `uniqueId`.
Ingress (`DischargeableExtension`) and egress (`LoadingStationExtension`) already key off
`owningPlaceable`, which is the parent, so they needed no change. Display paths
(`PlaceableInfoTriggerExtension`, `PlayerHUDUpdateExtension`) resolve an extension to its
parent via `MoistureSystem:getParentSiloForExtension` before reading.

Known and accepted: an extension in range of two silos is registered with **both**, so its
grain counts toward both pools. The error is a blend of two averages, not a lost value; keying
per-`Storage` instead would need synthetic savegame keys for a rare case.

## Weather profiles

Nine regional profiles, each with 2–4 weighted scenarios. Scenario selected once per January via `PERIOD_CHANGED`; persists in savegame under `<weatherProfile>` key.

**Available profiles:** `ukwest`, `ukeast`, `centraleurope`, `mediterranean`, `usmidwest`, `uspnw`, `eastasia`, `brazilcentral`, `brazilsouth`

**Weather history** (`WeatherHistoryCollector`) records actual realized weather. It samples
the scheduled weather type once per game-hour into per-season buckets, and archives the
completed year at the **start of March** (the FS25 year boundary), labelling it `currentYear-1`.
The reporting year runs March→February so each winter (Dec/Jan/Feb) is a complete contiguous
season; archiving in January would split winter and capture only December.

Each month entry defines `rain`, `thunder`, `snow`, `hail`, `sun`, `partlyCloudy`, `cloudy` (weather type weights), `tempMin`, `tempMax` (absolute °C), and `moistureMin`, `moistureMax`.

**Inner clamp range** — `adjustMoisture` uses the inner 80% of the min/max range:
```
innerMin = min + 0.1 * (max - min)
innerMax = max - 0.1 * (max - min)
```
This is what field moisture actually settles within. Always check inner range, not raw min/max, when evaluating grade A feasibility.

**Grade A feasibility rule** — realistic primary crops for a region should be achievable at grade A in a normal scenario. It is not required for every crop in every scenario. When tuning clamps, verify the inner range overlaps the grade A window for the crop's FS25 harvest month(s).

**FS25 harvest months** (relevant to profile tuning):
- Wheat/WinterWheat: July, August
- Barley/WinterBarley: July, August
- Maize/Soybean: October, November
- Rice/LongGrainRice: August (rice), September (both)
- Canola: July

## Weather weights → actual weather

Each month entry carries per-type weights (`rain`, `thunder`, `snow`, `hail`, `sun`,
`partlyCloudy`, `cloudy`). The design goal: **a type's weight share equals its share of
time** — e.g. 40% rain weight ⇒ raining ~40% of that month. `WeatherProfileSystem:rebuildWeatherWeights`
rebuilds the engine's `weightedWeatherObjects` pool each period from these weights. Getting
weight→time fidelity required three engine-level fixes (all in `WeatherProfileSystem.lua`):

- **Equal spell durations.** The engine runs each scheduled weather object for a random
  `minHours..maxHours` *specific to that object*; base-game sun spells are much longer than
  rain spells, so weighting the pool by raw weight made long-spell types dominate the hours.
  We normalize EVERY variation to `SPELL_MIN_HOURS`..`SPELL_MAX_HOURS` (2–5h). With equal
  durations the duration term cancels and hours-share == pool-share == weight-share. Pool
  copies are therefore just the raw weight (no duration correction).
- **Missing weather objects injected.** The base map only authors RAIN/HAIL objects for some
  seasons (engine season 4 / winter has no rain object; hail exists only in spring). Weight
  for an absent type would be unschedulable. `injectMissingWeatherObjects` clones real RAIN
  and HAIL objects into every season that lacks them (cloning via the source's own class so
  `WeatherObjectHail` behavior is preserved, and deep-copying variations so our per-instance
  temperature mutation stays isolated). This is why winter rain works.
- **Fallback chains.** As a safety net for any still-unschedulable weight (e.g. THUNDER, which
  has no object class), `rebuildWeatherWeights` redirects it to a related available type
  (rain↔snow↔hail, partlyCloudy↔cloudy) so its precipitation/cloud share is preserved.

**`thunder` always becomes extra `rain` — author it as a small flavor value, not a second
rain budget.** THUNDER has no `WeatherObject` subclass in FS25 at all (unlike RAIN/HAIL, which
get injected real objects — see above), so its weight is *never* schedulable as its own type.
Every point of `thunder` weight redirects 100% into `RAIN` for that season (chain:
`RAIN → SNOW → HAIL`). This means the profile's actual rain frequency for a month is
`rain + thunder` (plus `hail` too, but only in the rare case a season somehow lacks even the
injected hail object), not just the `rain` field. A profile authored with `rain=4, thunder=3`
doesn't read as "mostly rain with occasional thunderstorms" — it plays as `rain=7`, i.e. rain
~39% of that month instead of the apparent ~22%. This is easy to get wrong because per-month
values look reasonable in isolation; the inflation only shows up when you sum `rain + thunder`
against the month's total weight. Keep `thunder` low (normally ≤1, occasionally 2 for a
short peak-storm season) even in climates with genuinely frequent thunderstorms — the "more
thunderstorms" character should mostly already be expressed through a higher `rain` value,
since the engine can't visually distinguish the two. (Fixed 2026-08 in `centraleurope`,
`brazilcentral`, `brazilsouth`, `usmidwest`, which had `thunder` weights of 2–5 stacking on
top of already-substantial `rain` values during the crop's harvest window, producing
"nearly non-stop rain" complaints — `brazilcentral`'s Nov peak hit ~62% effective rain time.)

**What drives simulated field moisture up, in order of leverage:**
1. **`moistureMin`/`moistureMax` for the month** — the hard clamp `adjustMoisture` settles
   within (see inner-80% rule below). This is the primary lever; always check it first when a
   crop can't hit grade A.
2. **`rain` weight relative to the month's total weight** — determines how much of the month
   the sim treats as "raining" (see `getRainFallScale() > 0.1` below), which pushes moisture
   toward `moistureMax` and slows drying between rain events.
3. **`thunder` weight** — see above; functionally identical to `rain` weight once redirected,
   so it has the same moisture-raising effect but is easy to under-account for when tuning.
4. **`hail`/`snow` weight** — also precipitation, but typically much smaller shares and, unlike
   `thunder`, schedule as their own distinct type (via injection) rather than silently
   inflating `rain`.
5. **`tempMin`/`tempMax`** — lower temps slow evaporation/drying between precipitation events,
   compounding whatever moisture the rain/thunder weights already put in.

When a profile feels too wet, check all five in that order rather than assuming the `rain`
field alone is the story — `thunder` in particular hides real rain-time increases behind a
value that looks like a separate, minor weather type.

**Engine season vs. calendar month.** The engine groups the 12 months into 4 visual seasons
(`weatherObjects`/`weightedWeatherObjects` are keyed by season 1–4, three months each). With
~1-day months, each reporting season is a small sample, so single-year scatter is wide
(±~10pp) — extreme dry/wet years are statistically expected and intentional, not a bug.

**Temperature application.** `tempMin`/`tempMax` are absolute °C values (not offsets). They are applied at two points:

- **`WeatherObject.activate` hook** — stamps the exact current-month temps onto the variation just before the engine calls the real `activate()`, which passes them to `TemperatureUpdater:setTargetValues`. This keeps the live "now" temperature and near-term spells accurate.
- **`applyTemperatureToVariations`** — called at mission start and after each `rebuild()` (period change). Stamps temps onto every variation in the object pool so that `WeatherForecast:getHourlyForecast`/`getDailyForecast`, which read `variation.minTemperature`/`maxTemperature` directly without going through `activate()`, show correct values. Uses a representative middle month per engine season (spring→April, summer→July, autumn→October, winter→January). The **current season** uses the active scenario's temps; **other seasons** use the normal scenario as a neutral assumption for the year not yet rolled.

The `InGameMenuCalendarFrame` forecast panels read directly from variation objects — they never call `activate()` — so they depend entirely on `applyTemperatureToVariations` being current.

**Single source of truth for "raining":** the moisture sim treats `getRainFallScale() > 0.1`
as raining (`GroundPropertyTracker`). Note `getRainFallScale()` is rain *intensity* (ramped
per the active object's preset), NOT a scheduled-type flag — do not use it to measure weather
type composition; use the scheduled weather type instead (see `WeatherHistoryCollector`).

## Console commands

| Command | Description |
|---------|-------------|
| `msWeatherDebug` | Print active profile/scenario and current month clamp |
| `msSetScenario <id>` | Force-switch scenario mid-game |
| `msListScenarios` | List available scenarios for the active profile |
| `msIrrigationDebug [farmlandId]` | Print a farmland's boost, grace and pending job, or every irrigated farmland |
| `msIrrigationDiary [daysAhead]` | Dump free/committed/booked hours per contractor for that day, plus the seed |
| `msIrrigationBook <farmlandId> <boostPP> <daysAhead>` | Force-book a job, skipping payment and permission |
| `msIrrigationSetBoost <farmlandId> <boostPP>` | Set a farmland's boost directly, to test decay |

## Decompiled FS25 source

Located at `C:\Users\steve\Documents\My FS 25 Mods\Reference\FS25_Lua`. Relevant weather engine files:
- `environment/weather/Weather.lua` — constants (e.g. `SEND_BITS_TEMPERATURE = 6`, so max encodable value = 2^6 = 64°C)
- `environment/weather/WeatherObject.lua` — loads `minTemperature`/`maxTemperature` per variation from XML (integers, default 15/25); `activate()` calls `temperatureUpdater:setTargetValues(variation.minTemperature, variation.maxTemperature, ...)`
- `environment/weather/WeatherInstance.lua`, `WeatherForecast.lua`, `WeatherStateEvent.lua`

## Key conventions

- Moisture values stored internally on 0–1 scale; displayed as percentage (×100).
- All simulation is server-side. Clients receive state via `InitialClientStateEvent`.
- `MoistureClamp.lua` is retained on disk but not loaded — replaced entirely by WeatherProfileSystem.
- Adding a new profile: create `xml/weatherProfiles/<id>.xml` **and** add its id to the `BUILTIN_PROFILES` list near the top of `WeatherProfileSystem.lua`. The old auto-discovery via `Files.new()` was removed because `getFiles()` cannot enumerate files inside a zip archive — it only works on a real filesystem directory. The modSettings user directory is still scanned via `Files.new()` because that path is always on the real filesystem.
- Multiplayer: do not add client-side moisture logic without a corresponding network event.

## Map → profile auto-defaults

`MoistureSystem.MapProfileDefaults` (top of `src/main.lua`) maps `g_currentMission.missionInfo.customEnvironment` (the map's mod folder name, e.g. `FS25_Witcombe`) to a profile id. This is used as the **default** only — it is overridden by any value saved in the player's savegame. If the map is not in the table the default falls back to `ukwest`.

`MoistureSystem:getDefaultProfileForMap()` performs the lookup and is called at `loadMap()` time to initialise `settings.weatherProfile` before `loadFromXMLFile()` overwrites it if save data exists.

When adding entries: use the exact zip filename without `.zip` as the key. Maps with multiple variants (crossplay, pc, etc.) need separate entries. Only add maps where the region is reasonably confident — leave ambiguous/generic maps unmapped so they fall back gracefully.

## Multiplayer networking rules

**Object identity over the network:** `placeable.uniqueId` is a local string identifier and is NOT guaranteed to match between client and server. Never send `uniqueId` over the network. Always use `NetworkUtil.getObjectId(object)` (returns an int32) to identify objects in events, then resolve back to the local object on the receiving side with `NetworkUtil.getObject(objectId)`. From there, read `.uniqueId` locally as needed.

**DryingSystem MP pattern:** `DryingToggleEvent` is bidirectional:
- Client→server: sends `objectId` (int32), `newState` absent — server toggles and broadcasts back.
- Server→all clients: sends `objectId` + `newState` (bool) — clients call `dryingSystem:setDryingState(uniqueId, isActive)` to sync their local `activeDryers` table and show the notification.
- Auto-stop (drying complete): server broadcasts `newState=false` to all clients from `onHourChanged`.
- The server player's notification comes from `toggleDrying()` directly; client notifications come from `setDryingState()`.

**Silo moisture sync:** `drySilo` broadcasts `ObjectMoistureResponseEvent` each hour it runs, keeping client `objectInfo` current. No equivalent is needed for shed pile moisture (that lives in `GroundPropertyTracker` which has its own sync path).
