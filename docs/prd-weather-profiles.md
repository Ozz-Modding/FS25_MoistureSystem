# PRD: Weather Profiles & Scenarios

## Problem Statement

The mod currently reacts to whatever weather the game generates, which is the same random distribution regardless of where in the world the player imagines their farm to be. A UK player gets the same weather as a US Midwest player. There is no sense of a "bad year" or a "good year" — each season feels statistically identical. The mod is too easy: there is no meaningful year-to-year variance in moisture conditions that forces players to adapt their strategy.

The existing `environment` setting (Dry/Normal/Wet) provides moisture clamps but is decoupled from weather generation, meaning a player can set "Wet" clamps while the game generates dry weather, producing incoherent results. The clamp values are not tied to any regional reality.

## Solution

Players choose a regional weather profile (e.g. UK East, Central Europe, US Midwest) in the mod settings. Each profile defines everything about how that region behaves: rainfall probability by month, temperature offsets by month, and moisture clamps by month. At the start of each January, the game selects a named scenario for the year (e.g. "Dry Summer", "Very Wet Spring") based on weighted probabilities. The scenario drives weather and moisture bounds coherently for the full year. The separate `environment` setting is removed.

## User Stories

1. As a player, I want to choose a regional weather profile, so that the weather and moisture conditions reflect the farming region I am roleplaying.
2. As a player, I want to choose a regional weather profile from within the existing mod settings menu, so that I do not need to find a separate configuration screen.
3. As a player, I want each year to have a distinct, named character (e.g. "Wet Spring, Dry Summer"), so that I can talk about "that terrible drought year" and plan around historical patterns.
4. As a player, I want normal years to be more common than extreme years, so that bad or exceptional years feel meaningful rather than routine.
5. As a player, I want temperature, rainfall, and moisture clamps to all reflect the same regional profile, so that conditions feel coherent rather than contradictory.
6. As a player, I want the weather to feel coherent across the year, so that a "drought year" scenario means consistently dry conditions throughout summer, not random dry patches.
7. As a player starting a new game in August, I want the mod to default to a normal year scenario, so that weather is sensible from the start without requiring a January trigger.
8. As a player loading an existing save with the mod newly installed, I want the mod to default to a normal year scenario, so that mid-playthrough installs work without errors or bizarre weather.
9. As a player, I want the active scenario to persist across save/load, so that my year's weather character is not reset when I quit and reload.
10. As a player, I want to see what scenario is active this year, so that I can understand why conditions are the way they are.
11. As a player, I want the moisture clamps to automatically reflect my chosen profile and active scenario, so that I do not need to separately configure an environment setting.
12. As a server admin, I want profile selection to be a server-side setting with permission controls, so that players on a shared server cannot individually change the regional weather.
13. As a multiplayer client, I want the weather to just work without needing to know the active scenario, so that there are no sync issues.
14. As a mod developer, I want rainfall, temperature, and clamp values in profile XMLs to be relative (0.1–1.0), so that a single Lua tuning constant adjusts the overall intensity during playtesting without editing every XML value.
15. As a mod developer, I want a console command to dump the active profile, scenario, and per-month weights, temperature offsets, and moisture clamps, so that I can verify the system is working without observing indirect effects.
16. As a mod developer, I want a console command to force-set the active weather scenario, so that I can test specific scenarios without waiting for January.
17. As a mod developer, I want a console command to list all available scenarios for the current profile, so that I can confirm XML parsing is correct.
18. As a mod developer, I want the weather generation rate to match the base game exactly, so that no new timing bugs are introduced.
19. As a content author, I want profile XMLs to define 5–10 real-world regions (UK, Europe, USA, Asia), so that most players have a relevant option.
20. As a content author, I want scenario weather values to be based on real climate research, so that profiles are credible and immersive.
21. As a content author, I want each profile's scenarios to include a "normal" scenario, so that there is always a default fallback.
22. As a player upgrading from a previous version of the mod, I want a smooth migration away from the `environment` setting, so that my save is not broken.

## Implementation Decisions

