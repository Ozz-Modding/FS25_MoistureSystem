# FS25_MoistureSystem

FS25 mod (Lua + XML) that adds moisture simulation, crop quality grading, bale rotting, grass drying, and silo drying to Farming Simulator 25.

## Architecture

`src/main.lua` — core `MoistureSystem` object, registered as a mod event listener. Entry point for field moisture simulation, `adjustMoisture`, and savegame persistence.

`src/WeatherProfileSystem.lua` — loaded alongside main. Owns monthly moisture clamps, rainfall weight overrides, and temperature offsets. Registered as `g_currentMission.WeatherProfileSystem`. Installs hooks on `Weather.fillWeatherForecast` and `WeatherObject.activate`.

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

`src/gui/` — tabbed menu frames (Shift+M). `MoistureGuiCalendar` shows monthly clamp ranges from the active scenario.

`xml/weatherProfiles/` — one XML per region. Loaded at `loadMap()`.

## Weather profiles

Seven regional profiles, each with 2–4 weighted scenarios. Scenario selected once per January via `PERIOD_CHANGED`; persists in savegame under `<weatherProfile>` key.

Each month entry defines `rainfall`, `tempMinOffset`, `tempMaxOffset`, `moistureMin`, `moistureMax`.

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

## Console commands

| Command | Description |
|---------|-------------|
| `msWeatherDebug` | Print active profile/scenario and current month clamp |
| `msSetScenario <id>` | Force-switch scenario mid-game |
| `msListScenarios` | List available scenarios for the active profile |

## Key conventions

- Moisture values stored internally on 0–1 scale; displayed as percentage (×100).
- All simulation is server-side. Clients receive state via `InitialClientStateEvent`.
- `MoistureClamp.lua` is retained on disk but not loaded — replaced entirely by WeatherProfileSystem.
- Adding a new profile: create `xml/weatherProfiles/<id>.xml`, add the filename to the `profileFiles` list in `WeatherProfileSystem:loadProfiles()`.
- Multiplayer: do not add client-side moisture logic without a corresponding network event.
