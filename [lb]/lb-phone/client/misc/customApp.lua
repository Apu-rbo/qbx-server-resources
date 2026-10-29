function FormatCustomAppDataForUI(app)
    return {
        identifier = app.identifier,
        resourceName = app.resourceName,
        custom = true,
        name = app.name,
        icon = app.icon,
        description = app.description,
        images = app.images,
        developer = app.developer,
        size = app.size or 42000,
        price = app.price,
        game = app.game,
        landscape = app.landscape or false,
        removable = not app.defaultApp,
        disableInAppNotifications = app.disableInAppNotifications,
        ui = app.ui,
        fixBlur = app.fixBlur,
        access = HasAccessToApp(app.identifier)
    }
end

exports("SendCustomAppMessage", function(identifier, message)
    local resourceName = GetInvokingResource()

    if not identifier then
        infoprint("error", "SendCustomAppMessage: No identifier provided by resource " .. resourceName)
        return false, "No identifier provided"
    end

    local app = Config.CustomApps[identifier]

    if not app then
        infoprint("error", "SendCustomAppMessage: App " .. identifier .. " does not exist. Triggered by: " .. resourceName)
        return false, "App does not exist"
    end

    if app.resourceName ~= resourceName then
        infoprint("error", "SendCustomAppMessage: App " .. identifier .. " was not created by " .. resourceName)
        return false, "App was not created by " .. resourceName
    end

    SendNUIAction("customApp:sendMessage", {
        identifier = identifier,
        message = message
    })

    return true
end)

local function BuildCustomApp(app, resourceName)
    return {
        identifier = app.identifier,
        resourceName = resourceName,
        custom = true,
        name = app.name,
        icon = app.icon,
        description = app.description,
        images = app.images,
        developer = app.developer,
        size = app.size or 42000,
        price = app.price,
        game = app.game,
        landscape = app.landscape or false,
        removable = not app.defaultApp,
        defaultApp = app.defaultApp,
        disableInAppNotifications = app.disableInAppNotifications,
        ui = app.ui,
        fixBlur = app.fixBlur,
        onOpen = app.onOpen,
        onClose = app.onClose,
        onUse = app.onUse,
        onDelete = app.onDelete,
        onInstall = app.onInstall
    }
end

exports("AddCustomApp", function(app)
    local resourceName = GetInvokingResource()

    if not app or not app.identifier then
        return false, "No identifier provided"
    end

    if not app.name then
        return false, "No name provided"
    end

    if not app.description then
        return false, "No description provided"
    end

    if Config.CustomApps[app.identifier] then
        return false, "App already exists"
    end

    Config.CustomApps[app.identifier] = BuildCustomApp(app, resourceName)

    debugprint("adding custom app", app.identifier)
    SendNUIAction("addCustomApp", FormatCustomAppDataForUI(Config.CustomApps[app.identifier]))

    return true
end)

exports("RemoveCustomApp", function(identifier)
    local resourceName = GetInvokingResource()

    if not identifier then
        return false, "No identifier provided"
    end

    local app = Config.CustomApps[identifier]

    if not app then
        return false, "App does not exist"
    end

    if app.resourceName ~= resourceName then
        return false, "App was not created by " .. resourceName
    end

    Config.CustomApps[identifier] = nil
    SendNUIAction("removeCustomApp", identifier)

    return true
end)

AddEventHandler("onResourceStop", function(resourceName)
    for identifier, app in pairs(Config.CustomApps) do
        if app.resourceName == resourceName then
            Config.CustomApps[identifier] = nil
            SendNUIAction("removeCustomApp", identifier)
            debugprint("Removed app " .. identifier .. " due to resource stopping")
        end
    end
end)
