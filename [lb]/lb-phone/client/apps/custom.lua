RegisterNUICallback("CustomApp", function(data, cb)
    local app = data.app
    local action = data.action

    cb("ok")

    if not action or not app then
        debugprint("invalid data")
        return
    end

    local appConfig = Config.CustomApps[app]

    if not appConfig then
        debugprint("Invalid custom app", app)
        return
    end

    if action == "open" then
        if appConfig.onServerUse then
            TriggerServerEvent("lb-phone:customApp", app)
        end

        if not appConfig.ui and not appConfig.keepOpen then
            debugprint("Closing phone due to custom app without ui")
            ToggleOpen(false)
        end

        if appConfig.onUse then
            Citizen.CreateThreadNow(function()
                appConfig.onUse()
            end)
        end

        if appConfig.onOpen then
            Citizen.CreateThreadNow(function()
                appConfig.onOpen()
            end)
        end
    elseif action == "close" then
        if appConfig.onClose then
            appConfig.onClose()
        end
    elseif action == "install" then
        if appConfig.onInstall then
            appConfig.onInstall()
        end
    elseif action == "uninstall" then
        if appConfig.onDelete then
            appConfig.onDelete()
        end
    end
end)

local componentCallbacks = {}

local validButtonColors = {
    blue = true,
    red = true,
    green = true,
    yellow = true
}

local function GenerateCallbackId()
    local id = math.random(999999999)

    while componentCallbacks[id] do
        id = math.random(999999999)
    end

    return id
end

RegisterNUICallback("PopUp", function(id, cb)
    if not componentCallbacks[id] then
        return
    end

    cb("ok")
    componentCallbacks[id]()
    componentCallbacks[id] = nil
end)

RegisterNUICallback("PopUpInputChanged", function(data, cb)
    local id = data.id
    local value = data.value

    if not componentCallbacks[id] then
        return
    end

    cb("ok")
    componentCallbacks[id](value)
end)

