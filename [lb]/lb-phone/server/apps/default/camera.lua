RegisterCallback("camera:getPresignedUrl", function(source, uploadType)
    if Config.UploadMethod[uploadType] ~= "Fivemanage" then
        if GetPresignedUrl then
            return GetPresignedUrl(source, uploadType)
        end

        infoprint("warning", "GetPresignedUrl has not been set up. Set it up in lb-phone/server/custom/functions/functions.lua, or change your upload method to Fivemanage.")
        return
    end

    local status, body, headers, errorData = PerformHttpRequestAwait(
        "https://api.fivemanage.com/api/v3/file/presigned-url",
        "GET",
        "",
        {
            Authorization = API_KEYS[uploadType]
        }
    )

    if status ~= 200 or not body then
        infoprint("error", "Failed to get presigned URL from Fivemanage")
        print("Status:", status)
        print("Body:", body)
        print("Headers:", json.encode(headers or {}, { indent = true }))

        if errorData then
            print("Error:", errorData)
        end

        return
    end

    local decoded = json.decode(body)

    return decoded and decoded.data and decoded.data.presignedUrl
end)

RegisterNetEvent("phone:setListeningPeerId", function(peerId)
    if not Config.Voice.RecordNearby then
        return
    end

    local playerSource = source
    local playerState = Player(playerSource).state
    local previousPeerId = playerState.listeningPeerId

    if previousPeerId then
        TriggerClientEvent("phone:stoppedListening", -1, playerSource, previousPeerId)
    end

    playerState.listeningPeerId = peerId
    debugprint(playerSource, "set listeningPeerId to", peerId)

    if peerId then
        TriggerClientEvent("phone:startedListening", -1, playerSource, peerId)
    end
end)

AddEventHandler("playerDropped", function()
    local playerSource = source
    local listeningPeerId = Player(playerSource).state.listeningPeerId

    if listeningPeerId then
        debugprint(playerSource, "dropped, listeningPeerId", listeningPeerId)
        TriggerClientEvent("phone:stoppedListening", -1, playerSource, listeningPeerId)
    end
end)

RegisterCallback("camera:getUploadApiKey", function(source, uploadType)
    if not uploadType or not API_KEYS[uploadType] then
        return
    end

    local uploadMethod = Config.UploadMethod[uploadType]
    local methodConfig = UploadMethods[uploadMethod] and UploadMethods[uploadMethod][uploadType]

    if not methodConfig then
        methodConfig = UploadMethods[uploadMethod] and UploadMethods[uploadMethod].Default
    end

    if not methodConfig then
        return
    end

    local usesApiKey = methodConfig.url:find("API_KEY") ~= nil

    if not usesApiKey and methodConfig.headers then
        for _, headerValue in pairs(methodConfig.headers) do
            if headerValue:find("API_KEY") then
                usesApiKey = true
                break
            end
        end
    end

    if not usesApiKey then
        DropPlayer(source, "Tried to abuse the upload system")
        infoprint("warning", DebugPlayerName(source) .. " tried to abuse the upload system (attempted to steal API key)")
        return
    end

    return API_KEYS[uploadType]
end)

local function ForEachAlbumMember(albumId, handler, excludeOwner)
    local members = MySQL.query.await(
        "SELECT phone_number FROM phone_photo_album_members WHERE album_id = ?",
        { albumId }
    )

    if not members then
        return
    end

    if not excludeOwner then
        members[#members + 1] = {
            phone_number = MySQL.scalar.await(
                "SELECT phone_number FROM phone_photo_albums WHERE id = ?",
                { albumId }
            )
        }
    end

    for i = 1, #members do
        local phoneNumber = members[i].phone_number
        local memberSource = GetSourceFromNumber(phoneNumber)

        handler(phoneNumber, memberSource)
    end
end

