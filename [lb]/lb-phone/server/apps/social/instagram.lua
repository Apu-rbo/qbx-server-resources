local liveStreams = {}
local liveCalls = {}

local function GetLoggedInInstagramUsername(source)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return false
    end

    return GetLoggedInAccount(phoneNumber, "Instagram")
end

local function RegisterInstagramCallback(name, handler, defaultReturn)
    BaseCallback("instagram:" .. name, function(source, phoneNumber, ...)
        local username = GetLoggedInAccount(phoneNumber, "Instagram")

        if not username then
            return defaultReturn
        end

        return handler(source, phoneNumber, username, ...)
    end, defaultReturn)
end

local function CloneArray(list)
    local clone = {}

    if not list then
        return clone
    end

    for i = 1, #list do
        clone[i] = list[i]
    end

    return clone
end

local function ContainsValue(list, value)
    if not list then
        return false
    end

    for i = 1, #list do
        if list[i] == value then
            return true, i
        end
    end

    return false
end

local function RemoveValue(list, value)
    local found, index = ContainsValue(list, value)

    if found then
        table.remove(list, index)
        return true
    end

    return false
end

local function DecodeJson(value)
    if not value then
        return nil
    end

    if type(value) == "table" then
        return value
    end

    return json.decode(value)
end

RegisterLegacyCallback("instagram:getLives", function(source, cb)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    local visibleLives = {}

    for liveUsername, live in pairs(liveStreams) do
        if not live.private then
            visibleLives[liveUsername] = live
        else
            local follows = MySQL.Sync.fetchScalar(
                "SELECT TRUE FROM phone_instagram_follows WHERE follower=@follower AND followed=@followed",
                {
                    ["@follower"] = username,
                    ["@followed"] = liveUsername
                }
            )

            if follows then
                visibleLives[liveUsername] = live
            end
        end
    end

    cb(visibleLives)
end)