local function SetPopUp(options, cbOrExport)
    assert(options.buttons and #options.buttons > 0, "You need at least one button")

    options = table.clone(options)

    for _, button in pairs(options.buttons) do
        assert(button.title, "You need a title for each button")
        assert(validButtonColors[button.color or "blue"], "Invalid color")

        if cbOrExport == true then
            if button.cb then
                local callbackId = GenerateCallbackId()
                local buttonCallback = button.cb
                local originalCallbackId = button.callbackId

                componentCallbacks[callbackId] = function()
                    buttonCallback(originalCallbackId)
                end

                button.cb = callbackId
            end
        elseif button.callbackId then
            local callbackId = GenerateCallbackId()
            local originalCallbackId = button.callbackId

            componentCallbacks[callbackId] = function()
                cbOrExport(originalCallbackId)
            end

            button.cb = callbackId
        end
    end

    local inputs = options.inputs or {}

    if options.input then
        inputs[#inputs + 1] = options.input
    end

    for i = 1, #inputs do
        local input = inputs[i]

        if input.onChange then
            local callbackId = GenerateCallbackId()

            if cbOrExport == true then
                local onChange = input.onChange

                componentCallbacks[callbackId] = function(value)
                    onChange(value)
                end
            else
                componentCallbacks[callbackId] = function(value)
                    SendNUIAction("customApp:sendMessage", {
                        identifier = "any",
                        message = {
                            type = "popUpInputChanged",
                            value = value
                        }
                    })
                end
            end

            input.onChange = callbackId
        end
    end

    SendNUIAction("onComponentUse", {
        type = "popup",
        data = options
    })
end

RegisterNUICallback("SetPopUp", SetPopUp)

exports("SetPopUp", function(options)
    SetPopUp(options, true)
end)

RegisterNUICallback("ContextMenu", function(id, cb)
    if not componentCallbacks[id] then
        return
    end

    componentCallbacks[id]()
    componentCallbacks[id] = nil

    cb("ok")
end)

local function SetContextMenu(options, cbOrExport)
    assert(options.buttons and #options.buttons > 0, "You need at least one button")

    for _, button in pairs(options.buttons) do
        assert(button.title, "You need a title for each button")
        assert(validButtonColors[button.color or "blue"], "Invalid colour")

        if cbOrExport == true then
            assert(button.cb, "You need a callback for each button")
        else
            assert(button.callbackId, "You need a callback for each button")
        end

        local callbackId = GenerateCallbackId()
        local buttonCallback = button.cb
        local originalCallbackId = button.callbackId

        componentCallbacks[callbackId] = function()
            if cbOrExport == true then
                buttonCallback()
            else
                cbOrExport(originalCallbackId)
            end
        end

        button.cb = callbackId
    end

    SendNUIAction("onComponentUse", {
        type = "contextmenu",
        data = options
    })
end

RegisterNUICallback("SetContextMenu", SetContextMenu)

exports("SetContextMenu", function(options)
    SetContextMenu(options, true)
end)

local function SetCameraComponent(options, cb)
    if type(options) ~= "table" then
        options = {}
    end

    local resultPromise
    local wasPhoneOpen = phoneOpen
    local callbackId = GenerateCallbackId()

    options.id = callbackId

    if not wasPhoneOpen then
        debugprint("Opening phone due to camera component")
        ToggleOpen(true)
    end

    if not cb then
        resultPromise = promise.new()
    end

    componentCallbacks[callbackId] = function(result)
        if cb then
            cb(result.url)
        else
            resultPromise:resolve(result.url)
        end

        if not wasPhoneOpen then
            debugprint("Closing phone due to camera component")
            ToggleOpen(false)
        end
    end

    SendNUIAction("onComponentUse", {
        type = "camera",
        data = options
    })

    if not cb then
        return Citizen.Await(resultPromise)
    end
end

exports("SetCameraComponent", SetCameraComponent)

local function SetContactModal(data)
    assert(data, "You need to provide a phone number")

    SendNUIAction("onComponentUse", {
        type = "contactmodal",
        data = data
    })
end

RegisterNUICallback("SetContactModal", function(data, cb)
    SetContactModal(data)
    cb("ok")
end)

exports("SetContactModal", SetContactModal)

local componentReturnFields = {
    gallery = { "image" },
    gif = { "gif" },
    emoji = { "emoji" },
    camera = { "url" },
    colorpicker = { "color" },
    contactselector = { "contact" }
}

RegisterNUICallback("UsedComponent", function(data, cb)
    local id = data and data.id

    if not (id and componentCallbacks[id]) then
        return
    end

    componentCallbacks[id](data)
    componentCallbacks[id] = nil

    cb("ok")
end)

local function ShowComponent(options, cb)
    local component = options.component

    assert(component, "You need to specify a component")
    assert(componentReturnFields[component], "Invalid component")

    local callbackId = GenerateCallbackId()

    componentCallbacks[callbackId] = function(result)
        local values = {}
        local fields = componentReturnFields[component]

        for _, field in pairs(fields) do
            values[#values + 1] = result[field]
        end

        cb(table.unpack(values))
    end

    options.id = callbackId

    SendNUIAction("onComponentUse", {
        type = component,
        data = options
    })
end

RegisterNUICallback("ShowComponent", ShowComponent)
exports("ShowComponent", ShowComponent)

RegisterNUICallback("CreateCall", function(data, cb)
    CreateCall(data)
    cb("ok")
end)

RegisterNUICallback("GetSettings", function(data, cb)
    cb(settings)
end)

RegisterNUICallback("GetLocale", function(data, cb)
    cb(L(data.path, data.format))
end)

RegisterNUICallback("SendNotification", function(data, cb)
    if data and data.customData and data.customData.buttons then
        data.customData.buttons = nil
        debugprint("You cannot create notifications with buttons from the NUI.")
    end

    TriggerEvent("phone:sendNotification", data)
    cb(true)
end)
