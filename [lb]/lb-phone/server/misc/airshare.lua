local pendingAlbumShares = {}

BaseCallback("airShare:share", function(source, phoneNumber, targetSource, targetDevice, data)
    local senderName = Player(source).state.phoneName or phoneNumber

    data.sender = {
        name = senderName,
        source = source,
        device = "phone"
    }

    if targetDevice == "tablet" then
        if GetResourceState("lb-tablet") ~= "started" or not Player(targetSource).state.lbTabletOpen then
            return false
        end

        TriggerClientEvent("tablet:airShare:received", targetSource, data)
    elseif targetDevice == "phone" then
        if not Player(targetSource).state.phoneOpen then
            debugprint("sendToSource's phone is not open")
            return false
        end

        TriggerClientEvent("phone:airShare:received", targetSource, data)
    end

    if data.type == "album" then
        pendingAlbumShares[targetSource] = pendingAlbumShares[targetSource] or {}
        pendingAlbumShares[targetSource][source] = data.album.id
    end

    return true
end, false)

RegisterNetEvent("phone:airShare:interacted", function(senderSource, senderDevice, accepted)
    local receiverSource = source

    if type(senderSource) ~= "number" or type(senderDevice) ~= "string" then
        debugprint("AirShare:interacted: Invalid senderSource or senderDevice", senderSource, senderDevice)
        return
    end

    if senderDevice == "tablet" then
        TriggerClientEvent("tablet:airShare:interacted", senderSource, receiverSource, accepted)
    elseif senderDevice == "phone" then
        TriggerClientEvent("phone:airShare:interacted", senderSource, receiverSource, accepted)
    end

    local receiverShares = pendingAlbumShares[receiverSource]
    local albumId = receiverShares and receiverShares[senderSource]

    if not albumId then
        return
    end

    receiverShares[senderSource] = nil

    if not next(receiverShares) then
        pendingAlbumShares[receiverSource] = nil
    end

    if not accepted then
        debugprint("AirShare: denied album share", albumId)
        return
    end

    debugprint("AirShare: accepted album share", albumId)
    HandleAcceptAirShareAlbum(receiverSource, senderSource, albumId)
end)

local validShareTypes = {
    image = true,
    contact = true,
    location = true,
    note = true,
    voicememo = true
}

exports("AirShare", function(sender, target, shareType, data)
    assert(type(sender) == "number", "Invalid sender")
    assert(type(target) == "number", "Invalid target")
    assert(validShareTypes[shareType], "Invalid shareType")
    assert(type(data) == "table", "Invalid data")

    local phoneNumber = GetEquippedPhoneNumber(sender)

    if not phoneNumber then
        return false
    end

    local shareData = {
        type = shareType,
        sender = {
            name = (Player(sender) and Player(sender).state.phoneName) or phoneNumber,
            source = sender,
            device = "phone"
        }
    }

    if shareType == "image" then
        assert(data.src, "Invalid image data (missing src)")

        shareData.attachment = data
        shareData.attachment.timestamp = shareData.attachment.timestamp or os.time() * 1000
    elseif shareType == "contact" then
        shareData.contact = data

        assert(type(shareData.contact.number) == "string", "Invalid/missing contact data (contact.number)")
        assert(type(shareData.contact.firstname) == "string", "Invalid/missing contact data (contact.firstname)")
    elseif shareType == "location" then
        assert(data.location, "Invalid location data (missing location)")
        assert(type(data.name) == "string", "Invalid/missing location data (location.name)")

        shareData.location = data.location
        shareData.name = data.name
    elseif shareType == "note" then
        shareData.note = data

        assert(type(shareData.note.title) == "string", "Invalid/missing note data (note.title)")
        assert(type(shareData.note.content) == "string", "Invalid/missing note data (note.content)")
    elseif shareType == "voicememo" then
        shareData.voicememo = data

        assert(type(shareData.voicememo.title) == "string", "Invalid/missing voicememo data (voicememo.title)")
        assert(type(shareData.voicememo.src) == "string", "Invalid/missing voicememo data (voicememo.src)")
        assert(type(shareData.voicememo.duration) == "number", "Invalid/missing voicememo data (voicememo.duration)")
    end

    TriggerClientEvent("phone:airShare:received", target, shareData)
end)

AddEventHandler("playerDropped", function()
    pendingAlbumShares[source] = nil
end)
