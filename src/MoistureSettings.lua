MoistureSettings = {}
MoistureSettings.CONTROLS = {}

-- Moisture Meter Reporting Types
MoistureSettings.METER_REPORTING_BLINKING = 1
MoistureSettings.METER_REPORTING_NOTIFICATION = 2

MoistureSettings.menuItems = {
    'environment',
    'moistureLossMultiplier',
    'moistureGainMultiplier',
    'teddingMoistureReduction',
    'baleRotEnabled',
    'baleRotRate',
    'baleExposureDecayRate',
    'qualityDecayMultiplier',
    'dryingSpeed',
    'sellDryingChargeRate',
    'showFieldMoisture',
    'moistureMeterReporting'
}

MoistureSettings.multiplayerPermissions = {
    'moistureSettings'
}

Farm.PERMISSION['MOISTURE_SETTINGS'] = "moistureSettings"
table.insert(Farm.PERMISSIONS, Farm.PERMISSION.MOISTURE_SETTINGS)

-- SETTINGS DEFINITIONS
MoistureSettings.SETTINGS = {}

MoistureSettings.SETTINGS.environment = {
    ['default'] = 2,  -- NORMAL
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { MoistureClampEnvironments.DRY, MoistureClampEnvironments.NORMAL, MoistureClampEnvironments.WET },
    ['strings'] = {
        g_i18n:getText("setting_moisture_environment_dry"),
        g_i18n:getText("setting_moisture_environment_normal"),
        g_i18n:getText("setting_moisture_environment_wet")
    }
}

MoistureSettings.SETTINGS.moistureLossMultiplier = {
    ['default'] = 3,
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
    ['strings'] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
}

MoistureSettings.SETTINGS.moistureGainMultiplier = {
    ['default'] = 3,
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
    ['strings'] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
}

MoistureSettings.SETTINGS.teddingMoistureReduction = {
    ['default'] = 2,
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 0.01, 0.02, 0.03, 0.04, 0.05 },
    ['strings'] = { "1%", "2%", "3%", "4%", "5%" }
}

MoistureSettings.SETTINGS.baleRotEnabled = {
    ['default'] = 2, -- Enabled by default
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { false, true },
    ['strings'] = {
        g_i18n:getText("setting_setting_off"),
        g_i18n:getText("setting_setting_on")
    }
}

MoistureSettings.SETTINGS.baleRotRate = {
    ['default'] = 3, -- 1.0 multiplier (100%)
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 },
    ['strings'] = { "50%", "75%", "100%", "125%", "150%", "200%" }
}

MoistureSettings.SETTINGS.baleExposureDecayRate = {
    ['default'] = 3, -- 1.0 multiplier (40 minutes to dry)
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 0.5, 0.75, 1.0, 1.5, 2.0 }, -- decay rate multipliers
    ['strings'] = { "0.5x", "0.75x", "1x", "1.5x", "2x" }
}

MoistureSettings.SETTINGS.showFieldMoisture = {
    ['default'] = 1, -- Disabled by default
    ['serverOnly'] = false,
    ['permission'] = 'moistureSettings',
    ['values'] = { false, true },
    ['strings'] = {
        g_i18n:getText("setting_setting_off"),
        g_i18n:getText("setting_setting_on")
    }
}

MoistureSettings.SETTINGS.moistureMeterReporting = {
    ['default'] = 1, -- Blinking alert by default (METER_REPORTING_BLINKING)
    ['serverOnly'] = false,
    ['permission'] = 'moistureSettings',
    ['values'] = { MoistureSettings.METER_REPORTING_BLINKING, MoistureSettings.METER_REPORTING_NOTIFICATION },
    ['strings'] = {
        g_i18n:getText("setting_moisture_moistureMeterReporting_blinking"),
        g_i18n:getText("setting_moisture_moistureMeterReporting_notification")
    }
}

MoistureSettings.SETTINGS.qualityDecayMultiplier = {
    ['default'] = 2,
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 0.5, 1.0, 1.5, 2.0 },
    ['strings'] = { "0.5x", "1x", "1.5x", "2x" }
}

MoistureSettings.SETTINGS.dryingSpeed = {
    ['default'] = 2,
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 0.005, 0.01, 0.02, 0.03 },
    ['strings'] = { "0.5%", "1%", "2%", "3%" }
}

MoistureSettings.SETTINGS.sellDryingChargeRate = {
    ['default'] = 2,
    ['serverOnly'] = true,
    ['permission'] = 'moistureSettings',
    ['values'] = { 0.5, 1.0, 2.0, 4.0 },
    ['strings'] = { "0.5x", "1x", "2x", "4x" }
}

function MoistureSettings.getStateIndex(id, value)
    local value = value or g_currentMission.MoistureSystem.settings[id]
    local values = MoistureSettings.SETTINGS[id].values
    if type(value) == 'number' then
        local index = MoistureSettings.SETTINGS[id].default
        local initialdiff = math.huge
        for i, v in pairs(values) do
            local currentdiff = math.abs(v - value)
            if currentdiff < initialdiff then
                initialdiff = currentdiff
                index = i
            end
        end
        return index
    else
        for i, v in pairs(values) do
            if value == v then
                return i
            end
        end
    end
    return MoistureSettings.SETTINGS[id].default
end

MoistureSettingsControls = {}
function MoistureSettingsControls.onMenuOptionChanged(self, state, menuOption)
    local id = menuOption.id
    local setting = MoistureSettings.SETTINGS
    local value = setting[id].values[state]

    if value ~= nil then
        g_currentMission.MoistureSystem.settings[id] = value
    end

    g_client:getServerConnection():sendEvent(MoistureSettingsEvent.new())