- **New module: WeatherProfileSystem** — responsible for loading profile XMLs, selecting the active scenario on January period change, and exposing the active month's rainfall weight, temperature offsets, and moisture clamps to the rest of the mod. Persists selected profile ID and active scenario ID to the existing MoistureSystem savegame XML.

- **Remove `environment` setting** — `MoistureSettings.SETTINGS.environment`, `MoistureClamp.lua`, and `MoistureClampEnvironments` are removed. All callers of `MoistureClamp.Environments` in `MoistureSystem.lua` (`adjustMoisture`, `getMoistureAtPosition`, `firstLoad`) are updated to read clamps from `WeatherProfileSystem` instead. Savegame migration: if an old save contains a `settings#environment` key, it is silently ignored on load.

- **Profile XML structure** — one XML file per profile, stored in a `xml/weatherProfiles/` directory. Each profile contains a set of named scenarios with a `weight` attribute. Each scenario defines 12 month entries with: a relative `rainfall` value (0.1–1.0), `tempMinOffset`/`tempMaxOffset` (degrees C, can be negative), and `moistureMin`/`moistureMax` (percentage, 0–100, replacing the old clamp table). Example shape:
    ```xml
    <profile id="ukeast" displayName="UK East">
        <scenarios>
            <scenario id="normal" weight="10">
                <month id="1" rainfall="0.25" tempMinOffset="-1" tempMaxOffset="1" moistureMin="17" moistureMax="36"/>
                <!-- ... 12 months ... -->
            </scenario>
            <scenario id="drySummer" weight="2">
                <month id="1" rainfall="0.25" tempMinOffset="-1" tempMaxOffset="1" moistureMin="17" moistureMax="36"/>
                <month id="6" rainfall="0.1"  tempMinOffset="2"  tempMaxOffset="4"  moistureMin="5"  moistureMax="14"/>
                <!-- ... -->
            </scenario>
        </scenarios>
    </profile>
    ```

- **Rainfall implementation** — override `Weather:fillWeatherForecast` via `Utils.overwrittenFunction`. Before each call to `createRandomWeatherInstance`, derive the month from the instance's `startDay` using `MoistureSystem.periodToMonth`, look up the active scenario's rainfall weight for that month, and rebuild `self.weightedWeatherObjects` for the relevant season accordingly. The rebuild is fresh on each call; no state is carried between calls. This matches the rate at which the base game generates forecast items (reactively, one slot at a time, maintaining a 9-day forward window).

- **Temperature implementation** — override `WeatherObject:activate` via `Utils.overwrittenFunction`. Intercept `variation.minTemperature` and `variation.maxTemperature`, apply the active scenario's monthly `tempMinOffset`/`tempMaxOffset` before passing to the original function. Confirmed integration point: `WeatherObject:activate` calls `temperatureUpdater:setTargetValues(variation.minTemperature, variation.maxTemperature)` on every activation with no bypass paths.

- **Moisture clamp integration** — `MoistureSystem:adjustMoisture` and `MoistureSystem:getMoistureAtPosition` call `WeatherProfileSystem:getClampForMonth(month)` which returns `{ min, max }` from the active scenario's current month. `MoistureSystem:firstLoad` does the same for the starting month. The clamps change when a new scenario is selected each January.

- **Tuning constants** — three Lua constants in WeatherProfileSystem: `RAINFALL_WEIGHT_SCALE` (multiplier applied to raw rainfall values when building `weightedWeatherObjects`), `TEMPERATURE_OFFSET_SCALE` (multiplier applied to XML temperature offsets), and `MOISTURE_CLAMP_SCALE` (multiplier applied to moistureMin/moistureMax, for overall intensity tuning). These are the only values that need changing during playtesting.

- **Scenario selection** — subscribe to `MessageType.PERIOD_CHANGED` on the server. When the derived month is January (using `MoistureSystem.periodToMonth`), randomly select a scenario from the active profile using weighted random selection across scenario weights. Default to the scenario with `id="normal"` when no saved scenario exists (new game, mid-playthrough install, missing save data, or upgrade from a version with the old `environment` setting).

