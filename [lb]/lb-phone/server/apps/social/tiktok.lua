local function GetLoggedInTiktokUsername(source)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return false
    end

    return GetLoggedInAccount(phoneNumber, "TikTok")
end

local function RegisterTiktokCallback(name, handler, defaultReturn)
    BaseCallback("tiktok:" .. name, function(source, phoneNumber, ...)
        local username = GetLoggedInAccount(phoneNumber, "TikTok")

        if not username then
            return defaultReturn
        end

        return handler(source, phoneNumber, username, ...)
    end, defaultReturn)
end

local profileFields = "`name`, bio, avatar, username, verified, follower_count, following_count, like_count, twitter, instagram, show_likes"

local function GetTiktokProfile(username, loggedInUsername)
    local profile

    if loggedInUsername then
        profile = MySQL.Sync.fetchAll(([[
            SELECT %s,
                (SELECT TRUE FROM phone_tiktok_follows WHERE follower = @username AND followed = @loggedIn) AS isFollowingYou,
                (SELECT TRUE FROM phone_tiktok_follows WHERE follower = @loggedIn AND followed = @username) AS isFollowing
            FROM phone_tiktok_accounts WHERE username = @username
        ]]):format(profileFields), {
            ["@username"] = username,
            ["@loggedIn"] = loggedInUsername
        })
        profile = profile and profile[1]
    else
        profile = MySQL.Sync.fetchAll(("SELECT %s FROM phone_tiktok_accounts WHERE username = @username"):format(profileFields), {
            ["@username"] = username
        })
        profile = profile and profile[1]
    end

    if profile then
        profile.isFollowing = profile.isFollowing == 1 or profile.isFollowing == true
        profile.isFollowingYou = profile.isFollowingYou == 1 or profile.isFollowingYou == true
    end

    return profile
end

local notificationTranslation = {
    like = "BACKEND.TIKTOK.LIKE",
    save = "BACKEND.TIKTOK.SAVE",
    comment = "BACKEND.TIKTOK.COMMENT",
    follow = "BACKEND.TIKTOK.FOLLOW",
    like_comment = "BACKEND.TIKTOK.LIKED_COMMENT",
    reply = "BACKEND.TIKTOK.REPLIED_COMMENT",
    message = "BACKEND.TIKTOK.DM"
}