end

local function updateFocusIds(element)
    if not element then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

function MoistureSettings.addSettingsToMenu()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    local settingsPage = inGameMenu.pageSettings
    -- The name is required as otherwise the focus manager would ignore any control which has MoistureSettings as a callback target
    MoistureSettingsControls.name = settingsPage.name

    function MoistureSettings.addMultiMenuOption(id)
        local callback = "onMenuOptionChanged"
        local i18n_title = "setting_moisture_" .. id
        local i18n_tooltip = "setting_moisture_" .. id .. "_tooltip"
        local options = MoistureSettings.SETTINGS[id].strings

        local originalBox = settingsPage.multiVolumeVoiceBox

        local menuOptionBox = originalBox:clone(settingsPage.gameSettingsLayout)
        menuOptionBox.id = id .. "box"

        local menuMultiOption = menuOptionBox.elements[1]
        menuMultiOption.id = id
        menuMultiOption.target = MoistureSettingsControls

        menuMultiOption:setCallback("onClickCallback", callback)
        menuMultiOption:setDisabled(false)

        local toolTip = menuMultiOption.elements[1]
        toolTip:setText(g_i18n:getText(i18n_tooltip))

        local setting = menuOptionBox.elements[2]
        setting:setText(g_i18n:getText(i18n_title))

        menuMultiOption:setTexts({ table.unpack(options) })
        menuMultiOption:setState(MoistureSettings.getStateIndex(id))

        MoistureSettings.CONTROLS[id] = menuMultiOption

        -- Assign new focus IDs to the controls as clone() copies the existing ones which are supposed to be unique
        updateFocusIds(menuOptionBox)
        table.insert(settingsPage.controlsList, menuOptionBox)
        return menuOptionBox
    end

    -- Add section
    local sectionTitle = nil
    for idx, elem in ipairs(settingsPage.gameSettingsLayout.elements) do
        if elem.name == "sectionHeader" then
            sectionTitle = elem:clone(settingsPage.gameSettingsLayout)
            break
        end
    end

    if sectionTitle then
        sectionTitle:setText(g_i18n:getText("setting_moisture_section"))
    else
        sectionTitle = TextElement.new()
        sectionTitle:applyProfile("fs25_settingsSectionHeader", true)
        sectionTitle:setText(g_i18n:getText("setting_moisture_section"))
        sectionTitle.name = "sectionHeader"
        settingsPage.gameSettingsLayout:addElement(sectionTitle)
    end
    -- Apply a new focus ID in either case
    sectionTitle.focusId = FocusManager:serveAutoFocusId()
    table.insert(settingsPage.controlsList, sectionTitle)
    MoistureSettings.CONTROLS[sectionTitle.name] = sectionTitle

    for _, id in pairs(MoistureSettings.menuItems) do
        MoistureSettings.addMultiMenuOption(id)
    end

    settingsPage.gameSettingsLayout:invalidateLayout()

    -- MULTIPLAYER PERMISSIONS
    local multiplayerPage = inGameMenu.pageMultiplayer

    function MoistureSettings.addMultiplayerPermission(id)
        local newPermissionName = id .. 'PermissionCheckbox'
        local i18n_title = "permission_moisture_" .. id

        local original = multiplayerPage.cutTreesPermissionCheckbox.parent
        local newPermissionRow = original:clone(multiplayerPage.permissionsBox)

        local newPermissionCheckbox = newPermissionRow.elements[1]
        newPermissionCheckbox.id = newPermissionName

        local newPermissionLabel = newPermissionRow.elements[2]
        newPermissionLabel:setText(g_i18n:getText(i18n_title))

        table.insert(multiplayerPage.permissionRow, newPermissionRow)

        multiplayerPage.controlIDs[newPermissionName] = true
        multiplayerPage.permissionCheckboxes[id] = newPermissionCheckbox
        multiplayerPage.checkboxPermissions[newPermissionCheckbox] = id
    end

    for _, id in pairs(MoistureSettings.multiplayerPermissions) do
        MoistureSettings.addMultiplayerPermission(id)
    end

    -- ENABLE/DISABLE OPTIONS FOR CLIENTS
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
        local isAdmin = g_currentMission:getIsServer() or g_currentMission.isMasterUser

        for _, id in pairs(MoistureSettings.menuItems) do
            local menuOption = MoistureSettings.CONTROLS[id]
            menuOption:setState(MoistureSettings.getStateIndex(id))

            if MoistureSettings.SETTINGS[id].disabled then
                menuOption:setDisabled(true)
            elseif MoistureSettings.SETTINGS[id].serverOnly and g_server == nil then
                menuOption:setDisabled(not isAdmin)
            else
                local permission = MoistureSettings.SETTINGS[id].permission
                local hasPermission = g_currentMission:getHasPlayerPermission(permission)

                local canChange = isAdmin or hasPermission or false
                menuOption:setDisabled(not canChange)
            end
        end
    end)
end

-- Allow keyboard navigation of menu options
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == "ingameMenuSettings" then
        -- Let the focus manager know about our custom controls now
        for _, control in pairs(MoistureSettings.CONTROLS) do
            if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    print(
                        "Could not register control %s with the focus manager. Selecting the control might be bugged",
                        control.id or control.name or control.focusId)
                end
            end
        end
        -- Invalidate the layout so the up/down connections are analyzed again
        local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
        settingsPage.gameSettingsLayout:invalidateLayout()
    end
end)

-- Send settings to new clients
FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
    function(self, connection, user, farm)
        g_client:getServerConnection():sendEvent(MoistureSettingsEvent.new())
    end)
