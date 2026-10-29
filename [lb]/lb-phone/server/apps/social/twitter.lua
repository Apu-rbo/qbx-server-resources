local function GetLoggedInBirdyUsername(source)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return false
    end

    return GetLoggedInAccount(phoneNumber, "Twitter")
end

local function RegisterBirdyCallback(name, handler, defaultReturn, options)
    BaseCallback("birdy:" .. name, function(source, phoneNumber, ...)
        local username = GetLoggedInAccount(phoneNumber, "Twitter")

        if not username then
            return defaultReturn
        end

        return handler(source, phoneNumber, username, ...)
    end, defaultReturn, options)
end

local function NotifyActiveBirdyAccounts(username, notification, excludedPhoneNumber)
    local rows = MySQL.query.await(
        "SELECT phone_number FROM phone_logged_in_accounts WHERE username = ? AND app = 'Twitter' AND `active` = 1",
        { username }
    )

    notification.app = "Twitter"

    for i = 1, #rows do
        local phoneNumber = rows[i].phone_number

        if phoneNumber ~= excludedPhoneNumber then
            SendNotification(phoneNumber, notification)
        end
    end
end

local function DecodeJsonArray(value)
    if not value then
        return nil
    end

    if type(value) == "table" then
        return value
    end

    local decoded = json.decode(value)

    if decoded and type(decoded) == "table" then
        return decoded
    end

    return nil
end

function GetTweet(tweetId, loggedInAs)
    if not tweetId then
        return
    end

    local tweets = MySQL.Sync.fetchAll([[
        SELECT
            DISTINCT t.id, t.username, t.content, t.attachments,
            t.like_count, t.reply_count, t.retweet_count, t.reply_to,
            t.`timestamp`,

            (
                CASE WHEN t.reply_to IS NULL THEN NULL ELSE (SELECT username FROM phone_twitter_tweets WHERE id=t.reply_to LIMIT 1) END
            ) AS replyToAuthor,

            a.display_name, a.username, a.profile_image, a.verified, a.private,

            (
                SELECT TRUE FROM phone_twitter_likes l
                WHERE l.tweet_id=t.id AND l.username=@loggedInAs
            ) AS liked,
            (
                SELECT TRUE FROM phone_twitter_retweets r
                WHERE r.tweet_id=t.id AND r.username=@loggedInAs
            ) AS retweeted

        FROM phone_twitter_tweets t

        INNER JOIN phone_twitter_accounts a
            ON a.username=t.username

        WHERE t.id=@tweetId AND (a.private=0 OR a.username=@loggedInAs OR (
            SELECT TRUE FROM phone_twitter_follows f
            WHERE f.follower=@loggedInAs AND f.followed=a.username
        ))
    ]], {
        ["@tweetId"] = tweetId,
        ["@loggedInAs"] = loggedInAs
    })

    return tweets and tweets[1]
end

local function GetBirdyProfile(username, phoneNumber)
    if type(username) ~= "string" then
        return false
    end

    username = username:lower()

    local account = MySQL.single.await(
        "SELECT `display_name`, `bio`, `profile_image`, `profile_header`, `verified`, `follower_count`, `following_count`, `date_joined`, private FROM `phone_twitter_accounts` WHERE `username`=?",
        { username }
    )

    if not account then
        return false
    end

    local loggedInAs

    if phoneNumber then
        loggedInAs = GetLoggedInAccount(phoneNumber, "Twitter")
    end

    local isFollowing = false
    local isFollowingYou = false
    local notificationsEnabled = false
    local requested = false
    local pinnedTweet

    if loggedInAs then
        isFollowing = MySQL.scalar.await(
            "SELECT `followed` FROM `phone_twitter_follows` WHERE `follower` = ? AND `followed` = ?",
            { loggedInAs, username }
        ) ~= nil

        isFollowingYou = MySQL.scalar.await(
            "SELECT `followed` FROM `phone_twitter_follows` WHERE `follower` = ? AND `followed` = ?",
            { username, loggedInAs }
        ) ~= nil

        local notifications = MySQL.scalar.await(
            "SELECT `notifications` FROM `phone_twitter_follows` WHERE `follower` = ? AND `followed` = ?",
            { loggedInAs, username }
        )
        notificationsEnabled = notifications == true or notifications == 1

        requested = MySQL.scalar.await(
            "SELECT TRUE FROM phone_twitter_follow_requests WHERE requester = ? AND requestee = ?",
            { loggedInAs, username }
        ) ~= nil

        pinnedTweet = MySQL.scalar.await(
            "SELECT pinned_tweet FROM phone_twitter_accounts WHERE username = ?",
            { username }
        )

        if pinnedTweet then
            pinnedTweet = GetTweet(pinnedTweet, loggedInAs)
        end
    end

    return {
        name = account.display_name,
        username = username,
        followers = account.follower_count,
        following = account.following_count,
        date_joined = account.date_joined,
        bio = account.bio,
        verified = account.verified,
        private = account.private,
        profile_picture = account.profile_image,
        header = account.profile_header,
        isFollowing = isFollowing,
        isFollowingYou = isFollowingYou,
        notificationsEnabled = notificationsEnabled,
        pinnedTweet = pinnedTweet,
        requested = requested
    }
end

local notificationKeys = {
    like = "BACKEND.TWITTER.LIKE",
    retweet = "BACKEND.TWITTER.RETWEET",
    reply = "BACKEND.TWITTER.REPLY",
    follow = "BACKEND.TWITTER.FOLLOW",
    tweet = "BACKEND.TWITTER.TWEET"
}

