local function FormatVideo(video)
    if video.metadata then
        video.metadata = json.decode(video.metadata)
    end

    if video.music then
        video.music = json.decode(video.music)

        local song = Music.Songs[video.music and video.music.path]

        if song then
            local album = Music.Albums[song.album]

            if album and album.Cover then
                song.Cover = album.Cover
            end

            video.music = {
                title = song.Title,
                artist = song.Artist,
                cover = song.Cover,
                volume = video.music.volume,
                path = video.music.path
            }
        end
    end

    video.liked = video.liked == 1
    video.saved = video.saved == 1
    video.viewed = video.viewed == 1

    return video
end

local function EncodeUploadPayload(data)
    if not (data.src and data.caption) then
        return false, "invalid_caption"
    end

    if data.music then
        if not (data.music.path and data.music.volume) then
            return false, "invalid_music"
        end

        data.music = json.encode(data.music)
    end

    if data.metadata and type(data.metadata) == "table" and next(data.metadata) ~= nil then
        data.metadata = json.encode(data.metadata)
    else
        data.metadata = nil
    end

    return true
end

RegisterNUICallback("TikTok", function(data, cb)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("Trendy:" .. (action or ""))

    if action == "login" then
        local loginData = data.data

        TriggerCallback("tiktok:login", cb, loginData.username, loginData.password)
    elseif action == "signup" then
        local signupData = data.data

        TriggerCallback("tiktok:signup", cb, signupData.username, signupData.password, signupData.name)
    elseif action == "changePassword" then
        TriggerCallback("tiktok:changePassword", cb, data.oldPassword, data.newPassword)
    elseif action == "deleteAccount" then
        TriggerCallback("tiktok:deleteAccount", cb, data.password)
    elseif action == "logout" then
        TriggerCallback("tiktok:logout", cb)
    elseif action == "isLoggedIn" then
        TriggerCallback("tiktok:isLoggedIn", cb)
    elseif action == "getProfile" then
        TriggerCallback("tiktok:getProfile", cb, data.username)
    elseif action == "updateProfile" then
        TriggerCallback("tiktok:updateProfile", cb, data.data)
    elseif action == "searchAccounts" then
        TriggerCallback("tiktok:searchAccounts", cb, data.query, data.page)
    elseif action == "toggleFollow" then
        local followData = data.data

        TriggerCallback("tiktok:toggleFollow", cb, followData.username, followData.follow)
    elseif action == "getFollowing" then
        TriggerCallback("tiktok:getFollowing", cb, data.username, data.page)
    elseif action == "getFollowers" then
        TriggerCallback("tiktok:getFollowers", cb, data.username, data.page)
    elseif action == "uploadVideo" then
        local uploadData = data.data
        local valid, error = EncodeUploadPayload(uploadData)

        if not valid then
            return cb({
                success = false,
                error = error
            })
        end

        TriggerCallback("tiktok:uploadVideo", cb, uploadData)
    elseif action == "deleteVideo" then
        TriggerCallback("tiktok:deleteVideo", cb, data.id)
    elseif action == "togglePinnedVideo" then
        TriggerCallback("tiktok:togglePinnedVideo", cb, data.id, data.toggle)
    elseif action == "getVideos" then
        TriggerCallback("tiktok:getVideos", function(videos)
            for i = 1, #videos do
                videos[i] = FormatVideo(videos[i])
            end

            cb(videos)
        end, data.data, data.page or 0)
    elseif action == "getVideo" then
        TriggerCallback("tiktok:getVideo", function(response)
            if response.video then
                response.video = FormatVideo(response.video)
            end

            cb(response)
        end, data.id)
    elseif action == "setViewed" then
        TriggerServerEvent("phone:tiktok:setViewed", data.id)
        cb("ok")
    elseif action == "toggleLike" then
        TriggerCallback("tiktok:toggleVideoAction", cb, "like", data.id, data.toggle)
    elseif action == "toggleSave" then
        TriggerCallback("tiktok:toggleVideoAction", cb, "save", data.id, data.toggle)
    elseif action == "postComment" then
        local commentData = data.data

        TriggerCallback("tiktok:postComment", cb, commentData.id, commentData.replyTo, commentData.comment)
    elseif action == "getComments" then
        local commentData = data.data

        TriggerCallback(
            "tiktok:getComments",
            cb,
            commentData.id,
            commentData.replyTo,
            commentData.creator,
            data.page
        )
    elseif action == "deleteComment" then
        TriggerCallback("tiktok:deleteComment", cb, data.id, data.videoId)
    elseif action == "setPinnedComment" then
        TriggerCallback("tiktok:setPinnedComment", cb, data.commentId, data.videoId)
    elseif action == "toggleLikeComment" then
        TriggerCallback("tiktok:toggleLikeComment", cb, data.id, data.toggle)
    elseif action == "getRecentMessages" then
        TriggerCallback("tiktok:getRecentMessages", cb)
    elseif action == "getMessages" then
        TriggerCallback("tiktok:getMessages", cb, data.id, data.page)
    elseif action == "sendMessage" then
        if not CanInteract() then
            return cb(false)
        end

        TriggerCallback("tiktok:sendMessage", cb, data.data)
    elseif action == "getChannelId" then
        TriggerCallback("tiktok:getChannelId", cb, data.username)
    elseif action == "getNotifications" then
        TriggerCallback("tiktok:getNotifications", cb, data.page)
    elseif action == "getUnreadMessages" then
        TriggerCallback("tiktok:getUnreadMessages", cb)
    elseif action == "clearUnreadMessages" then
        TriggerServerEvent("phone:tiktok:clearUnreadMessages", data.id)
        cb("ok")
    else
        cb("ok")
    end
end)

RegisterNetEvent("phone:tiktok:updateFollowers", function(username, method)
    SendNUIAction("tiktok:updateFollowers", {
        username = username,
        method = method
    })
end)

RegisterNetEvent("phone:tiktok:updateFollowing", function(username, method)
    SendNUIAction("tiktok:updateFollowing", {
        username = username,
        method = method
    })
end)

RegisterNetEvent("phone:tiktok:updateVideoStats", function(action, id, method, count)
    local data = {
        id = id,
        method = method,
        count = count
    }

    if action == "like" then
        SendNUIAction("tiktok:updateLikes", data)
    elseif action == "save" then
        SendNUIAction("tiktok:updateSaves", data)
    elseif action == "comment" then
        SendNUIAction("tiktok:updateComments", data)
    end
end)

RegisterNetEvent("phone:tiktok:updateCommentStats", function(action, id, method)
    if action == "reply" then
        SendNUIAction("tiktok:updateReplies", {
            id = id,
            method = method
        })
    elseif action == "like" then
        SendNUIAction("tiktok:updateCommentLikes", {
            id = id,
            method = method
        })
    end
end)

RegisterNetEvent("phone:tiktok:receivedMessage", function(data)
    SendNUIAction("tiktok:receivedMessage", data)
end)

RegisterNetEvent("phone:tiktok:newVideo", function(data)
    TriggerEvent("lb-phone:trendy:newPost", data)
end)