local function GetAlbumData(albumId)
    local album = MySQL.single.await([[
        SELECT
            pa.id,
            pa.title,
            pa.shared,
            (
                SELECT
                    pp_cover.link
                FROM
                    phone_photos pp_cover
                JOIN
                    phone_photo_album_photos ap_cover ON ap_cover.photo_id = pp_cover.id
                WHERE
                    ap_cover.album_id = pa.id
                ORDER BY
                    ap_cover.photo_id DESC
                LIMIT 1
            ) AS cover,
            SUM(CASE WHEN pp.is_video = 1 THEN 1 ELSE 0 END) AS videoCount,
            SUM(CASE WHEN pp.is_video = 0 THEN 1 ELSE 0 END) AS photoCount
        FROM
            phone_photo_albums pa
        LEFT JOIN
            phone_photo_album_photos ap ON ap.album_id = pa.id
        LEFT JOIN
            phone_photos pp ON pp.id = ap.photo_id
        WHERE
            pa.id = ?
        GROUP BY
            pa.id, pa.title, pa.shared, pa.phone_number
    ]], { albumId })

    if not album then
        return
    end

    album.photoCount = tonumber(album.photoCount or 0)
    album.videoCount = tonumber(album.videoCount or 0)
    album.count = album.photoCount + album.videoCount

    return album
end

local function DoesPhoneNumberHaveAccessToAlbum(phoneNumber, albumId)
    local album = MySQL.single.await(
        "SELECT phone_number, shared FROM phone_photo_albums WHERE id = ?",
        { albumId }
    )

    if not album then
        debugprint("DoesPhoneNumberHaveAccessToAlbum: Album not found", phoneNumber, albumId)
        return false
    end

    if not album.shared then
        if album.phone_number ~= phoneNumber then
            debugprint("DoesPhoneNumberHaveAccessToAlbum: Private album, not the owner", phoneNumber, albumId)
            return false
        end
    elseif album.phone_number ~= phoneNumber then
        local isMember = MySQL.scalar.await(
            "SELECT 1 FROM phone_photo_album_members WHERE album_id = ? AND phone_number = ?",
            { albumId, phoneNumber }
        )

        if not isMember then
            debugprint("DoesPhoneNumberHaveAccessToAlbum: Album is shared, but not a member", phoneNumber, albumId)
            return false
        end
    end

    return album
end

local function UpdateAlbumForMembers(albumId)
    local album = GetAlbumData(albumId)

    if not album then
        return
    end

    ForEachAlbumMember(albumId, function(phoneNumber, memberSource)
        if memberSource then
            TriggerClientEvent("phone:photos:updateAlbum", memberSource, album)
        end
    end)
end

local validMetadata = {
    selfie = true,
    import = true,
    screenshot = true
}

BaseCallback("camera:saveToGallery", function(source, phoneNumber, link, size, isVideo, metadata, shouldLog)
    if not IsMediaLinkAllowed(link, source) then
        infoprint("error", ("%s %s tried to save an image with a link that is not allowed:"):format(source, phoneNumber), link)
        return false
    end

    if metadata and not validMetadata[metadata] then
        debugprint("Invalid metadata", metadata)
        metadata = nil
    end

    local photoId = MySQL.insert.await(
        "INSERT INTO phone_photos (phone_number, link, is_video, size, metadata) VALUES (?, ?, ?, ?, ?)",
        { phoneNumber, link, isVideo == true, size or 0, metadata }
    )

    if shouldLog then
        Log(
            "Uploads",
            source,
            "info",
            L("BACKEND.LOGS.UPLOADED_MEDIA"),
            L("BACKEND.LOGS.UPLOADED_MEDIA_DESCRIPTION", {
                type = isVideo and L("BACKEND.LOGS.VIDEO") or L("BACKEND.LOGS.PHOTO"),
                id = photoId,
                link = link
            }),
            link
        )
    end

    return photoId
end)

BaseCallback("camera:updateImage", function(source, phoneNumber, photoId, link, size)
    if not (photoId and link and size) or size < 0 then
        return false
    end

    if not IsMediaLinkAllowed(link, source) then
        infoprint("error", ("%s %s tried to update an image with a link that is not allowed:"):format(source, phoneNumber), link)
        return false
    end

    MySQL.update.await(
        "UPDATE phone_photos SET link = ?, size = ? WHERE id = ? AND phone_number = ? AND is_video = 0",
        { link, size, photoId, phoneNumber }
    )

    return true
end)

