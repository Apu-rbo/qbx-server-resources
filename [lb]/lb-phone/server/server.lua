function GenerateString(length)
    local result = ""

    length = length or 15

    for _ = 1, length do
        if math.random(1, 2) == 1 then
            local char = string.char(math.random(97, 122))

            if math.random(1, 2) == 1 then
                char = char:upper()
            end

            result = result .. char
        else
            result = result .. math.random(1, 9)
        end
    end

    return result
end

function GenerateId(tableName, columnName)
    local isUnique = false
    local id

    while not isUnique do
        id = GenerateString(5)

        local existingId = MySQL.Sync.fetchScalar(
            ("SELECT `%s` FROM `%s` WHERE `%s` = @id"):format(columnName, tableName, columnName),
            {
                ["@id"] = id
            }
        )

        isUnique = existingId == nil

        if not isUnique then
            Wait(50)
        end
    end

    return id
end

function GeneratePhoneNumber()
    local prefixes = Config.PhoneNumber.Prefixes
    local isUnique = false
    local phoneNumber

    while not isUnique do
        local number = ""

        for _ = 1, Config.PhoneNumber.Length do
            number = number .. math.random(0, 9)
        end

        if #prefixes == 0 then
            phoneNumber = number
        else
            phoneNumber = prefixes[math.random(1, #prefixes)] .. number
        end

        local existingNumber = MySQL.Sync.fetchScalar(
            "SELECT phone_number FROM phone_phones WHERE phone_number = @number",
            {
                ["@number"] = phoneNumber
            }
        )

        isUnique = existingNumber == nil

        if not isUnique then
            Wait(0)
        end
    end

    return phoneNumber
end

local phoneNumberToSource = {}
local sourceToPhoneNumberStore = {}
local sourceToPhoneNumber = setmetatable({}, {
    __index = sourceToPhoneNumberStore,
    __newindex = function(_, source, phoneNumber)
        local oldPhoneNumber = sourceToPhoneNumberStore[source]

        if phoneNumber == oldPhoneNumber then
            return
        end

        TriggerEvent("lb-phone:numberChanged", source, phoneNumber, oldPhoneNumber)
        debugprint("sourceToPhoneNumber: " .. source .. " changed from " .. tostring(oldPhoneNumber) .. " to " .. tostring(phoneNumber))

        sourceToPhoneNumberStore[source] = phoneNumber
    end
})

local settingsCache = {}
local dirtySettings = {}

function GetSettings(phoneNumber)
    return settingsCache[phoneNumber]
end

exports("GetSettings", GetSettings)

function SetSettings(phoneNumber, settings)
    if not settings and dirtySettings[phoneNumber] then
        dirtySettings[phoneNumber] = nil

        if Config.CacheSettings ~= false then
            debugprint("Updating settings in database for", phoneNumber)

            MySQL.update(
                "UPDATE phone_phones SET settings = ? WHERE phone_number = ?",
                { json.encode(settingsCache[phoneNumber]), phoneNumber }
            )
        end
    end

    settingsCache[phoneNumber] = settings
end

function SaveAllSettings()
    if Config.CacheSettings == false then
        return
    end

    infoprint("info", "Saving all settings")

    for phoneNumber, settings in pairs(settingsCache) do
        if dirtySettings[phoneNumber] then
            MySQL.update(
                "UPDATE phone_phones SET settings = ? WHERE phone_number = ?",
                { json.encode(settings), phoneNumber }
            )
        else
            debugprint("Not saving settings for", phoneNumber, "because no changes were made")
        end
    end
end

RegisterLegacyCallback("playerLoaded", function(playerSource, callback)
    local identifier = GetIdentifier(playerSource)

    if not identifier then
        debugprint("playerLoaded: no identifier for source", playerSource)
        return callback()
    end

    debugprint(GetPlayerName(playerSource), playerSource, identifier, "triggered phone:playerLoaded")

    if not Config.Item.Unique then
        local phoneNumber = MySQL.scalar.await(
            "SELECT phone_number FROM phone_phones WHERE id = ?",
            { identifier }
        )

        if phoneNumber and HasPhoneItem(playerSource, phoneNumber) then
            phoneNumberToSource[phoneNumber] = playerSource
            sourceToPhoneNumber[playerSource] = phoneNumber

            MySQL.update(
                "UPDATE phone_phones SET last_seen = CURRENT_TIMESTAMP WHERE phone_number = ?",
                { phoneNumber }
            )
        end

        return callback(phoneNumber)
    end

    local lastPhoneNumber = MySQL.scalar.await(
        "SELECT phone_number FROM phone_last_phone WHERE id = ?",
        { identifier }
    )

    debugprint("result from phone_last_phone: ", lastPhoneNumber)

    if lastPhoneNumber then
        debugprint("checking if " .. playerSource .. " has phone with metadata for last phone number equipped")

        if HasPhoneItem(playerSource, lastPhoneNumber) then
            debugprint(playerSource .. "has phone with metadata")

            phoneNumberToSource[lastPhoneNumber] = playerSource
            sourceToPhoneNumber[playerSource] = lastPhoneNumber

            MySQL.update(
                "UPDATE phone_phones SET last_seen = CURRENT_TIMESTAMP WHERE phone_number = ?",
                { lastPhoneNumber }
            )

            return callback(lastPhoneNumber)
        end

        debugprint(playerSource .. " doesn't have phone with metadata for last phone number equipped")
        return callback()
    end

    debugprint("checking if " .. playerSource .. " has an empty phone")

    if not HasPhoneItem(playerSource) then
        debugprint(playerSource .. " does not have an empty phone")
        return callback()
    end

    debugprint(playerSource .. " does have an empty phone, checking if they have an existing phone from pre-unique phone")

    local oldPhoneNumber = MySQL.scalar.await(
        "SELECT phone_number FROM phone_phones WHERE id = ? AND assigned = FALSE",
        { identifier }
    )

    if not oldPhoneNumber or not SetPhoneNumber(playerSource, oldPhoneNumber) then
        debugprint(playerSource .. " does not have an existing phone from pre-unique phone, or failed to set number to item metadata")
        return callback()
    end

    debugprint(playerSource .. " does have an existing phone from pre-unique phone")

    MySQL.update(
        "UPDATE phone_phones SET assigned = TRUE, last_seen = CURRENT_TIMESTAMP WHERE phone_number = ?",
        { oldPhoneNumber }
    )

    MySQL.update(
        "INSERT INTO phone_last_phone (id, phone_number) VALUES (?, ?)",
        { identifier, oldPhoneNumber }
    )

    phoneNumberToSource[oldPhoneNumber] = playerSource
    sourceToPhoneNumber[playerSource] = oldPhoneNumber

    callback(oldPhoneNumber)
end)

RegisterLegacyCallback("setLastPhone", function(playerSource, callback, newPhoneNumber)
    local identifier = GetIdentifier(playerSource)
    local oldPhoneNumber = GetEquippedPhoneNumber(playerSource)

    debugprint(DebugPlayerName(playerSource), identifier, "triggered phone:setLastPhone. old number:", oldPhoneNumber, "new number:", newPhoneNumber)
    SaveBattery(playerSource)

    if not newPhoneNumber then
        if identifier then
            MySQL.update(
                "DELETE FROM phone_last_phone WHERE id = ?",
                { identifier }
            )
        end

        if oldPhoneNumber then
            phoneNumberToSource[oldPhoneNumber] = nil
            sourceToPhoneNumber[playerSource] = nil

            local playerState = Player(playerSource).state

            playerState.phoneOpen = false
            playerState.phoneName = nil
            playerState.phoneNumber = nil

            if GetSettings(oldPhoneNumber) then
                SetSettings(oldPhoneNumber, nil)
            end
        end

        return callback()
    end

    if not identifier then
        debugprint("setLastPhone: no identifier for source", playerSource)
        return callback()
    end

    if phoneNumberToSource[newPhoneNumber] and phoneNumberToSource[newPhoneNumber] ~= playerSource then
        return callback()
    end

    local phoneExists = MySQL.scalar.await(
        "SELECT 1 FROM phone_phones WHERE phone_number = ?",
        { newPhoneNumber }
    )

    if not phoneExists then
        infoprint("warning", GetPlayerName(playerSource) .. " | " .. playerSource .. " tried to use a phone with a number that doesn't exist. This usually happens when you delete the phone from phone_phones, without deleting the phone item from the player's inventory. Phone number: " .. newPhoneNumber)
        return callback()
    end

    MySQL.update.await(
        "INSERT INTO phone_last_phone (id, phone_number) VALUES (?, ?) ON DUPLICATE KEY UPDATE phone_number = ?",
        { identifier, newPhoneNumber, newPhoneNumber }
    )

    if oldPhoneNumber then
        phoneNumberToSource[oldPhoneNumber] = nil
        sourceToPhoneNumber[playerSource] = nil

        if GetSettings(oldPhoneNumber) then
            SetSettings(oldPhoneNumber, nil)
        end
    end

    phoneNumberToSource[newPhoneNumber] = playerSource
    sourceToPhoneNumber[playerSource] = newPhoneNumber

    callback()
end)

RegisterLegacyCallback("generatePhoneNumber", function(playerSource, callback)
    local identifier = GetIdentifier(playerSource)
    local phoneId = identifier

    debugprint(GetPlayerName(playerSource), playerSource, identifier, "wants to generate a phone number")

    if Config.Item.Unique then
        debugprint("unique phones enabled, checking if " .. GetPlayerName(playerSource) .. " has a phone item without a number assigned")

        if not HasPhoneItem(playerSource) then
            debugprint(GetPlayerName(playerSource) .. " does not have a phone item without a number assigned")
            return callback()
        end

        phoneId = GenerateId("phone_phones", "id")
    else
        local existingPhoneNumber = MySQL.scalar.await(
            "SELECT phone_number FROM phone_phones WHERE id = ?",
            { identifier }
        )

        if existingPhoneNumber then
            infoprint("warning", GetPlayerName(playerSource) .. " wants to generate a phone number, but they already have one. Please set Config.Debug to true, and send the full log in customer-support if this happens again.")

            phoneNumberToSource[existingPhoneNumber] = playerSource
            sourceToPhoneNumber[playerSource] = existingPhoneNumber

            return callback(existingPhoneNumber)
        end
    end

    local phoneNumber = GeneratePhoneNumber()

    MySQL.update.await(
        "INSERT INTO phone_phones (id, owner_id, phone_number) VALUES (?, ?, ?)",
        { phoneId, identifier, phoneNumber }
    )

    TriggerEvent("lb-phone:phoneNumberGenerated", playerSource, phoneNumber)

    if Config.Item.Unique then
        SetPhoneNumber(playerSource, phoneNumber)

        MySQL.update.await(
            "UPDATE phone_phones SET assigned = TRUE WHERE phone_number = ?",
            { phoneNumber }
        )

        MySQL.update.await(
            "INSERT INTO phone_last_phone (id, phone_number) VALUES (?, ?) ON DUPLICATE KEY UPDATE phone_number = ?",
            { GetIdentifier(playerSource), phoneNumber, phoneNumber }
        )
    end

    phoneNumberToSource[phoneNumber] = playerSource
    sourceToPhoneNumber[playerSource] = phoneNumber

    callback(phoneNumber)
end)

RegisterLegacyCallback("getPhone", function(playerSource, callback, phoneNumber)
    debugprint(GetPlayerName(playerSource), "triggered phone:getPhone. checking if they have an item")

    if not HasPhoneItem(playerSource, phoneNumber) then
        debugprint(GetPlayerName(playerSource), "does not have an item")
        return callback()
    end

    debugprint(GetPlayerName(playerSource), "has an item, getting phone data")

    local phoneData = MySQL.single.await(
        "SELECT owner_id, is_setup, settings, `name`, battery FROM phone_phones WHERE phone_number = ?",
        { phoneNumber }
    )

    if not phoneData then
        debugprint(GetPlayerName(playerSource), "does not have any phone data")
        return callback()
    end

    if phoneData.settings then
        local cachedSettings = GetSettings(phoneNumber)

        phoneData.settings = cachedSettings or json.decode(phoneData.settings)

        if not cachedSettings then
            SetSettings(phoneNumber, phoneData.settings)
        end
    end

    Player(playerSource).state.phoneName = phoneData.name

    debugprint(GetPlayerName(playerSource), "has phone data")

    if not phoneData.owner_id then
        local identifier = GetIdentifier(playerSource)

        debugprint(GetPlayerName(playerSource) .. "'s phone does not have an owner, setting owner to " .. identifier)

        MySQL.update(
            "UPDATE phone_phones SET owner_id = ? WHERE phone_number = ?",
            { identifier, phoneNumber }
        )
    end

    return callback(phoneData)
end)

function GetEquippedPhoneNumber(playerSource)
    return sourceToPhoneNumber[playerSource]
end

function GetSourceFromNumber(phoneNumber)
    if not phoneNumber then
        return false
    end

    return phoneNumberToSource[phoneNumber] or false
end

exports("GetSourceFromNumber", GetSourceFromNumber)

RegisterLegacyCallback("isAdmin", function(playerSource, callback)
    callback(IsAdmin(playerSource))
end)

RegisterLegacyCallback("getCharacterName", function(playerSource, callback)
    local firstName, lastName = GetCharacterName(playerSource)

    callback({
        firstname = firstName,
        lastname = lastName
    })
end)

local latestVersion = nil

PerformHttpRequest("https://version.loaf-scripts.com/phone/version.json", function(statusCode, body, headers, errorData)
    if statusCode ~= 200 then
        debugprint("Failed to get latest script version")
        debugprint("Status:", statusCode)
        debugprint("Body:", body)
        debugprint("Headers:", headers)
        debugprint("Error:", errorData)
        return
    end

    latestVersion = json.decode(body).latest
end, "GET")

RegisterCallback("getLatestVersion", function()
    return latestVersion
end)

RegisterNetEvent("phone:finishedSetup", function(settings)
    local playerSource = source
    local phoneNumber = GetEquippedPhoneNumber(playerSource)

    if not phoneNumber then
        return
    end

    SetSettings(phoneNumber, settings)

    MySQL.update(
        "UPDATE phone_phones SET is_setup = true, settings = ? WHERE phone_number = ?",
        { json.encode(settings), phoneNumber }
    )

    if Config.AutoCreateEmail then
        GenerateEmailAccount(playerSource, phoneNumber)
    end
end)

RegisterNetEvent("phone:setName", function(phoneName)
    local playerSource = source
    local phoneNumber = GetEquippedPhoneNumber(playerSource)

    if not phoneNumber then
        debugprint("phone:setName: no phone number for source", playerSource)
        return
    end

    if Config.NameFilter and not phoneName:match(Config.NameFilter) then
        infoprint("warning", "Player " .. GetPlayerName(playerSource) .. " tried to set an invalid phone name: " .. phoneName)

        local firstName, lastName = GetCharacterName(playerSource)

        phoneName = L("BACKEND.MISC.X_PHONE", {
            name = firstName,
            lastname = lastName
        })
    end

    MySQL.Async.execute(
        "UPDATE phone_phones SET `name`=@name WHERE phone_number=@phoneNumber",
        {
            ["@phoneNumber"] = phoneNumber,
            ["@name"] = phoneName
        }
    )

    if Config.Item.Unique and SetItemName then
        SetItemName(playerSource, phoneNumber, phoneName)
    end

    local settings = GetSettings(phoneNumber)

    if settings then
        settings.name = phoneName
    end

    Player(playerSource).state.phoneName = phoneName
end)

BaseCallback("setSettings", function(playerSource, phoneNumber, settings)
    debugprint(playerSource, "saving settings for phone number", phoneNumber)

    dirtySettings[phoneNumber] = true
    SetSettings(phoneNumber, settings)

    if Config.CacheSettings == false then
        MySQL.update(
            "UPDATE phone_phones SET settings = ? WHERE phone_number = ?",
            { json.encode(settings), phoneNumber }
        )
    end
end)

RegisterNetEvent("phone:togglePhone", function(isOpen)
    local playerSource = source
    local playerState = Player(playerSource).state

    playerState.phoneOpen = isOpen

    local phoneNumber = GetEquippedPhoneNumber(playerSource)

    if not phoneNumber then
        debugprint("phone:togglePhone: no phone number for source", playerSource)
        return
    end

    playerState.phoneNumber = phoneNumber
end)

RegisterNetEvent("phone:toggleFlashlight", function(enabled)
    Player(source).state.flashlight = enabled
end)

AddEventHandler("playerDropped", function()
    local playerSource = source
    local phoneNumber = GetEquippedPhoneNumber(playerSource)

    if phoneNumber then
        Wait(1000)

        SetSettings(phoneNumber, nil)

        phoneNumberToSource[phoneNumber] = nil
        sourceToPhoneNumber[playerSource] = nil
    end
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    SaveAllSettings()
end)

AddEventHandler("txAdmin:events:serverShuttingDown", function()
    SaveAllSettings()
end)

local function FactoryReset(phoneNumber)
    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE phone_number = ?",
        { phoneNumber }
    )

    local reset = MySQL.update.await(
        "UPDATE phone_phones SET is_setup = false, settings = NULL, pin = NULL, face_id = NULL WHERE phone_number = ?",
        { phoneNumber }
    ) > 0

    local playerSource = phoneNumberToSource[phoneNumber]

    if reset and playerSource then
        TriggerEvent("lb-phone:factoryReset", playerSource, phoneNumber)
        TriggerClientEvent("phone:factoryReset", playerSource)

        SetSettings(phoneNumber, nil)

        phoneNumberToSource[phoneNumber] = nil
        sourceToPhoneNumber[playerSource] = nil
    end
end

RegisterNetEvent("phone:factoryReset", function()
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return
    end

    FactoryReset(phoneNumber)
end)

exports("FactoryReset", FactoryReset)
