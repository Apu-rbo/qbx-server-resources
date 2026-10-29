local function ApplyBackup(phoneNumber, callback)
    if phoneNumber == currentPhone then
        debugprint("can't apply backup since it's the currently equipped number")
        return callback(false)
    end

    local applied = AwaitCallback("backup:applyBackup", phoneNumber)

    debugprint("phone:backup:applyBackup", phoneNumber, ":", applied)
    callback(applied)

    if not applied then
        return
    end

    Wait(5000)
    OnDeath()

    Wait(500)
    FetchPhone()

    Wait(500)
    ToggleOpen(true)
end

RegisterNUICallback("Backup", function(data, callback)
    local action = data.action

    debugprint("Backup:" .. (action or ""))

    if action == "create" then
        TriggerCallback("backup:createBackup", callback)
    elseif action == "delete" then
        TriggerCallback("backup:deleteBackup", callback, data.number)
    elseif action == "apply" then
        ApplyBackup(data.number, callback)
    elseif action == "get" then
        TriggerCallback("backup:getBackups", callback)
    end
end)