local function SendBirdyNotification(username, fromUsername, notificationType, tweetId)
    if username == fromUsername then
        return
    end

    local translationKey = notificationKeys[notificationType]

    if not translationKey then
        return
    end

    if notificationType == "like" or notificationType == "retweet" or notificationType == "follow" then
        local query = "SELECT TRUE FROM phone_twitter_notifications WHERE username=@username AND `from`=@from AND `type`=@type"

        if notificationType ~= "follow" then
            query = query .. " AND tweet_id=@tweet_id"
        end

        local exists = MySQL.Sync.fetchScalar(query, {
            ["@username"] = username,
            ["@from"] = fromUsername,
            ["@type"] = notificationType,
            ["@tweet_id"] = tweetId
        })

        if exists then
            return
        end
    end

    local fromAccount = MySQL.Sync.fetchAll(
        "SELECT display_name, private FROM phone_twitter_accounts WHERE username=@username",
        { ["@username"] = fromUsername }
    )[1]

    if not fromAccount or (fromAccount.private and notificationType == "reply") then
        return
    end

    MySQL.Async.execute(
        "INSERT INTO phone_twitter_notifications (id, username, `from`, `type`, tweet_id) VALUES (@id, @username, @from, @type, @tweetId)",
        {
            ["@id"] = GenerateId("phone_twitter_notifications", "id"),
            ["@username"] = username,
            ["@from"] = fromUsername,
            ["@type"] = notificationType,
            ["@tweetId"] = tweetId
        }
    )

    local content
    local attachments

    if notificationType ~= "follow" then
        local tweet = MySQL.Sync.fetchAll(
            "SELECT content, attachments FROM phone_twitter_tweets WHERE id=@tweetId",
            { ["@tweetId"] = tweetId }
        )[1]

        if tweet then
            content = tweet.content
            attachments = DecodeJsonArray(tweet.attachments)
        end
    end

    NotifyLoggedInAccounts("Twitter", username, {
        title = L(translationKey, {
            displayName = fromAccount.display_name,
            username = fromUsername
        }),
        content = content,
        thumbnail = attachments and attachments[1]
    })
end

RegisterLegacyCallback("birdy:getNotifications", function(source, cb, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb({
            notifications = {},
            requests = 0
        })
    end

    page = page or 0

    local notifications = MySQL.Sync.fetchAll([[
        SELECT
            n.`from`, n.`type`, n.tweet_id,
            t.username, t.content, t.attachments, t.reply_to, t.like_count,
            t.reply_count, t.retweet_count, t.`timestamp`,

            (
                SELECT TRUE FROM phone_twitter_likes l
                WHERE l.tweet_id=t.id AND l.username=@username
            ) AS liked,
            (
                SELECT TRUE FROM phone_twitter_retweets r
                WHERE r.tweet_id=t.id AND r.username=@username
            ) AS retweeted,

            a.display_name AS `name`, a.profile_image AS profile_picture, a.verified,
            (
                CASE WHEN t.reply_to IS NULL THEN NULL ELSE (SELECT username FROM phone_twitter_tweets WHERE id=t.reply_to LIMIT 1) END
            ) AS replyToAuthor

        FROM phone_twitter_notifications n

        LEFT JOIN phone_twitter_tweets t
            ON n.tweet_id = t.id

        JOIN phone_twitter_accounts a
            ON a.username = n.from

        WHERE n.username=@username

        ORDER BY n.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@page"] = page * 15,
        ["@perPage"] = 15,
        ["@username"] = username
    })

    if page > 0 then
        return cb({
            notifications = notifications
        })
    end

    cb({
        notifications = notifications,
        requests = MySQL.Sync.fetchScalar(
            "SELECT COUNT(1) FROM phone_twitter_follow_requests WHERE requestee=@username",
            { ["@username"] = username }
        )
    })
end)

RegisterLegacyCallback("birdy:createAccount", function(source, cb, displayName, username, password)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb(false)
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

    if MySQL.Sync.fetchScalar("SELECT TRUE FROM phone_twitter_accounts WHERE username=@username", {
        ["@username"] = username
    }) then
        return cb({
            success = false,
            error = "USERNAME_TAKEN"
        })
    end

    MySQL.Sync.execute(
        "INSERT INTO phone_twitter_accounts (display_name, username, `password`, phone_number) VALUES (@displayName, @username, @password, @phonenumber)",
        {
            ["@displayName"] = displayName,
            ["@username"] = username,
            ["@password"] = GetPasswordHash(password),
            ["@phonenumber"] = phoneNumber
        }
    )

    AddLoggedInAccount(phoneNumber, "Twitter", username)

    cb({
        success = true
    })

    if Config.AutoFollow.Enabled and Config.AutoFollow.Birdy.Enabled then
        for i = 1, #Config.AutoFollow.Birdy.Accounts do
            MySQL.update.await(
                "INSERT INTO phone_twitter_follows (followed, follower, notifications) VALUES (?, ?, 1)",
                { Config.AutoFollow.Birdy.Accounts[i], username }
            )
        end
    end
end, {
    preventSpam = true,
    rateLimit = 4
})

RegisterBirdyCallback("changePassword", function(source, phoneNumber, username, oldPassword, newPassword)
    if not Config.ChangePassword.Birdy then
        infoprint("warning", ("%s tried to change password on Birdy, but it's not enabled in the config."):format(source))
        return false
    end

    if oldPassword == newPassword or type(newPassword) ~= "string" or #newPassword < 3 then
        debugprint("same password / too short")
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_twitter_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(oldPassword, passwordHash) then
        return false
    end

    local changed = MySQL.update.await(
        "UPDATE phone_twitter_accounts SET password = ? WHERE username = ?",
        { GetPasswordHash(newPassword), username }
    ) > 0

    if not changed then
        return false
    end

    NotifyActiveBirdyAccounts(username, {
        title = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.TITLE"),
        content = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.DESCRIPTION")
    }, phoneNumber)

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'Twitter' AND phone_number != ?",
        { username, phoneNumber }
    )

    ClearActiveAccountsCache("Twitter", username, phoneNumber)

    Log(
        "Birdy",
        source,
        "info",
        L("BACKEND.LOGS.CHANGED_PASSWORD.TITLE"),
        L("BACKEND.LOGS.CHANGED_PASSWORD.DESCRIPTION", {
            number = phoneNumber,
            username = username,
            app = "Birdy"
        })
    )

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "twitter",
        reason = "password",
        number = phoneNumber
    })

    return true
