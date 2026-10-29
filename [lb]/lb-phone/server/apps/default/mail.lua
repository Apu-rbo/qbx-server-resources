exports("GetEmailAddress", function(phoneNumber)
    return GetLoggedInAccount(phoneNumber, "Mail", true)
end)

local function RegisterMailCallback(name, handler, defaultResponse)
    BaseCallback("mail:" .. name, function(source, phoneNumber, ...)
        local address = GetLoggedInAccount(phoneNumber, "Mail")

        if not address then
            return defaultResponse
        end

        return handler(source, phoneNumber, address, ...)
    end, defaultResponse)
end

RegisterMailCallback("isLoggedIn", function(source, phoneNumber, address)
    return address
end, false)

local function CreateMailAccount(address, password, callback)
    if not address or not password or #address < 3 or #password < 3 then
        if callback then
            callback({
                success = false,
                reason = "Invalid email / password"
            })
        end

        return false, "Invalid email / password"
    end

    password = GetPasswordHash(password)

    local exists = MySQL.scalar.await(
        "SELECT 1 FROM phone_mail_accounts WHERE address=?",
        { address }
    )

    if exists then
        if callback then
            callback({
                success = false,
                error = "Address already exists"
            })
        end

        return false, "Address already exists"
    end

    local success = MySQL.update.await(
        "INSERT INTO phone_mail_accounts (address, `password`) VALUES (?, ?)",
        { address, password }
    ) == 1

    if not success then
        if callback then
            callback({
                success = false,
                error = "Server error"
            })
        end

        return false, "Server error"
    end

    if callback then
        callback({
            success = true
        })
    end

    return true
end

exports("CreateMailAccount", CreateMailAccount)

BaseCallback("mail:createAccount", function(source, phoneNumber, username, password)
    if #username < 3 or #password < 3 then
        return {
            success = false,
            error = "Invalid email / password"
        }
    end

    local address = username .. "@" .. Config.EmailDomain
    local success, errorMessage = CreateMailAccount(address, password)

    if success then
        AddLoggedInAccount(phoneNumber, "Mail", address)
    end

    return {
        success = success,
        error = errorMessage
    }
end)

RegisterMailCallback("changePassword", function(source, phoneNumber, address, currentPassword, newPassword)
    if not Config.ChangePassword.Mail then
        infoprint("warning", ("%s tried to change password on Mail, but it's not enabled in the config."):format(source))
        return false
    end

    if currentPassword == newPassword or #newPassword < 3 then
        debugprint("same password / too short")
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_mail_accounts WHERE address = ?",
        { address }
    )

    if not passwordHash or not VerifyPasswordHash(currentPassword, passwordHash) then
        return false
    end

    local updated = MySQL.update.await(
        "UPDATE phone_mail_accounts SET password = ? WHERE address = ?",
        { GetPasswordHash(newPassword), address }
    ) > 0

    if not updated then
        return false
    end

    NotifyLoggedInAccounts("Mail", address, {
        title = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.TITLE"),
        content = L("BACKEND.MISC.LOGGED_OUT_PASSWORD.DESCRIPTION")
    }, { phoneNumber })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'Mail' AND phone_number != ?",
        { address, phoneNumber }
    )

    ClearActiveAccountsCache("Mail", address, phoneNumber)

    Log(
        "Mail",
        source,
        "info",
        L("BACKEND.LOGS.CHANGED_PASSWORD.TITLE"),
        L("BACKEND.LOGS.CHANGED_PASSWORD.DESCRIPTION", {
            number = phoneNumber,
            username = address,
            app = "Mail"
        })
    )

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = address,
        app = "mail",
        reason = "password",
        number = phoneNumber
    })

    return true
end, false)

RegisterMailCallback("deleteAccount", function(source, phoneNumber, address, password)
    if not Config.DeleteAccount.Mail then
        infoprint("warning", ("%s tried to delete their account on Mail, but it's not enabled in the config."):format(source))
        return false
    end

    local passwordHash = MySQL.scalar.await(
        "SELECT password FROM phone_mail_accounts WHERE address = ?",
        { address }
    )

    if not passwordHash or not VerifyPasswordHash(password, passwordHash) then
        return false
    end

    local deleted = MySQL.update.await(
        "DELETE FROM phone_mail_accounts WHERE address = ?",
        { address }
    ) > 0

    if not deleted then
        return false
    end

    NotifyLoggedInAccounts("Mail", address, {
        title = L("BACKEND.MISC.DELETED_NOTIFICATION.TITLE"),
        content = L("BACKEND.MISC.DELETED_NOTIFICATION.DESCRIPTION")
    })

    MySQL.update.await(
        "DELETE FROM phone_logged_in_accounts WHERE username = ? AND app = 'Mail'",
        { address }
    )

    ClearActiveAccountsCache("Mail", address)

    Log(
        "Mail",
        source,
        "info",
        L("BACKEND.LOGS.DELETED_ACCOUNT.TITLE"),
        L("BACKEND.LOGS.DELETED_ACCOUNT.DESCRIPTION", {
            number = phoneNumber,
            username = address,
            app = "Mail"
        })
    )

    TriggerClientEvent("phone:logoutFromApp", -1, {
        username = address,
        app = "mail",
        reason = "deleted"
    })

    return true
end, false)

