RegisterNUICallback("AppStore", function(data, callback)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("AppStore:" .. (action or ""))

    if action == "buyApp" then
        TriggerCallback("appstore:buyApp", callback, data.price)
    end
end)