local function SendTiktokNotification(username, fromUsername, notificationType, videoId, commentId, data)
    local translationKey = notificationTranslation[notificationType]

    if not translationKey or username == fromUsername then
        return
    end

    local fromProfile = GetTiktokProfile(fromUsername)

    if not fromProfile then
        return
    end

    if notificationType ~= "message" then
        local params = { username, fromUsername, notificationType }
        local query = "SELECT 1 FROM phone_tiktok_notifications WHERE username = ? AND `from` = ? AND `type` = ?"

        if videoId then
            query = query .. " AND video_id = ?"
            params[#params + 1] = videoId
        end

        if commentId then
            query = query .. " AND comment_id = ?"
            params[#params + 1] = commentId
        end

        if MySQL.scalar.await(query, params) == 1 then
            return
        end

        MySQL.insert(
            "INSERT INTO phone_tiktok_notifications (username, `from`, `type`, video_id, comment_id) VALUES (?, ?, ?, ?, ?)",
            { username, fromUsername, notificationType, videoId, commentId }
        )
    end

    local thumbnail

    if videoId then
        thumbnail = MySQL.Sync.fetchScalar(
            "SELECT src FROM phone_tiktok_videos WHERE id = @id",
            { ["@id"] = videoId }
        )
    end

    local notification = {
        app = "TikTok",
        title = L(translationKey, {
            displayName = fromProfile.name
        }),
        thumbnail = thumbnail
    }

    if notificationType == "message" then
        notification.avatar = fromProfile.avatar
        notification.content = data and data.content
        notification.showAvatar = true
    end

    NotifyLoggedInAccounts("TikTok", username, notification)
end

CreateThread(function()
    while not DatabaseCheckerFinished do
        Wait(500)
    end

    while true do
        MySQL.Async.execute("DELETE FROM phone_tiktok_notifications WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL 7 DAY)", {})
        Wait(3600000)
    end
end)

RegisterLegacyCallback("tiktok:getNotifications", function(source, cb, page)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    MySQL.Async.fetchAll([[
        SELECT
            n.`type`, n.`timestamp`, n.video_id AS videoId,
            a.`name`, a.avatar, a.username, a.verified,
            CASE
                WHEN n.video_id IS NOT NULL THEN
                    v.src
                ELSE NULL
            END AS videoSrc,
            n.comment_id,
            CASE
                WHEN n.comment_id IS NOT NULL THEN
                    c.comment
                ELSE NULL
            END AS commentText,
            CASE
                WHEN n.`type` = 'follow' THEN
                    CASE
                        WHEN f.follower IS NOT NULL THEN
                            TRUE
                        ELSE FALSE
                    END
                ELSE NULL
            END AS isFollowing,
            CASE
                WHEN n.`type` = 'reply' THEN
                    c_original.comment
                ELSE NULL
            END AS originalText
        FROM
            phone_tiktok_notifications n
            LEFT JOIN phone_tiktok_accounts a ON n.from = a.username
            LEFT JOIN phone_tiktok_videos v ON n.video_id = v.id
            LEFT JOIN phone_tiktok_comments c ON n.comment_id = c.id
            LEFT JOIN phone_tiktok_comments c_original ON c.reply_to = c_original.id
            LEFT JOIN phone_tiktok_follows f ON n.username = f.follower AND n.from = f.followed
        WHERE
            n.username = @username
        ORDER BY
            n.`timestamp` DESC
        LIMIT @page, @perPage
    ]], {
        ["@username"] = username,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, function(notifications)
        cb({
            success = true,
            data = notifications
        })
    end)
end)

RegisterLegacyCallback("tiktok:login", function(source, cb, username, password)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb({
            success = false,
            error = "no_number"
        })
    end

    if type(username) ~= "string" then
        return cb({
            success = false,
            error = "invalid_username"
        })
    end

    username = username:lower()

    MySQL.Async.fetchScalar(
        "SELECT password FROM phone_tiktok_accounts WHERE username = @username",
        { ["@username"] = username },
        function(passwordHash)
            if not passwordHash then
                return cb({
                    success = false,
                    error = "invalid_username"
                })
            end

            if not VerifyPasswordHash(password, passwordHash) then
                return cb({
                    success = false,
                    error = "incorrect_password"
                })
            end

            local profile = GetTiktokProfile(username)

            if not profile then
                return cb({
                    success = false,
                    error = "invalid_username"
                })
            end

            AddLoggedInAccount(phoneNumber, "TikTok", username)

            cb({
                success = true,
                data = profile
            })
        end
    )
end)

RegisterLegacyCallback("tiktok:signup", function(source, cb, username, password, displayName)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb({
            success = false,
            error = "UNKNOWN"
        })
    end

    if type(username) ~= "string" then
        return cb({
            success = false,
            error = "USERNAME_NOT_ALLOWED"
        })
    end

    username = username:lower()

    if not IsUsernameValid(username) then
        return cb({
            success = false,
            error = "USERNAME_NOT_ALLOWED"
        })
    end

    local usernameTaken = MySQL.Sync.fetchScalar(
        "SELECT TRUE FROM phone_tiktok_accounts WHERE username = @username",
        { ["@username"] = username }
    )

    if usernameTaken then
        return cb({
            success = false,
            error = "USERNAME_TAKEN"
        })
    end

    MySQL.Sync.execute(
        "INSERT INTO phone_tiktok_accounts (`name`, username, password, phone_number) VALUES (@displayName, @username, @password, @phoneNumber)",
        {
            ["@displayName"] = displayName,
            ["@username"] = username,
            ["@password"] = GetPasswordHash(password),
            ["@phoneNumber"] = phoneNumber
        }
    )

    AddLoggedInAccount(phoneNumber, "TikTok", username)

    cb({
        success = true
    })

    if Config.AutoFollow.Enabled and Config.AutoFollow.Trendy.Enabled then
        for i = 1, #Config.AutoFollow.Trendy.Accounts do
            MySQL.update.await(
                "INSERT INTO phone_tiktok_follows (followed, follower) VALUES (?, ?)",
                { Config.AutoFollow.Trendy.Accounts[i], username }
            )
        end
    end
end, {
    preventSpam = true,
    rateLimit = 4
})

RegisterTiktokCallback("changePassword", function(source, phoneNumber, username, oldPassword, newPassword)
    if not Config.ChangePassword.Trendy then
        infoprint("warning", ("%s tried to change password on Trendy, but it's not enabled in the config."):format(source))
        return false
    end

    if oldPassword == newPassword or type(newPassword) ~= "string" or #newPassword < 3 then
        debugprint("same password / too short")
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_tiktok_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(oldPassword, passwordHash) then
        return false
    end

    local changed = MySQL.update.await(
        "UPDATE phone_tiktok_accounts SET password = ? WHERE username = ?",
        { GetPasswordHash(newPassword), username }
    ) > 0

    if not changed then
        return false
    end

    NotifyLoggedInAccounts("TikTok", username, {
        title = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.TITLE"),
        content = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.DESCRIPTION")
    }, { phoneNumber })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'TikTok' AND phone_number != ?",
        { username, phoneNumber }
    )

    ClearActiveAccountsCache("TikTok", username, phoneNumber)

    Log(
        "Trendy",
        source,
        "info",
        L("BACKEND.LOGS.CHANGED_PASSWORD.TITLE"),
        L("BACKEND.LOGS.CHANGED_PASSWORD.DESCRIPTION", {
            number = phoneNumber,
            username = username,
            app = "Trendy"
        })
    )

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "tiktok",
        reason = "password",
        number = phoneNumber
    })

    return true
end, false)

local function DeleteTiktokAccount(username)
    assert(type(username) == "string", "Expected string for argument 1 (username), got " .. type(username))

    local deleted = MySQL.update.await(
        "DELETE FROM phone_tiktok_accounts WHERE username = ?",
        { username }
    ) > 0

    if not deleted then
        return false
    end

    NotifyLoggedInAccounts("TikTok", username, {
        title = L("BACKEND.MISC.DELETED_NOTIFICATION.TITLE"),
        content = L("BACKEND.MISC.DELETED_NOTIFICATION.DESCRIPTION")
    })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'TikTok'",
        { username }
    )

    ClearActiveAccountsCache("TikTok", username)

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "tiktok",
        reason = "deleted"
    })

    return true
