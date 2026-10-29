local interactionActions = {
    "sendMessage",
    "createGroup",
    "renameGroup"
}

RegisterNUICallback("Messages", function(data, cb)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("Messages:" .. (action or ""))

    if table.contains(interactionActions, action) and not CanInteract() then
        return cb(false)
    end

    if data.attachments then
        data.attachments = json.encode(data.attachments)
    else
        data.attachments = nil
    end

    if action == "sendMessage" then
        TriggerServerEvent("phone:messages:messageSent", data.number, data.content, data.attachments)
        TriggerCallback(
            "messages:sendMessage",
            cb,
            data.number,
            data.content,
            data.attachments,
            data.replyTo,
            data.id
        )
    elseif action == "createGroup" then
        local members = {}

        for i = 1, #data.members do
            members[i] = data.members[i].number
        end

        TriggerCallback("messages:createGroup", cb, members, data.content, data.attachments)
    elseif action == "renameGroup" then
        TriggerCallback("messages:renameGroup", cb, data.id, data.name)
    elseif action == "getRecentMessages" then
        local rows = AwaitCallback("messages:getRecentMessages")
        local conversations = {}

        local function FindConversation(channelId)
            for i = 1, #conversations do
                if conversations[i].id == channelId then
                    return i
                end
            end

            return false
        end

        for i = 1, #rows do
            local row = rows[i]
            local conversationIndex = FindConversation(row.channel_id)

            if not conversationIndex then
                if row.is_group then
                    conversations[#conversations + 1] = {
                        id = row.channel_id,
                        lastMessage = row.last_message,
                        timestamp = row.last_message_timestamp,
                        name = row.name,
                        isGroup = true,
                        members = {
                            {
                                isOwner = row.is_owner,
                                number = row.phone_number
                            }
                        }
                    }
                elseif row.phone_number ~= currentPhone then
                    conversations[#conversations + 1] = {
                        id = row.channel_id,
                        lastMessage = row.last_message,
                        timestamp = row.last_message_timestamp,
                        number = row.phone_number,
                        isGroup = false
                    }
                end
            elseif row.is_group then
                local conversation = conversations[conversationIndex]

                conversation.members[#conversation.members + 1] = {
                    isOwner = row.is_owner,
                    number = row.phone_number
                }
            end
        end

        for i = 1, #rows do
            local row = rows[i]
            local conversationIndex = FindConversation(row.channel_id)

            if conversationIndex and row.phone_number == currentPhone then
                local conversation = conversations[conversationIndex]

                conversation.deleted = row.deleted
                conversation.unread = row.unread > 0
            end
        end

        cb(conversations)
    elseif action == "getMessages" then
        TriggerCallback("messages:getMessages", function(messages)
            for i = 1, #messages do
                local message = messages[i]

                if message.attachments then
                    message.attachments = json.decode(message.attachments)
                end

                if message.reply_message then
                    message.reply = {
                        id = message.reply_to,
                        sender = message.reply_sender,
                        message = message.reply_message,
                        attachment = message.reply_attachment
                    }

                    message.reply_to = nil
                    message.reply_sender = nil
                    message.reply_message = nil
                    message.reply_attachment = nil
                end
            end

            cb(messages)
        end, data.id, data.lastId)
    elseif action == "deleteMessage" then
        if Config.DeleteMessages then
            TriggerCallback("messages:deleteMessage", cb, data.id, data.channel)
        end
    elseif action == "addMember" then
        TriggerCallback("messages:addMember", cb, data.id, data.number)
    elseif action == "removeMember" then
        TriggerCallback("messages:removeMember", cb, data.id, data.number)
    elseif action == "leaveGroup" then
        TriggerCallback("messages:leaveGroup", cb, data.id)
    elseif action == "markRead" then
        TriggerCallback("messages:markRead", cb, data.id)
    elseif action == "deleteConversations" then
        TriggerCallback("messages:deleteConversations", cb, data.channels)
    elseif action == "toggleReaction" then
        TriggerCallback("messages:toggleReaction", cb, data.messageId, data.reaction, data.toggle)
    end
end)

RegisterNetEvent("phone:messages:newMessage", function(channelId, messageId, sender, content, attachments, replyData)
    local message = {
        channelId = channelId,
        messageId = messageId,
        sender = sender,
        content = content,
        attachments = (attachments and json.decode(attachments)) or {},
        reply = replyData and {
            sender = replyData.sender,
            message = replyData.content,
            attachment = replyData.attachments ~= nil
        } or nil
    }

    SendNUIAction("messages:newMessage", message)
end)

RegisterNetEvent("phone:messages:messageDeleted", function(channelId, messageId, isLastMessage)
    SendNUIAction("messages:messageDeleted", {
        channelId = channelId,
        messageId = messageId,
        isLastMessage = isLastMessage
    })
end)

RegisterNetEvent("phone:messages:renameGroup", function(channelId, name)
    SendNUIAction("messages:renameGroup", {
        channelId = channelId,
        name = name
    })
end)

RegisterNetEvent("phone:messages:memberAdded", function(channelId, number)
    SendNUIAction("messages:addMember", {
        channelId = channelId,
        number = number
    })
end)

RegisterNetEvent("phone:messages:memberRemoved", function(channelId, number)
    SendNUIAction("messages:removeMember", {
        channelId = channelId,
        number = number
    })
end)

RegisterNetEvent("phone:messages:ownerChanged", function(channelId, number)
    SendNUIAction("messages:changeOwner", {
        channelId = channelId,
        number = number
    })
end)

RegisterNetEvent("phone:messages:newChannel", function(channel)
    SendNUIAction("messages:newChannel", channel)
end)

RegisterNetEvent("phone:messages:toggleReaction", function(data)
    SendNUIAction("messages:toggleReaction", data)
end)
