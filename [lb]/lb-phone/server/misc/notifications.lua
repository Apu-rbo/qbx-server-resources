local disabledNotifications = {}

if Config.DisabledNotifications then
    for i = 1, #Config.DisabledNotifications do
        disabledNotifications[Config.DisabledNotifications[i]] = true
    end
end

local function IsNotificationDisabled(app)
    return app and disabledNotifications[app] == true
end

local function TrimNotificationContent(data)
    if data.content and #data.content > 500 then
        data.content = data.content:sub(1, 500)
    end
end

local function EncodeCustomData(customData)
    return customData and json.encode(customData) or nil
end

function SendNotification(target, data, cb)
    if type(data) ~= "table" then
        if cb then
            cb(false)
        end

        return debugprint("SendNotification: Invalid data or no app", data)
    end

    data = table.clone(data)

    if IsNotificationDisabled(data.app) then
        if cb then
            cb(false)
        end

        return debugprint("SendNotification: Notification are disabled for app", data.app)
    end

    local phoneNumber
    local targetType = type(target)

    if not data.app and targetType == "string" then
        if cb then
            cb(false)
        end

        return debugprint("SendNotification: Invalid data or no app", data)
    end

    TrimNotificationContent(data)

    if targetType == "number" then
        data.source = target
    elseif targetType == "string" then
        phoneNumber = target
    end

    if data.app and not data.source and targetType == "string" then
        local source = GetSourceFromNumber(target)

        if source then
            data.source = source
        end
    end

    if not data.app or not phoneNumber then
        if cb then
            cb(true)
        end

        if data.source then
            TriggerClientEvent("phone:sendNotification", data.source, data)
            debugprint("SendNotification: Sending notification to source: " .. data.source)
        end

        debugprint("SendNotification: No app or no phone number provided (target is not a string)", phoneNumber, data)
        return
    end

    if Config.MaxNotifications then
        local oldestAllowedId = MySQL.scalar.await(
            "SELECT id FROM phone_notifications WHERE phone_number = ? ORDER BY id DESC LIMIT ?, 1",
            { phoneNumber, Config.MaxNotifications - 1 }
        )

        if oldestAllowedId then
            debugprint("SendNotification: " .. phoneNumber .. " has reached max notifications, deleting old notifications. id:", oldestAllowedId)

            MySQL.update.await(
                "DELETE FROM phone_notifications WHERE phone_number = ? AND id <= ?",
                { phoneNumber, oldestAllowedId }
            )
        end
    end

    local notificationId = MySQL.insert.await(
        "INSERT IGNORE INTO phone_notifications (phone_number, app, title, content, thumbnail, avatar, show_avatar, custom_data) VALUES (@phoneNumber, @app, @title, @content, @thumbnail, @avatar, @showAvatar, @data)",
        {
            phoneNumber = phoneNumber,
            app = data.app,
            title = data.title,
            content = data.content,
            thumbnail = data.thumbnail,
            avatar = data.avatar,
            showAvatar = data.showAvatar,
            data = EncodeCustomData(data.customData)
        }
    )

    data.id = notificationId

    if data.source then
        TriggerClientEvent("phone:sendNotification", data.source, data)
        debugprint("SendNotification: Sending notification to source: " .. data.source)
    else
        debugprint("SendNotification: couldn't find source, not triggering event")
    end

    if cb then
        cb(notificationId)
    end

    return notificationId
end

exports("SendNotification", SendNotification)

function NotifyEveryone(target, data)
    assert(target == "all" or target == "online", "Invalid notify")
    assert(type(data and data.app) == "string", "Invalid app")
    assert(type(data and data.title) == "string", "Invalid title")

    if IsNotificationDisabled(data.app) then
        debugprint("NotifyEveryone: Notification are disabled for app", data.app)
        return
    end

    TrimNotificationContent(data)

    if target == "all" then
        MySQL.insert([[
            INSERT INTO phone_notifications
                (phone_number, app, title, content, thumbnail, avatar, show_avatar)
            SELECT
                phone_number, @app, @title, @content, @thumbnail, @avatar, @showAvatar
            FROM
                phone_phones
            WHERE
                last_seen > DATE_SUB(NOW(), INTERVAL 7 DAY)
        ]], {
            app = data.app,
            title = data.title,
            content = data.content,
            thumbnail = data.thumbnail,
            avatar = data.avatar,
            showAvatar = data.showAvatar
        })
    end

    TriggerClientEvent("phone:sendNotification", -1, data)
end

exports("NotifyEveryone", NotifyEveryone)