BaseCallback("mail:login", function(source, phoneNumber, address, password)
    local passwordHash = MySQL.scalar.await(
        "SELECT `password` FROM phone_mail_accounts WHERE address=?",
        { address }
    )

    if not passwordHash then
        return {
            success = false,
            error = "Invalid address"
        }
    end

    if not VerifyPasswordHash(password, passwordHash) then
        return {
            success = false,
            error = "Invalid password"
        }
    end

    AddLoggedInAccount(phoneNumber, "Mail", address)

    return {
        success = true
    }
end, {
    success = false,
    error = "No phone equipped"
})

RegisterMailCallback("logout", function(source, phoneNumber, address)
    RemoveLoggedInAccount(phoneNumber, "Mail", address)

    return {
        success = true
    }
end, {
    success = false,
    error = "Not logged in"
})

local function NotifyMail(mail)
    if mail.to == "all" then
        TriggerClientEvent("phone:mail:newMail", -1, mail)
        return
    end

    local phoneNumbers = GetLoggedInNumbers("Mail", mail.to)

    for i = 1, #phoneNumbers do
        local source = GetSourceFromNumber(phoneNumbers[i])

        if source then
            TriggerClientEvent("phone:mail:newMail", source, mail)
        end
    end

    NotifyPhones(phoneNumbers, {
        app = "Mail",
        title = mail.sender,
        content = mail.subject,
        thumbnail = mail.attachments and mail.attachments[1]
    })
end

local function SendMail(mail)
    local validRecipient = mail.to == "all"

    if mail.to and not validRecipient then
        validRecipient = MySQL.scalar.await(
            "SELECT 1 FROM phone_mail_accounts WHERE address = ?",
            { mail.to }
        ) ~= nil
    end

    if not validRecipient then
        return false, "Invalid address"
    end

    if Config.ConvertMailToMarkdown and ConvertHTMLToMarkdown then
        mail.message = ConvertHTMLToMarkdown(mail.message)
    end

    mail.attachments = mail.attachments or {}
    mail.actions = mail.actions or {}

    local mailId = MySQL.insert.await(
        "INSERT INTO phone_mail_messages (recipient, sender, subject, content, attachments, actions) VALUES (@recipient, @sender, @subject, @content, @attachments, @actions)",
        {
            ["@recipient"] = mail.to,
            ["@sender"] = mail.sender or "system",
            ["@subject"] = mail.subject or "System mail",
            ["@content"] = mail.message or "",
            ["@attachments"] = #mail.attachments > 0 and json.encode(mail.attachments) or nil,
            ["@actions"] = #mail.actions > 0 and json.encode(mail.actions) or nil
        }
    )

    local mailData = {
        id = mailId,
        to = mail.to,
        sender = mail.sender or "System",
        subject = mail.subject or "System mail",
        message = mail.message or "",
        attachments = mail.attachments,
        actions = mail.actions,
        read = false,
        timestamp = os.time() * 1000
    }

    TriggerEvent("lb-phone:mail:mailSent", mailData)
    NotifyMail(mailData)

    return true, mailId
end

exports("SendMail", SendMail)

function GenerateEmailAccount(source, phoneNumber)
    if not Config.AutoCreateEmail or not phoneNumber then
        return
    end

    local firstName, lastName = GetCharacterName(source)

    firstName = firstName:gsub("[^%w]", "")
    lastName = lastName:gsub("[^%w]", "")

    if #firstName == 0 then
        firstName = GenerateString(5)
    end

    if #lastName == 0 then
        lastName = GenerateString(5)
    end

    local username = firstName .. "." .. lastName
    local count = MySQL.scalar.await(
        "SELECT COUNT(1) FROM phone_mail_accounts WHERE address LIKE ?",
        { username .. "%" }
    ) or 0

    if count > 0 then
        username = username .. count + 1
    end

    local address = username .. "@" .. Config.EmailDomain
    local exists = MySQL.scalar.await(
        "SELECT 1 FROM phone_mail_accounts WHERE address=?",
        { address }
    )
    local attempts = 0

    while exists and attempts < 50 do
        address = firstName .. "." .. lastName .. math.random(1000, 9999) .. "@" .. Config.EmailDomain
        exists = MySQL.scalar.await(
            "SELECT 1 FROM phone_mail_accounts WHERE address=?",
            { address }
        )
        attempts = attempts + 1

        Wait(0)
    end

    if exists then
        debugprint("Failed to generate address for", source)
        return
    end

    address = address:lower()

    local password = GenerateString(5)

    if not CreateMailAccount(address, password) then
        return
    end

    AddLoggedInAccount(phoneNumber, "Mail", address)

    SendMail({
        to = address,
        sender = L("BACKEND.MAIL.AUTOMATIC_PASSWORD.SENDER"),
        subject = L("BACKEND.MAIL.AUTOMATIC_PASSWORD.SUBJECT"),
        message = L("BACKEND.MAIL.AUTOMATIC_PASSWORD.MESSAGE", {
            address = address,
            password = password
        })
    })
