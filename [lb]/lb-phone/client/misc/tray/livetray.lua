local liveTrays = {}

local validOptions = {
    icon = true,
    title = true,
    text = true,
    color = true,
    progress = true,
    badge = true,
    expandable = true,
    buttons = true,
    duration = true,
    removable = true,
    embed = true,
    handlers = true
}

local function ValidateEmbed(embed)
    if embed == nil then
        return
    end

    assert(type(embed) == "table", "options.embed must be a table")
    assert(type(embed.url) == "string" or type(embed.html) == "string", "options.embed must contain either url or html")

    if embed.url and embed.html then
        error("options.embed cannot contain both url and html")
    end

    assert(embed.size == 3 or embed.size == 4 or embed.size == 5, "options.embed.size must be 3, 4 or 5")
end

local function PrepareButtons(buttons)
    if buttons == nil then
        return nil, {}
    end

    assert(type(buttons) == "table", "options.buttons must be a table")

    local nuiButtons = {}
    local buttonHandlers = {}

    for i = 1, #buttons do
        local button = buttons[i]

        assert(type(button) == "table", ("options.buttons[%s] must be a table"):format(i))
        assert(type(button.id) == "string", ("options.buttons[%s].id must be a string"):format(i))

        if button.click ~= nil then
            buttonHandlers[button.id] = button.click
        end

        nuiButtons[i] = {
            id = button.id,
            label = button.label,
            icon = button.icon,
            color = button.color
        }
    end

    return nuiButtons, buttonHandlers
end

local function ApplyDataOption(data, key, value)
    if key ~= "handlers" and key ~= "buttons" then
        data[key] = value
    end
end

local function RemoveLiveTray(id)
    liveTrays[id] = nil
    SendNUIAction("liveTray:remove", id)
end

local function RemoveLiveTraysForResource(resourceName)
    for id, tray in pairs(liveTrays) do
        if tray.resourceName == resourceName then
            RemoveLiveTray(id)
        end
    end
end

local function UpdateLiveTray(id, resourceName, update)
    local tray = liveTrays[id]

    if not tray then
        return false, "Live tray does not exist"
    end

    if tray.resourceName ~= resourceName then
        return false, "Live tray was not created by " .. resourceName
    end

    for key in pairs(update) do
        if not validOptions[key] then
            return false, "Invalid live tray option: " .. key
        end
    end

    if update.embed ~= nil then
        ValidateEmbed(update.embed)
    end

    if update.handlers ~= nil then
        assert(type(update.handlers) == "table", "options.handlers must be a table")

        tray.handlers = update.handlers
    end

    if update.buttons ~= nil then
        local buttons, buttonHandlers = PrepareButtons(update.buttons)

        tray.data.buttons = buttons
        tray.buttonHandlers = buttonHandlers
    end

    local nuiUpdate = {
        id = id
    }

    for key, value in pairs(update) do
        ApplyDataOption(tray.data, key, value)

        if key ~= "handlers" and key ~= "buttons" then
            nuiUpdate[key] = value
        end
    end

    if update.buttons ~= nil then
        nuiUpdate.buttons = tray.data.buttons
    end

    SendNUIAction("liveTray:update", nuiUpdate)

    return true
end

exports("ShowLiveTray", function(options)
    local resourceName = GetInvokingResource() or "lb-phone"

    assert(type(options) == "table", "options must be a table")
    assert(type(options.title) == "string", "options.title must be a string")

    ValidateEmbed(options.embed)

    if options.handlers ~= nil then
        assert(type(options.handlers) == "table", "options.handlers must be a table")
    end

    local buttons, buttonHandlers = PrepareButtons(options.buttons)
    local id = "livetray-" .. math.random(1, 1000000000)

    liveTrays[id] = {
        resourceName = resourceName,
        data = {
            id = id,
            resourceName = resourceName,
            icon = options.icon,
            title = options.title,
            text = options.text,
            color = options.color,
            progress = options.progress,
            badge = options.badge,
            expandable = options.expandable,
            buttons = buttons,
            duration = options.duration,
            removable = options.removable,
            embed = options.embed
        },
        handlers = options.handlers or {},
        buttonHandlers = buttonHandlers
    }

    SendNUIAction("liveTray:show", liveTrays[id].data)

    return id
end)

exports("UpdateLiveTray", function(id, option, value)
    local resourceName = GetInvokingResource()

    if not id then
        return false, "No id provided"
    end

    local update

    if type(option) == "table" then
        update = option
    elseif type(option) == "string" then
        if not validOptions[option] then
            return false, "Invalid live tray option: " .. option
        end

        update = {
            [option] = value
        }
    else
        return false, "No update provided"
    end

    return UpdateLiveTray(id, resourceName, update)
end)

exports("RemoveLiveTray", function(id)
    local resourceName = GetInvokingResource()

    if not id then
        RemoveLiveTraysForResource(resourceName)
        return true
    end

    local tray = liveTrays[id]

    if not tray then
        return false, "Live tray does not exist"
    end

    if tray.resourceName ~= resourceName then
        return false, "Live tray was not created by " .. resourceName
    end

    RemoveLiveTray(id)

    return true
end)

RegisterNUICallback("LiveTray", function(data, cb)
    cb("ok")

    if type(data) ~= "table" or type(data.id) ~= "string" or type(data.action) ~= "string" then
        return
    end

    local tray = liveTrays[data.id]

    if not tray or tray.resourceName ~= data.resourceName then
        return
    end

    local handlers = tray.handlers
    local action = data.action

    if action == "tap" then
        if handlers.tap then
            handlers.tap()
        end
    elseif action == "remove" then
        if handlers.remove then
            handlers.remove()
        end

        RemoveLiveTray(data.id)
    elseif action == "autoHide" then
        if handlers.autoHide then
            handlers.autoHide()
        end

        RemoveLiveTray(data.id)
    elseif action == "button" then
        if type(data.buttonId) == "string" then
            local handler = tray.buttonHandlers[data.buttonId]

            if handler then
                handler()
            end
        end
    elseif action == "update" and type(data.patch) == "table" then
        if UpdateLiveTray(data.id, tray.resourceName, data.patch) and handlers.update then
            handlers.update(data.patch)
        end
    end

    if handlers.action then
        if action == "button" then
            handlers.action(action, data.buttonId)
        elseif action == "update" then
            handlers.action(action, data.patch)
        else
            handlers.action(action)
        end
    end
end)

AddEventHandler("onResourceStop", function(resourceName)
    RemoveLiveTraysForResource(resourceName)
end)