end

RegisterTiktokCallback("deleteAccount", function(source, phoneNumber, username, password)
    if not Config.DeleteAccount.Trendy then
        infoprint("warning", ("%s tried to delete their account on Trendy, but it's not enabled in the config."):format(source))
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_tiktok_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(password, passwordHash) then
        return false
    end

    local deleted = DeleteTiktokAccount(username)

    if deleted then
        Log(
            "Trendy",
            source,
            "info",
            L("BACKEND.LOGS.DELETED_ACCOUNT.TITLE"),
            L("BACKEND.LOGS.DELETED_ACCOUNT.DESCRIPTION", {
                number = phoneNumber,
                username = username,
                app = "Trendy"
            })
        )
    end

    return deleted
end, false)

exports("DeleteTrendyAccount", DeleteTiktokAccount)

RegisterLegacyCallback("tiktok:logout", function(source, cb)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb(false)
    end

    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb(false)
    end

    RemoveLoggedInAccount(phoneNumber, "TikTok", username)
    cb(true)
end)

RegisterLegacyCallback("tiktok:isLoggedIn", function(source, cb)
    local username = GetLoggedInTiktokUsername(source)

    cb(username and GetTiktokProfile(username) or false)
end)

RegisterLegacyCallback("tiktok:getProfile", function(source, cb, username)
    cb(GetTiktokProfile(username, GetLoggedInTiktokUsername(source)))
end)

RegisterLegacyCallback("tiktok:updateProfile", function(source, cb, data)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb({
            success = false,
            error = "no_number"
        })
    end

    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local displayName = data.name
    local bio = data.bio
    local avatar = data.avatar
    local twitter = data.twitter
    local instagram = data.instagram
    local showLikes = data.show_likes

    if type(displayName) ~= "string" or #displayName > 30 then
        return cb({
            success = false,
            error = "display_name_too_long"
        })
    end

    if bio and #bio > 150 then
        return cb({
            success = false,
            error = "bio_too_long"
        })
    end

    if twitter then
        local linkedTwitter = MySQL.Sync.fetchScalar(
            "SELECT TRUE FROM phone_logged_in_accounts WHERE phone_number = @phoneNumber and app = @app and username = @username",
            {
                ["@phoneNumber"] = phoneNumber,
                ["@app"] = "Twitter",
                ["@username"] = twitter
            }
        )

        if not linkedTwitter then
            return cb({
                success = false,
                error = "invalid_twitter"
            })
        end
    end

    if instagram then
        local linkedInstagram = MySQL.Sync.fetchScalar(
            "SELECT TRUE FROM phone_logged_in_accounts WHERE phone_number = @phoneNumber and app = @app and username = @username",
            {
                ["@phoneNumber"] = phoneNumber,
                ["@app"] = "Instagram",
                ["@username"] = instagram
            }
        )

        if not linkedInstagram then
            return cb({
                success = false,
                error = "invalid_instagram"
            })
        end
    end

    MySQL.Async.execute(
        "UPDATE phone_tiktok_accounts SET `name` = @displayName, bio = @bio, avatar = @avatar, twitter = @twitter, instagram = @instagram, `show_likes` = @showLikes WHERE username = @username",
        {
            ["@displayName"] = displayName,
            ["@bio"] = bio,
            ["@avatar"] = avatar,
            ["@twitter"] = twitter,
            ["@instagram"] = instagram,
            ["@showLikes"] = showLikes == true,
            ["@username"] = username
        },
        function()
            cb({
                success = true
            })
        end
    )
end)

RegisterLegacyCallback("tiktok:searchAccounts", function(source, cb, query, page)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.fetchAll([[
        SELECT `name`, username, avatar, verified, follower_count, video_count,
            (SELECT TRUE FROM phone_tiktok_follows WHERE follower = @username AND followed = a.username) AS isFollowing

        FROM phone_tiktok_accounts a
        WHERE username LIKE @query OR `name` LIKE @query
        ORDER BY username
        LIMIT @page, @perPage
    ]], {
        ["@query"] = "%" .. query .. "%",
        ["@username"] = username,
        ["@page"] = (page or 0) * 10,
        ["@perPage"] = 10
    }, cb)
end)

RegisterLegacyCallback("tiktok:toggleFollow", function(source, cb, targetUsername, follow)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    if targetUsername == username then
        return cb({
            success = false,
            error = "cannot_follow_self"
        })
    end

    if not GetTiktokProfile(targetUsername) then
        return cb({
            success = false,
            error = "invalid_username"
        })
    end

    cb({
        success = true
    })

    local sql = follow == true
        and "INSERT IGNORE INTO phone_tiktok_follows (follower, followed) VALUES (@follower, @followed)"
        or "DELETE FROM phone_tiktok_follows WHERE follower = @follower AND followed = @followed"

    MySQL.Async.execute(sql, {
        ["@follower"] = username,
        ["@followed"] = targetUsername
    }, function(affectedRows)
        if affectedRows == 0 then
            return
        end

        local action = follow == true and "add" or "remove"

        TriggerClientEvent("phone:tiktok:updateFollowers", -1, targetUsername, action)
        TriggerClientEvent("phone:tiktok:updateFollowing", -1, username, action)

        if follow == true then
            SendTiktokNotification(targetUsername, username, "follow")
        end
    end)
end, {
    preventSpam = true
})

