local peerOwners = {}
local peersBySource = {}
local activeCalls = {}

local function EndCall(peerId, targetPeerId)
    if not activeCalls[peerId] or not activeCalls[peerId][targetPeerId] then
        return
    end

    local targetSource = peerOwners[targetPeerId]

    if targetSource then
        TriggerClientEvent("phone:webrtc:endCall", targetSource, peerId)
    end

    activeCalls[peerId][targetPeerId] = nil

    if activeCalls[targetPeerId] then
        activeCalls[targetPeerId][peerId] = nil
    end
end

local function DeletePeer(peerId)
    local playerId = peerOwners[peerId]

    if not playerId then
        return
    end

    local calls = activeCalls[peerId]

    if calls then
        for targetPeerId in pairs(calls) do
            EndCall(peerId, targetPeerId)
        end

        activeCalls[peerId] = nil
    end

    local playerPeers = peersBySource[playerId]

    if playerPeers then
        for i = 1, #playerPeers do
            if playerPeers[i] == peerId then
                table.remove(playerPeers, i)
                break
            end
        end

        if #playerPeers == 0 then
            peersBySource[playerId] = nil
        end
    end

    peerOwners[peerId] = nil
end

RegisterNetEvent("phone:webrtc:createdPeer", function(peerId)
    local playerId = source

    if peerOwners[peerId] then
        return
    end

    peerOwners[peerId] = playerId
    peersBySource[playerId] = peersBySource[playerId] or {}

    table.insert(peersBySource[playerId], peerId)
end)

RegisterNetEvent("phone:webrtc:deletedPeer", function(peerId)
    if peerOwners[peerId] ~= source then
        return
    end

    DeletePeer(peerId)
end)

RegisterNetEvent("phone:webrtc:signal", function(fromPeerId, targetPeerId, signalData)
    local playerId = source

    if peerOwners[fromPeerId] ~= playerId then
        return
    end

    local targetSource = peerOwners[targetPeerId]

    if not targetSource then
        return
    end

    if signalData.type == "offer" then
        activeCalls[fromPeerId] = activeCalls[fromPeerId] or {}
        activeCalls[targetPeerId] = activeCalls[targetPeerId] or {}
        activeCalls[fromPeerId][targetPeerId] = true
        activeCalls[targetPeerId][fromPeerId] = true
    end

    TriggerClientEvent("phone:webrtc:signal", targetSource, {
        signalData = signalData,
        from = fromPeerId,
        target = targetPeerId
    })
end)

AddEventHandler("playerDropped", function()
    local playerId = source
    local playerPeers = peersBySource[playerId]

    if not playerPeers then
        return
    end

    local peers = table.clone(playerPeers)

    for i = 1, #peers do
        DeletePeer(peers[i])
    end

    peersBySource[playerId] = nil
end)
