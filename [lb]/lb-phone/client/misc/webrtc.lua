RegisterNUICallback("WebRTC", function(data, callback)
    local action = data.action

    if action == "createdPeer" then
        TriggerServerEvent("phone:webrtc:createdPeer", data.peerId)
    elseif action == "deletedPeer" then
        TriggerServerEvent("phone:webrtc:deletedPeer", data.peerId)
    elseif action == "signal" then
        TriggerServerEvent("phone:webrtc:signal", data.from, data.target, data.signalData)
    else
        debugprint("Unknown WebRTC action:", action)
    end

    callback("ok")
end)

RegisterNetEvent("phone:webrtc:signal", function(signalData)
    SendNUIAction("webrtc:signal", signalData)
end)

RegisterNetEvent("phone:webrtc:endCall", function(from)
    SendNUIAction("webrtc:endCall", {
        from = from
    })
end)