RegisterLegacyCallback("tiktok:getFollowing", function(source, cb, username, page)
    local loggedInUsername = GetLoggedInTiktokUsername(source)

    if not loggedInUsername then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            a.username, a.`name`, a.avatar, a.verified,
            (SELECT TRUE FROM phone_tiktok_follows WHERE follower = a.username AND followed = @loggedIn) AS isFollowingYou,
            (SELECT TRUE FROM phone_tiktok_follows WHERE follower = @loggedIn AND followed = a.username) AS isFollowing
        FROM phone_tiktok_follows f
        INNER JOIN phone_tiktok_accounts a ON a.username = f.followed
        WHERE f.follower = @username
        ORDER BY a.username
        LIMIT @page, @perPage
    ]], {
        ["@username"] = username,
        ["@loggedIn"] = loggedInUsername,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, cb)
end)

RegisterLegacyCallback("tiktok:getFollowers", function(source, cb, username, page)
    local loggedInUsername = GetLoggedInTiktokUsername(source)

    if not loggedInUsername then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            a.username, a.`name`, a.avatar, a.verified,
            (SELECT TRUE FROM phone_tiktok_follows WHERE follower = a.username AND followed = @loggedIn) AS isFollowingYou,
            (SELECT TRUE FROM phone_tiktok_follows WHERE follower = @loggedIn AND followed = a.username) AS isFollowing
        FROM phone_tiktok_follows f
        INNER JOIN phone_tiktok_accounts a ON a.username = f.follower
        WHERE f.followed = @username
        ORDER BY a.username
        LIMIT @page, @perPage
    ]], {
        ["@username"] = username,
        ["@loggedIn"] = loggedInUsername,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, cb)
end)

RegisterLegacyCallback("tiktok:uploadVideo", function(source, cb, data)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    if ContainsBlacklistedWord(source, "Trendy", data.caption) then
        return cb(false)
    end

    if type(data.src) ~= "string" or #data.src == 0 then
        return cb({
            success = false,
            error = "invalid_src"
        })
    end

    if type(data.caption) ~= "string" or #data.caption == 0 then
        return cb({
            success = false,
            error = "invalid_caption"
        })
    end

    if not ValidateChecks("postTrendy", source, username, data.src, data.caption) then
        debugprint("tiktok:uploadVideo - postTrendy check failed")
        return cb(false)
    end

    local videoId = GenerateId("phone_tiktok_videos", "id")

    MySQL.Async.execute(
        "INSERT INTO phone_tiktok_videos (id, username, src, caption, metadata, music) VALUES (@id, @username, @src, @caption, @metadata, @music)",
        {
            ["@id"] = videoId,
            ["@username"] = username,
            ["@src"] = data.src,
            ["@caption"] = data.caption,
            ["@metadata"] = data.metadata,
            ["@music"] = data.music
        },
        function()
            cb({
                success = true,
                id = videoId
            })

            local post = {
                username = username,
                caption = data.caption,
                videoUrl = data.src,
                id = videoId,
                source = source
            }

            TriggerClientEvent("phone:tiktok:newVideo", -1, post)
            TriggerEvent("lb-phone:trendy:newPost", post)

            Log(
                "Trendy",
                source,
                "success",
                L("BACKEND.LOGS.TRENDY_UPLOAD_TITLE"),
                L("BACKEND.LOGS.TRENDY_UPLOAD_DESCRIPTION", {
                    username = username,
                    caption = data.caption,
                    id = videoId
                })
            )
        end
    )
end, {
    preventSpam = true,
    rateLimit = 6
})

RegisterLegacyCallback("tiktok:deleteVideo", function(source, cb, videoId)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local query = "DELETE FROM phone_tiktok_videos WHERE id = @id"

    if not IsAdmin(source) then
        query = query .. " AND username = @username"
    end

    MySQL.Async.execute(query, {
        ["@id"] = videoId,
        ["@username"] = username
    }, function(affectedRows)
        cb({
            success = affectedRows > 0
        })

        if affectedRows > 0 then
            Log(
                "Trendy",
                source,
                "error",
                L("BACKEND.LOGS.TRENDY_DELETE_TITLE"),
                L("BACKEND.LOGS.TRENDY_DELETE_DESCRIPTION", {
                    username = username,
                    id = videoId
                })
            )
        end
    end)
end)

RegisterLegacyCallback("tiktok:togglePinnedVideo", function(source, cb, videoId, pinned)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    if pinned then
        local pinnedCount = MySQL.Sync.fetchScalar(
            "SELECT COUNT(*) FROM phone_tiktok_pinned_videos WHERE username = @username",
            { ["@username"] = username }
        )

        if pinnedCount >= 3 then
            return cb({
                success = false,
                error = "max_pinned"
            })
        end
    end

    local query = pinned
        and "INSERT INTO phone_tiktok_pinned_videos (username, video_id) VALUES (@username, @videoId)"
        or "DELETE FROM phone_tiktok_pinned_videos WHERE username = @username AND video_id = @videoId"

    MySQL.Async.execute(query, {
        ["@videoId"] = videoId,
        ["@username"] = username
    }, function(affectedRows)
        cb({
            success = affectedRows > 0
        })
    end)
end)

