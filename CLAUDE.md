# FS25_MoistureSystem

FS25 mod (Lua + XML) that adds moisture simulation, crop quality grading, bale rotting, grass drying, and silo drying to Farming Simulator 25.

## Architecture

`src/main.lua` — core `MoistureSystem` object, registered as a mod event listener. Entry point for field moisture simulation, `adjustMoisture`, and savegame persistence.

`src/WeatherProfileSystem.lua` — loaded alongside main. Owns monthly moisture clamps, rainfall weight overrides, and per-month temperature ranges. Registered as `g_currentMission.WeatherProfileSystem`. Installs hooks on `Weather.updateAvailableWeatherObjects` (appended) and `WeatherObject.activate` (overwritten).

`src/data/CropValueMap.lua` — static table mapping fill type names to moisture→grade bands. Grade A windows (moisture % range, 0–100 scale):
- Wheat/WinterWheat: 11–13%
- Barley/WinterBarley: 12–14%
- Canola/Mustard/Poppy: 8–10%
- Maize/Soybean: 13–16%
- Oat/Rye/Triticale/Buckwheat/Millet/Sorghum: 13–14%
- Rice/LongGrainRice: 12–14%
- Sunflower: 11–14%

`src/MoistureSettings.lua` — in-game settings menu, including the weather profile picker. Calls `populateWeatherProfileSetting()` at build time to fill values from loaded profiles.

`src/BaleRottingSystem.lua`, `src/DryingSystem.lua`, `src/GroundPropertyTracker.lua` — self-contained subsystems, each registered on `g_currentMission`.

`src/extensions/` — appended functions on vanilla FS25 specializations (Combine, Baler, Tedder, etc.) to hook moisture tracking into harvest/processing events.

`src/events/` — multiplayer network events. All simulation runs server-side only; no new sync events were added for WeatherProfileSystem.

`src/gui/` — tabbed menu frames (Shift+M). `MoistureGuiCalendar` shows monthly clamp ranges from the active scenario. `MoistureGuiWeather` shows the weather Forecast (per-month group %, with per-month forecast error/jitter) and History (per-season group % vs. normal, newest year rightmost) tabs.

`xml/weatherProfiles/` — one XML per region. Loaded at `loadMap()`.

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

## Decompiled FS25 source

Located at `C:\Users\steve\Documents\My FS 25 Mods\Reference\FS25_Lua`. Relevant weather engine files:
- `environment/weather/Weather.lua` — constants (e.g. `SEND_BITS_TEMPERATURE = 6`, so max encodable value = 2^6 = 64°C)
- `environment/weather/WeatherObject.lua` — loads `minTemperature`/`maxTemperature` per variation from XML (integers, default 15/25); `activate()` calls `temperatureUpdater:setTargetValues(variation.minTemperature, variation.maxTemperature, ...)`
- `environment/weather/WeatherInstance.lua`, `WeatherForecast.lua`, `WeatherStateEvent.lua`

## Key conventions

- Moisture values stored internally on 0–1 scale; displayed as percentage (×100).
- All simulation is server-side. Clients receive state via `InitialClientStateEvent`.
- `MoistureClamp.lua` is retained on disk but not loaded — replaced entirely by WeatherProfileSystem.
- Adding a new profile: create `xml/weatherProfiles/<id>.xml`. All `.xml` files in that directory are auto-discovered via `Files.new()` — no code registration needed.
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
