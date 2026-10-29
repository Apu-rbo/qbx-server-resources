local function AddSpeakerphoneTarget(targetSource, listenerSource, playFromSource)
    debugprint(
        DebugPlayerName(listenerSource)
            .. " is now speaking to "
            .. DebugPlayerName(targetSource)
            .. (playFromSource and (" (playing from %s)"):format(DebugPlayerName(playFromSource)) or "")
    )

    TriggerClientEvent("phone:phone:addVoiceTarget", listenerSource, {
        sources = targetSource
    })

    TriggerClientEvent("phone:phone:addVoiceTarget", targetSource, {
        sources = listenerSource,
        audio = true,
        phoneCall = true,
        playFromSource = playFromSource
    })
end

local function RemoveSpeakerphoneTarget(targetSource, listenerSource)
    debugprint(DebugPlayerName(listenerSource) .. " stopped speaking to " .. DebugPlayerName(targetSource))

    TriggerClientEvent("phone:phone:removeVoiceTarget", listenerSource, targetSource, true)
    TriggerClientEvent("phone:phone:removeVoiceTarget", targetSource, listenerSource, true)
end

local function GetCallSides(call, participantSource)
    local isCaller = call.caller.source == participantSource
    local participant = isCaller and call.caller or call.callee
    local otherParticipant = isCaller and call.callee or call.caller

    return isCaller, participant, otherParticipant
end

local function CloneNearbyWithSource(nearby, source)
    local list = table.clone(nearby)

    list[#list + 1] = source

    return list
end

RegisterNetEvent("phone:phone:toggleMute", function(muted)
    local playerSource = source
    local _, _, call = IsInCall(playerSource)

    if not call then
        return
    end

    local _, participant, otherParticipant = GetCallSides(call, playerSource)
    local otherSource = otherParticipant.source

    if not otherSource then
        return
    end

    muted = muted == true
    Player(playerSource).state.mutedCall = muted

    if not call.answered then
        return
    end

    local audibleSources = CloneNearbyWithSource(participant.nearby, playerSource)
    local listeners = CloneNearbyWithSource(otherParticipant.nearby, otherSource)

    for i = 1, #listeners do
        local listener = listeners[i]

        debugprint(
            DebugPlayerName(listener),
            "set " .. (muted and "not " or "") .. "audible for",
            audibleSources
        )

        TriggerClientEvent("phone:phone:setTargetsAudible", listener, audibleSources, not muted)
    end
end)

RegisterNetEvent("phone:phone:toggleSpeaker", function(enabled)
    Player(source).state.speakerphone = enabled == true
end)

RegisterNetEvent("phone:phone:enteredCallProximity", function(speakerSource)
    local nearbySource = source
    local _, _, call = IsInCall(speakerSource)

    debugprint(
        "phone:phone:enteredCallProximity:",
        DebugPlayerName(nearbySource),
        "entered the proximity of",
        DebugPlayerName(speakerSource)
    )

    if not call then
        debugprint(DebugPlayerName(speakerSource), "is not in a call")
        return
    end

    if not call.answered then
        debugprint("call not answered yet")
        return
    end

    local _, speaker, otherParticipant = GetCallSides(call, speakerSource)
    local speakerNearby = speaker.nearby
    local otherNearby = otherParticipant.nearby
    local otherSource = otherParticipant.source
    local speakerState = Player(speakerSource).state

    if not speakerState.speakerphone then
        debugprint(DebugPlayerName(speakerSource), "does not have speakerphone on")
        return
    end

    if not otherSource then
        debugprint("other call participant not found")
        return
    end

    local otherState = Player(otherSource).state

    if not speakerState.mutedCall then
        AddSpeakerphoneTarget(otherSource, nearbySource, otherSource)
    end

    if not otherState.mutedCall then
        AddSpeakerphoneTarget(nearbySource, otherSource, speakerSource)
    end

    for i = 1, #otherNearby do
        local otherNearbySource = otherNearby[i]

        if otherState.speakerphone and not speakerState.mutedCall then
            AddSpeakerphoneTarget(otherNearbySource, nearbySource, otherSource)
        end

        if otherState.speakerphone and not otherState.mutedCall then
            AddSpeakerphoneTarget(nearbySource, otherNearbySource, speakerSource)
        end
    end

    if table.contains(speakerNearby, nearbySource) then
        return
    end

    speakerNearby[#speakerNearby + 1] = nearbySource
end)

RegisterNetEvent("phone:phone:leftCallProximity", function(speakerSource)
    local nearbySource = source
    local _, _, call = IsInCall(speakerSource)

    if not call or not call.answered then
        return
    end

    local _, speaker, otherParticipant = GetCallSides(call, speakerSource)
    local speakerNearby = speaker.nearby
    local inProximity, index = table.contains(speakerNearby, nearbySource)

    if not inProximity then
        return
    end

    local otherSource = otherParticipant.source

    if not otherSource then
        return
    end

    debugprint("phone:phone:leftCallProximity", DebugPlayerName(nearbySource), DebugPlayerName(speakerSource))

    RemoveSpeakerphoneTarget(otherSource, nearbySource)
    table.remove(speakerNearby, index)

    local otherNearby = otherParticipant.nearby

    for i = 1, #otherNearby do
        RemoveSpeakerphoneTarget(otherNearby[i], nearbySource)
    end
end)

AddEventHandler("lb-phone:callEnded", function(call)
    local callerSource = call.caller.source
    local calleeSource = call.callee.source
    local callerNearby = call.caller.nearby and table.clone(call.caller.nearby)
    local calleeNearby = call.callee.nearby and table.clone(call.callee.nearby)

    if callerNearby and calleeSource and #callerNearby > 0 then
        TriggerClientEvent("phone:phone:removeVoiceTarget", calleeSource, callerNearby, true)

        for i = 1, #callerNearby do
            TriggerClientEvent("phone:phone:removeVoiceTarget", callerNearby[i], calleeSource, true)

            if calleeNearby and #calleeNearby > 0 then
                TriggerClientEvent("phone:phone:removeVoiceTarget", callerNearby[i], calleeNearby, true)
            end
        end
    end

    if calleeNearby and callerSource and #calleeNearby > 0 then
        TriggerClientEvent("phone:phone:removeVoiceTarget", callerSource, calleeNearby, true)

        for i = 1, #calleeNearby do
            TriggerClientEvent("phone:phone:removeVoiceTarget", calleeNearby[i], callerSource, true)

            if callerNearby and #callerNearby > 0 then
                TriggerClientEvent("phone:phone:removeVoiceTarget", calleeNearby[i], callerNearby, true)
            end
        end
    end
end)