local videoSelect = [[
    SELECT
        v.id, v.src, v.caption, v.`timestamp`,
        p.video_id IS NOT NULL AS pinned,

        v.likes, v.comments, v.views, v.saves,
        (SELECT TRUE FROM phone_tiktok_likes WHERE username = @loggedIn AND video_id = v.id) AS liked,
        (SELECT TRUE FROM phone_tiktok_saves WHERE username = @loggedIn AND video_id = v.id) AS saved,
        w.video_id IS NOT NULL AS viewed,

        v.metadata, v.music,

        a.username, a.`name`, a.avatar, a.verified,
        (SELECT TRUE FROM phone_tiktok_follows WHERE follower = @loggedIn AND followed = a.username) AS following

    FROM phone_tiktok_videos v
    INNER JOIN phone_tiktok_accounts a ON a.username = v.username
    LEFT JOIN phone_tiktok_views w ON v.id = w.video_id AND w.username = @loggedIn
    LEFT JOIN phone_tiktok_pinned_videos p ON p.video_id = v.id AND p.username = @loggedIn
]]

RegisterLegacyCallback("tiktok:getVideo", function(source, cb, videoId)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    MySQL.Async.fetchAll(videoSelect .. [[
        WHERE v.id = @id
    ]], {
        ["@id"] = videoId,
        ["@loggedIn"] = username,
        ["@username"] = username
    }, function(videos)
        if #videos == 0 then
            return cb({
                success = false,
                error = "invalid_id"
            })
        end

        cb({
            success = true,
            video = videos[1]
        })
    end)
end)

