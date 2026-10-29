local updatingCoords = false
local playerPed = PlayerPedId()
local lastCoords = vector3(0, 0, 0)

local function AddSavedLocation(name, location)
    if not name then
        return false
    end

    local coords = location and vector2(location[2], location[1]) or GetEntityCoords(PlayerPedId())
    local id = AwaitCallback("maps:addLocation", name, coords.x, coords.y)

    if not id then
        return false
    end

    local savedLocation = {
        id = id,
        name = name,
        position = { coords.y, coords.x }
    }

    SavedLocations[#SavedLocations + 1] = savedLocation

    return savedLocation
end

local function SendCurrentCoords(coords)
    SendNUIAction("maps:updateCoords", {
        x = math.floor(coords.x + 0.5),
        y = math.floor(coords.y + 0.5)
    })
end

local function UpdateCoordsThread()
    playerPed = PlayerPedId()
    lastCoords = GetEntityCoords(playerPed)

    SendCurrentCoords(lastCoords)

    while updatingCoords do
        local coords = GetEntityCoords(playerPed)

        if phoneOpen and #(lastCoords - coords) > 1.0 then
            lastCoords = coords
            SendCurrentCoords(coords)
        end

        Wait(250)
    end
end

RegisterNUICallback("Maps", function(data, callback)
    local action = data.action

    debugprint("Maps:" .. (action or ""))

    if action == "getCurrentLocation" then
        local coords = GetEntityCoords(PlayerPedId())

        callback({
            x = coords.x,
            y = coords.y
        })
    elseif action == "toggleUpdateCoords" then
        callback("ok")

        if updatingCoords == data.toggle then
            return
        end

        updatingCoords = data.toggle == true
        UpdateCoordsThread()
    elseif action == "setWaypoint" then
        callback("ok")

        local waypoint = data.data
        local x = tonumber(waypoint.x)
        local y = tonumber(waypoint.y)

        if not x or not y then
            return
        end

        SetNewWaypoint(x / 1, y / 1)
    elseif action == "getLocations" then
        callback(SavedLocations)
    elseif action == "addLocation" then
        callback(AddSavedLocation(data.name, data.location))
    elseif action == "renameLocation" then
        local name = data.name
        local renamed = name and AwaitCallback("maps:renameLocation", data.id, name)

        if not renamed then
            return callback(false)
        end

        for i = 1, #SavedLocations do
            if SavedLocations[i].id == data.id then
                SavedLocations[i].name = name
                break
            end
        end

        callback(true)
    elseif action == "removeLocation" then
        local removed = AwaitCallback("maps:removeLocation", data.id)

        if not removed then
            return callback(false)
        end

        for i = 1, #SavedLocations do
            if SavedLocations[i].id == data.id then
                table.remove(SavedLocations, i)
                break
            end
        end

        callback(true)
    end
end)
