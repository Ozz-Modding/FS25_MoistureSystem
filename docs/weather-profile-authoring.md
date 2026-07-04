# Authoring Weather Profile XMLs

Weather profiles define the climate behaviour for a region — monthly moisture clamps, absolute temperatures, and per-type weather weights. Each profile lives in an XML file and is discovered automatically at map load — no code changes required.

## File structure

```xml
<?xml version="1.0" encoding="utf-8"?>
<weatherProfile id="myregion" displayName="My Region">
    <scenarios>
        <scenario id="normal" weight="10">
            <month id="1"  tempMin="4" tempMax="9"
                rain="3" thunder="0" snow="0" hail="0" sun="5" partlyCloudy="5" cloudy="3"
                moistureMin="10" moistureMax="25"/>
            <!-- months 2–12 required -->
        </scenario>
    </scenarios>
</weatherProfile>
```

## `<weatherProfile>` attributes

| Attribute     | Type   | Description                                               |
|---------------|--------|-----------------------------------------------------------|
| `id`          | string | Unique identifier. Must match the filename (without .xml) |
| `displayName` | string | Label shown in the in-game settings picker                |

## `<scenario>` attributes

| Attribute | Type  | Description                                                                      |
|-----------|-------|----------------------------------------------------------------------------------|
| `id`      | string | Unique within this profile. **A scenario with `id="normal"` is required** (see below) |
| `weight`  | float  | Relative probability of this scenario being chosen for a given year. Higher = more common |

**The `normal` scenario is mandatory.** It is used as the forecast baseline and as the fallback when no other scenario is active. If it is missing the entire profile is rejected at load time — it will not appear in the picker and a warning is logged.

## `<month>` attributes

All 12 months (`id="1"` through `id="12"`, January–December) **must be defined** in every scenario. Missing months fall back to hard-coded defaults (0 rain, 1 sun/partlyCloudy/cloudy, 10–30% moisture) which are unlikely to match your region.

### Moisture clamp

| Attribute    | Type  | Unit | Description                                              |
|--------------|-------|------|----------------------------------------------------------|
| `moistureMin`| float | %    | Lower bound for field moisture (0–100 scale)             |
| `moistureMax`| float | %    | Upper bound for field moisture                           |

The simulation uses the inner 80% of this range as the realistic settling window:

```
innerMin = moistureMin + 0.1 * (moistureMax - moistureMin)
innerMax = moistureMax - 0.1 * (moistureMax - moistureMin)
```

When tuning for crop quality, check that `innerMin`–`innerMax` overlaps the grade A window for your region's primary crops during their harvest months. See [Crop grade A windows](#crop-grade-a-windows) below.

### Temperature

| Attribute  | Type    | Unit | Description                                                        |
|------------|---------|------|--------------------------------------------------------------------|
| `tempMin`  | integer | °C   | Absolute daily minimum temperature for this month                  |
| `tempMax`  | integer | °C   | Absolute daily maximum temperature for this month                  |

These values replace the engine's built-in variation temperatures for the duration of the month. Both attributes are optional — if omitted, the engine's baked-in temperatures for the active weather variation are used unchanged.

Values must be integers. The engine enforces a hard ceiling of 63°C; there is no enforced floor but sub-zero values work correctly. Vary these between scenarios to represent warmer dry years, cooler wet years, etc.

### Weather weights

Each weight is a non-negative integer representing the relative share of time that weather type occupies. The system normalises all weights so that their proportions drive the scheduler directly — a weight of `4` out of a total of `20` means that type is active roughly 20% of the time.

| Attribute     | Weather type     | Notes                                                          |
|---------------|------------------|----------------------------------------------------------------|
| `rain`        | Rain             |                                                                |
| `thunder`     | Thunderstorm     | Shares the precipitation group with `rain`                     |
| `snow`        | Snow             | Injected into seasons that lack a snow object if needed        |
| `hail`        | Hail             | Injected into seasons that lack a hail object if needed        |
| `sun`         | Clear/sunny      |                                                                |
| `partlyCloudy`| Partly cloudy    |                                                                |
| `cloudy`      | Overcast         |                                                                |

**Tips:**
- All weights can be `0` except that at least one type per month should be non-zero, otherwise the season pool will fall back to base-game defaults.
- `rain` and `thunder` both count as precipitation for forecast display and moisture gain purposes.
- The engine groups the 12 months into four seasons (spring 3–5, summer 6–8, autumn 9–11, winter 12–2). Objects missing from a given season (e.g. rain in winter on many base maps) are automatically injected by the system, so you can freely assign `rain` weight in winter months.

## Scenarios and year-to-year variation

Additional scenarios beyond `normal` represent unusual years (drought, wet summer, strong monsoon, etc.). One scenario is selected at the start of each in-game January by weighted random draw and applies for the whole year.

