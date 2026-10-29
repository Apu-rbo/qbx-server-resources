if not Config.AutoDeleteNotifications then
    return
end

if type(Config.AutoDeleteNotifications) ~= "number" then
    Config.AutoDeleteNotifications = 168
end

while not DatabaseCheckerFinished do
    Wait(500)
end

while true do
    debugprint("Deleting all old notifications..")

    local startedAt = os.nanotime()

    MySQL.update(
        "DELETE FROM phone_notifications WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL ? HOUR)",
        { Config.AutoDeleteNotifications },
        function(deletedCount)
            local duration = (os.nanotime() - startedAt) / 1000000.0
            local suffix = deletedCount == 1 and "" or "s"

            debugprint("Deleted " .. deletedCount .. " notification" .. suffix .. " in " .. duration .. " ms")
        end
    )

    Wait(3600000)
end
