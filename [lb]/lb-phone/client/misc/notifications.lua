local notificationsWithActions = {}

local function GetNotifications()
    local notifications = AwaitCallback("getNotifications")

    for i = 1, #notifications do
        local notification = notifications[i]

        if notification.content == nil then
            notification.content = notification.title
            notification.title = nil
        end

        if notification.custom_data then
            local customData = json.decode(notification.custom_data)

            if customData.buttons then
                notification.actions = customData.buttons
                notificationsWithActions[notification.id] = notification
            end

            notification.custom_data = nil
        end
    end

    return notifications
end

local function DeleteNotification(id)
    if not id then
        return true
    end

    if notificationsWithActions[id] then
        notificationsWithActions[id] = nil
    end

    if type(id) == "string" and id:find("client%-notification%-") then
        return true
    end

    if type(id) ~= "number" then
        return true
    end

    return AwaitCallback("deleteNotification", id)
end

local function ClearNotifications(app)
    local success = AwaitCallback("clearNotifications", app)

    if not success then
        return false
    end

    for id, notification in pairs(notificationsWithActions) do
        if notification.app == app then
            notificationsWithActions[id] = nil
        end
    end

    return success
end

local function TriggerNotificationButton(id, buttonIndex)
    local actions = notificationsWithActions[id] and notificationsWithActions[id].actions

    if not actions then
        debugprint("No buttons found for notification", id, notificationsWithActions)
        return false
    end

    local button = actions[buttonIndex]

    if not button then
        debugprint("Button not found for notification", id, buttonIndex)
        return false
    end

    if button.event then
        if button.server then
            TriggerServerEvent(button.event, button.data)
        else
            TriggerEvent(button.event, button.data)
        end
    end

    if button.remove then
        SendNUIAction("removeNotification", id)
        notificationsWithActions[id] = nil
    end

    if type(id) == "number" then
        AwaitCallback("deleteNotification", id)
    end

    return true
end

RegisterNUICallback("Notifications", function(data, callback)
    local action = data.action

    debugprint("Notifications:" .. (action or ""))

    if action == "getNotifications" then
        return callback(GetNotifications())
    elseif action == "deleteNotification" then
        return callback(DeleteNotification(data.id))
    elseif action == "clearNotifications" then
        return callback(ClearNotifications(data.app))
    elseif action == "button" then
        return callback(TriggerNotificationButton(data.id, (data.buttonId or 0) + 1))
    end
end)

RegisterNetEvent("phone:sendNotification", function(notification)
    if not HasPhoneItem(currentPhone) or phoneDisabled then
        debugprint("no phone, not showing notification")
        return
    end

    notification.id = notification.id or ("client-notification-" .. math.random())

    if notification.content == nil then
        notification.content = notification.title
        notification.title = nil
    end

    if notification.customData then
        if notification.customData.buttons and notification.id then
            notification.actions = notification.customData.buttons
            notificationsWithActions[notification.id] = notification
        end

        notification.customData = nil
    end

    SendNUIAction("newNotification", notification)

    if not phoneOpen and Config.NotificationsUpdateZIndex and SetNuiZindex then
        SetNuiZindex(99)
    end
end)

exports("SendNotification", function(notification)
    notification.id = "client-notification-" .. math.random()
    TriggerEvent("phone:sendNotification", notification)
end)

exports("DeleteNotification", DeleteNotification)
