local cachedPin = nil
local cachedFaceIdentifier = nil
local cachedIdentifier = nil

function ResetSecurity(skipNuiReset)
    debugprint("ResetSecurity triggered")

    cachedPin = nil
    cachedFaceIdentifier = nil
    cachedIdentifier = nil

    if not skipNuiReset then
        SendNUIAction("resetSecurity")
    end
end

function GetIdentifier()
    if not cachedIdentifier then
        cachedIdentifier = AwaitCallback("security:getIdentifier")
        debugprint("getIdentifier:", cachedIdentifier)
    end

    return cachedIdentifier or "unknown"
end

local function IsValidPin(pin)
    if type(pin) ~= "string" then
        return false
    end

    if #pin ~= 4 then
        debugprint("invalid data.pin: invalid length", pin)
        return false
    end

    if not tonumber(pin) then
        debugprint("invalid data.pin: failed to convert to number", pin)
        return false
    end

    return true
end

RegisterNUICallback("Security", function(data, callback)
    local action = data.action

    debugprint("Security:" .. (action or ""), data)

    if action == "setPin" then
        if data.pin == cachedPin then
            debugprint("Failed to set pin: new pin is the same as the old pin")
            return callback(false)
        end

        if not IsValidPin(data.pin) then
            debugprint("Failed to set pin: invalid pin")
            return callback(false)
        end

        local success = AwaitCallback("security:setPin", data.pin, cachedPin)

        if success then
            debugprint("Successfully set pin to", data.pin)
            cachedPin = data.pin
        else
            debugprint("Failed to set pin")
        end

        callback(success)
    elseif action == "removePin" then
        local success = AwaitCallback("security:removePin", cachedPin)

        if success then
            ResetSecurity()
        end

        callback(success)
    elseif action == "verifyPin" then
        if cachedPin then
            debugprint("Has cached pin", cachedPin, data.pin)
            return callback(cachedPin == data.pin)
        end

        if not IsValidPin(data.pin) then
            debugprint("Failed to verify pin: invalid pin")
            return callback(false)
        end

        local success = AwaitCallback("security:verifyPin", data.pin)

        debugprint("security:verifyPin returned:", success)

        if success then
            debugprint("Correct pin, caching it", data.pin)
            cachedPin = data.pin
        end

        callback(success)
    elseif action == "setFaceId" then
        if not cachedPin or cachedPin ~= data.pin then
            debugprint("Failed to enable Face Unlock: incorrect pin")
            debugprint(cachedPin, data.pin)
            return callback(false)
        end

        debugprint("Correct pin, triggering enableFaceUnlock")
        TriggerCallback("security:enableFaceUnlock", callback, data.pin)
    elseif action == "removeFaceId" then
        if not cachedPin or cachedPin ~= data.pin then
            debugprint("Failed to disable Face Unlock: incorrect pin")
            return callback(false)
        end

        debugprint("Correct pin, triggering disableFaceUnlock")
        TriggerCallback("security:disableFaceUnlock", callback, data.pin)
    elseif action == "verifyFace" then
        if IsFaceObstructed() then
            debugprint("Face is obstructed")
            return callback(false)
        end

        if not cachedIdentifier then
            GetIdentifier()
        end

        if cachedFaceIdentifier then
            local verified = cachedFaceIdentifier == cachedIdentifier

            debugprint("Has cached face, returning:", verified)
            return callback(verified)
        end

        local success = AwaitCallback("security:verifyFace")

        debugprint("security:verifyFace returned:", success)

        if success then
            cachedFaceIdentifier = cachedIdentifier
        end

        callback(success)
    elseif action == "factoryReset" then
        TriggerServerEvent("phone:factoryReset")
    end
end)

RegisterNetEvent("phone:factoryReset", function()
    OnDeath()
    ResetSecurity()
    FetchPhone()
end)

RegisterNetEvent("phone:security:reset", function(phoneNumber)
    if phoneNumber == currentPhone then
        ResetSecurity()
        Wait(500)
        FetchPhone()
    end
end)