RegisterLegacyCallback("tiktok:getVideos", function(source, cb, filters, page)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({})
    end

    filters = filters or {}
    page = page or 0

    local query
    local perPage

    if filters.full then
        perPage = 5

        if filters.type == "recent" then
            if filters.id then
                local direction = filters.backwards and ">" or "<"

                if filters.username then
                    query = videoSelect .. ([[
                        WHERE v.username = @username AND v.`timestamp` %s (SELECT `timestamp` FROM phone_tiktok_videos WHERE id = @id)
                        ORDER BY (w.username IS NOT NULL), v.timestamp DESC
                        LIMIT @page, @perPage
                    ]]):format(direction)
                else
                    query = videoSelect .. ([[
                        WHERE v.username != @loggedIn AND v.`timestamp` %s (SELECT `timestamp` FROM phone_tiktok_videos WHERE id = @id)
                        ORDER BY (w.username IS NOT NULL), v.timestamp DESC
                        LIMIT @page, @perPage
                    ]]):format(direction)
                end
            else
                query = videoSelect .. [[
                    WHERE v.username != @loggedIn
                    ORDER BY (w.username IS NOT NULL), v.timestamp DESC
                    LIMIT @page, @perPage
                ]]
            end
        elseif filters.type == "following" then
            query = videoSelect .. [[
                INNER JOIN phone_tiktok_follows f ON f.followed = v.username
                WHERE f.follower = @loggedIn
                ORDER BY (w.username IS NOT NULL), v.timestamp DESC
                LIMIT @page, @perPage
            ]]
        end
    else
        perPage = 15

        if filters.type == "recent" then
            if filters.username then
                if page == 0 then
                    query = [[
                        SELECT
                            v.id, v.src, v.views,
                            p.video_id IS NOT NULL AS pinned
                        FROM phone_tiktok_videos v
                        LEFT JOIN phone_tiktok_pinned_videos p ON p.video_id = v.id AND p.username = @username
                        WHERE v.username = @username
                        ORDER BY (p.video_id IS NOT NULL) DESC, v.`timestamp` DESC
                        LIMIT @page, @perPage
                    ]]
                else
                    query = [[
                        SELECT id, src, views
                        FROM phone_tiktok_videos
                        WHERE username = @username
                        ORDER BY `timestamp` DESC
                        LIMIT @page, @perPage
                    ]]
                end
            end
        elseif filters.type == "liked" then
            query = [[
                SELECT v.id, v.src, v.views
                FROM phone_tiktok_videos v
                INNER JOIN phone_tiktok_likes l ON l.video_id = v.id
                WHERE l.username = @username
                ORDER BY v.`timestamp` DESC
                LIMIT @page, @perPage
            ]]
        elseif filters.type == "saved" then
            if username ~= filters.username then
                debugprint("wrong account", username, #username, filters.username, filters.username and #filters.username or 0)
                return cb({})
            end

            query = [[
                SELECT v.id, v.src, v.views
                FROM phone_tiktok_videos v
                INNER JOIN phone_tiktok_saves s ON s.video_id = v.id
                WHERE s.username = @username
                ORDER BY v.`timestamp` DESC
                LIMIT @page, @perPage
            ]]
        end
    end

    if not query then
        return cb({})
    end

    MySQL.Async.fetchAll(query, {
        ["@username"] = filters.username,
        ["@loggedIn"] = username,
        ["@id"] = filters.id,
        ["@page"] = page * perPage,
        ["@perPage"] = perPage
    }, cb)
end)

RegisterNetEvent("phone:tiktok:setViewed", function(videoId)
    local playerSource = source
    local username = GetLoggedInTiktokUsername(playerSource)

    if not username then
        return
    end

    MySQL.Async.execute(
        "INSERT IGNORE INTO phone_tiktok_views (username, video_id) VALUES (@username, @videoId)",
        {
            ["@username"] = username,
            ["@videoId"] = videoId
        }
    )
end)

RegisterLegacyCallback("tiktok:toggleVideoAction", function(source, cb, action, videoId, enabled)
    if action ~= "like" and action ~= "save" then
        return cb({
            success = false,
            error = "invalid_action"
        })
    end

    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local videoOwner = MySQL.Sync.fetchScalar(
        "SELECT username FROM phone_tiktok_videos WHERE id = @id",
        { ["@id"] = videoId }
    )

    if not videoOwner then
        return cb({
            success = false,
            error = "invalid_id"
        })
    end

    cb({
        success = true
    })

    local tableName = action == "like" and "likes" or "saves"
    local query = enabled == true
        and ("INSERT IGNORE INTO phone_tiktok_%s (username, video_id) VALUES (@username, @videoId)"):format(tableName)
        or ("DELETE FROM phone_tiktok_%s WHERE username = @username AND video_id = @videoId"):format(tableName)

    MySQL.Async.execute(query, {
        ["@username"] = username,
        ["@videoId"] = videoId
    }, function(affectedRows)
        if affectedRows == 0 then
            return
        end

        TriggerClientEvent(
            "phone:tiktok:updateVideoStats",
            -1,
            action,
            videoId,
            enabled == true and "add" or "remove"
        )

        if enabled then
            SendTiktokNotification(videoOwner, username, action, videoId)
        end
    end)
end, {
    preventSpam = true,
    rateLimit = 30
})

RegisterLegacyCallback("tiktok:postComment", function(source, cb, videoId, replyTo, comment)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    if type(comment) ~= "string" or #comment == 0 or #comment > 500 then
        return cb({
            success = false,
            error = "invalid_comment"
        })
    end

    if ContainsBlacklistedWord(source, "Trendy", comment) then
        return cb(false)
    end

    local videoOwner = MySQL.Sync.fetchScalar(
        "SELECT username FROM phone_tiktok_videos WHERE id = @id",
        { ["@id"] = videoId }
    )

    if not videoOwner then
        return cb({
            success = false,
            error = "invalid_id"
        })
    end

    local replyOwner

    if replyTo then
        replyOwner = MySQL.Sync.fetchScalar(
            "SELECT username FROM phone_tiktok_comments WHERE id = @id",
            { ["@id"] = replyTo }
        )

        if not replyOwner then
            return cb({
                success = false,
                error = "invalid_reply_to"
            })
        end
    end

    local commentId = GenerateId("phone_tiktok_comments", "id")

    MySQL.Async.execute(
        "INSERT INTO phone_tiktok_comments (id, reply_to, video_id, username, comment) VALUES (@id, @replyTo, @videoId, @loggedIn, @comment)",
        {
            ["@id"] = commentId,
            ["@replyTo"] = replyTo,
            ["@videoId"] = videoId,
            ["@loggedIn"] = username,
            ["@comment"] = comment
        },
        function(affectedRows)
            if affectedRows == 0 then
                return cb({
                    success = false,
                    error = "failed_insert"
                })
            end

            TriggerClientEvent("phone:tiktok:updateVideoStats", -1, "comment", videoId, "add")

            if replyTo then
                MySQL.Async.execute(
                    "UPDATE phone_tiktok_comments SET replies = replies + 1 WHERE id = @id",
                    { ["@id"] = replyTo }
                )

                TriggerClientEvent("phone:tiktok:updateCommentStats", -1, "reply", replyTo, "add")
                SendTiktokNotification(replyOwner, username, "reply", videoId, commentId)
            end

            cb({
                success = true,
                id = commentId
            })

            SendTiktokNotification(videoOwner, username, "comment", videoId, commentId)
        end
    )
end, {
    preventSpam = true,
    rateLimit = 10
})

RegisterLegacyCallback("tiktok:deleteComment", function(source, cb, commentId, videoId)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local ownershipClause = ""

    if not IsAdmin(source) then
        ownershipClause = " AND username = @username"
    end

    local removedReplies = 0
    local replyTo = MySQL.Sync.fetchScalar(
        "SELECT reply_to FROM phone_tiktok_comments WHERE id = @id" .. ownershipClause,
        {
            ["@id"] = commentId,
            ["@username"] = username
        }
    )

    if replyTo then
        MySQL.Async.execute(
            "UPDATE phone_tiktok_comments SET replies = replies - 1 WHERE id = @id",
            { ["@id"] = replyTo }
        )

        TriggerClientEvent("phone:tiktok:updateCommentStats", -1, "reply", replyTo, "remove")
    else
        removedReplies = MySQL.Sync.fetchScalar(
            "SELECT COUNT(*) FROM phone_tiktok_comments WHERE reply_to = @id",
            { ["@id"] = commentId }
        )
    end

    MySQL.Async.execute(
        "DELETE FROM phone_tiktok_comments WHERE id = @id" .. ownershipClause,
        {
            ["@id"] = commentId,
            ["@username"] = username
        },
        function(affectedRows)
            if affectedRows > 0 then
                cb({
                    success = true
                })

                TriggerClientEvent(
                    "phone:tiktok:updateVideoStats",
                    -1,
                    "comment",
                    videoId,
                    "remove",
                    removedReplies + 1
                )
            else
                cb({
                    success = false,
                    error = "failed_delete"
                })
            end
        end
    )
end)

RegisterLegacyCallback("tiktok:setPinnedComment", function(source, cb, commentId, videoId)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local ownsVideo = MySQL.Sync.fetchScalar(
        "SELECT TRUE FROM phone_tiktok_videos WHERE id = @id AND username = @username",
        {
            ["@id"] = videoId,
            ["@username"] = username
        }
    )

    if not ownsVideo then
        return cb({
            success = false,
            error = "invalid_id"
        })
    end

    if commentId ~= nil then
        local ownsComment = MySQL.Sync.fetchScalar(
            "SELECT TRUE FROM phone_tiktok_comments WHERE id = @id AND username = @username",
            {
                ["@id"] = commentId,
                ["@username"] = username
            }
        )

        if not ownsComment then
            return cb({
                success = false,
                error = "invalid_comment"
            })
        end
    end

    MySQL.Async.execute(
        "UPDATE phone_tiktok_videos SET pinned_comment = @commentId WHERE id = @id",
        {
            ["@commentId"] = commentId,
            ["@id"] = videoId
        },
        function(affectedRows)
            if affectedRows > 0 then
                cb({
                    success = true
                })
            else
                cb({
                    success = false,
                    error = "failed_update"
                })
            end
        end
    )
end)

RegisterLegacyCallback("tiktok:getComments", function(source, cb, videoId, replyTo, creator, page)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local query = [[
        SELECT
            a.username, a.`name`, a.avatar, a.verified,
            c.id, c.comment, c.likes, c.replies AS reply_count, c.`timestamp`,
            (SELECT TRUE FROM phone_tiktok_comments_likes WHERE username = @loggedIn AND comment_id = c.id) AS liked,
            (SELECT TRUE FROM phone_tiktok_comments_likes WHERE username = @creator AND comment_id = c.id) AS creator_liked

        FROM phone_tiktok_comments c
        INNER JOIN phone_tiktok_accounts a ON a.username = c.username

        WHERE c.video_id = @videoId
    ]]

    if replyTo then
        query = query .. " AND c.reply_to = @replyTo"
    else
        query = query .. " AND c.reply_to IS NULL"
    end

    query = query .. " ORDER BY c.`timestamp` DESC LIMIT @page, @perPage"

    MySQL.Async.fetchAll(query, {
        ["@loggedIn"] = username,
        ["@creator"] = creator,
        ["@videoId"] = videoId,
        ["@replyTo"] = replyTo,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, function(comments)
        cb({
            success = true,
            comments = comments
        })
    end)
end)

RegisterLegacyCallback("tiktok:toggleLikeComment", function(source, cb, commentId, liked)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    if not commentId or liked == nil then
        return cb({
            success = false,
            error = "invalid_data"
        })
    end

    local comment = MySQL.Sync.fetchAll(
        "SELECT username, video_id FROM phone_tiktok_comments WHERE id = @id",
        { ["@id"] = commentId }
    )[1]

    if not comment then
        return cb({
            success = false,
            error = "invalid_id"
        })
    end

    local query = liked == true
        and "INSERT IGNORE INTO phone_tiktok_comments_likes (username, comment_id) VALUES (@username, @commentId)"
        or "DELETE FROM phone_tiktok_comments_likes WHERE username = @username AND comment_id = @commentId"

    MySQL.Async.execute(query, {
        ["@username"] = username,
        ["@commentId"] = commentId
    }, function(affectedRows)
        cb({
            success = true
        })

        if affectedRows == 0 then
            return debugprint("Failed to toggle like comment, no rows changed")
        end

        TriggerClientEvent(
            "phone:tiktok:updateCommentStats",
            -1,
            "like",
            commentId,
            liked == true and "add" or "remove"
        )

        if liked then
            SendTiktokNotification(comment.username, username, "like_comment", comment.video_id, commentId)
        end
    end)
end, {
    preventSpam = true
})

RegisterLegacyCallback("tiktok:getRecentMessages", function(source, cb)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    MySQL.Async.fetchAll([[
        SELECT
            id, last_message, `timestamp`,
            a.username, a.`name`, a.avatar, a.verified, a.follower_count, a.following_count,
            COALESCE((SELECT amount FROM phone_tiktok_unread_messages WHERE channel_id = id AND username = @loggedIn), 0) AS unread_messages

        FROM phone_tiktok_channels
        INNER JOIN phone_tiktok_accounts a ON a.username = IF(member_1 = @loggedIn, member_2, member_1)
        WHERE member_1 = @loggedIn OR member_2 = @loggedIn
        ORDER BY `timestamp` DESC
    ]], {
        ["@loggedIn"] = username
    }, function(channels)
        cb({
            success = true,
            channels = channels
        })
    end)
end)

RegisterLegacyCallback("tiktok:getMessages", function(source, cb, channelId, page)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local isMember = MySQL.Sync.fetchScalar(
        "SELECT TRUE FROM phone_tiktok_channels WHERE id = @id AND (member_1 = @loggedIn OR member_2 = @loggedIn)",
        {
            ["@id"] = channelId,
            ["@loggedIn"] = username
        }
    )

    if not isMember then
        return cb({
            success = false,
            error = "invalid_id"
        })
    end

    MySQL.Async.fetchAll(
        "SELECT id, sender, content, `timestamp` FROM phone_tiktok_messages WHERE channel_id = @channelId ORDER BY `timestamp` DESC LIMIT @page, @perPage",
        {
            ["@channelId"] = channelId,
            ["@page"] = (page or 0) * 25,
            ["@perPage"] = 25
        },
        function(messages)
            cb({
                success = true,
                messages = messages
            })
        end
    )
end)

RegisterLegacyCallback("tiktok:getUnreadMessages", function(source, cb)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    MySQL.Async.fetchScalar(
        "SELECT COUNT(*) FROM phone_tiktok_unread_messages WHERE username = @username AND amount > 0",
        { ["@username"] = username },
        function(unread)
            cb({
                success = true,
                unread = unread
            })
        end
    )
end)

RegisterNetEvent("phone:tiktok:clearUnreadMessages", function(channelId)
    local playerSource = source
    local username = GetLoggedInTiktokUsername(playerSource)

    if not username then
        return
    end

    MySQL.Async.execute(
        "UPDATE phone_tiktok_unread_messages SET amount = 0 WHERE username = @username AND channel_id = @channelId",
        {
            ["@username"] = username,
            ["@channelId"] = channelId
        }
    )
end)

RegisterLegacyCallback("tiktok:sendMessage", function(source, cb, data)
    local username = GetLoggedInTiktokUsername(source)

    if not username then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    if ContainsBlacklistedWord(source, "Trendy", data.content) then
        return cb(false)
    end

    local channelId = data.id
    local content = data.content
    local recipientUsername = data.username

    if channelId then
        local channel = MySQL.Sync.fetchAll([[
            SELECT IF(member_1 = @loggedIn, member_2, member_1) AS recipient
            FROM phone_tiktok_channels
            WHERE id = @id AND (member_1 = @loggedIn OR member_2 = @loggedIn)
        ]], {
            ["@id"] = channelId,
            ["@loggedIn"] = username
        })[1]

        if not channel then
            return cb({
                success = false,
                error = "invalid_id"
            })
        end

        recipientUsername = recipientUsername or channel.recipient
    else
        if not recipientUsername then
            return cb({
                success = false,
                error = "invalid_id"
            })
        end

        channelId = MySQL.Sync.fetchScalar([[
            SELECT id FROM phone_tiktok_channels
            WHERE (member_1 = @loggedIn AND member_2 = @username)
                OR (member_1 = @username AND member_2 = @loggedIn)
        ]], {
            ["@loggedIn"] = username,
            ["@username"] = recipientUsername
        })

        if not channelId then
            channelId = GenerateId("phone_tiktok_channels", "id")

            local created = MySQL.Sync.execute(
                "INSERT IGNORE INTO phone_tiktok_channels (id, last_message, member_1, member_2) VALUES (@id, @message, @member_1, @member_2)",
                {
                    ["@id"] = channelId,
                    ["@message"] = content,
                    ["@member_1"] = username,
                    ["@member_2"] = recipientUsername
                }
            ) > 0

            if not created then
                return cb({
                    success = false,
                    error = "failed_create_channel"
                })
            end
        end
    end

    local messageId = GenerateId("phone_tiktok_messages", "id")

    MySQL.Async.execute(
        "INSERT INTO phone_tiktok_messages (id, channel_id, sender, content) VALUES (@messageId, @channelId, @sender, @content)",
        {
            ["@messageId"] = messageId,
            ["@channelId"] = channelId,
            ["@sender"] = username,
            ["@content"] = content
        },
        function(affectedRows)
            cb({
                success = affectedRows > 0,
                id = messageId,
                channelId = channelId,
                error = "failed_insert"
            })

            if affectedRows <= 0 then
                return
            end

            MySQL.Async.execute([[
                INSERT INTO phone_tiktok_unread_messages
                    (username, channel_id, amount)
                VALUES
                    (@username, @channelId, 1)
                ON DUPLICATE KEY UPDATE
                    amount = amount + 1
            ]], {
                ["@username"] = recipientUsername,
                ["@channelId"] = channelId
            })

            local activeAccounts = GetActiveAccounts("TikTok")

            for phoneNumber, activeUsername in pairs(activeAccounts) do
                if activeUsername == recipientUsername then
                    local targetSource = GetSourceFromNumber(phoneNumber)

                    if targetSource then
                        TriggerClientEvent("phone:tiktok:receivedMessage", targetSource, {
                            id = messageId,
                            channelId = channelId,
                            sender = username,
                            content = content
                        })
                    end
                end
            end

            SendTiktokNotification(recipientUsername, username, "message", nil, nil, {
                content = content
            })
        end
    )
end, {
    preventSpam = true
})

RegisterLegacyCallback("tiktok:getChannelId", function(source, cb, username)
    local loggedInUsername = GetLoggedInTiktokUsername(source)

    if not loggedInUsername then
        return cb({
            success = false,
            error = "not_logged_in"
        })
    end

    local channelId = MySQL.Sync.fetchScalar([[
        SELECT id FROM phone_tiktok_channels
        WHERE (member_1 = @loggedIn AND member_2 = @username)
            OR (member_1 = @username AND member_2 = @loggedIn)
    ]], {
        ["@loggedIn"] = loggedInUsername,
        ["@username"] = username
    })

    if not channelId then
        return cb({
            success = false,
            error = "no_channel"
        })
    end

    cb({
        success = true,
        id = channelId
    })
end)
