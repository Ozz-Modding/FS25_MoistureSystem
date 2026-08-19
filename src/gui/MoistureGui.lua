---
-- MoistureSystem - GUI Layout
--

MoistureGui = {}

local MoistureGui_mt = Class(MoistureGui, TabbedMenu)

function MoistureGui:new(messageCenter, l18n, inputManager)
    local self = TabbedMenu.new(nil, MoistureGui_mt, messageCenter, l18n, inputManager)

    self.messageCenter = messageCenter
    self.l18n = l18n
    self.inputManager = g_inputBinding

    return self
end

function MoistureGui:onGuiSetupFinished()
    MoistureGui:superClass().onGuiSetupFinished(self)

    self.clickBackCallback = self:makeSelfCallback(self.onButtonBack)

    self.pageGrades:initialize()
    self.pagePrices:initialize()
    self.pageWeather:initialize()
    self.pageDrying:initialize()
    self.pageIrrigation:initialize()

    self:setupPages()
    self:setupMenuButtonInfo()
end

function MoistureGui:setupPages()
    local dryingIconFilename = Utils.getFilename('grainDrying.dds', MoistureSystem.dir)
    local dryingIconUVs = GuiUtils.getUVs({ 0, 0, 128, 128 }, { 128, 128 })

    local pages = {
        { self.pageGrades, 'gui.icon_ingameMenu_finances' },
        { self.pagePrices, 'gui.icon_ingameMenu_prices' },
        { self.pageWeather, 'gui.icon_ingameMenu_calendar' },
        { self.pageDrying, nil, dryingIconFilename, dryingIconUVs },
        -- Reuses the already-loaded drying icon so the irrigation icon can be
        -- swapped later by dropping in a file, with no code change.
        { self.pageIrrigation, nil, dryingIconFilename, dryingIconUVs }
    }

    for idx, thisPage in ipairs(pages) do
        local page, sliceId, iconFilename, iconUVs = unpack(thisPage)
        self:registerPage(page, idx)
        self:addPageTab(page, iconFilename, iconUVs, sliceId)
    end

    self:rebuildTabList()
end

function MoistureGui:setupMenuButtonInfo()
    local onButtonBackFunction = self.clickBackCallback

    self.defaultMenuButtonInfo = {
        {
            inputAction = InputAction.MENU_BACK,
            text = g_i18n:getText("button_back"),
            callback = onButtonBackFunction
        }
    }

    self.defaultMenuButtonInfoByActions[InputAction.MENU_BACK] = self.defaultMenuButtonInfo[1]

    self.defaultButtonActionCallbacks = {
        [InputAction.MENU_BACK] = onButtonBackFunction,
    }
end

function MoistureGui:onButtonBack()
    self:exitMenu()
end

function MoistureGui:exitMenu()
    self:changeScreen(nil)
end