- **MoistureSettings integration** — replace the existing `environment` entry in `MoistureSettings.menuItems` with `weatherProfile`. Add `weatherProfile` as a new server-only setting with `moistureSettings` permission, following the same pattern as existing settings. The available values are the loaded profile IDs; strings are their `displayName` attributes. Changing profile takes effect at the next January scenario selection.

- **Savegame persistence** — save `activeProfileId` and `activeScenarioId` into the existing `MoistureSystem.xml` savegame file under a `<weatherProfile>` key. Remove save/load of `settings#environment`. Follow the existing `loadFromXMLFile`/`saveToXmlFile` pattern in `MoistureSystem.lua`.

- **Multiplayer** — scenario selection, forecast weight rebuilding, and clamp lookups all run server-side only. No new network events are needed. The active scenario is not synced to clients.

- **Real-world climate research** — profile XMLs for the initial release should cover at least: UK East, UK West, Central Europe, Mediterranean, US Midwest, US Pacific Northwest, East Asia (temperate). Moisture clamp values should be derived from published monthly average soil moisture / evapotranspiration data; rainfall and temperature from published monthly climate normals. All values normalised appropriately.

## Testing Decisions

**What makes a good test:** Test observable outputs, not internal state. Verify what the console commands report, then cross-check against actual in-game conditions using the existing `gsWeatherDebug` overlay and the moisture HUD. Do not test `weightedWeatherObjects` array contents directly — test that rain appears at the expected frequency and moisture clamps land in the expected range over accelerated time.

**Console commands to implement on WeatherProfileSystem:**

- `msWeatherDebug` — dumps: active profile ID, active scenario ID, active scenario weight, and for the current month: rainfall weight (raw and scaled), temperature offsets (min/max), moisture clamp (min/max). Primary verification tool.
- `msSetScenario <scenarioId>` — force-sets the active scenario for the current profile, bypassing the January trigger. Enables testing any scenario without waiting.
- `msListScenarios` — lists all scenario IDs and weights for the currently active profile. Confirms XML parsing is correct and all scenarios loaded.

**Existing prior art:** `msSetMoisture` console command in `MoistureSystem.lua` and `gsWeatherDebug`/`gsWeatherSet` in the base game `Weather.lua` show the expected pattern for console command registration and output.

**Manual test procedure:** Load a save, run `msListScenarios` to confirm profiles loaded, run `msSetScenario drySummer`, run `msWeatherDebug` to confirm weights and clamps are as expected, then use `gsWeatherDebug` overlay over accelerated time to observe that rain frequency and moisture levels match the scenario's values. Compare a "normal" scenario against a "wet" scenario to confirm meaningful difference in both weather generation and moisture clamping.

## Out of Scope

- Per-scenario effects beyond rainfall probability, temperature offset, and moisture clamps (wind, fog, hail frequency) — the existing game systems handle these.
- UI display of the active scenario name to the player in the HUD or forecast screen.
- Changing profile mid-year taking immediate effect — profile changes apply at the next January scenario selection.
- Syncing the active scenario to multiplayer clients — the game handles weather sync natively.
- More than one active scenario at a time (e.g. blended scenarios).
- A separate difficulty multiplier to compensate for removing the `environment` setting — `moistureLossMultiplier` and `moistureGainMultiplier` already serve this purpose.

## Further Notes

- The existing `moistureLossMultiplier` and `moistureGainMultiplier` settings remain and serve as difficulty knobs. Players who previously used the "Wet" environment setting for easier conditions can achieve the same effect by reducing the loss multiplier.
- The `refs/FS25_RealisticWeather` mod is reference only. Do not use its visual effects, puddle system, fire system, or any other gameplay systems — only the weather control patterns (`fillWeatherForecast`, `WeatherObject:activate` overrides) are relevant.
- The base game `Weather:fillWeatherForecast` fills ahead to 9 in-game days and is triggered reactively each time a forecast slot is consumed. The override must maintain this behaviour exactly.
- Period-to-month conversion: `month = (period + 2) % 12`, with `% 12 = 0` mapping to 12. This is already implemented as `MoistureSystem.periodToMonth`.
- The existing `MoistureClamp.lua` file and `MoistureClampEnvironments` table are deleted as part of this change. Any modDesc.lua source references to `MoistureClamp.lua` must also be removed.
