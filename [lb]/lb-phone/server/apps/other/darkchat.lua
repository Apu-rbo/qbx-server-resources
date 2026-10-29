if Config.AutoJoinDarkChat and #Config.AutoJoinDarkChat > 0 then
    MySQL.ready(function()
        while not DatabaseCheckerFinished do
            Wait(500)
        end

        local channels = {}

        for i = 1, #Config.AutoJoinDarkChat do
            channels[#channels + 1] = { Config.AutoJoinDarkChat[i] }
        end

        MySQL.rawExecute("INSERT IGNORE INTO phone_darkchat_channels (`name`) VALUES (?)", channels)
    end)
end

BaseCallback("darkchat:getUsername", function(source, phoneNumber)
    local username = GetLoggedInAccount(phoneNumber, "DarkChat")

    if not username then
        username = MySQL.scalar.await(
            "SELECT username FROM phone_darkchat_accounts WHERE phone_number = ? AND `password` IS NULL",
            { phoneNumber }
        )

        if not username then
            return false
        end

        AddLoggedInAccount(phoneNumber, "DarkChat", username)
    end

    local hasPassword = MySQL.scalar.await(
        "SELECT TRUE FROM phone_darkchat_accounts WHERE username = ? AND `password` IS NOT NULL",
        { username }
    )

    return {
        username = username,
        password = hasPassword and true or false
    }
end, nil, {
    defaultReturn = {
        success = false,
        reason = "unknown"
    },
    preventSpam = true
})

BaseCallback("darkchat:setPassword", function(source, phoneNumber, password)
    if #password < 3 then
        debugprint("DarkChat: password < 3 characters")
        return false
    end

    local username = GetLoggedInAccount(phoneNumber, "DarkChat")

    if not username then
        return false
    end

    local alreadyHasPassword = MySQL.scalar.await(
        "SELECT TRUE FROM phone_darkchat_accounts WHERE username = ? AND `password` IS NOT NULL",
        { username }
    )

    if alreadyHasPassword then
        return false
    end

    MySQL.update.await(
        "UPDATE phone_darkchat_accounts SET `password` = ? WHERE username = ?",
        { GetPasswordHash(password), username }
    )

    return true
end, nil, {
    defaultReturn = false,
    preventSpam = true
})

BaseCallback("darkchat:login", function(source, phoneNumber, username, password)
    local passwordHash = MySQL.scalar.await(
        "SELECT `password` FROM phone_darkchat_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash then
        return {
            success = false,
            reason = "invalid_username"
        }
    end

    if not VerifyPasswordHash(password, passwordHash) then
        return {
            success = false,
            reason = "incorrect_password"
        }
    end

    AddLoggedInAccount(phoneNumber, "DarkChat", username)

    return {
        success = true
    }
end, nil, {
    defaultReturn = {
        success = false,
        reason = "unknown"
    },
    preventSpam = true
})

BaseCallback("darkchat:register", function(source, phoneNumber, username, password)
    username = username:lower()

    if not IsUsernameValid(username) then
        return {
            success = false,
            reason = "USERNAME_NOT_ALLOWED"
        }
    end

    local usernameExists = MySQL.scalar.await(
        "SELECT 1 FROM phone_darkchat_accounts WHERE username = ?",
        { username }
    )

    if usernameExists then
        return {
            success = false,
            reason = "username_taken"
        }
    end

    local created = MySQL.update.await(
        "INSERT INTO phone_darkchat_accounts (phone_number, username, `password`) VALUES (?, ?, ?)",
        { phoneNumber, username, GetPasswordHash(password) }
    ) > 0

    if not created then
        return {
            success = false,
            reason = "unknown"
        }
    end

    AddLoggedInAccount(phoneNumber, "DarkChat", username)

    if Config.AutoJoinDarkChat and #Config.AutoJoinDarkChat > 0 then
        local memberRows = {}

        for i = 1, #Config.AutoJoinDarkChat do
            memberRows[#memberRows + 1] = {
                Config.AutoJoinDarkChat[i],
                username
            }
        end

        MySQL.prepare.await(
            "INSERT INTO phone_darkchat_members (channel_name, username) VALUES (?, ?)",
            memberRows
        )
    end

    return {
        success = true
    }
end, nil, {
    defaultReturn = {
        success = false,
        reason = "unknown"
    },
    preventSpam = true
})

local function RegisterDarkChatCallback(name, handler, defaultReturn)
    BaseCallback("darkchat:" .. name, function(source, phoneNumber, ...)
        local username = GetLoggedInAccount(phoneNumber, "DarkChat")

        if not username then
            return defaultReturn
        end

        return handler(source, phoneNumber, username, ...)
    end, nil, {
        defaultReturn = defaultReturn,
        preventSpam = true
    })
end

RegisterDarkChatCallback("changePassword", function(source, phoneNumber, username, oldPassword, newPassword)
    if not Config.ChangePassword.DarkChat then
        infoprint("warning", ("%s tried to change password on DarkChat, but it's not enabled in the config."):format(source))
        return false
    end

    if oldPassword == newPassword or #newPassword < 3 then
        debugprint("same password / too short")
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT `password` FROM phone_darkchat_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(oldPassword, passwordHash) then
        return false
    end

    local changed = MySQL.update.await(
        "UPDATE phone_darkchat_accounts SET `password` = ? WHERE username = ?",
        { GetPasswordHash(newPassword), username }
    ) > 0

    if not changed then
        return false
    end

    NotifyLoggedInAccounts("DarkChat", username, {
        title = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.TITLE"),
        content = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.DESCRIPTION")
    }, { phoneNumber })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'DarkChat' AND phone_number != ?",
        { username, phoneNumber }
    )

    ClearActiveAccountsCache("DarkChat", username, phoneNumber)

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "darkchat",
        reason = "password",
        number = phoneNumber
    })

    return true
