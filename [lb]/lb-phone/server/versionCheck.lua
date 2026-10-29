if GetCurrentResourceName() ~= "lb-phone" then
    Citizen.CreateThreadNow(function()
        while true do
            infoprint(
                "error",
                "The resource name is not ^2lb-phone^7. The resource will not work properly. Please change the resource name to ^2lb-phone^7."
            )
            Wait(5000)
        end
    end)
end

PerformHttpRequest("https://version.loaf-scripts.com/", function(statusCode, response)
    if response then
        print(response)
    end
end, "POST", json.encode({
    resource = IS_BETA_VERSION and "lb-phone-beta" or "phone",
    version = GetResourceMetadata(GetCurrentResourceName(), "version", 0) or "0.0.0"
}), {
    ["Content-Type"] = "application/json"
})
