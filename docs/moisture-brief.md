Currently moisture and therefore quality are driven by weather. Our mod does not currently control weather, it only reacts to it.

We use clamps (high/low) to ensure moisture values remain realistic.

The mod is a little bit too easy. The existing weather clamps may need to be modified to accommodate the weather scenarios we define below.

We should enhance it to actually control the weather. Uses should choose a weather profile, e.g. UK East, UK West, etc

The weather profile should be defined in xml files with something like:

```xml
<profiles>
    <profile id="ukeast">
        <seasons>
            <season id="spring_normal" rainfall="0.3" />
            <season id="spring_wet" rainfall="0.7" />
        </seasons>
        <scenarios>
            <scenario id="wet_all_year">
                <spring options="spring_wet" />
                ...etc
            </scenario>
        </scenarios>
    </profile>
</profiles>
```

Seasons describe possible weather factors for the profile. Scenarios are selected as a year begins and this is used to drive the weather.
We should generate some weather profiles that accurately reflect a good range of players for UK, Europe, USA, Asia. This does not need to be exhaustive, just 5-10 profiles. 

Do research to ensure the weather reflects reality
The goal of the selected combination is to drive interesting weather that might give good of bad yields. Note we might need to add 'weights' to ensure that 'normal' years are more common than abnormal years.

Expand or revise the xml structure as required. I provide it only to explain some thinking.

Note the game uses currentPeriod instead of month. Conversion can be done e.g.

```lua
function RedTape.periodToMonth(period)
    period = period + 2
    if period > 12 then
        period = period - 12
    end
    return period
end
```

In refs/ directory I've provided the Realistic Weather mod which may have code for controlling the weather. We do NOT want to use it for effects, only control of ingame weather (the mod has extreme weather effects).

Where the xmls define values, these should be RELATIVE to each other ranging 0.1 - 1. In code we should have contants to tune them as we play test. (For example, if I play and find a rain scenario has too little rain, I'd like to adjust one value to tune that and re-test)