end)

RegisterDarkChatCallback("deleteAccount", function(source, phoneNumber, username, password)
    if not Config.DeleteAccount.DarkChat then
        infoprint("warning", ("%s tried to delete their account on DarkChat, but it's not enabled in the config."):format(source))
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT `password` FROM phone_darkchat_accounts WHERE username = ?",
        { username }
    )

    if not passwordHash or not VerifyPasswordHash(password, passwordHash) then
        return false
    end

    NotifyLoggedInAccounts("DarkChat", username, {
        title = L("BACKEND.MISC.DELETED_NOTIFICATION.TITLE"),
        content = L("BACKEND.MISC.DELETED_NOTIFICATION.DESCRIPTION")
    })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'DarkChat'",
        { username }
    )

    ClearActiveAccountsCache("DarkChat", username)

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = username,
        app = "darkchat",
        reason = "deleted"
    })

    return true
end)

RegisterDarkChatCallback("logout", function(source, phoneNumber, username)
    RemoveLoggedInAccount(phoneNumber, "DarkChat", username)

    return true
end)

local function CreateDarkChatChannel(channel, password)
    assert(type(channel) == "string", "channel must be a string")

    if #channel < 1 or #channel > 50 or channel:find("%s") then
        debugprint("darkchat: invalid channel name")
        return false, "invalid_name"
    end

    local channelExists = MySQL.scalar.await(
        "SELECT TRUE FROM phone_darkchat_channels WHERE `name` = ?",
        { channel }
    )

    if channelExists then
        debugprint("darkchat:createChannel: channel already exists", channel)
        return false, "channel_exists"
    end

    local passwordHash = password and GetPasswordHash(password) or nil
    local created = MySQL.update.await(
        "INSERT INTO phone_darkchat_channels (`name`, `password`) VALUES (@name, @password)",
        {
            ["@name"] = channel,
            ["@password"] = passwordHash
        }
    ) > 0

    if not created then
        debugprint("darkchat:createChannel: failed to create channel", channel)
        return false, "unknown_error"
    end

    return true
end

local function GetChannelPreview(channel)
    local members = MySQL.scalar.await(
        "SELECT COUNT(username) FROM phone_darkchat_members WHERE channel_name = ?",
        { channel }
    )
    local lastMessage = MySQL.single.await([[
        SELECT sender, content, `timestamp`
        FROM phone_darkchat_messages
        WHERE `channel` = ?
        ORDER BY `id` DESC
        LIMIT 1
    ]], { channel })
    local channelData = {
        name = channel,
        members = members or 1
    }

    if lastMessage then
        channelData.sender = lastMessage.sender
        channelData.lastMessage = lastMessage.content
        channelData.timestamp = lastMessage.timestamp
    end

    return channelData
end

