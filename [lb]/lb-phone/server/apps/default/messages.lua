local function GetDirectChannel(firstNumber, secondNumber)
    return MySQL.scalar.await([[
        SELECT c.id FROM phone_message_channels c
        WHERE c.is_group = 0
            AND EXISTS (SELECT TRUE FROM phone_message_members m WHERE m.channel_id = c.id AND m.phone_number = ?)
            AND EXISTS (SELECT TRUE FROM phone_message_members m WHERE m.channel_id = c.id AND m.phone_number = ?)
    ]], { firstNumber, secondNumber })
end

local function GetFirstAttachment(attachments)
    if not attachments then
        return nil
    end

    if type(attachments) == "table" then
        return attachments[1]
    end

    if type(attachments) == "string" then
        local decoded = json.decode(attachments)

        return decoded and decoded[1]
    end

    return nil
end

local function HasContent(content, attachments)
    if content and #content > 0 then
        return true
    end

    return attachments and #attachments > 0
end

local function IsBlocked(sender, recipient)
    if not recipient then
        return false
    end

    return MySQL.scalar.await([[
        SELECT 1 FROM phone_phone_blocked_numbers
        WHERE (phone_number = ? AND blocked_number = ?)
            OR (phone_number = ? AND blocked_number = ?)
    ]], { sender, recipient, recipient, sender }) ~= nil
end

local function CreateDirectChannel(sender, recipient, content)
    local channelId = MySQL.insert.await("INSERT INTO phone_message_channels (is_group) VALUES (0)")

    MySQL.update.await(
        "INSERT INTO phone_message_members (channel_id, phone_number) VALUES (?, ?), (?, ?)",
        { channelId, sender, channelId, recipient }
    )

    local senderSource = GetSourceFromNumber(sender)
    local recipientSource = GetSourceFromNumber(recipient)
    local timestamp = os.time() * 1000

    if senderSource then
        TriggerClientEvent("phone:messages:newChannel", senderSource, {
            id = channelId,
            lastMessage = content,
            timestamp = timestamp,
            number = recipient,
            isGroup = false,
            unread = false
        })
    end

    if recipientSource then
        TriggerClientEvent("phone:messages:newChannel", recipientSource, {
            id = channelId,
            lastMessage = content,
            timestamp = timestamp,
            number = sender,
            isGroup = false,
            unread = true
        })
    end

    return channelId
end

local function LogMessage(senderSource, sender, recipient, content)
    if not senderSource or not recipient then
        return
    end

    Log(
        "Messages",
        senderSource,
        "info",
        L("BACKEND.LOGS.MESSAGE_TITLE"),
        L("BACKEND.LOGS.NEW_MESSAGE", {
            sender = FormatNumber(sender),
            recipient = FormatNumber(recipient),
            message = content or "Attachment"
        })
    )
end

