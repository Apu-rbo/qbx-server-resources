local selectedMail = nil

local function DecodeMail(mail)
    if not mail then
        return false
    end

    mail.attachments = mail.attachments and json.decode(mail.attachments) or {}
    mail.actions = mail.actions and json.decode(mail.actions) or {}

    return mail
end

RegisterNUICallback("Mail", function(data, callback)
    local action = data.action

    debugprint("Mail:", action or "")

    if action == "isLoggedIn" then
        TriggerCallback("mail:isLoggedIn", callback)
    elseif action == "createMail" then
        TriggerCallback("mail:createAccount", callback, data.data.email, data.data.password)
    elseif action == "changePassword" then
        TriggerCallback("mail:changePassword", callback, data.oldPassword, data.newPassword)
    elseif action == "deleteAccount" then
        TriggerCallback("mail:deleteAccount", callback, data.password)
    elseif action == "login" then
        TriggerCallback("mail:login", callback, data.data.email, data.data.password)
    elseif action == "logout" then
        TriggerCallback("mail:logout", callback)
    elseif action == "getMails" then
        TriggerCallback("mail:getMails", callback, {
            lastId = data.lastId
        })
    elseif action == "getMail" then
        TriggerCallback("mail:getMail", function(mail)
            selectedMail = DecodeMail(mail)
            callback(selectedMail)
        end, data.id)
    elseif action == "search" then
        TriggerCallback("mail:getMails", callback, {
            search = data.query,
            lastId = data.lastId
        })
    elseif action == "sendMail" then
        TriggerCallback("mail:sendMail", callback, data.data)
    elseif action == "deleteMail" then
        TriggerCallback("mail:deleteMail", callback, data.id)
    elseif action == "action" then
        if not selectedMail or selectedMail.id ~= data.id then
            return debugprint("wrong mail id for action")
        end

        local actionIndex = (data.actionId or 0) + 1
        local mailAction = selectedMail.actions[actionIndex] and selectedMail.actions[actionIndex].data

        if not mailAction then
            return debugprint("no action found", actionIndex)
        end

        if mailAction.data and mailAction.data.qbMail then
            TriggerEvent(mailAction.event, mailAction.data.data)
            return callback("ok")
        end

        if mailAction.isServer then
            TriggerServerEvent(mailAction.event, data.id, mailAction.data)
        else
            TriggerEvent(mailAction.event, data.id, mailAction.data)
        end

        callback("ok")
    end
end)

RegisterNetEvent("phone:mail:newMail", function(mail)
    SendNUIAction("mail:newMail", mail)
end)

RegisterNetEvent("phone:mail:mailDeleted", function(mailId)
    SendNUIAction("mail:deleteMail", mailId)
end)
