local function IsValidPin(pin)
    return type(pin) == "string" and #pin == 4
end

RegisterLegacyCallback("security:getIdentifier", function(source, callback)
    callback(GetIdentifier(source))
end)

BaseCallback("security:setPin", function(source, phoneNumber, pin, oldPin)
    if not IsValidPin(pin) then
        debugprint("Failed to set pin: invalid type or length")
        return false
    end

    local affectedRows = MySQL.update.await(
        "UPDATE phone_phones SET pin = ? WHERE phone_number = ? AND (pin = ? OR pin IS NULL)",
        { pin, phoneNumber, oldPin or "" }
    )

    local success = affectedRows > 0

    debugprint("phone:security:setPin", GetPlayerName(source), success, phoneNumber, pin, oldPin)

    return success
end, false)

BaseCallback("security:removePin", function(source, phoneNumber, pin)
    if not IsValidPin(pin) then
        debugprint("Failed to remove pin: invalid type or length")
        return false
    end

    local affectedRows = MySQL.update.await(
        "UPDATE phone_phones SET pin = NULL, face_id = NULL WHERE phone_number = ? AND (pin = ? OR pin IS NULL)",
        { phoneNumber, pin }
    )

    return affectedRows > 0
end, false)

BaseCallback("security:verifyPin", function(source, phoneNumber, pin)
    if not IsValidPin(pin) then
        debugprint("Failed to verify pin: invalid type or length")
        return false
    end

    local savedPin = MySQL.scalar.await(
        "SELECT pin FROM phone_phones WHERE phone_number = ?",
        { phoneNumber }
    )

    local verified = savedPin == nil or savedPin == pin

    debugprint("phone:security:verifyPin", GetPlayerName(source), verified, savedPin, pin)

    return verified
end, false)

BaseCallback("security:enableFaceUnlock", function(source, phoneNumber, pin)
    if not IsValidPin(pin) then
        debugprint("Failed to enable face unlock: invalid type or length")
        return false
    end

    local affectedRows = MySQL.update.await(
        "UPDATE phone_phones SET face_id = ? WHERE phone_number = ? AND pin = ?",
        { GetIdentifier(source), phoneNumber, pin }
    )

    return affectedRows > 0
end, false)

BaseCallback("security:disableFaceUnlock", function(source, phoneNumber, pin)
    if not IsValidPin(pin) then
        debugprint("Failed to disable face unlock: invalid type or length")
        return false
    end

    local affectedRows = MySQL.update.await(
        "UPDATE phone_phones SET face_id = NULL WHERE phone_number = ? AND (pin = ? OR pin IS NULL)",
        { phoneNumber, pin }
    )

    return affectedRows > 0
end, false)

BaseCallback("security:verifyFace", function(source, phoneNumber)
    local identifier = GetIdentifier(source)
    local faceId = MySQL.scalar.await(
        "SELECT face_id FROM phone_phones WHERE phone_number = ?",
        { phoneNumber }
    )

    debugprint("phone:security:verifyFace", GetPlayerName(source), faceId, identifier)

    return faceId == identifier
end, false)

function ResetSecurity(phoneNumber)
    assert(
        type(phoneNumber) == "string",
        "Invalid argument #1 to ResetSecurity, expected string, got " .. type(phoneNumber)
    )

    MySQL.update.await(
        "UPDATE phone_phones SET pin = NULL, face_id = NULL WHERE phone_number = ?",
        { phoneNumber }
    )

    local source = GetSourceFromNumber(phoneNumber)

    if source then
        TriggerClientEvent("phone:security:reset", source, phoneNumber)
    end
end

exports("GetPin", function(phoneNumber)
    assert(
        type(phoneNumber) == "string",
        "Invalid argument #1 to GetPin, expected string, got " .. type(phoneNumber)
    )

    return MySQL.scalar.await(
        "SELECT pin FROM phone_phones WHERE phone_number = ?",
        { phoneNumber }
    )
end)

exports("ResetSecurity", ResetSecurity)