function SendMessage(sender, recipient, content, attachments, callback, channelId, replyTo)
    if not sender or (not channelId and not recipient) then
        return
    end

    if not HasContent(content, attachments) then
        debugprint("No message or attachments provided")
        return
    end

    if content and #content == 0 then
        content = nil

        if not HasContent(content, attachments) then
            debugprint("No attachments provided")
            return
        end
    end

    if IsBlocked(sender, recipient) then
        debugprint("Message blocked between " .. sender .. " and " .. recipient)
        return
    end

    if not channelId then
        channelId = GetDirectChannel(sender, recipient)
    end

    local senderSource = GetSourceFromNumber(sender)

    if not channelId then
        channelId = CreateDirectChannel(sender, recipient, content)
    end

    LogMessage(senderSource, sender, recipient, content)

    if type(attachments) == "table" then
        attachments = json.encode(attachments)
    end

    local replyData

    if replyTo then
        replyData = MySQL.single.await(
            "SELECT id, content, sender, attachments FROM phone_message_messages WHERE id = ? AND channel_id = ?",
            { replyTo, channelId }
        )

        if not replyData then
            debugprint("Reply message with id", replyTo, "not found in channel", channelId)
            replyTo = nil
        end
    end

    local messageId = MySQL.insert.await(
        "INSERT INTO phone_message_messages (channel_id, sender, content, attachments, reply_to) VALUES (@channelId, @sender, @content, @attachments, @reply_to)",
        {
            channelId = channelId,
            sender = sender,
            content = content,
            attachments = attachments,
            reply_to = replyTo
        }
    )

    if not messageId then
        if callback then
            callback(false)
        end

        return
    end

    MySQL.update(
        "UPDATE phone_message_channels SET last_message = ? WHERE id = ?",
        { string.sub(content or "Attachment", 1, 50), channelId }
    )

    MySQL.update(
        "UPDATE phone_message_members SET unread = unread + 1 WHERE channel_id = ? AND phone_number != ?",
        { channelId, sender }
    )

    MySQL.update(
        "UPDATE phone_message_members SET deleted = 0 WHERE channel_id = ?",
        { channelId }
    )

    local recipients = MySQL.query.await(
        "SELECT phone_number FROM phone_message_members WHERE channel_id = ? AND phone_number != ?",
        { channelId, sender }
    )
    local attachmentThumbnail = GetFirstAttachment(attachments)
    local packedMessage = msgpack.pack_args(channelId, messageId, sender, content, attachments, replyData)
    local packedLength = #packedMessage

    for i = 1, #recipients do
        local phoneNumber = recipients[i].phone_number
        local source = GetSourceFromNumber(phoneNumber)

        if source then
            TriggerClientEventInternal("phone:messages:newMessage", source, packedMessage, packedLength)
        end

        if content ~= "<!CALL-NO-ANSWER!>" then
            local contact = GetContact(phoneNumber, sender)

            SendNotification(phoneNumber, {
                app = "Messages",
                title = (contact and contact.name) or sender,
                content = content,
                thumbnail = attachmentThumbnail,
                avatar = contact and contact.avatar,
                showAvatar = true
            })
        end
    end

    if callback then
        callback(channelId)
    end

    TriggerEvent("lb-phone:messages:messageSent", {
        channelId = channelId,
        messageId = messageId,
        sender = sender,
        recipient = recipient,
        message = content,
        attachments = attachments
    })

    return {
        channelId = channelId,
        messageId = messageId
    }
end

exports("SentMoney", function(sender, recipient, amount)
    assert(type(sender) == "string", "Expected string for argument 1, got " .. type(sender))
    assert(type(recipient) == "string", "Expected string for argument 2, got " .. type(recipient))
    assert(type(amount) == "number", "Expected number for argument 3, got " .. type(amount))

    SendMessage(sender, recipient, "<!SENT-PAYMENT-" .. math.floor(amount + 0.5) .. "!>")
end)

exports("SendCoords", function(sender, recipient, coords)
    assert(type(sender) == "string", "Expected string for argument 1, got " .. type(sender))
    assert(type(recipient) == "string", "Expected string for argument 2, got " .. type(recipient))

    local coordsType = type(coords)

    assert(coordsType == "vector2" or coordsType == "vector3" or coordsType == "vector4", "Expected vector or table with x & y for argument 3, got " .. coordsType)

    SendMessage(sender, recipient, "<!SENT-LOCATION-X=" .. coords.x .. "Y=" .. coords.y .. "!>")
end)

exports("SendMessage", function(sender, recipient, content, attachments, callback, channelId)
    assert(type(sender) == "string", "Expected string for argument 1, got " .. type(sender))
    assert(recipient == nil or type(recipient) == "string", "Expected string or nil for argument 2, got " .. type(recipient))
    assert(content == nil or type(content) == "string", "Expected string or nil for argument 3, got " .. type(content))
    assert(attachments == nil or type(attachments) == "table" or type(attachments) == "string", "Expected table, string or nil for argument 4, got " .. type(attachments))
    assert(callback == nil or type(callback) == "function", "Expected function or nil for argument 5, got " .. type(callback))

    return SendMessage(sender, recipient, content, attachments, callback, channelId)
end)

BaseCallback("messages:sendMessage", function(source, phoneNumber, recipient, content, attachments, replyTo, channelId)
    if ContainsBlacklistedWord(source, "Messages", content) then
        return false
    end

    return SendMessage(phoneNumber, recipient, content, attachments, nil, channelId, replyTo)
end)

