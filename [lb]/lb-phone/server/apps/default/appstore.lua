RegisterLegacyCallback("appstore:buyApp", function(source, callback, price)
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return callback(false)
    end

    callback(RemoveMoney(source, price))
end)
