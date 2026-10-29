RegisterNUICallback("logError", function(data, callback)
    if GetResourceMetadata(GetCurrentResourceName(), "ui_page", 0) == "ui/dist/index.html" then
        TriggerServerEvent(
            "phone:logError",
            data.error or "No error message",
            data.stack or "No stack",
            data.componentStack or "No component stack"
        )
    end

    local wasPhoneOpen = phoneOpen

    OnDeath()

    if wasPhoneOpen then
        debugprint("Opening phone due to error")
        ToggleOpen(true)
    end

    Wait(5000)

    TriggerEvent("phone:sendNotification", {
        app = "Settings",
        title = "System Crash",
        content = "Your phone crashed. Press F8 for more info."
    })

    callback("ok")
end)