BaseCallback("messages:createGroup", function(source, phoneNumber, members, content, attachments)
    local channelId = MySQL.insert.await("INSERT INTO phone_message_channels (is_group) VALUES (1)")

    if not channelId then
        return false
    end

    local memberRows = {
        {
            number = phoneNumber,
            isOwner = true
        }
    }

    MySQL.update.await(
        "INSERT INTO phone_message_members (channel_id, phone_number, is_owner) VALUES (?, ?, 1)",
        { channelId, phoneNumber }
    )

    for i = 1, #members do
        local memberNumber = members[i]

        MySQL.update.await(
            "INSERT INTO phone_message_members (channel_id, phone_number, is_owner) VALUES (?, ?, 0)",
            { channelId, memberNumber }
        )

        memberRows[i + 1] = {
            number = memberNumber,
            isOwner = false
        }
    end

    local channelData = {
        id = channelId,
        lastMessage = content,
        timestamp = os.time() * 1000,
        name = nil,
        isGroup = true,
        members = memberRows,
        unread = false
    }

    for i = 1, #members do
        local memberSource = GetSourceFromNumber(members[i])

        if memberSource then
            TriggerClientEvent("phone:messages:newChannel", memberSource, channelData)
        end
    end

    TriggerClientEvent("phone:messages:newChannel", source, channelData)

    return SendMessage(phoneNumber, nil, content, attachments, nil, channelId)
end)

BaseCallback("messages:renameGroup", function(source, phoneNumber, channelId, name)
    local renamed = MySQL.update.await(
        "UPDATE phone_message_channels SET `name` = ? WHERE id = ? AND is_group = 1",
        { name, channelId }
    ) > 0

    if renamed then
        TriggerClientEvent("phone:messages:renameGroup", -1, channelId, name)
    end

    return renamed
end)

BaseCallback("messages:getRecentMessages", function(source, phoneNumber)
    return MySQL.query.await([[
        SELECT
            channel.id AS channel_id,
            channel.is_group,
            channel.`name`,
            channel.last_message,
            channel.last_message_timestamp,
            channel_member.phone_number,
            channel_member.is_owner,
            channel_member.unread,
            channel_member.deleted
        FROM
            phone_message_members target_member

        INNER JOIN phone_message_channels channel
            ON channel.id = target_member.channel_id

        INNER JOIN phone_message_members channel_member
            ON channel_member.channel_id = channel.id

        WHERE
            target_member.phone_number = ?

        ORDER BY
            channel.last_message_timestamp DESC
    ]], { phoneNumber })
end)

BaseCallback("messages:getMessages", function(source, phoneNumber, channelId, lastId)
    local query = [[
        SELECT
            m.id,
            m.sender,
            m.content,
            m.attachments,
            m.`timestamp`,
            m.reply_to,
            reply_message.content AS reply_message,
            reply_message.attachments IS NOT NULL AS reply_attachment,
            reply_message.sender AS reply_sender

        FROM phone_message_messages m

        LEFT JOIN phone_message_messages reply_message
            ON reply_message.id = m.reply_to
            AND m.reply_to IS NOT NULL

        WHERE
            m.channel_id = @channelId
            AND EXISTS (SELECT TRUE FROM phone_message_members mem WHERE m.channel_id = @channelId AND mem.phone_number = @phoneNumber)
            {PAGINATION}

        ORDER BY m.id DESC
        LIMIT 25
    ]]

    if lastId then
        query = query:gsub("{PAGINATION}", "AND m.id < @lastId")
    else
        query = query:gsub("{PAGINATION}", "")
    end

    local messages = MySQL.query.await(query, {
        channelId = channelId,
        phoneNumber = phoneNumber,
        lastId = lastId
    })

    if #messages == 0 then
        return messages
    end

    local messageIds = {}
    local messagesById = {}

    for i = 1, #messages do
        local message = messages[i]

        messageIds[i] = message.id
        messagesById[message.id] = message
        message.reactions = {}
    end

    local reactions = MySQL.query.await([[
        SELECT
            message_id,
            reaction,
            COUNT(*) AS reactions,
            CAST(SUM(phone_number = ?) AS INT) AS reacted
        FROM phone_message_reactions
        WHERE message_id IN (?)
        GROUP BY message_id, reaction
    ]], { phoneNumber, messageIds })

    for i = 1, #reactions do
        local reaction = reactions[i]
        local message = messagesById[reaction.message_id]

        if message then
            message.reactions[reaction.reaction] = {
                reactions = reaction.reactions,
                reacted = reaction.reacted > 0
            }
        end
    end

    return messages
end)