Recommended practice:
- Give `normal` a high weight (e.g. `10`) so it is the most common outcome.
- Give variant scenarios lower weights (e.g. `2`–`3`) so they occur roughly 1 year in 5–6.
- Only change the months that characterise the unusual year — months that are the same as normal can be copied directly.

Example with one variant:

```xml
<scenarios>
    <scenario id="normal"    weight="10"> ... </scenario>
    <scenario id="drySummer" weight="2">  ... </scenario>
</scenarios>
```

## Adding a new profile

There are two places the mod looks for profile XMLs, in load order:

1. **`xml/weatherProfiles/`** (inside the mod) — the built-in profiles shipped with the mod.
2. **`modSettings/FS25_MoistureSystem/`** (inside your FS25 game documents folder, e.g. `Documents/My Games/FarmingSimulator2025/modSettings/FS25_MoistureSystem/`) — user-supplied profiles loaded after the built-ins.

**For end users:** drop your `.xml` file into the `modSettings/FS25_MoistureSystem/` folder. It appears in the in-game profile picker automatically without editing the mod. If your file uses the same `id` as a built-in profile it will replace it.

**For mod authors bundling a profile:** drop the file into `xml/weatherProfiles/` as before.

## Crop grade A windows

Use this table when setting `moistureMin`/`moistureMax` to ensure grade A quality is achievable during harvest months.

| Crop                                          | Grade A moisture | FS25 harvest months |
|-----------------------------------------------|-----------------|---------------------|
| Wheat, Winter Wheat                           | 11–13%          | July, August        |
| Barley, Winter Barley                         | 12–14%          | July, August        |
| Canola                                        | 8–10%           | July                |
| Mustard, Poppy                                | 8–10%           | July                |
| Maize, Soybean                                | 13–16%          | October, November   |
| Oat, Rye, Triticale, Buckwheat, Millet, Sorghum | 13–14%       | July–August         |
| Rice, Long Grain Rice                         | 12–14%          | August–September    |
| Sunflower                                     | 11–14%          | September–October   |

Remember to check the **inner range** (the 80% window described above), not raw min/max, when evaluating whether grade A is reachable.

## Minimal valid example

```xml
<?xml version="1.0" encoding="utf-8"?>
<weatherProfile id="template" displayName="Template Region">
    <scenarios>
        <scenario id="normal" weight="10">
            <month id="1"  tempMin="3"  tempMax="8"
                rain="2" thunder="0" snow="2" hail="0" sun="4" partlyCloudy="4" cloudy="4"
                moistureMin="15" moistureMax="30"/>
            <month id="2"  tempMin="3"  tempMax="9"
                rain="2" thunder="0" snow="1" hail="0" sun="4" partlyCloudy="4" cloudy="4"
                moistureMin="14" moistureMax="28"/>
            <month id="3"  tempMin="5"  tempMax="11"
                rain="3" thunder="0" snow="0" hail="1" sun="4" partlyCloudy="5" cloudy="3"
                moistureMin="12" moistureMax="25"/>
            <month id="4"  tempMin="7"  tempMax="14"
                rain="3" thunder="1" snow="0" hail="1" sun="4" partlyCloudy="5" cloudy="3"
                moistureMin="10" moistureMax="22"/>
            <month id="5"  tempMin="10" tempMax="17"
                rain="3" thunder="1" snow="0" hail="0" sun="5" partlyCloudy="5" cloudy="3"
                moistureMin="9"  moistureMax="20"/>
            <month id="6"  tempMin="13" tempMax="20"
                rain="2" thunder="1" snow="0" hail="0" sun="6" partlyCloudy="5" cloudy="2"
                moistureMin="7"  moistureMax="17"/>
            <month id="7"  tempMin="15" tempMax="22"
                rain="2" thunder="1" snow="0" hail="0" sun="6" partlyCloudy="5" cloudy="2"
                moistureMin="6"  moistureMax="15"/>
            <month id="8"  tempMin="15" tempMax="22"
                rain="2" thunder="1" snow="0" hail="0" sun="6" partlyCloudy="5" cloudy="2"
                moistureMin="7"  moistureMax="16"/>
            <month id="9"  tempMin="11" tempMax="18"
                rain="3" thunder="0" snow="0" hail="1" sun="4" partlyCloudy="4" cloudy="4"
                moistureMin="10" moistureMax="22"/>
            <month id="10" tempMin="7"  tempMax="13"
                rain="3" thunder="0" snow="0" hail="0" sun="3" partlyCloudy="4" cloudy="5"
                moistureMin="13" moistureMax="26"/>
            <month id="11" tempMin="5"  tempMax="10"
                rain="3" thunder="0" snow="1" hail="0" sun="3" partlyCloudy="3" cloudy="5"
                moistureMin="14" moistureMax="28"/>
            <month id="12" tempMin="3"  tempMax="8"
                rain="2" thunder="0" snow="2" hail="0" sun="3" partlyCloudy="3" cloudy="5"
                moistureMin="15" moistureMax="30"/>
        </scenario>
    </scenarios>
</weatherProfile>
```