RegisterDarkChatCallback("createChannel", function(source, phoneNumber, username, channel, password)
    if not ValidateChecks("createDarkChatChannel", source, username, channel) then
        debugprint("darkchat:createChannel: createDarkChatChannel check returned false")
        return false
    end

    local created, reason = CreateDarkChatChannel(channel, password)

    if not created then
        return reason
    end

    Log(
        "DarkChat",
        source,
        "info",
        L("BACKEND.LOGS.DARKCHAT_CREATED_TITLE"),
        L("BACKEND.LOGS.DARKCHAT_CREATED_DESCRIPTION", {
            creator = username,
            channel = channel
        })
    )

    local joined = MySQL.update.await(
        "INSERT INTO phone_darkchat_members (channel_name, username) VALUES (?, ?)",
        { channel, username }
    ) > 0

    if not joined then
        debugprint("darkchat:createChannel: failed to insert into members")
        return "unknown_error"
    end

    return {
        name = channel,
        members = 1
    }
end)

RegisterDarkChatCallback("joinChannel", function(source, phoneNumber, username, channel, password)
    local alreadyMember = MySQL.scalar.await(
        "SELECT TRUE FROM phone_darkchat_members WHERE channel_name = ? AND username = ?",
        { channel, username }
    )

    if alreadyMember then
        debugprint("darkchat: already in channel")
        return "already_in_channel"
    end

    local channelData = MySQL.single.await(
        "SELECT `name`, `password` FROM phone_darkchat_channels WHERE `name` = ?",
        { channel }
    )

    if not channelData then
        return "invalid_channel"
    end

    if not ValidateChecks("joinDarkChatChannel", source, username, channel) then
        debugprint("darkchat:joinChannel: joinDarkChatChannel check returned false")
        return "check_failed"
    end

    if channelData.password then
        if not password then
            debugprint("darkchat:joinChannel: password required")
            return "password_required"
        end

        if not VerifyPasswordHash(password, channelData.password) then
            debugprint("darkchat:joinChannel: incorrect password")
            return "incorrect_password"
        end
    end

    MySQL.update.await(
        "INSERT INTO phone_darkchat_members (channel_name, username) VALUES (?, ?)",
        { channel, username }
    )

    local preview = GetChannelPreview(channel)

    TriggerClientEvent("phone:darkChat:updateChannel", -1, channel, username, "joined")

    return preview
end)

RegisterDarkChatCallback("leaveChannel", function(source, phoneNumber, username, channel)
    local deleted = MySQL.update.await(
        "DELETE FROM phone_darkchat_members WHERE channel_name = ? AND username = ?",
        { channel, username }
    )

    if not deleted then
        return false
    end

    TriggerClientEvent("phone:darkChat:updateChannel", -1, channel, username, "left")

    return true
end)

RegisterDarkChatCallback("getChannels", function(source, phoneNumber, username)
    return MySQL.query.await([[
        SELECT
            c.name,
            (SELECT COUNT(username) FROM phone_darkchat_members WHERE channel_name = c.name) AS members,
            m.sender,
            m.content AS lastMessage,
            m.timestamp

        FROM phone_darkchat_channels c

        LEFT JOIN phone_darkchat_messages m ON m.channel = c.name
            AND m.id = (SELECT MAX(id) FROM phone_darkchat_messages WHERE channel = c.name)

        WHERE EXISTS (SELECT 1 FROM phone_darkchat_members WHERE channel_name = c.name AND username = ?)
    ]], { username })
end, {})

RegisterDarkChatCallback("getMessages", function(source, phoneNumber, username, channel, lastId)
    local query = [[
        SELECT
            id,
            sender,
            content,
            `timestamp`

        FROM phone_darkchat_messages

        WHERE `channel` = @channel
            {PAGINATION}

        ORDER BY `id` DESC

        LIMIT 15
    ]]

    if lastId then
        query = query:gsub("{PAGINATION}", "AND id < @lastId")
    else
        query = query:gsub("{PAGINATION}", "")
    end

    return MySQL.query.await(query, {
        channel = channel,
        lastId = lastId
    })
end)

local function SendDarkChatMessage(username, channel, message)
    local messageId = MySQL.insert.await(
        "INSERT INTO phone_darkchat_messages (sender, `channel`, content) VALUES (?, ?, ?)",
        { username, channel, message }
    )

    if not messageId then
        return false
    end

    NotifyPhonesWithQuery([[
        phone_darkchat_members m
        JOIN phone_logged_in_accounts l
            ON l.app = 'DarkChat'
            AND l.`active` = 1
            AND l.username = m.username
        WHERE
            m.channel_name = @channel
            AND m.username != @username
    ]], {
        app = "DarkChat",
        title = channel,
        content = username .. ": " .. message
    }, "l.", {
        ["@channel"] = channel,
        ["@username"] = username
    })

    TriggerEvent("lb-phone:darkchat:newMessage", channel, username, message)
    TriggerClientEvent("phone:darkChat:newMessage", -1, channel, username, message)

    return true