BaseCallback("camera:deleteFromGallery", function(source, phoneNumber, photoIds)
    local photos = MySQL.query.await(
        "SELECT link FROM phone_photos WHERE phone_number = ? AND id IN (?)",
        { phoneNumber, photoIds }
    )

    for i = 1, #photos do
        TriggerEvent("lb-phone:deletedFromGallery", source, phoneNumber, photos[i].link)
    end

    MySQL.update(
        "DELETE FROM phone_photos WHERE phone_number = ? AND id IN (?)",
        { phoneNumber, photoIds }
    )

    return true
end)

BaseCallback("camera:toggleFavourites", function(source, phoneNumber, favourite, photoIds)
    MySQL.update.await(
        "UPDATE phone_photos SET is_favourite = ? WHERE phone_number = ? AND id IN (?)",
        { favourite == true, phoneNumber, photoIds }
    )

    return true
end)

BaseCallback("camera:getImages", function(source, phoneNumber, filters, page)
    if not filters.showVideos and not filters.showPhotos then
        return {}
    end

    local params = { phoneNumber }
    local where = { "phone_number = ?" }
    local query = "SELECT id, link, is_video, size, metadata, is_favourite, `timestamp` FROM phone_photos {WHERE}"

    if filters.showPhotos ~= filters.showVideos then
        where[#where + 1] = "(is_video = ? OR is_video != ?)"
        params[#params + 1] = filters.showVideos == true
        params[#params + 1] = filters.showPhotos == true
    end

    if filters.favourites == true then
        where[#where + 1] = "is_favourite = 1"
    end

    if filters.type then
        where[#where + 1] = "metadata = ?"
        params[#params + 1] = filters.type
    end

    if filters.album then
        if not DoesPhoneNumberHaveAccessToAlbum(phoneNumber, filters.album) then
            debugprint("getImages: No access to album", phoneNumber, filters.album)
            return {}
        end

        table.remove(where, 1)
        table.remove(params, 1)

        where[#where + 1] = "id IN (SELECT ap.photo_id FROM phone_photo_album_photos ap WHERE ap.album_id = ?)"
        params[#params + 1] = filters.album
    end

    if filters.duplicates then
        where[#where + 1] = [[
            link IN (
                SELECT link
                FROM phone_photos
                WHERE phone_number = ?
                GROUP BY link
                HAVING COUNT(1) > 1
            )
        ]]
        params[#params + 1] = phoneNumber
    end

    local perPage = math.clamp(filters.perPage or 32, 1, 32)

    query = query .. " ORDER BY `timestamp` DESC LIMIT ?, ?"
    query = query:gsub("{WHERE}", #where > 0 and ("WHERE " .. table.concat(where, " AND ")) or "")

    params[#params + 1] = (page or 0) * perPage
    params[#params + 1] = perPage

    return MySQL.query.await(query, params)
end)

BaseCallback("camera:getLastImage", function(source, phoneNumber)
    return MySQL.scalar.await(
        "SELECT link FROM phone_photos WHERE phone_number = ? ORDER BY id DESC LIMIT 1",
        { phoneNumber }
    )
end)

BaseCallback("camera:createAlbum", function(source, phoneNumber, title)
    return MySQL.insert.await(
        "INSERT INTO phone_photo_albums (phone_number, title) VALUES (?, ?)",
        { phoneNumber, title }
    )
end)

BaseCallback("camera:renameAlbum", function(source, phoneNumber, albumId, title)
    local renamed = MySQL.update.await(
        "UPDATE phone_photo_albums SET title = ? WHERE phone_number = ? AND id = ?",
        { title, phoneNumber, albumId }
    ) > 0

    if renamed then
        local shared = MySQL.scalar.await(
            "SELECT shared FROM phone_photo_albums WHERE id = ?",
            { albumId }
        )

        if shared then
            ForEachAlbumMember(albumId, function(memberNumber, memberSource)
                if memberSource then
                    TriggerClientEvent("phone:photos:renameAlbum", memberSource, albumId, title)
                end
            end, true)
        end
    end

    return renamed
end)

BaseCallback("camera:addToAlbum", function(source, phoneNumber, albumId, photoIds)
    local album = DoesPhoneNumberHaveAccessToAlbum(phoneNumber, albumId)

    if not album then
        debugprint("No access to album", phoneNumber, albumId)
        return false
    end

    MySQL.update.await(
        "INSERT IGNORE INTO phone_photo_album_photos (album_id, photo_id) SELECT ?, id FROM phone_photos WHERE phone_number = ? AND id IN (?)",
        { albumId, phoneNumber, photoIds }
    )

    debugprint("Added photos to album", phoneNumber, albumId, photoIds)

    if album.shared then
        UpdateAlbumForMembers(albumId)
    end

    return true
end)

BaseCallback("camera:removeFromAlbum", function(source, phoneNumber, albumId, photoIds)
    if not DoesPhoneNumberHaveAccessToAlbum(phoneNumber, albumId) then
        debugprint("No access to album", phoneNumber, albumId)
        return false
    end

    MySQL.update.await(
        "DELETE FROM phone_photo_album_photos WHERE album_id = ? AND photo_id IN (?)",
        { albumId, photoIds }
    )

    UpdateAlbumForMembers(albumId)

    return true
end)

BaseCallback("camera:deleteAlbum", function(source, phoneNumber, albumId)
    local album = MySQL.single.await(
        "SELECT shared FROM phone_photo_albums WHERE phone_number = ? AND id = ?",
        { phoneNumber, albumId }
    )

    if not album then
        debugprint("deleteAlbum: Album not found", phoneNumber, albumId)
        return false
    end

    if album.shared then
        ForEachAlbumMember(albumId, function(memberNumber, memberSource)
            if memberSource then
                TriggerClientEvent("phone:photos:removeMemberFromAlbum", memberSource, albumId, memberNumber)
            end
        end, true)
    end

    MySQL.update(
        "DELETE FROM phone_photo_albums WHERE phone_number = ? AND id = ?",
        { phoneNumber, albumId }
    )

    return true
end)

local mediaTypeKeys = {
    "videos",
    "photos",
    "favouritesVideos",
    "favouritesPhotos",
    "selfiesVideos",
    "selfiesPhotos",
    "screenshotsVideos",
    "screenshotsPhotos",
    "importsVideos",
    "importsPhotos",
    "duplicatesPhotos",
    "duplicatesVideos"
}

BaseCallback("camera:getHomePageData", function(source, phoneNumber)
    local mediaTypes = MySQL.single.await([[
        SELECT
            SUM(is_video = 1) AS videos,
            SUM(is_video = 0) AS photos,
            SUM(is_video = 1 AND is_favourite = 1) AS favouritesVideos,
            SUM(is_video = 0 AND is_favourite = 1) AS favouritesPhotos,
            SUM(metadata = 'selfie' AND is_video = 1) AS selfiesVideos,
            SUM(metadata = 'selfie' AND is_video = 0) AS selfiesPhotos,
            SUM(metadata = 'screenshot' AND is_video = 1) AS screenshotsVideos,
            SUM(metadata = 'screenshot' AND is_video = 0) AS screenshotsPhotos,
            SUM(metadata = 'import' AND is_video = 1) AS importsVideos,
            SUM(metadata = 'import' AND is_video = 0) AS importsPhotos

        FROM phone_photos
        WHERE phone_number = ?
    ]], { phoneNumber })

    mediaTypes.duplicatesPhotos = tonumber(mediaTypes.photos or 0) - MySQL.scalar.await([[
        SELECT COUNT(DISTINCT link)
        FROM phone_photos
        WHERE phone_number = ? AND is_video = 0
    ]], { phoneNumber })

    mediaTypes.duplicatesVideos = tonumber(mediaTypes.videos or 0) - MySQL.scalar.await([[
        SELECT COUNT(DISTINCT link)
        FROM phone_photos
        WHERE phone_number = ? AND is_video = 1
    ]], { phoneNumber })

    for i = 1, #mediaTypeKeys do
        local key = mediaTypeKeys[i]

        mediaTypes[key] = tonumber(mediaTypes[key] or 0)
    end

    if mediaTypes.duplicatesPhotos > 0 then
        mediaTypes.duplicatesPhotos = mediaTypes.duplicatesPhotos + 1
    end

    if mediaTypes.duplicatesVideos > 0 then
        mediaTypes.duplicatesVideos = mediaTypes.duplicatesVideos + 1
    end

    local albums = {
        {
            id = "recents",
            title = L("APPS.PHOTOS.RECENTS"),
            videoCount = mediaTypes.videos,
            photoCount = mediaTypes.photos,
            cover = MySQL.scalar.await(
                "SELECT link FROM phone_photos WHERE phone_number = ? ORDER BY id DESC LIMIT 1",
                { phoneNumber }
            ),
            removable = false
        },
        {
            id = "favourites",
            title = L("APPS.PHOTOS.FAVOURITES"),
            videoCount = mediaTypes.favouritesVideos,
            photoCount = mediaTypes.favouritesPhotos,
            cover = MySQL.scalar.await(
                "SELECT link FROM phone_photos WHERE phone_number = ? AND is_favourite = 1 ORDER BY id DESC LIMIT 1",
                { phoneNumber }
            ),
            removable = false
        }
    }

    local customAlbums = MySQL.query.await([[
        SELECT
            pa.id,
            pa.title,
            pa.shared,
            pa.phone_number,
            (
                SELECT
                    pp_cover.link
                FROM
                    phone_photos pp_cover
                JOIN
                    phone_photo_album_photos ap_cover ON ap_cover.photo_id = pp_cover.id
                WHERE
                    ap_cover.album_id = pa.id
                ORDER BY
                    ap_cover.photo_id DESC
                LIMIT 1
            ) AS cover,
            SUM(CASE WHEN pp.is_video = 1 THEN 1 ELSE 0 END) AS videoCount,
            SUM(CASE WHEN pp.is_video = 0 THEN 1 ELSE 0 END) AS photoCount
        FROM
            phone_photo_albums pa
        LEFT JOIN
            phone_photo_album_photos ap ON ap.album_id = pa.id
        LEFT JOIN
            phone_photos pp ON pp.id = ap.photo_id
        WHERE
            pa.phone_number = ?
            OR EXISTS (
                SELECT 1
                FROM phone_photo_album_members member
                WHERE member.album_id = pa.id AND member.phone_number = ?
            )
        GROUP BY
            pa.id, pa.title, pa.shared, pa.phone_number
        ORDER BY
            pa.id ASC
    ]], { phoneNumber, phoneNumber })

    for i = 1, #customAlbums do
        local album = customAlbums[i]

        album.removable = true
        album.isOwner = album.phone_number == phoneNumber
        album.phone_number = nil

        albums[#albums + 1] = album
    end

    for i = 1, #albums do
        local album = albums[i]

        album.photoCount = tonumber(album.photoCount or 0)
        album.videoCount = tonumber(album.videoCount or 0)
        album.count = album.photoCount + album.videoCount
    end

    return {
        albums = albums,
        mediaTypes = mediaTypes
    }
end, {
    albums = {},
    mediaTypes = {}
})

BaseCallback("camera:getAlbumMembers", function(source, phoneNumber, albumId)
    if not DoesPhoneNumberHaveAccessToAlbum(phoneNumber, albumId) then
        debugprint("getAlbumMembers: No access to album", phoneNumber, albumId)
        return false
    end

    local members = {}
    local owner = MySQL.scalar.await(
        "SELECT phone_number FROM phone_photo_albums WHERE id = ?",
        { albumId }
    )
    local albumMembers = MySQL.query.await(
        "SELECT phone_number FROM phone_photo_album_members WHERE album_id = ?",
        { albumId }
    )

    for i = 1, #albumMembers do
        members[i] = albumMembers[i].phone_number
    end

    members[#members + 1] = owner

    return members
end)

local function RemoveMemberFromAlbum(phoneNumber, albumId)
    local removed = MySQL.update.await(
        "DELETE FROM phone_photo_album_members WHERE album_id = ? AND phone_number = ?",
        { albumId, phoneNumber }
    ) > 0

    if not removed then
        debugprint("removeMemberFromAlbum: failed to remove member from album", phoneNumber, albumId)
        return false
    end

    local memberCount = MySQL.scalar.await(
        "SELECT COUNT(1) FROM phone_photo_album_members WHERE album_id = ?",
        { albumId }
    )

    ForEachAlbumMember(albumId, function(memberNumber, memberSource)
        if memberSource then
            TriggerClientEvent("phone:photos:removeMemberFromAlbum", memberSource, albumId, phoneNumber)
        end
    end)

    if memberCount == 0 then
        MySQL.update.await(
            "UPDATE phone_photo_albums SET shared = 0 WHERE id = ?",
            { albumId }
        )
    end

    local removedSource = GetSourceFromNumber(phoneNumber)

    if removedSource then
        TriggerClientEvent("phone:photos:removeMemberFromAlbum", removedSource, albumId, phoneNumber)
    end

    return true
end

BaseCallback("camera:removeMemberFromAlbum", function(source, phoneNumber, memberNumber, albumId)
    local isOwner = MySQL.scalar.await(
        "SELECT 1 FROM phone_photo_albums WHERE id = ? AND phone_number = ?",
        { albumId, phoneNumber }
    )

    if not isOwner then
        debugprint("removeMemberFromAlbum: not the owner of the album", phoneNumber, albumId)
        return
    end

    return RemoveMemberFromAlbum(memberNumber, albumId)
end)

BaseCallback("camera:leaveSharedAlbum", function(source, phoneNumber, albumId)
    RemoveMemberFromAlbum(phoneNumber, albumId)

    return true
end)

function HandleAcceptAirShareAlbum(receiverSource, senderSource, albumId)
    local senderPhoneNumber = GetEquippedPhoneNumber(senderSource)
    local receiverPhoneNumber = GetEquippedPhoneNumber(receiverSource)

    if not senderPhoneNumber or not receiverPhoneNumber then
        debugprint("HandleAcceptAirShareAlbum: senderPhoneNumber/recipientPhoneNumber not found", senderPhoneNumber, receiverPhoneNumber)
        return
    end

    local alreadyMember = MySQL.scalar.await(
        "SELECT 1 FROM phone_photo_album_members WHERE album_id = ? AND phone_number = ?",
        { albumId, receiverPhoneNumber }
    )

    if alreadyMember then
        debugprint("HandleAcceptAirShareAlbum: recipient is already a member of the album", senderPhoneNumber, receiverPhoneNumber, albumId)
        return
    end

    local senderIsOwner = MySQL.scalar.await(
        "SELECT 1 FROM phone_photo_albums WHERE id = ? AND phone_number = ?",
        { albumId, senderPhoneNumber }
    )

    if not senderIsOwner then
        debugprint("HandleAcceptAirShareAlbum: sender is not the owner of the album", senderPhoneNumber, receiverPhoneNumber, albumId)
        return
    end

    MySQL.update.await(
        "UPDATE phone_photo_albums SET shared = 1 WHERE id = ?",
        { albumId }
    )

    local albumData = GetAlbumData(albumId)

    if not albumData then
        debugprint("HandleAcceptAirShareAlbum: albumData not found", senderPhoneNumber, receiverPhoneNumber, albumId)
        return
    end

    ForEachAlbumMember(albumId, function(memberNumber, memberSource)
        if memberSource and memberSource ~= receiverSource then
            TriggerClientEvent("phone:photos:addMemberToAlbum", memberSource, albumId, receiverPhoneNumber)
        end
    end)

    MySQL.insert(
        "INSERT INTO phone_photo_album_members (album_id, phone_number) VALUES (?, ?) ON DUPLICATE KEY UPDATE phone_number = ?",
        { albumId, receiverPhoneNumber, receiverPhoneNumber }
    )

    TriggerClientEvent("phone:photos:addSharedAlbum", receiverSource, albumData)
end

SetTimeout(500, function()
    local apiKey = GetConvar("FIVEMANAGE_MEDIA_API_KEY", "")

    if apiKey == "" then
        return
    end

    for uploadType, currentKey in pairs(API_KEYS) do
        if Config.UploadMethod[uploadType] == "Fivemanage" and (currentKey == "API_KEY_HERE" or currentKey == "") then
            API_KEYS[uploadType] = apiKey
            debugprint("Set API_KEYS['" .. uploadType .. "'] to FIVEMANAGE_MEDIA_API_KEY")
        end
    end
end)
