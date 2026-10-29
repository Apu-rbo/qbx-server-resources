if not Config.Voice.HearNearby then
    return
end

local nearbyLives = {}

local function EnterLiveProximity(liveId)
    if nearbyLives[liveId] then
        return
    end

    nearbyLives[liveId] = true

    debugprint("entered live", liveId)
    TriggerServerEvent("phone:instagram:enteredLiveProximity", liveId)
end

local function LeaveLiveProximity(liveId)
    if not nearbyLives[liveId] then
        return
    end

    nearbyLives[liveId] = nil

    debugprint("left live 1", liveId)
    TriggerServerEvent("phone:instagram:leftLiveProximity", liveId)
end

RegisterNetEvent("phone:instagram:endLive", function(liveId, hostSource)
    if not hostSource then
        nearbyLives[liveId] = nil
        return debugprint("left live 2", liveId)
    end

    if nearbyLives[liveId] then
        nearbyLives[liveId] = nil
        TriggerServerEvent("phone:instagram:leftLiveProximity", hostSource, true)
    end
end)

local nearbyCallSources = {}

local function LeaveCallProximity(source)
    if not source then
        return
    end

    local inProximity, index = table.contains(nearbyCallSources, source)

    if not inProximity then
        return
    end

    debugprint("left proximity of", source)
    TriggerServerEvent("phone:phone:leftCallProximity", source)

    if Config.Voice.SpatialAudio then
        ResetSpatialAudioSubmixForSource(source)
    end

    table.remove(nearbyCallSources, index)

    return true
end

local function EnterCallProximity(source)
    if not source or table.contains(nearbyCallSources, source) then
        return
    end

    debugprint("entered proximity of", source)
    TriggerServerEvent("phone:phone:enteredCallProximity", source)

    if Config.Voice.SpatialAudio then
        SetSpatialAudioSubmixForSource(source)
    end

    nearbyCallSources[#nearbyCallSources + 1] = source

    return true
end

local hearNearbyInterval = Interval:new(function()
    local nearbyPlayers = GetNearbyPlayers()
    local playerCoords = GetEntityCoords(PlayerPedId())

    for i = 1, #nearbyPlayers do
        local nearbyPlayer = nearbyPlayers[i]
        local state = Player(nearbyPlayer.source).state
        local callOnSpeaker = state.onCallWith and state.speakerphone and state.callAnswered
        local liveId = state.instapicIsLive
        local distance = #(playerCoords - GetEntityCoords(nearbyPlayer.ped))

        if distance <= 10 then
            if liveId then
                EnterLiveProximity(liveId)
            elseif callOnSpeaker then
                EnterCallProximity(nearbyPlayer.source)
            elseif state.onCallWith then
                LeaveCallProximity(nearbyPlayer.source)
            end
        elseif liveId then
            LeaveLiveProximity(liveId)
        elseif state.onCallWith then
            LeaveCallProximity(nearbyPlayer.source)
        end
    end

    for i = 1, #nearbyCallSources do
        local source = nearbyCallSources[i]

        if not Player(source).state.onCallWith then
            LeaveCallProximity(source)
        end
    end
end, 250, false)

hearNearbyInterval.onStart = function()
    debugprint("Hear nearby interval started")
end

hearNearbyInterval.onStop = function()
    debugprint("Hear nearby interval stopped")

    for i = 1, #nearbyCallSources do
        local source = nearbyCallSources[i]

        debugprint("left proximity of", source)
        TriggerServerEvent("phone:phone:leftCallProximity", source)

        if Config.Voice.SpatialAudio then
            ResetSpatialAudioSubmixForSource(source)
        end
    end

    table.wipe(nearbyCallSources)

    for liveId in pairs(nearbyLives) do
        LeaveLiveProximity(liveId)
    end
end

local trackedStateNames = {
    "onCallWith",
    "speakerphone",
    "callAnswered",
    "instapicIsLive"
}

local trackedPlayers = {}

for i = 1, #trackedStateNames do
    AddStateBagChangeHandler(trackedStateNames[i], nil, function(bagName, key, value)
        local serverId = GetPlayerDataFromStateBag(bagName)

        if not serverId or serverId == GetPlayerServerId(PlayerId()) then
            return
        end

        Wait(0)

        if value then
            trackedPlayers[serverId] = trackedPlayers[serverId] or {}
            trackedPlayers[serverId][key] = true

            hearNearbyInterval:toggle(true)
        elseif trackedPlayers[serverId] then
            trackedPlayers[serverId][key] = nil

            if next(trackedPlayers[serverId]) == nil then
                trackedPlayers[serverId] = nil
            end
        end

        if not next(trackedPlayers) then
            hearNearbyInterval:toggle(false)
        end
    end)
end

RegisterNetEvent("onPlayerDropped", function(source)
    trackedPlayers[source] = nil

    if not next(trackedPlayers) then
        hearNearbyInterval:toggle(false)
    end
end)
