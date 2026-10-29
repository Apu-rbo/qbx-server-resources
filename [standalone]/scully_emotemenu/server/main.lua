RegisterNetEvent('scully_emotemenu:requestGroupEmote', function(senderData)
    local src = source

    if not senderData.CanGroupEmote then return end

    local senderPed = GetPlayerPed(src)
    local senderCoords = GetEntityCoords(senderPed)
    local players = lib.getNearbyPlayers(senderCoords, 10.0)
    local list = {}

    if #players > 0 then
        for i = 1, #players do
            local serverId = players[i].id

            if serverId ~= src then
                list[i] = players[i].id 
            end
        end
    end

    lib.triggerClientEvent('scully_emotemenu:groupEmoteRequest', list, src, senderData)
end)

RegisterNetEvent('scully_emotemenu:requestSynchronizedEmote', function(target, senderData, targetData)
    local src = source

    if not senderData.Synchronized then return end

    if senderData.SkipRequest then
        local senderPed, targetPed = GetPlayerPed(src), GetPlayerPed(target)
        local distance = #(GetEntityCoords(senderPed) - GetEntityCoords(targetPed))

        if distance < 5 then
            TriggerClientEvent('scully_emotemenu:targetStartSynchronizedEmote', target, src, senderData, targetData)
            TriggerClientEvent('scully_emotemenu:senderStartSynchronizedEmote', src, target, senderData)
        end

        return
    end

    TriggerClientEvent('scully_emotemenu:synchronizedEmoteRequest', target, src, senderData, targetData)
end)

RegisterNetEvent('scully_emotemenu:synchronizedEmoteResponse', function(sender, senderData, targetData)
    local src = source

    if not senderData.Synchronized then return end

    local senderPed, targetPed = GetPlayerPed(sender), GetPlayerPed(src)
    local distance = #(GetEntityCoords(senderPed) - GetEntityCoords(targetPed))

    if distance < 5 then
        TriggerClientEvent('scully_emotemenu:targetStartSynchronizedEmote', src, sender, senderData, targetData)
        TriggerClientEvent('scully_emotemenu:senderStartSynchronizedEmote', sender, src, senderData)
    end
end)