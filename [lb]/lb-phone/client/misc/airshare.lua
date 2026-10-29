local function GetNearbyDevices()
    local devices = {}
    local nearbyPlayers = GetNearbyPlayers()
    local coords = GetEntityCoords(PlayerPedId())

    debugprint("Nearby players:", nearbyPlayers)

    for i = 1, #nearbyPlayers do
        local player = nearbyPlayers[i]
        local state = Player(player.source).state
        local distance = #(coords - GetEntityCoords(player.ped))

        if distance > 7.5 then
            debugprint("Player is too far away", player.source)
        else
            debugprint("Player data", player.source, player)

            if state.lbTabletOpen then
                debugprint("Player has tablet open", player.source)

                devices[#devices + 1] = {
                    name = state.lbTabletName or "??",
                    source = player.source,
                    device = "tablet"
                }
            elseif state.phoneOpen then
                debugprint("Player has phone open", player.source)

                devices[#devices + 1] = {
                    name = state.phoneName or "??",
                    source = player.source,
                    device = "phone"
                }
            else
                debugprint("Player has no device open", player.source)
            end
        end
    end

    debugprint("Nearby devices:", devices)

    return devices
end

RegisterNUICallback("AirShare", function(data, callback)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("AirShare:" .. (action or ""))

    if action == "getNearby" then
        callback(GetNearbyDevices())
    elseif action == "share" then
        TriggerCallback("airShare:share", callback, data.source, data.device, data.data)
    elseif action == "accept" then
        TriggerServerEvent("phone:airShare:interacted", data.source, data.device, true)
        callback("ok")
    elseif action == "deny" then
        TriggerServerEvent("phone:airShare:interacted", data.source, data.device, false)
        callback("ok")
    end
end)

RegisterNetEvent("phone:airShare:received", function(data)
    debugprint("phone:airShare:received", data)
    SendNUIAction("airShare:received", data)
end)

RegisterNetEvent("phone:airShare:interacted", function(source, accepted)
    SendNUIAction("airShare:interacted", {
        source = source,
        accepted = accepted
    })
end)
