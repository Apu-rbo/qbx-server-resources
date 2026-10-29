local musicTrays = {}

local validOptions = {
    title = true,
    artist = true,
    album = true,
    cover = true,
    duration = true,
    position = true,
    playing = true,
    color = true,
    permissions = true,
    handlers = true
}

local function ValidatePermissions(permissions)
    if permissions == nil then
        return
    end

    assert(type(permissions) == "table", "options.permissions must be a table")
    assert(permissions.seek == nil or type(permissions.seek) == "boolean", "options.permissions.seek must be a boolean")
    assert(permissions.next == nil or type(permissions.next) == "boolean", "options.permissions.next must be a boolean")
    assert(permissions.previous == nil or type(permissions.previous) == "boolean", "options.permissions.previous must be a boolean")
end

local function ApplyPermissions(data, permissions)
    data.canSeek = permissions and permissions.seek
    data.canSkipNext = permissions and permissions.next
    data.canSkipPrev = permissions and permissions.previous
end

local function RemoveMusicTray(id)
    musicTrays[id] = nil
    SendNUIAction("musicTray:remove", id)
end

local function RemoveMusicTraysForResource(resourceName)
    for id, tray in pairs(musicTrays) do
        if tray.resourceName == resourceName then
            RemoveMusicTray(id)
        end
    end
end

exports("ShowMusicTray", function(options)
    local resourceName = GetInvokingResource() or "lb-phone"

    assert(type(options) == "table", "options must be a table")
    assert(type(options.title) == "string", "options.title must be a string")

    if options.id ~= nil then
        assert(type(options.id) == "string", "options.id must be a string")
    end

    ValidatePermissions(options.permissions)

    if options.handlers ~= nil then
        assert(type(options.handlers) == "table", "options.handlers must be a table")
    end

    local id = options.id or ("music-" .. math.random(1, 1000000000))

    if musicTrays[id] then
        return false, "Music tray already exists"
    end

    local data = {
        id = id,
        resourceName = resourceName,
        title = options.title,
        artist = options.artist,
        album = options.album,
        cover = options.cover,
        duration = options.duration,
        position = options.position,
        playing = options.playing,
        color = options.color
    }

    ApplyPermissions(data, options.permissions)

    musicTrays[id] = {
        resourceName = resourceName,
        data = data,
        handlers = options.handlers or {},
        permissions = options.permissions or {}
    }

    SendNUIAction("musicTray:show", data)

    return id
end)

exports("UpdateMusicTray", function(id, option, value)
    local resourceName = GetInvokingResource()

    if not id then
        return false, "No id provided"
    end

    local tray = musicTrays[id]

    if not tray then
        return false, "Music tray does not exist"
    end

    if tray.resourceName ~= resourceName then
        return false, "Music tray was not created by " .. resourceName
    end

    local update

    if type(option) == "table" then
        update = option
    elseif type(option) == "string" then
        if not validOptions[option] then
            return false, "Invalid music tray option: " .. option
        end

        update = {
            [option] = value
        }
    else
        return false, "No update provided"
    end

    for key in pairs(update) do
        if not validOptions[key] then
            return false, "Invalid music tray option: " .. key
        end
    end

    if update.permissions ~= nil then
        ValidatePermissions(update.permissions)

        tray.permissions = update.permissions
        ApplyPermissions(tray.data, update.permissions)
    end

    if update.handlers ~= nil then
        assert(type(update.handlers) == "table", "options.handlers must be a table")

        tray.handlers = update.handlers
    end

    local nuiUpdate = {
        id = id
    }

    for key, updateValue in pairs(update) do
        if key ~= "permissions" and key ~= "handlers" then
            tray.data[key] = updateValue
            nuiUpdate[key] = updateValue
        end
    end

    if update.permissions ~= nil then
        nuiUpdate.canSeek = tray.data.canSeek
        nuiUpdate.canSkipNext = tray.data.canSkipNext
        nuiUpdate.canSkipPrev = tray.data.canSkipPrev
    end

    SendNUIAction("musicTray:update", nuiUpdate)

    return true
end)

exports("RemoveMusicTray", function(id)
    local resourceName = GetInvokingResource()

    if not id then
        RemoveMusicTraysForResource(resourceName)
        return true
    end

    local tray = musicTrays[id]

    if not tray then
        return false, "Music tray does not exist"
    end

    if tray.resourceName ~= resourceName then
        return false, "Music tray was not created by " .. resourceName
    end

    RemoveMusicTray(id)

    return true
end)

RegisterNUICallback("MusicTray", function(data, cb)
    cb("ok")

    if type(data) ~= "table" or type(data.id) ~= "string" or type(data.action) ~= "string" then
        return
    end

    local tray = musicTrays[data.id]

    if not tray or tray.resourceName ~= data.resourceName then
        return
    end

    local handlers = tray.handlers
    local action = data.action

    if action == "play" and handlers.play then
        handlers.play()
    elseif action == "pause" and handlers.pause then
        handlers.pause()
    elseif action == "next" and handlers.next then
        handlers.next()
    elseif action == "previous" and handlers.previous then
        handlers.previous()
    elseif action == "seek" and handlers.seek then
        handlers.seek(data.position)
    end

    if handlers.action then
        if action == "seek" then
            handlers.action(action, data.position)
        else
            handlers.action(action)
        end
    end
end)

AddEventHandler("onResourceStop", function(resourceName)
    RemoveMusicTraysForResource(resourceName)
end)