end, false)

local function DeleteBirdyAccount(username)
    assert(type(username) == "string", "Expected string for argument 1 (username), got " .. type(username))

    local deleted = MySQL.update.await(
        "DELETE FROM phone_twitter_accounts WHERE username = ?",
        { username }
    ) > 0

    if not deleted then
        return false
    end

    NotifyActiveBirdyAccounts(username, {
        title = L("BACKEND.MISC.DELETED_NOTIFICATION.TITLE"),
        content = L("BACKEND.MISC.DELETED_NOTIFICATION.DESCRIPTION")
    })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'Twitter'",
        { username }
    )

    ClearActiveAccountsCache("Twitter", username)

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "twitter",
        reason = "deleted"
    })

    return true
end

RegisterBirdyCallback("deleteAccount", function(source, phoneNumber, username, password)
    if not Config.DeleteAccount.Birdy then
        infoprint("warning", ("%s tried to delete their account on Birdy, but it's not enabled in the config."):format(source))
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_twitter_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(password, passwordHash) then
        return false
    end

    local deleted = DeleteBirdyAccount(username)

    if deleted then
        Log(
            "Birdy",
            source,
            "info",
            L("BACKEND.LOGS.DELETED_ACCOUNT.TITLE"),
            L("BACKEND.LOGS.DELETED_ACCOUNT.DESCRIPTION", {
                number = phoneNumber,
                username = username,
                app = "Birdy"
            })
        )
    end

    return deleted
end, false)

exports("DeleteBirdyAccount", DeleteBirdyAccount)

BaseCallback("birdy:login", function(source, phoneNumber, username, password)
    if type(username) ~= "string" then
        return {
            success = false,
            error = "INVALID_ACCOUNT"
        }
    end

    username = username:lower()

    local passwordHash = MySQL.scalar.await(
        "SELECT `password` FROM phone_twitter_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash then
        return {
            success = false,
            error = "INVALID_ACCOUNT"
        }
    end

    if not VerifyPasswordHash(password, passwordHash) then
        return {
            success = false,
            error = "INVALID_PASSWORD"
        }
    end

    AddLoggedInAccount(phoneNumber, "Twitter", username)

    local profile = GetBirdyProfile(username)

    if not profile then
        return {
            success = false,
            error = "INVALID_ACCOUNT"
        }
    end

    return {
        success = true,
        data = profile
    }
end)

RegisterBirdyCallback("isLoggedIn", function(source, phoneNumber, username)
    return GetBirdyProfile(username)
end, false)

RegisterBirdyCallback("getProfile", function(source, phoneNumber, username, targetUsername)
    return GetBirdyProfile(targetUsername, phoneNumber)
end, false, {
    preventSpam = true,
    rateLimit = 15
})

RegisterLegacyCallback("birdy:pinPost", function(source, cb, tweetId)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    if tweetId then
        local ownsTweet = MySQL.scalar.await(
            "SELECT TRUE FROM phone_twitter_tweets WHERE id = ? AND username = ?",
            { tweetId, username }
        )

        if not ownsTweet then
            infoprint("warning", ("%s (%s) tried to pin a post on birdy that they didn't make."):format(username, source))
            return cb(false)
        end
    end

    MySQL.Async.execute(
        "UPDATE phone_twitter_accounts SET pinned_tweet=@tweetId WHERE username=@username",
        {
            ["@tweetId"] = tweetId or nil,
            ["@username"] = username
        },
        function()
            cb(true)
        end
    )
end)

RegisterLegacyCallback("birdy:signOut", function(source, cb)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb(false)
    end

    local username = GetLoggedInAccount(phoneNumber, "Twitter")

    if not username then
        return cb(false)
    end

    RemoveLoggedInAccount(phoneNumber, "Twitter", username)
    cb(true)
end)

RegisterLegacyCallback("birdy:updateProfile", function(source, cb, data)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.execute(
        "UPDATE phone_twitter_accounts SET display_name=@displayName, bio=@bio, profile_image=@profilePicture, profile_header=@header, private=@private WHERE username=@username",
        {
            ["@username"] = username,
            ["@displayName"] = data.name,
            ["@bio"] = data.bio,
            ["@profilePicture"] = data.profile_picture,
            ["@header"] = data.header,
            ["@private"] = data.private
        },
        function()
            cb(true)
        end
    )
end)

local function LogBirdyPost(tweetId, username, content, attachments, source)
    local attachmentCount = attachments and #attachments or 0
    local message = ("**Username**: %s\n\n**Content**: %s"):format(username, content or "")

    if attachments then
        message = message .. "\n\n**Attachments**:"

        for i = 1, attachmentCount do
            message = message .. ("\n\n[Attachment %s](%s)"):format(i, attachments[i])
        end
    end

    message = message .. ("\n\n**ID**: %s"):format(tweetId)

    Log("Birdy", source, "info", "New post", message)
end

local function SendBirdyWebhook(username, content, attachments, replyTo)
    if not Config.Post.Birdy or replyTo then
        return
    end

    if not BIRDY_WEBHOOK or BIRDY_WEBHOOK:sub(-14) == "/api/webhooks/" then
        return
    end

    local profileImage = MySQL.scalar.await(
        "SELECT profile_image FROM phone_twitter_accounts WHERE username = ?",
        { username }
    )

    PerformHttpRequest(BIRDY_WEBHOOK, function() end, "POST", json.encode({
        username = Config.Post.Accounts and Config.Post.Accounts.Birdy and Config.Post.Accounts.Birdy.Username or "Birdy",
        avatar_url = Config.Post.Accounts and Config.Post.Accounts.Birdy and Config.Post.Accounts.Birdy.Avatar or "https://assets.loaf-scripts.com/lb-phone/icons/Birdy.png",
        embeds = {
            {
                title = L("APPS.TWITTER.NEW_POST"),
                description = content and #content > 0 and content or nil,
                color = 1942002,
                timestamp = GetTimestampISO(),
                author = {
                    name = "@" .. username,
                    icon_url = profileImage or "https://cdn.discordapp.com/embed/avatars/5.png"
                },
                image = attachments and #attachments > 0 and {
                    url = attachments[1]
                } or nil,
                footer = {
                    text = "LB Phone",
                    icon_url = "https://docs.lbscripts.com/images/icons/icon.png"
                }
            }
        }
    }), {
        ["Content-Type"] = "application/json"
    })