BaseCallback("messages:deleteMessage", function(source, phoneNumber, messageId, channelId)
    if not Config.DeleteMessages then
        return false
    end

    local isLastMessage = MySQL.scalar.await(
        "SELECT MAX(id) FROM phone_message_messages WHERE channel_id = ?",
        { channelId }
    ) == messageId

    local deleted = MySQL.update.await(
        "DELETE FROM phone_message_messages WHERE id = ? AND sender = ? AND channel_id = ?",
        { messageId, phoneNumber, channelId }
    ) > 0

    if deleted and isLastMessage then
        MySQL.update.await(
            "UPDATE phone_message_channels SET last_message = ? WHERE id = ?",
            { L("APPS.MESSAGES.MESSAGE_DELETED"), channelId }
        )
    end

    if deleted then
        TriggerClientEvent("phone:messages:messageDeleted", -1, channelId, messageId, isLastMessage)
    end

    return deleted
end)

BaseCallback("messages:addMember", function(source, phoneNumber, channelId, memberNumber)
    if type(Config.GroupMessageMemberLimit) == "number" then
        local memberCount = MySQL.scalar.await(
            "SELECT COUNT(1) FROM phone_message_members WHERE channel_id = ?",
            { channelId }
        ) or 0

        if memberCount >= Config.GroupMessageMemberLimit then
            SendNotification(phoneNumber, {
                app = "Messages",
                title = L("APPS.MESSAGES.GROUP_MEMBER_LIMIT_NOTIFICATION.TITLE"),
                content = L("APPS.MESSAGES.GROUP_MEMBER_LIMIT_NOTIFICATION.CONTENT", {
                    limit = Config.GroupMessageMemberLimit
                }),
                showAvatar = false
            })

            return false
        end
    end

    local added = MySQL.update.await(
        "INSERT IGNORE INTO phone_message_members (channel_id, phone_number) VALUES (?, ?)",
        { channelId, memberNumber }
    ) > 0

    if not added then
        return false
    end

    local memberSource = GetSourceFromNumber(memberNumber)

    TriggerClientEvent("phone:messages:memberAdded", -1, channelId, memberNumber)

    if not memberSource then
        return true
    end

    local members = MySQL.Sync.fetchAll(
        "SELECT phone_number AS `number`, is_owner AS isOwner FROM phone_message_members WHERE channel_id = ?",
        { channelId }
    )
    local channel = MySQL.single.await(
        "SELECT `name`, last_message, last_message_timestamp FROM phone_message_channels WHERE id = ?",
        { channelId }
    )

    if #members > 0 and channel then
        TriggerClientEvent("phone:messages:newChannel", memberSource, {
            id = channelId,
            lastMessage = channel.last_message,
            timestamp = channel.last_message_timestamp,
            name = channel.name,
            isGroup = true,
            members = members,
            unread = false
        })
    end

    return true
end)

BaseCallback("messages:removeMember", function(source, phoneNumber, channelId, memberNumber)
    local isOwner = MySQL.scalar.await(
        "SELECT is_owner FROM phone_message_members WHERE channel_id = ? AND phone_number = ?",
        { channelId, phoneNumber }
    )

    if not isOwner then
        return false
    end

    local removed = MySQL.update.await(
        "DELETE FROM phone_message_members WHERE channel_id = ? AND phone_number = ?",
        { channelId, memberNumber }
    ) > 0

    if removed then
        TriggerClientEvent("phone:messages:memberRemoved", -1, channelId, memberNumber)
    end

    return removed
end)

