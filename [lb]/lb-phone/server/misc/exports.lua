local verifiedApps = {
    twitter = true,
    instagram = true,
    tiktok = true
}

local socialAliases = {
    birdy = "twitter",
    instapic = "instagram",
    trendy = "tiktok"
}

local verifiedNotificationApps = {
    twitter = "Twitter",
    instagram = "Instagram",
    tiktok = "TikTok"
}

local accountAppNames = {
    twitter = "Twitter",
    instagram = "Instagram",
    mail = "Mail",
    tiktok = "TikTok",
    darkchat = "DarkChat"
}

local usernameColumns = {
    twitter = "username",
    instagram = "username",
    tiktok = "username",
    mail = "address",
    darkchat = "username"
}

local function NormalizeVerifiedApp(app)
    assert(type(app) == "string", "Invalid app")

    app = app:lower()
    app = verifiedApps[app] and app or tostring(socialAliases[app])

    assert(verifiedApps[app], "Invalid app")

    return app
end

local function NormalizeAccountApp(app)
    assert(type(app) == "string", "Invalid app")

    app = app:lower()
    app = usernameColumns[app] and app or socialAliases[app]

    assert(usernameColumns[app], "Invalid app")

    return app
end

function ToggleVerified(app, username, verified)
    app = NormalizeVerifiedApp(app)

    assert(type(username) == "string", "Invalid username")

    TriggerEvent("lb-phone:toggleVerified", app, username, verified)

    if app ~= "twitter" then
        verified = verified ~= 0
    end

    local success = MySQL.update.await(
        ("UPDATE phone_%s_accounts SET verified = ? WHERE username = ?"):format(app),
        { verified, username }
    ) > 0

    if success and verified and verifiedNotificationApps[app] then
        local accounts = MySQL.query.await(
            "SELECT phone_number FROM phone_logged_in_accounts WHERE app = ? AND username = ? AND `active` = 1",
            { app, username }
        )

        for i = 1, #accounts do
            SendNotification(accounts[i].phone_number, {
                app = verifiedNotificationApps[app],
                title = L("BACKEND.MISC.VERIFIED")
            })
        end
    end

    return success
end

exports("ToggleVerified", ToggleVerified)

exports("IsVerified", function(app, username)
    app = NormalizeVerifiedApp(app)

    assert(type(username) == "string", "Invalid username")

    return MySQL.Sync.fetchScalar(
        ("SELECT verified FROM phone_%s_accounts WHERE username=@username"):format(app),
        { ["@username"] = username }
    ) or false
end)

function ChangePassword(app, username, password, skipLogout)
    app = NormalizeAccountApp(app)

    assert(type(username) == "string", "Invalid username")
    assert(type(password) == "string", "Invalid password")

    local success = MySQL.update.await(
        ("UPDATE phone_%s_accounts SET password = ? WHERE %s = ?"):format(app, usernameColumns[app]),
        { GetPasswordHash(password), username }
    ) > 0

    if not success then
        return false
    end

    if not skipLogout then
        NotifyLoggedInAccounts(accountAppNames[app], username, {
            title = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.TITLE"),
            content = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.DESCRIPTION")
        })

        ClearActiveAccountsCache(accountAppNames[app], username)

        TriggerClientEvent("phone:logoutFromApp", -1, {
            username = username,
            app = app,
            reason = "password"
        })

        MySQL.update("DELETE FROM phone_logged_in_accounts WHERE app = ? AND username = ?", {
            app,
            username
        })
    end

    return true
end

exports("ChangePassword", ChangePassword)

exports("GetEquippedPhoneNumber", function(identifier)
    if type(identifier) == "number" then
        return GetEquippedPhoneNumber(identifier)
    end

    local source = GetSourceFromIdentifier and GetSourceFromIdentifier(identifier)

    if source then
        return GetEquippedPhoneNumber(source)
    end

    local tableName = Config.Item.Unique and "phone_last_phone" or "phone_phones"

    return MySQL.scalar.await(
        ("SELECT phone_number FROM %s WHERE id = ?"):format(tableName),
        { identifier }
    )
end)