end

local function PostBirdy(username, content, attachments, replyTo, hashtags, source)
    content = content or ""

    assert(type(username) == "string", "PostBirdy: Expected string for argument 1 (username), got " .. type(username))
    assert(type(content) == "string", "PostBirdy: Expected string/nil for argument 2 (content), got " .. type(content))

    local hasAttachments = false

    if attachments ~= nil then
        if type(attachments) ~= "table" or table.type(attachments) ~= "array" then
            error("PostBirdy: Expected table/nil for argument 3 (attachments), got " .. type(attachments))
        end

        hasAttachments = #attachments > 0
    end

    if not hasAttachments and #content:gsub(" ", "") == 0 then
        debugprint("PostBirdy: No content & no attachments")
        return false
    end

    if replyTo ~= nil and type(replyTo) ~= "string" then
        error("PostBirdy: Expected string/nil for argument 4 (replyTo), got " .. type(replyTo))
    end

    local tweetId = GenerateId("phone_twitter_tweets", "id")
    local columns = { "id", "username", "content" }
    local params = { tweetId, username, content }

    if hasAttachments then
        columns[#columns + 1] = "attachments"
        params[#params + 1] = json.encode(attachments)
    end

    if replyTo then
        columns[#columns + 1] = "reply_to"
        params[#params + 1] = replyTo
    end

    local placeholders = {}

    for i = 1, #params do
        placeholders[i] = "?"
    end

    local inserted = MySQL.update.await(
        ("INSERT INTO phone_twitter_tweets (%s) VALUES (%s)"):format(table.concat(columns, ", "), table.concat(placeholders, ", ")),
        params
    )

    if inserted == 0 then
        return false
    end

    local author = MySQL.single.await(
        "SELECT display_name, profile_image, verified, private FROM phone_twitter_accounts WHERE username = ?",
        { username }
    ) or {
        display_name = username
    }

    if replyTo then
        MySQL.update("UPDATE phone_twitter_tweets SET reply_count = reply_count + 1 WHERE id = ?", { replyTo })
        TriggerClientEvent("phone:twitter:updateTweetData", -1, replyTo, "replies", true)

        local replyOwner = MySQL.scalar.await(
            "SELECT username FROM phone_twitter_tweets WHERE id = ?",
            { replyTo }
        )

        if replyOwner then
            SendBirdyNotification(replyOwner, username, "reply", tweetId)
        end
    end

    MySQL.query("SELECT follower FROM phone_twitter_follows WHERE followed = ? AND notifications=1", { username }, function(followers)
        for i = 1, #followers do
            SendBirdyNotification(followers[i].follower, username, "tweet", tweetId)
        end
    end)

    if source then
        LogBirdyPost(tweetId, username, content, attachments, source)
    end

    if not author.private then
        SendBirdyWebhook(username, content, attachments, replyTo)

        if Config.BirdyNotifications then
            NotifyEveryone(Config.BirdyNotifications == "all" and "all" or "online", {
                app = "Twitter",
                title = L("BACKEND.TWITTER.TWEET", {
                    username = username
                }),
                content = content,
                thumbnail = attachments and attachments[1]
            })
        end

        if Config.BirdyTrending.Enabled and type(hashtags) == "table" and table.type(hashtags) == "array" and #hashtags > 0 then
            MySQL.update(([[
                INSERT INTO
                    phone_twitter_hashtags (hashtag, amount)
                VALUES
                    %s
                ON DUPLICATE KEY UPDATE amount = amount + 1
            ]]):format(("(?, 1), "):rep(#hashtags):sub(1, -3)), hashtags)
        end

        local tweet = {
            id = tweetId,
            username = username,
            content = content,
            attachments = attachments,
            like_count = 0,
            reply_count = 0,
            retweet_count = 0,
            reply_to = replyTo,
            timestamp = os.time() * 1000,
            liked = false,
            retweeted = false,
            display_name = author.display_name,
            profile_image = author.profile_image,
            verified = author.verified,
            source = source
        }

        if replyTo then
            tweet.replyToAuthor = MySQL.scalar.await(
                "SELECT username FROM phone_twitter_tweets WHERE id = ?",
                { replyTo }
            )
        end

        TriggerClientEvent("phone:twitter:newtweet", -1, tweet)
        TriggerEvent("lb-phone:birdy:newPost", tweet)
    end

    return true, tweetId
end

exports("PostBirdy", PostBirdy)

RegisterBirdyCallback("sendPost", function(source, phoneNumber, username, content, attachments, replyTo, hashtags)
    if ContainsBlacklistedWord(source, "Birdy", content) then
        return false
    end

    if not ValidateChecks("postBirdy", source, username, content, attachments) then
        debugprint("birdy:sendPost - postBirdy check failed")
        return false
    end

    local success = PostBirdy(username, content, attachments, replyTo, hashtags, source)

    return success
end, nil, {
    preventSpam = true,
    rateLimit = 15
})

RegisterCallback("birdy:getRecentHashtags", function()
    if Config.BirdyTrending.Enabled then
        return MySQL.query.await("SELECT hashtag, amount AS uses FROM phone_twitter_hashtags ORDER BY amount DESC LIMIT 5")
    end

    return {}
end)

RegisterLegacyCallback("birdy:deletePost", function(source, cb, tweetId)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    local replyTo = MySQL.Sync.fetchScalar(
        "SELECT reply_to FROM phone_twitter_tweets WHERE id=@id",
        { ["@id"] = tweetId }
    )

    local canDelete = IsAdmin(source)

    if not canDelete then
        canDelete = MySQL.Sync.fetchScalar(
            "SELECT TRUE FROM phone_twitter_tweets WHERE id=@id AND username=@username",
            {
                ["@id"] = tweetId,
                ["@username"] = username
            }
        )
    end

    if not canDelete then
        return cb(false)
    end

    local params = { ["@id"] = tweetId }

    MySQL.Sync.execute("DELETE FROM phone_twitter_likes WHERE tweet_id=@id", params)
    MySQL.Sync.execute("DELETE FROM phone_twitter_retweets WHERE tweet_id=@id", params)
    MySQL.Sync.execute("DELETE FROM phone_twitter_notifications WHERE tweet_id=@id", params)

    local deleted = MySQL.Sync.execute("DELETE FROM phone_twitter_tweets WHERE id=@id", params) > 0

    cb(deleted)

    if not deleted then
        return
    end

    if replyTo then
        local replyCount = MySQL.Sync.fetchScalar(
            "SELECT COUNT(id) FROM phone_twitter_tweets WHERE reply_to=@replyTo",
            { ["@replyTo"] = replyTo }
        )

        MySQL.Sync.execute(
            "UPDATE phone_twitter_tweets SET reply_count=@count WHERE id=@replyTo",
            {
                ["@replyTo"] = replyTo,
                ["@count"] = replyCount
            }
        )

        TriggerClientEvent("phone:twitter:updateTweetData", -1, replyTo, "replies", false)
    end

    Log("Birdy", source, "info", "Post deleted", "**ID**: " .. tweetId)
end)

RegisterLegacyCallback("birdy:getRandomPromoted", function(source, cb)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    local tweetId = MySQL.Sync.fetchScalar("SELECT tweet_id FROM phone_twitter_promoted WHERE promotions > 0 ORDER BY RAND() LIMIT 1")

    if not tweetId then
        return cb(false)
    end

    MySQL.Async.execute(
        "UPDATE phone_twitter_promoted SET promotions = promotions - 1, views = views + 1 WHERE tweet_id = @tweetId",
        { ["@tweetId"] = tweetId }
    )

    cb(GetTweet(tweetId, username))
end)

RegisterLegacyCallback("birdy:promotePost", function(source, cb, tweetId)
    if not (Config.PromoteBirdy and Config.PromoteBirdy.Enabled and RemoveMoney) then
        return cb(false)
    end

    if not RemoveMoney(source, Config.PromoteBirdy.Cost) then
        return cb(false)
    end

    MySQL.Async.execute([[
        INSERT INTO phone_twitter_promoted (tweet_id, promotions, views) VALUES (@tweetId, @promotions, 0)
            ON DUPLICATE KEY UPDATE promotions = promotions + @promotions
    ]], {
        ["@tweetId"] = tweetId,
        ["@promotions"] = Config.PromoteBirdy.Views
    })

    cb(true)
end)

RegisterLegacyCallback("birdy:searchAccounts", function(source, cb, search, page)
    MySQL.Async.fetchAll([[
        SELECT
            display_name,
            username,
            profile_image,
            verified,
            private

        FROM
            phone_twitter_accounts

        WHERE
            username LIKE CONCAT(@search, "%")
            OR
            display_name LIKE CONCAT("%", @search, "%")

        ORDER BY username ASC

        LIMIT @page, @perPage
    ]], {
        ["@search"] = search,
        ["@page"] = (page or 0) * 25,
        ["@perPage"] = 25
    }, cb)
end)

RegisterLegacyCallback("birdy:searchTweets", function(source, cb, search, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.fetchAll([[
        SELECT
            DISTINCT t.id, t.username, t.content, t.attachments,
            t.like_count, t.reply_count, t.retweet_count, t.reply_to,
            t.`timestamp`,

            (
                CASE WHEN t.reply_to IS NULL THEN NULL ELSE (SELECT username FROM phone_twitter_tweets WHERE id=t.reply_to LIMIT 1) END
            ) AS replyToAuthor,

            a.display_name, a.username, a.profile_image, a.verified,

            (
                SELECT TRUE FROM phone_twitter_likes l
                WHERE l.tweet_id=t.id AND l.username=@loggedInAs
            ) AS liked,
            (
                SELECT TRUE FROM phone_twitter_retweets r
                WHERE r.tweet_id=t.id AND r.username=@loggedInAs
            ) AS retweeted

        FROM phone_twitter_tweets t
            LEFT JOIN phone_twitter_accounts a ON a.username=t.username
        WHERE
            t.content LIKE CONCAT("%", @search, "%")

        ORDER BY t.`timestamp` DESC

        LIMIT
            @page, @perPage
    ]], {
        ["@search"] = search,
        ["@loggedInAs"] = username,
        ["@page"] = (page or 0) * 10,
        ["@perPage"] = 10
    }, cb)
end)

RegisterLegacyCallback("birdy:getData", function(source, cb, dataType, value, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    local tableName = "phone_twitter_likes"
    local whereColumn = "tweet_id"
    local accountColumn = "username"

    if dataType == "following" or dataType == "followers" then
        tableName = "phone_twitter_follows"

        if dataType == "following" then
            whereColumn = "follower"
            accountColumn = "followed"
        else
            whereColumn = "followed"
            accountColumn = "follower"
        end
    elseif dataType == "retweeters" then
        tableName = "phone_twitter_retweets"
    elseif dataType ~= "likes" then
        return cb({})
    end

    MySQL.Async.fetchAll(([[
        SELECT
            a.display_name AS `name`,
            a.username,
            a.profile_image AS profile_picture,
            a.bio,
            a.verified,

        (
            SELECT CASE WHEN f.followed IS NULL THEN FALSE ELSE TRUE END
                FROM phone_twitter_follows f
                WHERE f.follower=@loggedInAs AND a.username=f.followed
        ) AS isFollowing,

        (
            SELECT CASE WHEN f.follower IS NULL THEN FALSE ELSE TRUE END
                FROM phone_twitter_follows f
                WHERE f.follower=a.username AND f.followed=@loggedInAs
        ) AS isFollowingYou

        FROM
            %s w
        JOIN
            phone_twitter_accounts a ON a.username=w.%s
        WHERE
            w.%s=@whereValue

        ORDER BY
            a.username DESC

        LIMIT
            @page, @perPage
    ]]):format(tableName, accountColumn, whereColumn), {
        ["@loggedInAs"] = username,
        ["@whereValue"] = value,
        ["@page"] = (page or 0) * 20,
        ["@perPage"] = 20
    }, cb)
end)

exports("GetTweet", function(tweetId, cb)
    assert(type(tweetId) == "string", "Expected string for argument 1, got " .. type(tweetId))
    infoprint("warning", "GetTweet is deprecated, use GetBirdyPost instead")

    MySQL.Async.fetchAll([[
        SELECT
            DISTINCT t.id, t.username, t.content, t.attachments,
            t.like_count, t.reply_count, t.retweet_count, t.reply_to,
            t.`timestamp`,
            a.display_name, a.username, a.profile_image, a.verified
        FROM (phone_twitter_tweets t, phone_twitter_accounts a)
        WHERE t.id=@tweetId AND t.username=a.username
    ]], {
        ["@tweetId"] = tweetId
    }, cb)
end)

exports("GetBirdyPost", function(tweetId)
    local tweet = MySQL.single.await([[
        SELECT
            t.id,
            t.username,
            t.content,
            t.attachments,
            t.like_count AS likes,
            t.reply_count AS replies,
            t.retweet_count AS reposts,
            t.reply_to AS replyTo,
            t.`timestamp`,
            a.display_name AS displayName,
            a.profile_image AS avatar,
            a.verified
        FROM
            phone_twitter_tweets t
            LEFT JOIN phone_twitter_accounts a ON a.username = t.username
        WHERE
            t.id = ?
    ]], { tweetId })

    if tweet then
        tweet.attachments = DecodeJsonArray(tweet.attachments)
    end

    return tweet
end)

RegisterLegacyCallback("birdy:getPost", function(source, cb, tweetId)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    cb(GetTweet(tweetId, username))
end)

RegisterLegacyCallback("birdy:getPosts", function(source, cb, filters, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb({})
    end

    page = page or 0

    local where = "t.reply_to IS NULL"
    local join = ""
    local orderBy = "`timestamp` DESC"
    local includeRetweets = false
    local retweetWhere = ""
    local retweetJoin = ""

    if not filters then
        includeRetweets = true
    elseif filters.type == "following" then
        where = "t.reply_to IS NULL AND f.follower=@loggedInAs AND f.followed=t.username"
        join = "JOIN phone_twitter_follows f"
        retweetJoin = "JOIN phone_twitter_follows f ON f.follower=@loggedInAs AND r.username=f.followed"
        includeRetweets = true
    elseif filters.type == "replyTo" then
        where = "t.reply_to=@replyTo"
        orderBy = "t.like_count DESC, t.timestamp DESC"
    elseif filters.type == "user" then
        where = "t.username=@username AND t.reply_to IS NULL"
        retweetWhere = " AND r.username=@username"
        includeRetweets = true
    elseif filters.type == "media" then
        where = "t.username=@username AND t.attachments IS NOT NULL"
    elseif filters.type == "replies" then
        where = "t.username=@username AND t.reply_to IS NOT NULL"
    elseif filters.type == "liked" then
        where = "l.username=@username AND t.id=l.tweet_id"
        join = "JOIN phone_twitter_likes l"
        orderBy = "l.timestamp DESC"
    else
        return cb({})
    end

    local query = ([[
        SELECT
            (
                CASE WHEN t.reply_to IS NULL THEN NULL ELSE (SELECT username FROM phone_twitter_tweets WHERE id=t.reply_to LIMIT 1) END
            ) AS replyToAuthor,

            t.id, t.username, t.content, t.attachments,
            t.like_count, t.reply_count, t.retweet_count, t.reply_to,
            t.`timestamp`,

            a.display_name, a.profile_image, a.verified, a.private,

            (
                SELECT TRUE FROM phone_twitter_likes l2
                WHERE l2.tweet_id=t.id AND l2.username=@loggedInAs
            ) AS liked,
            (
                SELECT TRUE FROM phone_twitter_retweets r2
                WHERE r2.tweet_id=t.id AND r2.username=@loggedInAs
            ) AS retweeted,

            NULL AS tweet_timestamp, NULL AS retweeted_by_display_name, NULL AS retweeted_by_username
        FROM phone_twitter_tweets t

        INNER JOIN phone_twitter_accounts a
            ON a.username=t.username

        %s
        WHERE (a.private=0 OR a.username=@loggedInAs OR (
            SELECT TRUE FROM phone_twitter_follows f
            WHERE f.follower=@loggedInAs AND f.followed=a.username
        )) AND %s
    ]]):format(join, where)

    if includeRetweets then
        query = query .. ([[
            UNION ALL
            SELECT
                (
                    CASE WHEN t.reply_to IS NULL THEN NULL ELSE (SELECT username FROM phone_twitter_tweets WHERE id=t.reply_to LIMIT 1) END
                ) AS replyToAuthor,

                t.id, t.username, t.content, t.attachments,
                t.like_count, t.reply_count, t.retweet_count, t.reply_to,
                r.timestamp,

                a.display_name, a.profile_image, a.verified, a.private,

                (
                    SELECT TRUE FROM phone_twitter_likes l2
                    WHERE l2.tweet_id=t.id AND l2.username=@loggedInAs
                ) AS liked,
                (
                    SELECT TRUE FROM phone_twitter_retweets r2
                    WHERE r2.tweet_id=t.id AND r2.username=@loggedInAs
                ) AS retweeted,

                t.`timestamp` AS tweet_timestamp,
                (
                    SELECT display_name FROM phone_twitter_accounts a2
                    WHERE r.username=a2.username
                ) AS retweeted_by_display_name,
                r.username AS retweeted_by_username

            FROM phone_twitter_tweets t

            INNER JOIN phone_twitter_accounts a
                ON a.username=t.username

            JOIN phone_twitter_retweets r ON r.tweet_id=t.id
            %s
            WHERE (a.private=0 OR a.username=@loggedInAs OR (
                SELECT TRUE FROM phone_twitter_follows f
                WHERE f.follower=@loggedInAs AND f.followed=a.username
            )) %s
        ]]):format(retweetJoin, retweetWhere)
    end

    query = query .. ("\nORDER BY %s\nLIMIT @page, @perPage"):format(orderBy)

    MySQL.Async.fetchAll(query, {
        ["@page"] = page * 10,
        ["@perPage"] = 10,
        ["@username"] = filters and filters.username or nil,
        ["@replyTo"] = filters and filters.tweet_id or nil,
        ["@loggedInAs"] = username
    }, cb)
end)

local interactionTables = {
    like = {
        table = "phone_twitter_likes",
        column1 = "username",
        column2 = "tweet_id"
    },
    retweet = {
        table = "phone_twitter_retweets",
        column1 = "username",
        column2 = "tweet_id"
    }
}

RegisterLegacyCallback("birdy:toggleInteraction", function(source, cb, interactionType, tweetId, enabled)
    if interactionType ~= "like" and interactionType ~= "retweet" then
        return cb(not enabled)
    end

    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(not enabled)
    end

    local interaction = interactionTables[interactionType]
    local query

    if enabled then
        query = ("INSERT IGNORE INTO %s (%s, %s) VALUES (@loggedInAs, @tweetId)"):format(
            interaction.table,
            interaction.column1,
            interaction.column2
        )
    else
        query = ("DELETE FROM %s WHERE %s=@loggedInAs AND %s=@tweetId"):format(
            interaction.table,
            interaction.column1,
            interaction.column2
        )
    end

    MySQL.Async.execute(query, {
        ["@loggedInAs"] = username,
        ["@tweetId"] = tweetId
    }, function(affectedRows)
        if affectedRows == 0 then
            return cb(not enabled)
        end

        cb(enabled)

        TriggerClientEvent(
            "phone:twitter:updateTweetData",
            -1,
            tweetId,
            interactionType == "like" and "likes" or "retweets",
            enabled == true
        )

        if enabled then
            local tweetOwner = MySQL.Sync.fetchScalar(
                "SELECT username FROM phone_twitter_tweets WHERE id=@tweetId",
                { ["@tweetId"] = tweetId }
            )

            SendBirdyNotification(tweetOwner, username, interactionType, tweetId)
        end
    end)
end, {
    preventSpam = true,
    rateLimit = 30
})

RegisterLegacyCallback("birdy:toggleNotifications", function(source, cb, targetUsername, enabled)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(not enabled)
    end

    MySQL.Async.execute(
        "UPDATE phone_twitter_follows SET notifications=@enabled WHERE follower=@loggedInAs AND followed=@username ",
        {
            ["@enabled"] = enabled,
            ["@loggedInAs"] = username,
            ["@username"] = targetUsername
        },
        function(affectedRows)
            cb(affectedRows > 0 and enabled or not enabled)
        end
    )
end)

RegisterLegacyCallback("birdy:toggleFollow", function(source, cb, targetUsername, follow)
    local username = GetLoggedInBirdyUsername(source)

    if not username or targetUsername == username then
        return cb(not follow)
    end

    local params = {
        ["@loggedInAs"] = username,
        ["@username"] = targetUsername
    }

    local isPrivate = MySQL.Sync.fetchScalar(
        "SELECT private FROM phone_twitter_accounts WHERE username=@username",
        params
    )

    if isPrivate then
        if follow then
            MySQL.Async.execute(
                "INSERT IGNORE INTO phone_twitter_follow_requests (requester, requestee) VALUES (@loggedInAs, @username)",
                params,
                function(affectedRows)
                    cb(follow)

                    if affectedRows == 0 then
                        return
                    end

                    NotifyLoggedInAccounts("Twitter", targetUsername, {
                        title = L("BACKEND.TWITTER.NEW_FOLLOW_REQUEST", {
                            username = username
                        })
                    })
                end
            )
            return
        end

        MySQL.Async.execute(
            "DELETE FROM phone_twitter_follow_requests WHERE requester=@loggedInAs AND requestee=@username",
            params
        )
    end

    local query = follow
        and "INSERT IGNORE INTO phone_twitter_follows (followed, follower, notifications) VALUES (@username, @loggedInAs, 1)"
        or "DELETE FROM phone_twitter_follows WHERE followed=@username AND follower=@loggedInAs"

    MySQL.Async.execute(query, params, function(affectedRows)
        if affectedRows == 0 then
            return cb(not follow)
        end

        TriggerClientEvent("phone:twitter:updateProfileData", -1, targetUsername, "followers", follow == true)
        TriggerClientEvent("phone:twitter:updateProfileData", -1, username, "following", follow == true)

        if follow then
            SendBirdyNotification(targetUsername, username, "follow")
        end

        cb(follow)
    end)
end, {
    preventSpam = true,
    rateLimit = 30
})

RegisterLegacyCallback("birdy:getFollowRequests", function(source, cb, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT a.username, a.display_name AS `name`, a.profile_image AS profile_picture, a.verified,
            (
                SELECT CASE WHEN f.follower IS NULL THEN FALSE ELSE TRUE END
                    FROM phone_twitter_follows f
                    WHERE f.follower=a.username AND f.followed=@loggedInAs
            ) AS isFollowingYou

        FROM phone_twitter_follow_requests r

        INNER JOIN phone_twitter_accounts a
            ON a.username=r.requester

        WHERE r.requestee=@loggedInAs

        ORDER BY r.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@loggedInAs"] = username,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, cb)
end)

RegisterLegacyCallback("birdy:handleFollowRequest", function(source, cb, requester, accepted)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb(false)
    end

    local params = {
        ["@loggedInAs"] = username,
        ["@username"] = requester
    }

    local deleted = MySQL.Sync.execute(
        "DELETE FROM phone_twitter_follow_requests WHERE requestee=@loggedInAs AND requester=@username",
        params
    )

    if deleted == 0 then
        return cb(false)
    end

    if not accepted then
        return cb(true)
    end

    MySQL.Sync.execute(
        "INSERT IGNORE INTO phone_twitter_follows (follower, followed, notifications) VALUES (@username, @loggedInAs, 1)",
        params
    )

    TriggerClientEvent("phone:twitter:updateProfileData", -1, username, "followers", true)
    TriggerClientEvent("phone:twitter:updateProfileData", -1, requester, "following", true)
    SendBirdyNotification(username, requester, "follow")

    NotifyLoggedInAccounts("Twitter", requester, {
        title = L("BACKEND.TWITTER.FOLLOW_REQUEST_ACCEPTED_DESCRIPTION", {
            username = username
        })
    })

    cb(true)
end)

RegisterBirdyCallback("sendMessage", function(source, phoneNumber, username, recipient, content, attachments)
    if ContainsBlacklistedWord(source, "Birdy", content) then
        return false
    end

    local messageId = GenerateId("phone_twitter_messages", "id")
    local inserted = MySQL.update.await([[
        INSERT INTO phone_twitter_messages (id, sender, recipient, content, attachments)
        VALUES (@id, @sender, @recipient, @content, @attachments)
    ]], {
        ["@id"] = messageId,
        ["@sender"] = username,
        ["@recipient"] = recipient,
        ["@content"] = content,
        ["@attachments"] = attachments and json.encode(attachments) or nil
    })

    if inserted == 0 then
        return false
    end

    local numbers = GetLoggedInNumbers("Twitter", recipient)

    for i = 1, #numbers do
        local targetSource = GetSourceFromNumber(numbers[i])

        if targetSource then
            TriggerClientEvent("phone:twitter:newMessage", targetSource, {
                sender = username,
                recipient = recipient,
                content = content,
                attachments = attachments,
                timestamp = os.time() * 1000
            })
        end
    end

    local senderProfile = GetBirdyProfile(username)

    if senderProfile then
        NotifyLoggedInAccounts("Twitter", recipient, {
            app = "Twitter",
            title = senderProfile.name,
            content = content,
            thumbnail = attachments and attachments[1],
            avatar = senderProfile.profile_picture,
            showAvatar = true
        })
    end

    return true
end, nil, {
    preventSpam = true,
    rateLimit = 15
})

RegisterLegacyCallback("birdy:getMessages", function(source, cb, targetUsername, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            sender, recipient, content, attachments, `timestamp`

        FROM phone_twitter_messages

        WHERE (sender=@loggedInAs AND recipient=@username) OR (sender=@username AND recipient=@loggedInAs)

        ORDER BY `timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@loggedInAs"] = username,
        ["@username"] = targetUsername,
        ["@page"] = (page or 0) * 25,
        ["@perPage"] = 25
    }, cb)
end)

RegisterLegacyCallback("birdy:getRecentMessages", function(source, cb, page)
    local username = GetLoggedInBirdyUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            m.content, m.attachments, m.sender, f_m.username, m.`timestamp`,

            a.display_name AS `name`, a.profile_image AS profile_picture, a.verified

        FROM phone_twitter_messages m

        JOIN ((
            SELECT (
                CASE WHEN recipient!=@loggedInAs THEN recipient ELSE sender END
            ) AS username, MAX(`timestamp`) AS `timestamp`

            FROM phone_twitter_messages

            WHERE sender=@loggedInAs OR recipient=@loggedInAs

            GROUP BY username
        ) f_m)
        ON m.`timestamp`=f_m.`timestamp`

        INNER JOIN phone_twitter_accounts a
            ON a.username=f_m.username

        WHERE m.sender=@loggedInAs OR m.recipient=@loggedInAs

        GROUP BY f_m.username

        ORDER BY m.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@loggedInAs"] = username,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, cb)
end)

CreateThread(function()
    if not Config.BirdyTrending.Enabled then
        return
    end

    while not DatabaseCheckerFinished do
        Wait(500)
    end

    while true do
        MySQL.Async.execute(
            ("DELETE FROM phone_twitter_hashtags WHERE last_used < DATE_SUB(NOW(), INTERVAL %s HOUR)"):format(tostring(Config.BirdyTrending.Reset or 24)),
            {}
        )
        Wait(3600000)
    end
end)
