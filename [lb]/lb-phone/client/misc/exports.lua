exports("ToggleHomeIndicator", function(enabled)
    SendNUIAction("toggleShowHomeIndicator", enabled)
end)

exports("ToggleLandscape", function(enabled)
    SendNUIAction("toggleLandscape", enabled)
end)

exports("OpenApp", function(app, metadata)
    SendNUIAction("setApp", {
        name = app,
        metadata = metadata
    })
end)

exports("CloseApp", function(options)
    options = options or {}

    debugprint("CloseApp: " .. (options.app or "nil") .. ", closeCompletely: " .. tostring(options.closeCompletely))

    SendNUIAction("closeApp", {
        app = options.app,
        closeCompletely = options.closeCompletely == true
    })
end)

local hiddenApps = {}

function GetHiddenApps()
    return hiddenApps
end

exports("SetAppHidden", function(app, hidden)
    hiddenApps[app] = hidden == true

    SendNUIAction("app:setHidden", {
        app = app,
        hidden = hidden == true
    })
end)

exports("SetAppInstalled", function(app, installed)
    SendNUIAction("app:setInstalled", {
        app = app,
        installed = installed == true
    })
end)
