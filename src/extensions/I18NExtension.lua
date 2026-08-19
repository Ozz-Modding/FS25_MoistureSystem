MSI18NExtension = {}

local modName = g_currentModName

table.insert(FinanceStats.statNames, "dryingCharge")
FinanceStats.statNameToIndex["dryingCharge"] = #FinanceStats.statNames

MoneyType.DRYING_CHARGE = MoneyType.register("dryingCharge", "ms_ui_dryingCharge")
MoneyType.LAST_ID = MoneyType.LAST_ID + 1

-- Irrigation gets its own finance row rather than sharing PURCHASE_WATER with
-- livestock troughs: it is a recurring seasonal expense the player is meant to
-- weigh against crop revenue, and it cannot be weighed if it is invisible.
--
-- The guard is REQUIRED -- do not copy the unguarded dryingCharge line above.
-- FinanceStats is a base-game class that lives for the whole process, while
-- extraSourceFiles re-execute on every mission load, so returning to the menu
-- and loading a second save would otherwise append the row again.
if FinanceStats.statNameToIndex["irrigation"] == nil then
    table.insert(FinanceStats.statNames, "irrigation")
    FinanceStats.statNameToIndex["irrigation"] = #FinanceStats.statNames
end

MoneyType.IRRIGATION = MoneyType.register("irrigation", "ms_ui_irrigation")

-- Not superstition: MoneyType.reset rewinds the module-private counter to
-- LAST_ID. Without this bump a reset rewinds below the mod's id and the next
-- registration collides.
MoneyType.LAST_ID = MoneyType.LAST_ID + 1

-- Both keys are needed, carrying identical text: FinanceStats.new calls
-- g_i18n:getText("finance_" .. statName) with no modEnv, so a mod l10n key
-- cannot resolve without the whitelist redirect below.
MSI18NExtension.texts = {
    ["ms_ui_dryingCharge"] = true,
    ["finance_dryingCharge"] = true,
    ["ms_ui_irrigation"] = true,
    ["finance_irrigation"] = true,
}

function MSI18NExtension:getText(superFunc, text, modEnv)
    if modEnv == nil and MSI18NExtension.texts[text] then
        return superFunc(self, text, modName)
    end
    return superFunc(self, text, modEnv)
end

I18N.getText = Utils.overwrittenFunction(I18N.getText, MSI18NExtension.getText)