BaseCallback("messages:leaveGroup", function(source, phoneNumber, channelId)
    local isOwner = MySQL.scalar.await(
        "SELECT is_owner FROM phone_message_members WHERE channel_id = ? AND phone_number = ?",
        { channelId, phoneNumber }
    )

    if isOwner then
        MySQL.update.await([[
            UPDATE phone_message_members m
            SET is_owner = TRUE
            WHERE m.channel_id = ?
            AND m.phone_number != ?
            LIMIT 1
        ]], { channelId, phoneNumber })

        local newOwner = MySQL.scalar.await(
            "SELECT phone_number FROM phone_message_members WHERE channel_id = ? AND is_owner = TRUE",
            { channelId }
        )

        TriggerClientEvent("phone:messages:ownerChanged", -1, channelId, newOwner)
    end

    local removed = MySQL.update.await(
        "DELETE FROM phone_message_members WHERE channel_id = ? AND phone_number = ?",
        { channelId, phoneNumber }
    ) > 0

    local isEmpty = MySQL.scalar.await(
        "SELECT COUNT(1) FROM phone_message_members WHERE channel_id = ?",
        { channelId }
    ) == 0

    if removed then
        TriggerClientEvent("phone:messages:memberRemoved", -1, channelId, phoneNumber)
    end

    if isEmpty then
        MySQL.update.await(
            "DELETE FROM phone_message_channels WHERE id = ?",
            { channelId }
        )

        debugprint("Deleted group " .. channelId, "due to it being empty")
    end

    return removed
end)

BaseCallback("messages:markRead", function(source, phoneNumber, channelId)
    MySQL.update.await(
        "UPDATE phone_message_members SET unread = 0 WHERE channel_id = ? AND phone_number = ?",
        { channelId, phoneNumber }
    )

    return true
end)

BaseCallback("messages:deleteConversations", function(source, phoneNumber, channelIds)
    if type(channelIds) ~= "table" then
        debugprint("expected table, got " .. type(channelIds))
        return false
    end

    MySQL.update.await(
        "UPDATE phone_message_members SET deleted = 1 WHERE channel_id IN (?) AND phone_number = ?",
        { channelIds, phoneNumber }
    )

    return true
end)

BaseCallback("messages:toggleReaction", function(source, phoneNumber, messageId, reaction, toggle)
    local message = MySQL.single.await(
        "SELECT channel_id, sender FROM phone_message_messages WHERE id = ?",
        { messageId }
    )

    if not message or not message.channel_id or not message.sender then
        return false
    end

    if toggle then
        MySQL.update.await(
            "INSERT INTO phone_message_reactions (message_id, reaction, phone_number) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE reaction = VALUES(reaction)",
            { messageId, reaction, phoneNumber }
        )
    else
        MySQL.update.await(
            "DELETE FROM phone_message_reactions WHERE message_id = ? AND phone_number = ?",
            { messageId, phoneNumber }
        )
    end

    local recipients = MySQL.query.await(
        "SELECT phone_number FROM phone_message_members WHERE channel_id = ? AND phone_number != ?",
        { message.channel_id, phoneNumber }
    )
    local packedReaction = msgpack.pack_args({
        channelId = message.channel_id,
        messageId = messageId,
        reaction = reaction,
        toggle = toggle,
        reactor = phoneNumber
    })
    local packedLength = #packedReaction

    for i = 1, #recipients do
        local recipient = recipients[i].phone_number
        local recipientSource = GetSourceFromNumber(recipient)

        if recipientSource then
            TriggerClientEventInternal("phone:messages:toggleReaction", recipientSource, packedReaction, packedLength)
        end
    end

    if toggle and message.sender ~= phoneNumber then
        local contact = GetContact(message.sender, phoneNumber)

        SendNotification(message.sender, {
            app = "Messages",
            title = L("APPS.MESSAGES.REACT_NOTIFICATION.TITLE"),
            content = L("APPS.MESSAGES.REACT_NOTIFICATION.CONTENT", {
                name = (contact and contact.name) or phoneNumber,
                reaction = reaction
            }),
            avatar = contact and contact.avatar,
            showAvatar = true
        })
    end

    return true
end, false, {
    preventSpam = true
})
