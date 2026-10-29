RegisterNUICallback("voice:getConfig", function(data, callback)
    callback({
        recordNearbyVoices = Config.Voice.RecordNearby,
        rtc = Config.RTCConfig
    })
end)

if not Config.Voice.RecordNearby then
    return
end

local nearbyVoices = {}

local volumeInterval = Interval:new(function()
    local coords = GetEntityCoords(PlayerPedId())

    for _, voiceData in pairs(nearbyVoices) do
        local distance = #(coords - GetEntityCoords(voiceData.ped))
        local volume = GetVoiceVolume(distance)

        if volume ~= voiceData.volume then
            voiceData.volume = volume

            SendNUIAction("voice:setVolume", {
                channel = voiceData.channel,
                volume = volume
            })
        end
    end
end, 50, false)

Interval:new(function()
    local currentNearbyVoices = {}
    local nearbyPlayers = GetNearbyPlayers()
    local coords = GetEntityCoords(PlayerPedId())

    for i = 1, #nearbyPlayers do
        local player = nearbyPlayers[i]
        local state = Player(player.source).state
        local channel = state and state.listeningPeerId

        if channel then
            local distance = #(coords - GetEntityCoords(player.ped))

            if distance <= 25.0 then
                currentNearbyVoices[player.source] = {
                    source = player.source,
                    ped = player.ped,
                    channel = channel
                }

                local previousVoice = nearbyVoices[player.source]

                if previousVoice then
                    currentNearbyVoices[player.source].volume = previousVoice.volume
                else
                    local volume = GetVoiceVolume(distance)

                    currentNearbyVoices[player.source].volume = volume

                    SendNUIAction("voice:joinChannel", {
                        channel = channel,
                        volume = volume
                    })
                end
            end
        end
    end

    for source, voiceData in pairs(nearbyVoices) do
        if not currentNearbyVoices[source] then
            SendNUIAction("voice:leaveChannel", voiceData.channel)
        end
    end

    nearbyVoices = currentNearbyVoices
    volumeInterval:toggle(next(nearbyVoices) ~= nil)
end, 1000)

RegisterNetEvent("phone:startedListening", function(source, channel)
    local player = GetPlayerFromServerId(source)

    if not player or player == PlayerId() or player == -1 then
        return
    end

    local ped = PlayerPedId()
    local targetPed = GetPlayerPed(player)
    local distance = #(GetEntityCoords(ped) - GetEntityCoords(targetPed))

    if not DoesEntityExist(targetPed) or targetPed == ped or distance > 25.0 then
        return
    end

    if nearbyVoices[source] then
        return
    end

    local volume = GetVoiceVolume(distance)

    nearbyVoices[source] = {
        source = source,
        ped = targetPed,
        channel = channel,
        volume = volume
    }

    SendNUIAction("voice:joinChannel", {
        channel = channel,
        volume = volume
    })

    volumeInterval:toggle(true)
end)

RegisterNetEvent("phone:stoppedListening", function(source, channel)
    if not nearbyVoices[source] then
        return
    end

    SendNUIAction("voice:leaveChannel", channel)
    nearbyVoices[source] = nil
    volumeInterval:toggle(next(nearbyVoices) ~= nil)
end)

RegisterNUICallback("setListeningPeerId", function(peerId, callback)
    TriggerServerEvent("phone:setListeningPeerId", peerId)
    callback("ok")
end)