RegisterLegacyCallback("instagram:getLiveViewers", function(source, cb, liveUsername)
    local live = liveStreams[liveUsername]

    if not live then
        return cb({})
    end

    local viewers = {}

    for i = 1, #live.viewers do
        local phoneNumber = GetEquippedPhoneNumber(live.viewers[i])

        if phoneNumber then
            local rows = MySQL.Sync.fetchAll([[
                SELECT
                    a.profile_image AS avatar, a.verified, a.display_name AS `name`, a.username
                FROM phone_logged_in_accounts l
                INNER JOIN phone_instagram_accounts a ON l.username = a.username
                WHERE l.phone_number = ? AND l.active = 1 AND l.app = 'Instagram'
            ]], { phoneNumber })

            if rows and rows[1] then
                viewers[#viewers + 1] = rows[1]
            end
        end
    end

    cb(viewers)
end)

local function NotifyLiveDenied(source, title)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if phoneNumber then
        SendNotification(phoneNumber, {
            app = "Instagram",
            title = title
        })
    end
end

RegisterLegacyCallback("instagram:canGoLive", function(source, cb)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local allowed, reason = CanGoLive(source, username)

    if allowed and not ValidateChecks("startInstaPicLive", source, username) then
        allowed = false
    end

    if not allowed then
        NotifyLiveDenied(source, reason or L("BACKEND.INSTAGRAM.NOT_ALLOWED_LIVE"))
    end

    cb(allowed)
end)

RegisterLegacyCallback("instagram:canCreateStory", function(source, cb)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local allowed, reason = CanCreateStory(source, username)

    if allowed and not ValidateChecks("postInstaPicStory", source, username) then
        allowed = false
    end

    if not allowed then
        NotifyLiveDenied(source, reason or L("BACKEND.INSTAGRAM.NOT_ALLOWED_STORY"))
    end

    cb(allowed)
end)

local function NotifyLiveStarted(username)
    local notification = {
        title = L("APPS.INSTAGRAM.TITLE"),
        content = L("BACKEND.INSTAGRAM.STARTED_LIVE", {
            username = username
        })
    }

    if Config.InstaPicLiveNotifications then
        NotifyEveryone(Config.InstaPicLiveNotifications == "all" and "all" or "online", {
            app = "Instagram",
            title = notification.title,
            content = notification.content
        })
        return
    end

    local followers = MySQL.query.await(
        "SELECT follower FROM phone_instagram_follows WHERE followed = ?",
        { username }
    )

    for i = 1, #followers do
        NotifyLoggedInAccounts("Instagram", followers[i].follower, notification)
    end
end

RegisterNetEvent("phone:instagram:startLive", function(streamId)
    local playerSource = source
    local username = GetLoggedInInstagramUsername(playerSource)

    if not username or liveStreams[username] then
        return
    end

    if not CanGoLive(playerSource, username) or not ValidateChecks("startInstaPicLive", playerSource, username) then
        return
    end

    local account = MySQL.single.await(
        "SELECT profile_image, verified, display_name, private FROM phone_instagram_accounts WHERE username = ?",
        { username }
    )

    if not account then
        return
    end

    liveStreams[username] = {
        id = streamId,
        avatar = account.profile_image,
        verified = account.verified,
        name = account.display_name,
        private = account.private,
        host = playerSource,
        viewers = {},
        nearby = {},
        invites = {},
        participants = {}
    }

    Player(playerSource).state.instapicIsLive = username

    TriggerClientEvent("phone:instagram:updateLives", -1, liveStreams)

    Log(
        "InstaPic",
        playerSource,
        "success",
        L("BACKEND.LOGS.LIVE_TITLE"),
        L("BACKEND.LOGS.STARTED_LIVE", {
            username = username
        })
    )

    NotifyLiveStarted(username)
end)

local function StopParticipantStream(hostUsername, participantUsername)
    local hostLive = liveStreams[hostUsername]

    if not hostLive or not hostLive.participants then
        return
    end

    local participantSource

    for i = 1, #hostLive.participants do
        if hostLive.participants[i].username == participantUsername then
            participantSource = hostLive.participants[i].source
            table.remove(hostLive.participants, i)
            break
        end
    end

    if not participantSource then
        return
    end

    local hostAndViewers = CloneArray(hostLive.viewers)
    hostAndViewers[#hostAndViewers + 1] = hostLive.host

    for i = 1, #hostAndViewers do
        TriggerClientEvent("phone:instagram:leftLive", hostAndViewers[i], hostUsername, participantUsername, participantSource)
    end

    local viewerTargets = CloneArray(hostLive.viewers)

    for i = 1, #hostLive.participants do
        RemoveValue(viewerTargets, hostLive.participants[i].source)
    end

    TriggerClientEvent("phone:phone:removeVoiceTarget", participantSource, viewerTargets)
end

local function StopMainLive(live)
    if not live or not live.participants then
        return
    end

    local hostAndViewers = CloneArray(live.viewers)
    hostAndViewers[#hostAndViewers + 1] = live.host

    for i = 1, #live.participants do
        local participantUsername = live.participants[i] and live.participants[i].username
        local participantLive = participantUsername and liveStreams[participantUsername]

        if participantLive then
            TriggerClientEvent("phone:phone:removeVoiceTarget", participantLive.host, hostAndViewers)
            Player(participantLive.host).state.instapicIsLive = nil
            liveStreams[participantUsername] = nil
            TriggerClientEvent("phone:instagram:endLive", -1, participantUsername)
        end
    end

    for i = 1, #live.nearby do
        local nearbySource = live.nearby[i]

        if nearbySource then
            TriggerClientEvent("phone:phone:removeVoiceTarget", nearbySource, hostAndViewers)
            TriggerClientEvent("phone:instagram:leftProximity", -1, nearbySource, live.host)
        end
    end

    TriggerClientEvent("phone:phone:removeVoiceTarget", live.host, live.viewers)
end

RegisterLegacyCallback("instagram:endLive", function(source, cb)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(true)
    end

    local live = liveStreams[username]

    if not live then
        return cb(true)
    end

    local parentLive = live.participant

    if parentLive then
        StopParticipantStream(parentLive, username)
    else
        StopMainLive(live)
    end

    liveStreams[username] = nil
    Player(source).state.instapicIsLive = nil

    TriggerClientEvent("phone:instagram:updateLives", -1, liveStreams)
    TriggerClientEvent("phone:instagram:endLive", -1, username, parentLive)

    Log(
        "InstaPic",
        source,
        "error",
        L("BACKEND.LOGS.LIVE_TITLE"),
        L("BACKEND.LOGS.ENDED_LIVE", {
            username = username
        })
    )

    cb(true)
end)

AddEventHandler("playerDropped", function()
    local playerSource = source

    for username, live in pairs(liveStreams) do
        for i = #live.viewers, 1, -1 do
            if live.viewers[i] == playerSource then
                if liveCalls[playerSource] then
                    TriggerClientEvent("phone:endCall", live.host, liveCalls[playerSource])
                    liveCalls[playerSource] = nil
                end

                table.remove(live.viewers, i)
                TriggerClientEvent("phone:instagram:updateViewers", -1, username, #live.viewers)
            end
        end

        if live.host == playerSource then
            if live.participant then
                StopParticipantStream(live.participant, username)
            else
                StopMainLive(live)
            end

            liveStreams[username] = nil
            TriggerClientEvent("phone:instagram:updateLives", -1, liveStreams)
            TriggerClientEvent("phone:instagram:endLive", -1, username, live.participant)
            return
        end
    end
end)

RegisterNetEvent("phone:instagram:addCall", function(callId)
    local playerSource = source
    local isViewing = false

    for _, live in pairs(liveStreams) do
        if ContainsValue(live.viewers, playerSource) then
            isViewing = true
            break
        end
    end

    if not liveCalls[playerSource] and isViewing then
        liveCalls[playerSource] = callId
    end
end)

RegisterLegacyCallback("instagram:viewLive", function(source, cb, liveUsername)
    local live = liveStreams[liveUsername]

    if not live then
        return cb(false)
    end

    if not ContainsValue(live.viewers, source) then
        live.viewers[#live.viewers + 1] = source

        TriggerClientEvent("phone:phone:addVoiceTarget", live.host, {
            sources = source
        })

        TriggerClientEvent("phone:instagram:updateViewers", -1, liveUsername, #live.viewers)

        for i = 1, #live.participants do
            TriggerClientEvent("phone:phone:addVoiceTarget", live.participants[i].source, {
                sources = source
            })
        end

        SetTimeout(500, function()
            local nearby = live and live.nearby or {}

            for i = 1, #nearby do
                TriggerClientEvent("phone:phone:addVoiceTarget", nearby[i], {
                    sources = source
                })
                TriggerClientEvent("phone:instagram:enteredProximity", source, nearby[i], live.host)
            end
        end)
    end

    cb(live)
end)

RegisterLegacyCallback("instagram:stopViewing", function(source, cb, liveUsername)
    local live = liveStreams[liveUsername]

    if not live then
        return cb()
    end

    local wasViewing = false

    for i = #live.viewers, 1, -1 do
        if live.viewers[i] == source then
            wasViewing = true

            if liveCalls[source] then
                TriggerClientEvent("phone:instagram:endCall", live.host, liveCalls[source])
                liveCalls[source] = nil
            end

            table.remove(live.viewers, i)
            break
        end
    end

    for i = 1, #live.nearby do
        local nearbySource = live.nearby[i]

        if nearbySource then
            TriggerClientEvent("phone:phone:removeVoiceTarget", nearbySource, source)
            TriggerClientEvent("phone:instagram:leftProximity", source, nearbySource, live.host)
        end
    end

    if wasViewing then
        TriggerClientEvent("phone:phone:removeVoiceTarget", live.host, source)
        TriggerClientEvent("phone:instagram:updateViewers", -1, liveUsername, #live.viewers)

        for i = 1, #live.participants do
            TriggerClientEvent("phone:phone:removeVoiceTarget", live.participants[i].source, source)
        end
    end

    cb()
end)

RegisterNetEvent("phone:instagram:inviteLive", function(targetUsername)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return
    end

    local live = liveStreams[username]

    if not live or not live.participants then
        return
    end

    if liveStreams[targetUsername] or #live.participants >= 3 then
        return
    end

    for i = 1, #live.participants do
        if live.participants[i].username == targetUsername then
            return
        end
    end

    live.invites[targetUsername] = true

    local activeAccounts = GetActiveAccounts("Instagram")

    for phoneNumber, activeUsername in pairs(activeAccounts) do
        if activeUsername == targetUsername then
            local targetSource = GetSourceFromNumber(phoneNumber)

            if targetSource then
                TriggerClientEvent("phone:instagram:invitedLive", targetSource, username)
            end
        end
    end
end)

RegisterNetEvent("phone:instagram:removeLive", function(participantUsername)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return
    end

    local live = liveStreams[username]

    if not live then
        return
    end

    local participantSource

    for i = 1, #live.participants do
        if live.participants[i].username == participantUsername then
            participantSource = live.participants[i].source
            break
        end
    end

    if participantSource then
        StopParticipantStream(username, participantUsername)
        liveStreams[participantUsername] = nil
        Player(participantSource).state.instapicIsLive = nil

        TriggerClientEvent("phone:instagram:updateLives", -1, liveStreams)
        TriggerClientEvent("phone:instagram:endLive", -1, participantUsername, username)
        TriggerClientEvent("phone:instagram:removedLive", participantSource)
    end

    TriggerClientEvent("phone:instagram:updateLives", -1, liveStreams)
end)

RegisterLegacyCallback("instagram:joinLive", function(source, cb, hostUsername, streamId)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    if not ValidateChecks("joinInstaPicLive", source, username, hostUsername) then
        return cb(false)
    end

    local hostLive = liveStreams[hostUsername]

    if not hostLive or not hostLive.participants then
        return cb(false)
    end

    if liveStreams[username] or #hostLive.participants >= 3 then
        return cb(false)
    end

    hostLive.invites[username] = nil

    for i = 1, #hostLive.participants do
        if hostLive.participants[i].username == username then
            return cb(false)
        end
    end

    local account = MySQL.single.await(
        "SELECT profile_image, verified, display_name FROM phone_instagram_accounts WHERE username=@username",
        { ["@username"] = username }
    )

    if not account then
        return cb(false)
    end

    local participant = {
        username = username,
        name = account.display_name,
        avatar = account.profile_image,
        verified = account.verified,
        id = streamId,
        source = source
    }

    hostLive.participants[#hostLive.participants + 1] = participant

    liveStreams[username] = {
        id = streamId,
        avatar = account.profile_image,
        verified = account.verified,
        name = account.display_name,
        host = source,
        nearby = {},
        viewers = {},
        participant = hostUsername
    }

    Player(source).state.instapicIsLive = username

    TriggerClientEvent("phone:instagram:updateLives", -1, liveStreams)

    local followers = MySQL.query.await(
        "SELECT follower FROM phone_instagram_follows WHERE followed = @username",
        { ["@username"] = username }
    )

    for i = 1, #followers do
        NotifyLoggedInAccounts("Instagram", followers[i].follower, {
            app = "Instagram",
            title = L("APPS.INSTAGRAM.TITLE"),
            content = L("BACKEND.INSTAGRAM.JOINED_LIVE", {
                invitee = username,
                inviter = hostUsername
            })
        })
    end

    local hostAndViewers = CloneArray(hostLive.viewers)
    hostAndViewers[#hostAndViewers + 1] = hostLive.host

    TriggerClientEvent("phone:phone:addVoiceTarget", source, {
        sources = hostAndViewers
    })

    for i = 1, #hostAndViewers do
        TriggerClientEvent("phone:instagram:joinedLive", hostAndViewers[i], {
            username = username,
            name = account.display_name,
            avatar = account.profile_image,
            verified = account.verified,
            id = streamId,
            host = hostUsername,
            source = source
        })
    end

    cb(true)
end)

RegisterNetEvent("phone:instagram:sendLiveMessage", function(data)
    if data and liveStreams[data.live] then
        TriggerClientEvent("phone:instagram:addLiveMessage", -1, data)
    end
end)

RegisterNetEvent("phone:instagram:enteredLiveProximity", function(liveUsername)
    local playerSource = source
    local participantLive = liveStreams[liveUsername]
    local parentLiveUsername = participantLive and participantLive.participant
    local participantContext

    if parentLiveUsername then
        participantContext = participantLive
        liveUsername = parentLiveUsername
    end

    local live = liveStreams[liveUsername]

    if not live or ContainsValue(live.nearby, playerSource) then
        return
    end

    for i = 1, #live.participants do
        if live.participants[i].source == playerSource then
            return
        end
    end

    live.nearby[#live.nearby + 1] = playerSource

    local shouldHear = CloneArray(live.viewers)

    if participantContext then
        shouldHear[#shouldHear + 1] = live.host
    end

    debugprint("shouldHear (joined)", json.encode(shouldHear, {
        indent = true
    }))

    TriggerClientEvent("phone:phone:addVoiceTarget", playerSource, {
        sources = shouldHear
    })
    TriggerClientEvent("phone:instagram:enteredProximity", -1, playerSource, participantContext and participantContext.host or live.host)
end)

RegisterNetEvent("phone:instagram:leftLiveProximity", function(liveUsername, includeHost)
    local playerSource = source
    local participantLive = liveStreams[liveUsername]
    local parentLiveUsername = participantLive and participantLive.participant
    local participantContext

    if parentLiveUsername then
        participantContext = participantLive
        liveUsername = parentLiveUsername
    end

    local live = liveStreams[liveUsername]

    if not live then
        return
    end

    RemoveValue(live.nearby, playerSource)

    local shouldHear = CloneArray(live.viewers)

    if participantContext or includeHost then
        shouldHear[#shouldHear + 1] = live.host
    end

    debugprint("shouldHear (left)", json.encode(shouldHear, {
        indent = true
    }))

    TriggerClientEvent("phone:phone:removeVoiceTarget", playerSource, shouldHear)
    TriggerClientEvent("phone:instagram:leftProximity", -1, playerSource, participantContext and participantContext.host or live.host)
end)

RegisterLegacyCallback("instagram:addToStory", function(source, cb, image, metadata)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local storyId = GenerateId("phone_instagram_stories", "id")

    MySQL.Async.execute(
        "INSERT INTO phone_instagram_stories (id, username, image, metadata) VALUES (@id, @username, @image, @metadata)",
        {
            ["@id"] = storyId,
            ["@username"] = username,
            ["@image"] = image,
            ["@metadata"] = metadata and json.encode(metadata) or nil
        },
        function(affectedRows)
            cb(affectedRows > 0)
        end
    )

    MySQL.Async.fetchAll(
        "SELECT profile_image, verified FROM phone_instagram_accounts WHERE username=@username",
        { ["@username"] = username },
        function(accounts)
            local account = accounts and accounts[1]

            if account then
                TriggerClientEvent("phone:instagram:addStory", -1, {
                    username = username,
                    avatar = account.profile_image,
                    verified = account.verified,
                    seen = false
                })
            end

            Log("InstaPic", source, "info", L("BACKEND.LOGS.ADDED_STORY", {
                username = username
            }), image)
        end
    )
end)

RegisterLegacyCallback("instagram:removeFromStory", function(source, cb, storyId)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.execute(
        "DELETE FROM phone_instagram_stories WHERE id=@id AND username=@username",
        {
            ["@id"] = storyId,
            ["@username"] = username
        },
        function(affectedRows)
            cb(affectedRows > 0)
        end
    )
end)

RegisterLegacyCallback("instagram:getStories", function(source, cb)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            s.username, a.verified, a.profile_image AS avatar,

            (SELECT
                (SELECT COUNT(*) FROM phone_instagram_stories s2
                    WHERE s2.username = s.username AND NOT EXISTS (
                    SELECT TRUE FROM phone_instagram_stories_views v
                    WHERE v.viewer = @loggedInAs AND v.story_id = s2.id
                )
            ) = 0) AS seen

        FROM phone_instagram_stories s

        INNER JOIN phone_instagram_accounts a
        ON a.username = s.username

        WHERE a.private=FALSE OR EXISTS (
            SELECT TRUE FROM phone_instagram_follows f
            WHERE f.followed = s.username AND f.follower = @loggedInAs
        )

        GROUP BY s.username, a.verified, a.profile_image

        ORDER BY MAX(s.`timestamp`) DESC
    ]], {
        ["@loggedInAs"] = username
    }, cb)
end)

RegisterInstagramCallback("getStory", function(source, phoneNumber, username, storyUsername)
    local stories = MySQL.query.await([[
        SELECT
            s.id,
            s.image,
            s.metadata,
            s.`timestamp`,
            (IF((
                SELECT TRUE FROM phone_instagram_stories_views v
                WHERE v.viewer = ? AND v.story_id = s.id
            ), TRUE, FALSE)) AS seen

        FROM phone_instagram_stories s

        WHERE s.username = ?

        ORDER BY s.timestamp ASC
    ]], { username, storyUsername })

    if not stories or #stories == 0 then
        return stories
    end

    for i = 1, #stories do
        local story = stories[i]

        if story.metadata then
            story.metadata = json.decode(story.metadata)
        end

        if username == storyUsername then
            story.views = MySQL.scalar.await(
                "SELECT COUNT(1) FROM phone_instagram_stories_views WHERE story_id = ? AND viewer != ?",
                { story.id, username }
            )

            story.viewers = MySQL.query.await([[
                SELECT
                    a.profile_image AS avatar,
                    a.verified

                FROM
                    phone_instagram_stories_views v

                INNER JOIN phone_instagram_accounts a
                ON a.username = v.viewer

                WHERE
                    v.story_id = ? AND v.viewer != ?

                ORDER BY v.`timestamp` DESC

                LIMIT 3
            ]], { story.id, username })
        end
    end

    return stories
end)

RegisterLegacyCallback("instagram:getViewers", function(source, cb, storyId, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local ownsStory = MySQL.Sync.fetchScalar(
        "SELECT TRUE FROM phone_instagram_stories WHERE id = @id AND username = @loggedInAs",
        {
            ["@id"] = storyId,
            ["@loggedInAs"] = username
        }
    )

    if not ownsStory then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT a.profile_image AS avatar, a.verified, a.display_name AS `name`, a.username
        FROM phone_instagram_stories_views v

        INNER JOIN phone_instagram_accounts a
        ON a.username = v.viewer

        WHERE v.story_id = @id AND v.viewer != @loggedInAs

        ORDER BY v.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@id"] = storyId,
        ["@loggedInAs"] = username,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, cb)
end)

RegisterLegacyCallback("instagram:viewedStory", function(source, cb, storyId)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.execute(
        "INSERT IGNORE INTO phone_instagram_stories_views (story_id, viewer) VALUES (@id, @loggedInAs)",
        {
            ["@id"] = storyId,
            ["@loggedInAs"] = username
        },
        function(affectedRows)
            cb(affectedRows > 0)
        end
    )
end)

CreateThread(function()
    while not DatabaseCheckerFinished do
        Wait(500)
    end

    while true do
        MySQL.Async.execute("DELETE FROM phone_instagram_stories WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL 24 HOUR)", {})
        Wait(3600000)
    end
end)

local notificationMessages = {
    like_photo = "BACKEND.INSTAGRAM.LIKED_PHOTO",
    like_comment = "BACKEND.INSTAGRAM.LIKED_COMMENT",
    comment = "BACKEND.INSTAGRAM.COMMENTED",
    follow = "BACKEND.INSTAGRAM.NEW_FOLLOWER"
}

local function SendInstagramNotification(username, fromUsername, notificationType, postId)
    if username == fromUsername then
        return
    end

    local messageKey = notificationMessages[notificationType]

    if not messageKey then
        return
    end

    if notificationType == "follow" or notificationType == "like_photo" or notificationType == "like_comment" then
        local query = "SELECT TRUE FROM phone_instagram_notifications WHERE username=@username AND `from`=@from AND `type`=@type"

        if notificationType ~= "follow" then
            query = query .. " AND post_id=@post_id"
        end

        local exists = MySQL.Sync.fetchScalar(query, {
            ["@username"] = username,
            ["@from"] = fromUsername,
            ["@type"] = notificationType,
            ["@post_id"] = postId
        })

        if exists then
            return
        end
    end

    MySQL.Async.execute(
        "INSERT INTO phone_instagram_notifications (id, username, `from`, `type`, post_id) VALUES (@id, @username, @from, @type, @postId)",
        {
            ["@id"] = GenerateId("phone_instagram_notifications", "id"),
            ["@username"] = username,
            ["@from"] = fromUsername,
            ["@type"] = notificationType,
            ["@postId"] = postId
        }
    )

    local thumbnail

    if notificationType == "like_photo" or notificationType == "comment" then
        thumbnail = MySQL.Sync.fetchScalar(
            "SELECT TRIM(BOTH '\"' FROM JSON_EXTRACT(media, '$[0]')) FROM phone_instagram_posts WHERE id=@id",
            { ["@id"] = postId }
        )
    end

    NotifyLoggedInAccounts("Instagram", username, {
        app = "Instagram",
        title = L("APPS.INSTAGRAM.TITLE"),
        content = L(messageKey, {
            username = fromUsername
        }),
        thumbnail = thumbnail
    })
end

RegisterLegacyCallback("instagram:getNotifications", function(source, cb, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({
            notifications = {},
            requests = {
                recent = {},
                total = 0
            }
        })
    end

    page = page or 0

    local notifications = MySQL.Sync.fetchAll([[
        SELECT
            (
                SELECT CASE WHEN f.followed IS NULL THEN FALSE ELSE TRUE END
                    FROM phone_instagram_follows f
                    WHERE f.follower=@username AND f.followed=n.`from`
            ) AS isFollowing,
            n.`from` AS username,
            n.`type`,
            n.`timestamp`,
            TRIM(BOTH '"' FROM JSON_EXTRACT(p.media, '$[0]')) AS photo,
            p.id AS postId,
            c.`comment`,
            c.id AS commentId,
            a.profile_image AS avatar,
            a.verified

        FROM phone_instagram_notifications n

        LEFT JOIN phone_instagram_comments c
            ON n.post_id = c.id

        LEFT JOIN phone_instagram_posts p
            ON p.id = (CASE
                WHEN n.`type`="like_photo"
                THEN n.post_id

                WHEN n.`type`="comment"
                THEN c.post_id

                WHEN n.`type`="like_comment"
                THEN c.post_id

                ELSE NULL
                END
            )

        LEFT JOIN phone_instagram_accounts a
            ON a.username=n.`from`

        WHERE n.username=@username

        ORDER BY n.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@username"] = username,
        ["@page"] = page * 15,
        ["@perPage"] = 15
    })

    if page > 0 then
        return cb({
            notifications = notifications
        })
    end

    local recentRequests = MySQL.Sync.fetchAll([[
        SELECT a.username, a.profile_image AS avatar

        FROM phone_instagram_follow_requests r

        INNER JOIN phone_instagram_accounts a
            ON a.username = r.requester

        WHERE r.requestee=@username

        ORDER BY r.`timestamp` DESC

        LIMIT 2
    ]], {
        ["@username"] = username
    })

    local requestCount = MySQL.Sync.fetchScalar(
        "SELECT COUNT(1) FROM phone_instagram_follow_requests WHERE requestee=@username",
        { ["@username"] = username }
    )

    cb({
        notifications = notifications,
        requests = {
            recent = recentRequests,
            total = requestCount
        }
    })
end)

RegisterLegacyCallback("instagram:getFollowRequests", function(source, cb, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT a.username, a.display_name AS `name`, a.profile_image AS avatar, a.verified
        FROM phone_instagram_follow_requests r

        INNER JOIN phone_instagram_accounts a
            ON a.username = r.requester

        WHERE r.requestee=@loggedInAs

        ORDER BY r.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@loggedInAs"] = username,
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15
    }, cb)
end)

RegisterLegacyCallback("instagram:handleFollowRequest", function(source, cb, requester, accepted)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local params = {
        ["@loggedInAs"] = username,
        ["@username"] = requester
    }

    local removed = MySQL.Sync.execute(
        "DELETE FROM phone_instagram_follow_requests WHERE requestee=@loggedInAs AND requester=@username",
        params
    )

    if removed == 0 then
        return cb(false)
    end

    if not accepted then
        return cb(true)
    end

    MySQL.Sync.execute(
        "INSERT IGNORE INTO phone_instagram_follows (follower, followed) VALUES (@username, @loggedInAs)",
        params
    )

    TriggerClientEvent("phone:instagram:updateProfileData", -1, username, "followers", true)
    TriggerClientEvent("phone:instagram:updateProfileData", -1, requester, "following", true)

    local displayName = MySQL.Sync.fetchScalar(
        "SELECT display_name FROM phone_instagram_accounts WHERE username=@loggedInAs",
        params
    )

    NotifyLoggedInAccounts("Instagram", requester, {
        app = "Instagram",
        title = L("BACKEND.INSTAGRAM.FOLLOW_REQUEST_ACCEPTED_TITLE"),
        content = L("BACKEND.INSTAGRAM.FOLLOW_REQUEST_ACCEPTED_DESCRIPTION", {
            displayName = displayName,
            username = username
        })
    })

    cb(true)
end)

RegisterLegacyCallback("instagram:search", function(source, cb, search, page)
    MySQL.Async.fetchAll([[
        SELECT
            username,
            display_name AS name,
            profile_image AS avatar,
            verified,
            private

        FROM
            phone_instagram_accounts

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

RegisterLegacyCallback("instagram:createAccount", function(source, cb, displayName, username, password)
    if type(username) ~= "string" then
        return cb({
            success = false,
            error = "USERNAME_NOT_ALLOWED"
        })
    end

    username = username:lower()

    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb({
            success = false,
            error = "UNKNOWN"
        })
    end

    if not IsUsernameValid(username) then
        return cb({
            success = false,
            error = "USERNAME_NOT_ALLOWED"
        })
    end

    debugprint("INSTAGRAM", ("%s wants to create an account"):format(phoneNumber))

    local existingUsername = MySQL.Sync.fetchScalar(
        "SELECT username FROM phone_instagram_accounts WHERE username=@username",
        { ["@username"] = username }
    )

    if existingUsername then
        debugprint("INSTAGRAM", ("%s tried to create an account with an existing username"):format(phoneNumber))
        return cb({
            success = false,
            error = "USERNAME_TAKEN"
        })
    end

    MySQL.Sync.execute(
        "INSERT INTO phone_instagram_accounts (display_name, username, password, phone_number) VALUES (@displayName, @username, @password, @phonenumber)",
        {
            ["@displayName"] = displayName,
            ["@username"] = username,
            ["@password"] = GetPasswordHash(password),
            ["@phonenumber"] = phoneNumber
        }
    )

    debugprint("INSTAGRAM", ("%s created an account"):format(phoneNumber))

    AddLoggedInAccount(phoneNumber, "Instagram", username)

    cb({
        success = true
    })

    if Config.AutoFollow.Enabled and Config.AutoFollow.InstaPic.Enabled then
        for i = 1, #Config.AutoFollow.InstaPic.Accounts do
            MySQL.update.await(
                "INSERT INTO phone_instagram_follows (followed, follower) VALUES (?, ?)",
                { Config.AutoFollow.InstaPic.Accounts[i], username }
            )
        end
    end
end, {
    preventSpam = true,
    rateLimit = 4
})

RegisterInstagramCallback("changePassword", function(source, phoneNumber, username, oldPassword, newPassword)
    if not Config.ChangePassword.InstaPic then
        infoprint("warning", ("%s tried to change password on InstaPic, but it's not enabled in the config."):format(source))
        return false
    end

    if oldPassword == newPassword or type(newPassword) ~= "string" or #newPassword < 3 then
        debugprint("same password / too short")
        return false
    end

    if liveStreams[username] then
        debugprint("Can't change password when live")
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_instagram_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(oldPassword, passwordHash) then
        return false
    end

    local changed = MySQL.update.await(
        "UPDATE phone_instagram_accounts SET password = ? WHERE username = ?",
        { GetPasswordHash(newPassword), username }
    ) > 0

    if not changed then
        return false
    end

    NotifyLoggedInAccounts("Instagram", username, {
        title = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.TITLE"),
        content = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.DESCRIPTION")
    })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'Instagram' AND phone_number != ?",
        { username, phoneNumber }
    )

    ClearActiveAccountsCache("Instagram", username, phoneNumber)

    Log(
        "InstaPic",
        source,
        "info",
        L("BACKEND.LOGS.CHANGED_PASSWORD.TITLE"),
        L("BACKEND.LOGS.CHANGED_PASSWORD.DESCRIPTION", {
            number = phoneNumber,
            username = username,
            app = "InstaPic"
        })
    )

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "instagram",
        reason = "password",
        number = phoneNumber
    })

    return true
end, false)

local function DeleteInstaPicAccount(username)
    assert(type(username) == "string", "Expected string for argument 1 (username), got " .. type(username))

    local deleted = MySQL.update.await(
        "DELETE FROM phone_instagram_accounts WHERE username = ?",
        { username }
    ) > 0

    if not deleted then
        return false
    end

    NotifyLoggedInAccounts("Instagram", username, {
        title = L("BACKEND.MISC.DELETED_NOTIFICATION.TITLE"),
        content = L("BACKEND.MISC.DELETED_NOTIFICATION.DESCRIPTION")
    })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'Instagram'",
        { username }
    )

    ClearActiveAccountsCache("Instagram", username)

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "instagram",
        reason = "deleted"
    })

    return true
end

RegisterInstagramCallback("deleteAccount", function(source, phoneNumber, username, password)
    if not Config.DeleteAccount.InstaPic then
        infoprint("warning", ("%s tried to delete their account on InstaPic, but it's not enabled in the config."):format(source))
        return false
    end

    if liveStreams[username] then
        debugprint("Can't delete account when live")
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_instagram_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(password, passwordHash) then
        return false
    end

    local deleted = DeleteInstaPicAccount(username)

    if deleted then
        Log(
            "InstaPic",
            source,
            "info",
            L("BACKEND.LOGS.DELETED_ACCOUNT.TITLE"),
            L("BACKEND.LOGS.DELETED_ACCOUNT.DESCRIPTION", {
                number = phoneNumber,
                username = username,
                app = "InstaPic"
            })
        )
    end

    return deleted
end, false)

exports("DeleteInstaPicAccount", DeleteInstaPicAccount)

RegisterLegacyCallback("instagram:logIn", function(source, cb, username, password)
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
            error = "UNKNOWN_ACCOUNT"
        })
    end

    debugprint("INSTAGRAM", ("%s wants to log in on account %s"):format(phoneNumber, username))
    debugprint("INSTAGRAM", ("%s is not logged in, checking if account exists"):format(phoneNumber))

    username = username:lower()

    local passwordHash = MySQL.Sync.fetchScalar(
        "SELECT password FROM phone_instagram_accounts WHERE username=@username",
        { ["@username"] = username }
    )

    if not passwordHash then
        debugprint("INSTAGRAM", ("%s tried to log in on non-existing account %s"):format(phoneNumber, username))
        return cb({
            success = false,
            error = "UNKNOWN_ACCOUNT"
        })
    end

    if not VerifyPasswordHash(password, passwordHash) then
        debugprint("INSTAGRAM", ("%s tried to log in on account %s with wrong password"):format(phoneNumber, username))
        return cb({
            success = false,
            error = "INCORRECT_PASSWORD"
        })
    end

    debugprint("INSTAGRAM", ("%s logged in on account %s"):format(phoneNumber, username))

    AddLoggedInAccount(phoneNumber, "Instagram", username)

    MySQL.Async.fetchAll([[
        SELECT
            display_name AS name, username, profile_image AS avatar, verified
        FROM phone_instagram_accounts

        WHERE username = @username
    ]], {
        ["@username"] = username
    }, function(accounts)
        debugprint("INSTAGRAM", ("%s got account data"):format(phoneNumber))

        cb({
            success = true,
            account = accounts and accounts[1]
        })
    end)
end)

RegisterLegacyCallback("instagram:isLoggedIn", function(source, cb)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb(false)
    end

    local username = GetLoggedInAccount(phoneNumber, "Instagram")

    if not username then
        return cb(false)
    end

    local account = MySQL.single.await([[
        SELECT display_name AS `name`, username, profile_image AS avatar, verified
        FROM phone_instagram_accounts
        WHERE username = ?
    ]], { username })

    cb(account or false)
end)

RegisterLegacyCallback("instagram:signOut", function(source, cb)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return cb(false)
    end

    local username = GetLoggedInAccount(phoneNumber, "Instagram")

    if not username then
        return cb(false)
    end

    RemoveLoggedInAccount(phoneNumber, "Instagram", username)
    cb(true)
end)

RegisterLegacyCallback("instagram:getProfile", function(source, cb, profileUsername)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.fetchAll([[
        SELECT display_name AS name, username, profile_image AS avatar, bio, verified, private, follower_count as followers, following_count as following, post_count as posts,
            (
                IF((SELECT TRUE FROM phone_instagram_follows f WHERE f.followed=@username AND f.follower=@loggedInAs), TRUE, FALSE)
            ) AS isFollowing,
            (
                IF((SELECT TRUE FROM phone_instagram_follow_requests fr WHERE fr.requester=@loggedInAs AND fr.requestee=@username), TRUE, FALSE)
            ) AS requested,

            (SELECT a.story_count > 0) AS hasStory,
            (SELECT a.story_count = (
                SELECT COUNT(*) FROM phone_instagram_stories_views
                WHERE viewer=@loggedInAs
                    AND story_id IN (SELECT id FROM phone_instagram_stories WHERE username=@username)
            )) AS seenStory

        FROM phone_instagram_accounts a

        WHERE a.username=@username
    ]], {
        ["@username"] = profileUsername,
        ["@loggedInAs"] = username
    }, function(result)
        local profile = result and result[1]

        if profile then
            profile.isLive = liveStreams[profileUsername] ~= nil
        end

        cb(profile or false)
    end)
end)

local function SendInstaPicWebhook(username, caption, media)
    if not Config.Post.InstaPic then
        return
    end

    if not INSTAPIC_WEBHOOK or INSTAPIC_WEBHOOK:sub(-14) == "/api/webhooks/" then
        return
    end

    local profileImage = MySQL.scalar.await(
        "SELECT profile_image FROM phone_instagram_accounts WHERE username=?",
        { username }
    )

    PerformHttpRequest(INSTAPIC_WEBHOOK, function() end, "POST", json.encode({
        username = Config.Post.Accounts and Config.Post.Accounts.InstaPic and Config.Post.Accounts.InstaPic.Username or "InstaPic",
        avatar_url = Config.Post.Accounts and Config.Post.Accounts.InstaPic and Config.Post.Accounts.InstaPic.Avatar or "https://assets.loaf-scripts.com/lb-phone/icons/InstaPic.png",
        embeds = {
            {
                title = L("APPS.INSTAGRAM.NEW_POST"),
                description = caption and #caption > 0 and caption or nil,
                color = 9059001,
                timestamp = GetTimestampISO(),
                author = {
                    name = "@" .. username,
                    icon_url = profileImage or "https://cdn.discordapp.com/embed/avatars/5.png"
                },
                image = {
                    url = media[1]
                },
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

RegisterLegacyCallback("instagram:createPost", function(source, cb, media, caption, location)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    if ContainsBlacklistedWord(source, "InstaPic", caption) then
        return cb(false)
    end

    if not ValidateChecks("postInstaPic", source, username, media, caption, location) then
        debugprint("instagram:createPost - postInstaPic check failed")
        return cb(false)
    end

    local postId = GenerateId("phone_instagram_posts", "id")
    local encodedMedia = json.encode(media)

    MySQL.Sync.execute(
        "INSERT INTO phone_instagram_posts (id, username, media, caption, location) VALUES (@id, @username, @media, @caption, @location)",
        {
            ["@id"] = postId,
            ["@username"] = username,
            ["@media"] = encodedMedia,
            ["@caption"] = caption,
            ["@location"] = location
        }
    )

    cb(true)

    local post = {
        username = username,
        media = encodedMedia,
        caption = caption,
        location = location,
        id = postId,
        source = source
    }

    TriggerClientEvent("phone:instagram:newPost", -1, post)
    TriggerEvent("lb-phone:instapic:newPost", post)

    local logMessage = ("**Caption**: %s\n\n**Photos**:\n"):format(caption or "")

    for i = 1, #media do
        logMessage = logMessage .. ("[Photo %s](%s)\n"):format(i, media[i])
    end

    logMessage = logMessage .. "**ID:** " .. postId

    Log("InstaPic", source, "info", "New post", logMessage)
    SendInstaPicWebhook(username, caption, media)
end, {
    preventSpam = true,
    rateLimit = 6
})

RegisterLegacyCallback("instagram:deletePost", function(source, cb, postId)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local canDelete = IsAdmin(source)

    if not canDelete then
        canDelete = MySQL.Sync.fetchScalar(
            "SELECT TRUE FROM phone_instagram_posts WHERE id=@id AND username=@username",
            {
                ["@id"] = postId,
                ["@username"] = username
            }
        )
    end

    if not canDelete then
        return cb(false)
    end

    local params = { ["@id"] = postId }

    MySQL.Sync.execute("DELETE FROM phone_instagram_likes WHERE id=@id", params)
    MySQL.Sync.execute("DELETE FROM phone_instagram_notifications WHERE post_id=@id", params)
    MySQL.Sync.execute("DELETE FROM phone_instagram_comments WHERE post_id=@id", params)

    local deleted = MySQL.Sync.execute("DELETE FROM phone_instagram_posts WHERE id=@id", params) > 0

    if deleted then
        Log("InstaPic", source, "error", "Deleted post", "**ID**: " .. postId)
    end

    cb(deleted)
end)

RegisterLegacyCallback("instagram:getPost", function(source, cb, postId)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    MySQL.Async.fetchAll([[
        SELECT
            p.id, p.media, p.caption, p.username, p.timestamp, p.like_count, p.comment_count, p.location,

            a.verified, a.profile_image AS avatar,

            (IF((
                SELECT TRUE FROM phone_instagram_likes l
                WHERE l.id=p.id AND l.username=@loggedInAs AND l.is_comment=FALSE
            ), TRUE, FALSE)) AS liked

        FROM phone_instagram_posts p

        INNER JOIN phone_instagram_accounts a
            ON p.username = a.username

        WHERE p.id=@id
    ]], {
        ["@id"] = postId,
        ["@loggedInAs"] = username
    }, function(posts)
        cb(posts and posts[1] or false)
    end)
end)

RegisterLegacyCallback("instagram:getPosts", function(source, cb, filters, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    filters = filters or {}

    local where

    if filters.following then
        where = [[
            JOIN phone_instagram_follows f

            WHERE f.follower=@loggedInAs
                AND f.followed=p.username
        ]]
    elseif filters.profile then
        where = "WHERE p.username=@username"
    else
        where = [[
            WHERE a.private=FALSE
        ]]
    end

    MySQL.Async.fetchAll(([[
        SELECT
            p.id, p.media, p.caption, p.username, p.timestamp, p.like_count, p.comment_count, p.location,

            a.verified, a.profile_image AS avatar,

            (IF((
                SELECT TRUE FROM phone_instagram_likes l
                WHERE l.id=p.id AND l.username=@loggedInAs AND l.is_comment=FALSE
            ), TRUE, FALSE)) AS liked

        FROM phone_instagram_posts p

        INNER JOIN phone_instagram_accounts a
            ON p.username = a.username

        %s

        ORDER BY p.timestamp DESC

        LIMIT @page, @perPage
    ]]):format(where), {
        ["@page"] = (page or 0) * 15,
        ["@perPage"] = 15,
        ["@loggedInAs"] = username,
        ["@username"] = filters.username
    }, cb)
end)

RegisterLegacyCallback("instagram:getComments", function(source, cb, postId, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            c.id, c.comment, c.`timestamp`, c.like_count,
            a.username, a.profile_image, a.verified,

            (IF((
                SELECT TRUE FROM phone_instagram_likes l
                WHERE l.id=c.id AND l.username=@loggedInAs AND l.is_comment=TRUE
            ), TRUE, FALSE)) AS liked,

            (IF((
                SELECT TRUE FROM phone_instagram_follows f
                WHERE f.follower=@loggedInAs AND f.followed=a.username
            ), TRUE, FALSE)) AS following

        FROM phone_instagram_comments c

        INNER JOIN phone_instagram_accounts a
            ON c.username = a.username

        WHERE c.post_id=@postId

        ORDER BY following DESC, c.like_count DESC, c.`timestamp` DESC

        LIMIT @page, @perPage
    ]], {
        ["@page"] = (page or 0) * 20,
        ["@perPage"] = 20,
        ["@postId"] = postId,
        ["@loggedInAs"] = username
    }, cb)
end)

RegisterLegacyCallback("instagram:postComment", function(source, cb, postId, comment)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    if ContainsBlacklistedWord(source, "InstaPic", comment) then
        return cb(false)
    end

    local commentId = GenerateId("phone_instagram_comments", "id")

    MySQL.Async.execute(
        "INSERT INTO phone_instagram_comments (id, post_id, username, comment) VALUES (@id, @postId, @username, @comment)",
        {
            ["@id"] = commentId,
            ["@postId"] = postId,
            ["@username"] = username,
            ["@comment"] = comment
        },
        function()
            MySQL.Async.fetchScalar(
                "SELECT username FROM phone_instagram_posts WHERE id=@id",
                { ["@id"] = postId },
                function(postOwner)
                    SendInstagramNotification(postOwner, username, "comment", commentId)
                end
            )

            TriggerClientEvent("phone:instagram:updatePostData", -1, postId, "comment_count", true)
            cb(commentId)
        end
    )
end, {
    preventSpam = true,
    rateLimit = 10
})

RegisterLegacyCallback("instagram:updateProfile", function(source, cb, data)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local updates = {}
    local params = {
        ["@displayName"] = data.name,
        ["@bio"] = data.bio,
        ["@avatar"] = data.avatar,
        ["@private"] = data.private,
        ["@username"] = username
    }

    if data.name then
        updates[#updates + 1] = "display_name=@displayName"
    end

    if data.bio then
        updates[#updates + 1] = "bio=@bio"
    end

    if data.avatar then
        updates[#updates + 1] = "profile_image=@avatar"
    end

    if type(data.private) == "boolean" then
        updates[#updates + 1] = "private=@private"
    end

    if #updates == 0 then
        return cb(true)
    end

    MySQL.Async.execute(
        "UPDATE phone_instagram_accounts SET " .. table.concat(updates, ",") .. " WHERE username=@username",
        params,
        function()
            cb(true)
        end
    )
end)

RegisterLegacyCallback("instagram:toggleFollow", function(source, cb, targetUsername, follow)
    local username = GetLoggedInInstagramUsername(source)

    if not username or targetUsername == username then
        return cb(not follow)
    end

    local params = {
        ["@username"] = targetUsername,
        ["@loggedInAs"] = username
    }

    local function finishFollow(affectedRows)
        if affectedRows == 0 then
            return cb(follow)
        end

        TriggerClientEvent("phone:instagram:updateProfileData", -1, targetUsername, "followers", follow)
        TriggerClientEvent("phone:instagram:updateProfileData", -1, username, "following", follow)

        cb(follow)

        if follow then
            SendInstagramNotification(targetUsername, username, "follow")
        end
    end

    local isPrivate = MySQL.Sync.fetchScalar(
        "SELECT private FROM phone_instagram_accounts WHERE username=@username",
        params
    )

    if isPrivate then
        if follow then
            MySQL.Async.execute(
                "INSERT IGNORE INTO phone_instagram_follow_requests (requester, requestee) VALUES (@loggedInAs, @username)",
                params,
                function()
                    cb(follow)
                end
            )

            local displayName = MySQL.Sync.fetchScalar(
                "SELECT display_name FROM phone_instagram_accounts WHERE username=@loggedInAs",
                params
            )

            NotifyLoggedInAccounts("Instagram", targetUsername, {
                title = L("BACKEND.INSTAGRAM.NEW_FOLLOW_REQUEST_TITLE"),
                content = L("BACKEND.INSTAGRAM.NEW_FOLLOW_REQUEST_DESCRIPTION", {
                    displayName = displayName,
                    username = username
                })
            })
            return
        end

        MySQL.Async.execute(
            "DELETE FROM phone_instagram_follow_requests WHERE requester=@loggedInAs AND requestee=@username",
            params
        )
    end

    local query = follow
        and "INSERT IGNORE INTO phone_instagram_follows (followed, follower) VALUES (@username, @loggedInAs)"
        or "DELETE FROM phone_instagram_follows WHERE followed=@username AND follower=@loggedInAs"

    MySQL.Async.execute(query, params, finishFollow)
end, {
    preventSpam = true
})

RegisterLegacyCallback("instagram:toggleLike", function(source, cb, targetId, enabled, isComment)
    if not targetId then
        return cb(false)
    end

    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    local query = enabled
        and "INSERT IGNORE INTO phone_instagram_likes (id, username, is_comment) VALUES (@postId, @loggedInAs, @isComment)"
        or "DELETE FROM phone_instagram_likes WHERE id=@postId AND username=@loggedInAs AND is_comment=@isComment"

    MySQL.Async.execute(query, {
        ["@postId"] = targetId,
        ["@loggedInAs"] = username,
        ["@isComment"] = isComment
    }, function(affectedRows)
        if affectedRows == 0 then
            return cb(enabled)
        end

        cb(enabled)

        if isComment then
            TriggerClientEvent("phone:instagram:updateCommentLikes", -1, targetId, enabled)
        else
            TriggerClientEvent("phone:instagram:updatePostData", -1, targetId, "like_count", enabled)
        end

        if enabled then
            local tableName = isComment and "phone_instagram_comments" or "phone_instagram_posts"
            local owner = MySQL.Sync.fetchScalar(
                "SELECT username FROM " .. tableName .. " WHERE id=@postId",
                { ["@postId"] = targetId }
            )

            if owner then
                SendInstagramNotification(owner, username, isComment and "like_comment" or "like_photo", targetId)
            end
        end
    end)
end, {
    preventSpam = true
})

RegisterLegacyCallback("instagram:getData", function(source, cb, dataType, data)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    local tableName
    local joinColumn
    local where
    local orderBy

    if dataType == "likes" then
        tableName = "phone_instagram_likes"
        joinColumn = "username"
        where = "id=@postId AND is_comment=@isComment"
        orderBy = "a.username"
    elseif dataType == "followers" then
        tableName = "phone_instagram_follows"
        joinColumn = "follower"
        where = "q.followed=@username"
        orderBy = "q.follower"
    elseif dataType == "following" then
        tableName = "phone_instagram_follows"
        joinColumn = "followed"
        where = "q.follower=@username"
        orderBy = "q.followed"
    else
        return cb({})
    end

    MySQL.Async.fetchAll(([[
        SELECT
            a.username, a.display_name AS name, a.profile_image AS avatar, a.verified,

            (IF((
                SELECT TRUE FROM phone_instagram_follows f
                WHERE f.followed=a.username AND f.follower=@loggedInAs
            ), TRUE, FALSE)) AS isFollowing

        FROM phone_instagram_accounts a

        INNER JOIN %s q ON q.%s=a.username

        WHERE %s

        ORDER BY %s DESC

        LIMIT @page, @perPage
    ]]):format(tableName, joinColumn, where, orderBy), {
        ["@username"] = data.username,
        ["@postId"] = data.postId,
        ["@isComment"] = data.isComment == true,
        ["@loggedInAs"] = username,
        ["@page"] = (data.page or 0) * 20,
        ["@perPage"] = 20
    }, cb)
end)

RegisterLegacyCallback("instagram:getRecentMessages", function(source, cb, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            m.content, m.attachments, m.sender, f_m.username, m.`timestamp`,

            a.display_name AS `name`, a.profile_image AS avatar, a.verified

        FROM phone_instagram_messages m

        JOIN ((
            SELECT (
                CASE WHEN recipient!=@loggedInAs THEN recipient ELSE sender END
            ) AS username, MAX(`timestamp`) AS `timestamp`

            FROM phone_instagram_messages

            WHERE sender=@loggedInAs OR recipient=@loggedInAs

            GROUP BY username
        ) f_m)
        ON m.`timestamp`=f_m.`timestamp`

        INNER JOIN phone_instagram_accounts a
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

RegisterLegacyCallback("instagram:getMessages", function(source, cb, targetUsername, page)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb({})
    end

    MySQL.Async.fetchAll([[
        SELECT
            sender, recipient, content, attachments, `timestamp`

        FROM phone_instagram_messages

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

RegisterLegacyCallback("instagram:sendMessage", function(source, cb, recipient, message)
    local username = GetLoggedInInstagramUsername(source)

    if not username then
        return cb(false)
    end

    if ContainsBlacklistedWord(source, "InstaPic", message.content) then
        return cb(false)
    end

    local messageId = GenerateId("phone_instagram_messages", "id")

    MySQL.Async.execute(
        "INSERT INTO phone_instagram_messages (id, sender, recipient, content, attachments) VALUES (@id, @sender, @recipient, @content, @attachments)",
        {
            ["@id"] = messageId,
            ["@sender"] = username,
            ["@recipient"] = recipient,
            ["@content"] = message.content,
            ["@attachments"] = message.attachments and json.encode(message.attachments) or nil
        },
        function(affectedRows)
            if affectedRows == 0 then
                return cb(false)
            end

            cb(true)

            local loggedInNumbers = MySQL.query.await(
                "SELECT phone_number FROM phone_logged_in_accounts WHERE username = ? AND app = 'Instagram' AND `active` = 1",
                { recipient }
            )

            if not loggedInNumbers or #loggedInNumbers == 0 then
                return
            end

            MySQL.single(
                "SELECT display_name, username, profile_image FROM phone_instagram_accounts WHERE username = ?",
                { username },
                function(senderAccount)
                    if not senderAccount then
                        return
                    end

                    for i = 1, #loggedInNumbers do
                        local phoneNumber = loggedInNumbers[i].phone_number
                        local targetSource = GetSourceFromNumber(phoneNumber)

                        if targetSource then
                            TriggerClientEvent("phone:instagram:newMessage", targetSource, {
                                sender = username,
                                recipient = recipient,
                                content = message.content,
                                attachments = message.attachments,
                                timestamp = os.time() * 1000
                            })
                        end

                        local content = message.content

                        if string.find(content, "<!REPLIED_STORY-DATA=", nil, true) then
                            content = L("APPS.INSTAGRAM.REPLIED_TO_YOUR_STORY")
                        end

                        SendNotification(phoneNumber, {
                            app = "Instagram",
                            title = senderAccount.display_name,
                            content = content,
                            thumbnail = message.attachments and message.attachments[1],
                            avatar = senderAccount.profile_image,
                            showAvatar = true
                        })
                    end
                end
            )
        end
    )
end, {
    preventSpam = true,
    rateLimit = 15
})