end

RegisterDarkChatCallback("sendMessage", function(source, phoneNumber, username, channel, message)
    if ContainsBlacklistedWord(source, "DarkChat", message) then
        return false
    end

    if not ValidateChecks("sendDarkchatMessage", source, username, channel, message) then
        debugprint("darkchat:sendMessage: sendDarkchatMessage check returned false")
        return false
    end

    if not SendDarkChatMessage(username, channel, message) then
        return false
    end

    Log(
        "DarkChat",
        source,
        "info",
        L("BACKEND.LOGS.DARKCHAT_MESSAGE_TITLE"),
        L("BACKEND.LOGS.DARKCHAT_MESSAGE_DESCRIPTION", {
            sender = username,
            channel = channel,
            message = message
        })
    )

    return true
end)

exports("SendDarkChatMessage", function(username, channel, message, callback)
    assert(type(username) == "string", "username must be a string")
    assert(type(channel) == "string", "channel must be a string")
    assert(type(message) == "string", "message must be a string")

    local sent = SendDarkChatMessage(username, channel, message)

    if callback then
        callback(sent)
    end

    return sent
end)

exports("SendDarkChatLocation", function(username, channel, coords, callback)
    assert(type(username) == "string", "Expected string for argument 1, got " .. type(username))
    assert(type(channel) == "string", "Expected string for argument 2, got " .. type(channel))
    assert(type(coords) == "vector2", "Expected vector2 for argument 3, got " .. type(coords))

    local sent = SendDarkChatMessage(username, channel, "<!SENT-LOCATION-X=" .. coords.x .. "Y=" .. coords.y .. "!>")

    if callback then
        callback(sent)
    end

    return sent
end)

exports("AddUserToDarkChatChannel", function(username, channel)
    assert(type(username) == "string", "username must be a string")
    assert(type(channel) == "string", "channel must be a string")

    local alreadyMember = MySQL.scalar.await(
        "SELECT TRUE FROM phone_darkchat_members WHERE channel_name = ? AND username = ?",
        { channel, username }
    )

    if alreadyMember then
        debugprint("AddUserToDarkChatChannel: already in channel")
        return true
    end

    local channelExists = MySQL.scalar.await(
        "SELECT TRUE FROM phone_darkchat_channels WHERE `name` = ?",
        { channel }
    )

    if not channelExists then
        debugprint("AddUserToDarkChatChannel: channel does not exist", channel)
        return false
    end

    local added = MySQL.update.await(
        "INSERT INTO phone_darkchat_members (channel_name, username) VALUES (?, ?)",
        { channel, username }
    ) > 0

    if not added then
        debugprint("AddUserToDarkChatChannel: failed to insert into members")
        return false
    end

    local channelData = GetChannelPreview(channel)

    TriggerClientEvent("phone:darkChat:updateChannel", -1, channel, username, "joined")

    local phoneNumbers = GetLoggedInNumbers("DarkChat", username)

    for i = 1, #phoneNumbers do
        local source = GetSourceFromNumber(phoneNumbers[i])

        if source then
            TriggerClientEvent("phone:darkChat:joinChannel", source, channelData)
        end
    end

    return true
end)

exports("RemoveUserFromDarkChatChannel", function(username, channel)
    assert(type(username) == "string", "username must be a string")
    assert(type(channel) == "string", "channel must be a string")

    local deleted = MySQL.update.await(
        "DELETE FROM phone_darkchat_members WHERE channel_name = ? AND username = ?",
        { channel, username }
    )

    if not deleted then
        return false
    end

    TriggerClientEvent("phone:darkChat:updateChannel", -1, channel, username, "left")

    local phoneNumbers = GetLoggedInNumbers("DarkChat", username)

    for i = 1, #phoneNumbers do
        local source = GetSourceFromNumber(phoneNumbers[i])

        if source then
            TriggerClientEvent("phone:darkChat:leaveChannel", source, channel)
        end
    end

    debugprint("Removed " .. username .. " from DarkChat channel " .. channel)

    return true
end)

exports("CreateDarkChatChannel", CreateDarkChatChannel)

exports("DeleteDarkChatChannel", function(channel, callback)
    assert(type(channel) == "string", "channel must be a string")

    local deleted = MySQL.update.await(
        "DELETE FROM phone_darkchat_channels WHERE `name` = ?",
        { channel }
    ) > 0

    if not deleted then
        return false
    end

    TriggerClientEvent("phone:darkChat:leaveChannel", -1, channel)
end)
