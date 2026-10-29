RegisterNUICallback("DarkChat", function(data, callback)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("DarkChat:" .. (action or ""))

    if action == "getUsername" then
        TriggerCallback("darkchat:getUsername", callback)
    elseif action == "setPassword" then
        TriggerCallback("darkchat:setPassword", callback, data.password)
    elseif action == "login" then
        TriggerCallback("darkchat:login", callback, data.username, data.password)
    elseif action == "logout" then
        TriggerCallback("darkchat:logout", callback)
    elseif action == "changePassword" then
        TriggerCallback("darkchat:changePassword", callback, data.oldPassword, data.newPassword)
    elseif action == "deleteAccount" then
        TriggerCallback("darkchat:deleteAccount", callback, data.password)
    elseif action == "register" then
        TriggerCallback("darkchat:register", callback, data.username, data.password)
    elseif action == "getChannels" then
        TriggerCallback("darkchat:getChannels", callback)
    elseif action == "createChannel" then
        TriggerCallback("darkchat:createChannel", callback, data.channel, data.password)
    elseif action == "joinChannel" then
        TriggerCallback("darkchat:joinChannel", callback, data.channel, data.password)
    elseif action == "getMessages" then
        TriggerCallback("darkchat:getMessages", callback, data.channel, data.lastId)
    elseif action == "sendMessage" then
        if not CanInteract() then
            return callback(false)
        end

        TriggerCallback("darkchat:sendMessage", callback, data.channel, data.content)
    elseif action == "leaveChannel" then
        TriggerCallback("darkchat:leaveChannel", callback, data.channel)
    end
end)

RegisterNetEvent("phone:darkChat:newMessage", function(channel, sender, content)
    SendNUIAction("darkChat:newMessage", {
        channel = channel,
        sender = sender,
        content = content
    })
end)

RegisterNetEvent("phone:darkChat:updateChannel", function(channel, username, action)
    SendNUIAction("darkChat:updateChannel", {
        action = action,
        channel = channel,
        username = username
    })
end)

RegisterNetEvent("phone:darkChat:joinChannel", function(channel)
    SendNUIAction("darkChat:addChannel", channel)
end)

RegisterNetEvent("phone:darkChat:leaveChannel", function(channel)
    SendNUIAction("darkChat:leaveChannel", channel)
end)