function NotifyPhonesWithQuery(tableName, data, selectPrefix, params)
    if IsNotificationDisabled(data.app) then
        debugprint("NotifyPhonesWithQuery: Notification are disabled for app", data.app)
        return
    end

    params = params or {}
    selectPrefix = selectPrefix or ""

    params.app = data.app
    params.title = data.title
    params.content = data.content
    params.thumbnail = data.thumbnail
    params.avatar = data.avatar
    params.showAvatar = data.showAvatar

    TrimNotificationContent(params)

    local query = ([[
        INSERT INTO phone_notifications
            (phone_number, app, title, content, thumbnail, avatar, show_avatar)
        SELECT
            %sphone_number, @app, @title, @content, @thumbnail, @avatar, @showAvatar
        FROM
            %s
        RETURNING
            id, phone_number
    ]]):format(selectPrefix, tableName)

    MySQL.query(query, params, function(rows)
        for i = 1, #rows do
            local phoneNumber = rows[i].phone_number
            local source = GetSourceFromNumber(phoneNumber)

            if source then
                local notification = table.clone(data)

                notification.id = rows[i].id
                TriggerClientEvent("phone:sendNotification", source, notification)
            end
        end
    end)
end

function NotifyPhones(phoneNumbers, data)
    local notification = table.clone(data)

    if IsNotificationDisabled(notification.app) then
        debugprint("NotifyPhones: Notification are disabled for app", notification.app)
        return
    end

    if #phoneNumbers == 0 then
        debugprint("NotifyPhones: No phone numbers provided")
        return
    end

    TrimNotificationContent(notification)

    local params = {
        notification.app,
        notification.title
    }
    local columns = {
        "phone_number",
        "app",
        "title"
    }

    if notification.content then
        params[#params + 1] = notification.content
        columns[#columns + 1] = "content"
    end

    if notification.thumbnail then
        params[#params + 1] = notification.thumbnail
        columns[#columns + 1] = "thumbnail"
    end

    if notification.avatar then
        params[#params + 1] = notification.avatar
        columns[#columns + 1] = "avatar"
    end

    if notification.showAvatar then
        params[#params + 1] = 1
        columns[#columns + 1] = "show_avatar"
    end

    if notification.customData then
        params[#params + 1] = json.encode(notification.customData)
        columns[#columns + 1] = "custom_data"
    end

    local query = ("INSERT INTO phone_notifications (%s) VALUES (%s)"):format(
        table.concat(columns, ", "),
        string.rep("?, ", #params + 1):sub(1, -3)
    )
    local rows = {}

    for i = 1, #phoneNumbers do
        local row = {
            phoneNumbers[i]
        }

        for j = 1, #params do
            row[#row + 1] = params[j]
        end

        rows[i] = row
    end

    MySQL.prepare(query, rows, function(result)
        for i = 1, #phoneNumbers do
            local phoneNumber = phoneNumbers[i]
            local notificationId = type(result) == "table" and result[i] or result

            if phoneNumber and notificationId then
                local source = GetSourceFromNumber(phoneNumber)

                if source then
                    local clientNotification = table.clone(notification)

                    clientNotification.id = notificationId
                    TriggerClientEvent("phone:sendNotification", source, clientNotification)
                end
            end
        end
    end)
end

function NotifyLoggedInAccounts(app, identifier, data, ignoredNumbers)
    if IsNotificationDisabled(app) then
        debugprint("NotifyLoggedInAccounts: Notification are disabled for app", app)
        return
    end

    local phoneNumbers = GetLoggedInNumbers(app, identifier)

    if ignoredNumbers then
        for i = #phoneNumbers, 1, -1 do
            local phoneNumber = phoneNumbers[i]

            if table.contains(ignoredNumbers, phoneNumber) then
                debugprint("NotifyLoggedInAccounts: Ignoring number", phoneNumber)
                table.remove(phoneNumbers, i)
            end
        end
    end

    if #phoneNumbers == 0 then
        debugprint("NotifyLoggedInAccounts: No logged in numbers for", identifier, "on", app)
        return
    end

    local notification = table.clone(data)

    notification.app = app

    NotifyPhones(phoneNumbers, notification)
end

function EmergencyNotification(source, data)
    assert(type(source) == "number", "Invalid source")
    assert(type(data) == "table", "Invalid data")

    return SendNotification(source, {
        title = data.title or "Emergency Alert",
        content = data.content or "This is a test emergency alert.",
        icon = "./assets/img/icons/" .. (data.icon or "warning") .. ".png"
    })
end

exports("SendAmberAlert", EmergencyNotification)
exports("EmergencyNotification", EmergencyNotification)

BaseCallback("getNotifications", function(source, phoneNumber, ...)
    return MySQL.query.await(
        "SELECT id, app, title, content, thumbnail, avatar, show_avatar AS showAvatar, custom_data, `timestamp` FROM phone_notifications WHERE phone_number=?",
        { phoneNumber }
    )
end, {})

BaseCallback("deleteNotification", function(source, phoneNumber, notificationId)
    local affectedRows = MySQL.update.await(
        "DELETE FROM phone_notifications WHERE id=? AND phone_number=?",
        { notificationId, phoneNumber }
    )

    return affectedRows > 0
end)

BaseCallback("clearNotifications", function(source, phoneNumber, app)
    MySQL.update.await(
        "DELETE FROM phone_notifications WHERE phone_number=? AND app=?",
        { phoneNumber, app }
    )

    return true
end)
