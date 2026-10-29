local activeAccounts = {}

local supportedApps = {
    Twitter = true,
    Instagram = true,
    Mail = true,
    TikTok = true,
    DarkChat = true
}

local exportAppAliases = {
    instapic = "Instagram",
    birdy = "Twitter",
    trendy = "TikTok",
    darkchat = "DarkChat",
    mail = "Mail"
}

for app in pairs(supportedApps) do
    activeAccounts[app] = {}
end

BaseCallback("accountSwitcher:switchAccount", function(source, phoneNumber, app, username)
    if not supportedApps[app] then
        return false
    end

    local isLoggedIn = MySQL.scalar.await(
        "SELECT TRUE FROM phone_logged_in_accounts WHERE phone_number = ? AND app = ? AND username = ?",
        { phoneNumber, app, username }
    )

    if not isLoggedIn then
        print(("Possible abuse? %s (%i) tried to switch to an account they aren't logged into."):format(GetPlayerName(source), source))
        return false
    end

    local success = MySQL.update.await(
        "UPDATE phone_logged_in_accounts SET `active` = (username = ?) WHERE phone_number = ? AND app = ?",
        { username, phoneNumber, app }
    ) > 0

    if success then
        activeAccounts[app][phoneNumber] = username
        TriggerEvent("phone:loggedInToAccount", app, phoneNumber, username)
    end

    return success
end)

BaseCallback("accountSwitcher:getAccounts", function(source, phoneNumber, app)
    if not supportedApps[app] then
        return {}
    end

    return MySQL.query.await(
        "SELECT username FROM phone_logged_in_accounts WHERE phone_number = ? AND app = ?",
        { phoneNumber, app }
    )
end)

function AddLoggedInAccount(phoneNumber, app, username)
    assert(supportedApps[app], "Invalid app: " .. app)
    assert(type(phoneNumber) == "string", "Invalid phone number. Expected string.")
    assert(type(username) == "string", "Invalid username. Expected string.")

    MySQL.update.await(
        "UPDATE phone_logged_in_accounts SET `active` = 0 WHERE phone_number = ? AND app = ? AND username != ?",
        { phoneNumber, app, username }
    )

    local success = MySQL.update.await(
        "INSERT INTO phone_logged_in_accounts (phone_number, app, username, active) VALUES (?, ?, ?, 1) ON DUPLICATE KEY UPDATE active = 1",
        { phoneNumber, app, username }
    ) > 0

    if success then
        activeAccounts[app][phoneNumber] = username
        TriggerEvent("phone:loggedInToAccount", app, phoneNumber, username)
    end

    return success
end

function RemoveLoggedInAccount(phoneNumber, app, username)
    assert(supportedApps[app], "Invalid app: " .. app)
    assert(type(phoneNumber) == "string", "Invalid phone number. Expected string.")
    assert(type(username) == "string", "Invalid username. Expected string.")

    local success = MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE phone_number = ? AND app = ? AND username = ?",
        { phoneNumber, app, username }
    ) > 0

    if success then
        if activeAccounts[app][phoneNumber] == username then
            activeAccounts[app][phoneNumber] = nil
        end

        TriggerEvent("phone:loggedOutFromAccount", app, username, phoneNumber)
    end

    return success
end

function GetLoggedInAccount(phoneNumber, app, skipCache)
    assert(supportedApps[app], "Invalid app: " .. app)
    assert(type(phoneNumber) == "string", "Invalid phone number. Expected string.")

    if activeAccounts[app][phoneNumber] then
        return activeAccounts[app][phoneNumber]
    end

    local username = MySQL.scalar.await(
        "SELECT username FROM phone_logged_in_accounts WHERE phone_number = ? AND app = ? AND active = 1",
        { phoneNumber, app }
    )

    if username and not skipCache then
        debugprint("AccountSwitcher: Setting cache for " .. phoneNumber .. ", logged in as " .. username .. " on " .. app)
        activeAccounts[app][phoneNumber] = username
    end

    return username or false
end

function GetLoggedInNumbers(app, username, activeOnly)
    assert(supportedApps[app], "Invalid app: " .. app)
    assert(type(username) == "string", "Invalid username. Expected string.")

    if activeOnly == nil then
        activeOnly = true
    end

    local query = "SELECT phone_number FROM phone_logged_in_accounts WHERE app = ? AND username = ?"

    if activeOnly then
        query = query .. " AND active = 1"
    end

    local rows = MySQL.query.await(query, { app, username })

    if not rows then
        return {}
    end

    local numbers = {}

    for i = 1, #rows do
        numbers[#numbers + 1] = rows[i].phone_number
    end

    return numbers
end

function GetActiveAccounts(app)
    return activeAccounts[app] or {}
end

function ClearActiveAccountsCache(app, username, exceptPhoneNumber)
    assert(supportedApps[app], "Invalid app: " .. app)
    assert(type(username) == "string", "Invalid username. Expected string.")

    for phoneNumber, activeUsername in pairs(activeAccounts[app]) do
        if activeUsername == username and phoneNumber ~= exceptPhoneNumber then
            activeAccounts[app][phoneNumber] = nil
        end
    end
end

exports("GetSocialMediaUsername", function(phoneNumber, app)
    assert(type(app) == "string", "Invalid app")

    local appKey = app:lower()

    assert(type(phoneNumber) == "string", "Invalid phone number. Expected string.")
    assert(exportAppAliases[appKey], "Invalid app: " .. app)

    return GetLoggedInAccount(phoneNumber, exportAppAliases[appKey], true)
end)

AddEventHandler("playerDropped", function()
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not phoneNumber then
        return
    end

    for app, accounts in pairs(activeAccounts) do
        if accounts[phoneNumber] then
            accounts[phoneNumber] = nil
            debugprint("AccountSwitcher: Player dropped, logging out " .. phoneNumber .. " from " .. app)
        end
    end
end)
