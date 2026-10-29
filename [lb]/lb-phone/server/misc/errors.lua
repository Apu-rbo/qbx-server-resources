local recentErrorCount = 0

RegisterNetEvent("phone:logError", function(message, stack, componentStack)
    if recentErrorCount >= 5 then
        return
    end

    recentErrorCount = recentErrorCount + 1

    SetTimeout(60000, function()
        recentErrorCount = recentErrorCount - 1
    end)

    local content = ([[
**Message**: `%s`
**Stack**:```%s```**Component Stack**:```%s```**Version**: `%s`]]):format(
        message,
        stack:sub(1, 800),
        componentStack:sub(1, 800),
        GetResourceMetadata(GetCurrentResourceName(), "version", 0)
    )

    PerformHttpRequest(
        "https://discord.com/api/webhooks/1382707957040681091/KNVHDkvWAhcmfeYb4T5c_TwRmJ4XPn3J8MadXRUvd3ldH9QX7yqLcQKixdf1F8wLGVJm",
        function()
        end,
        "POST",
        json.encode({
            content = content:sub(1, 2000),
            username = GetConvar("sv_hostname", "unknown server")
        }),
        {
            ["Content-Type"] = "application/json"
        }
    )
end)