end

exports("DeleteMail", function(mailId)
    local deleted = MySQL.Sync.execute(
        "DELETE FROM phone_mail_messages WHERE id=@id",
        {
            ["@id"] = mailId
        }
    ) > 0

    if deleted then
        TriggerClientEvent("phone:mail:mailDeleted", -1, mailId)
    end

    return deleted
end)

RegisterMailCallback("sendMail", function(source, phoneNumber, address, data)
    if data.to == "all" then
        return false
    end

    local recipient = data.to
    local subject = data.subject
    local message = data.message
    local attachments = data.attachments

    if not recipient or not subject or not message or type(attachments) ~= "table" then
        return false
    end

    if ContainsBlacklistedWord(source, "Mail", subject) or ContainsBlacklistedWord(source, "Mail", message) then
        return false
    end

    local success, mailId = SendMail({
        to = recipient,
        sender = address,
        subject = subject,
        message = message,
        attachments = attachments
    })

    if not success then
        return false
    end

    Log(
        "Mail",
        source,
        "info",
        L("BACKEND.LOGS.MAIL_TITLE"),
        L("BACKEND.LOGS.NEW_MAIL", {
            sender = address,
            recipient = recipient
        })
    )

    return mailId
end)

RegisterMailCallback("getMails", function(source, phoneNumber, address, data)
    local lastId = data and data.lastId
    local search = data and data.search
    local params = { address, address }
    local query = [[
        SELECT
            m.id,
            m.recipient AS `to`,
            m.sender,
            m.`subject`,
            LEFT(m.content, 70) AS message,
            m.`read`,
            m.`timestamp`

        FROM
            phone_mail_messages m

        WHERE (
            recipient=?
            OR recipient="all"
            OR sender=?
        ) {EXCLUDE_DELETED} {SEARCH} {PAGINATION}

        ORDER BY `id` DESC

        LIMIT 10
    ]]

    if Config.DeleteMail then
        query = query:gsub("{EXCLUDE_DELETED}", [[
            AND NOT EXISTS (
                SELECT 1
                FROM phone_mail_deleted d
                WHERE d.message_id = m.id
                AND d.address = ?
            )
        ]])

        params[#params + 1] = address
    else
        query = query:gsub("{EXCLUDE_DELETED}", "")
    end

    if search and #search > 0 then
        search = "%" .. search .. "%"
        query = query:gsub("{SEARCH}", [[
            AND (
                m.recipient LIKE ?
                OR m.sender LIKE ?
                OR m.subject LIKE ?
                OR m.content LIKE ?
            )
        ]])

        params[#params + 1] = search
        params[#params + 1] = search
        params[#params + 1] = search
        params[#params + 1] = search
    else
        query = query:gsub("{SEARCH}", "")
    end

    if lastId then
        query = query:gsub("{PAGINATION}", "AND m.id < ?")
        params[#params + 1] = lastId
    else
        query = query:gsub("{PAGINATION}", "")
    end

    return MySQL.query.await(query, params)
end, {})

RegisterMailCallback("getMail", function(source, phoneNumber, address, mailId)
    local mail = MySQL.single.await([[
        SELECT
            id, recipient AS `to`, sender, subject, content as message, attachments, `read`, `timestamp`, actions

        FROM phone_mail_messages

        WHERE (
            recipient=@address
            OR recipient="all"
            OR sender=@address
        ) AND id=@id
    ]], {
        ["@address"] = address,
        ["@id"] = mailId
    })

    if not mail then
        return false
    end

    if not mail.read then
        MySQL.update(
            "UPDATE phone_mail_messages SET `read`=1 WHERE id=? AND sender != ?",
            { mailId, address }
        )
    end

    return mail
end)

RegisterMailCallback("deleteMail", function(source, phoneNumber, address, mailId)
    if not Config.DeleteMail then
        return
    end

    MySQL.update.await(
        "INSERT IGNORE INTO phone_mail_deleted (message_id, address) VALUES (?, ?)",
        { mailId, address }
    )

    return true
end)
