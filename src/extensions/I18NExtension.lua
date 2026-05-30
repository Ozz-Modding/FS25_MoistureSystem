MSI18NExtension = {}

local modName = g_currentModName

table.insert(FinanceStats.statNames, "dryingCharge")
FinanceStats.statNameToIndex["dryingCharge"] = #FinanceStats.statNames

MoneyType.DRYING_CHARGE = MoneyType.register("dryingCharge", "ms_ui_dryingCharge")
MoneyType.LAST_ID = MoneyType.LAST_ID + 1

MSI18NExtension.texts = {
    ["ms_ui_dryingCharge"] = true,
    ["finance_dryingCharge"] = true,
}

function MSI18NExtension:getText(superFunc, text, modEnv)
    if modEnv == nil and MSI18NExtension.texts[text] then
        return superFunc(self, text, modName)
    end
    return superFunc(self, text, modEnv)
end

I18N.getText = Utils.overwrittenFunction(I18N.getText, MSI18NExtension.getText)
