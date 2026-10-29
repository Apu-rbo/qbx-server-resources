local activeCalls = {}
local disabledCompanyCalls = {}


local function generateCallId()
    local callId = math.random(999999999)

    while activeCalls[callId] do
        callId = math.random(999999999)
    end

    return callId
end

function GetContact(contactNumber, phoneNumber, callback)
    local params = { phoneNumber, contactNumber, phoneNumber }
    local query = [[
        SELECT
            CONCAT(firstname, ' ', lastname) AS `name`, profile_image AS avatar, firstname, lastname, email, address, contact_phone_number AS `number`, favourite,
            (IF((SELECT TRUE FROM phone_phone_blocked_numbers b WHERE b.phone_number=? AND b.blocked_number=`number`), TRUE, FALSE)) AS blocked

        FROM
            phone_phone_contacts
        WHERE
            contact_phone_number=? AND phone_number=?
    ]]

    if callback then
        return MySQL.single(query, params, callback)
    end

    return MySQL.single.await(query, params)
end

function CreateContact(phoneNumber, contact)
    if not contact then
        debugprint("CreateContact: contact is required", phoneNumber, contact)
        return false
    end

    if not contact.number then
        debugprint("CreateContact: contact.number is required", phoneNumber, contact)
        return false
    end

    local affectedRows = MySQL.Sync.execute([[
        INSERT INTO phone_phone_contacts (contact_phone_number, firstname, lastname, profile_image, email, address, phone_number)
        VALUES (@contactNumber, @firstname, @lastname, @avatar, @email, @address, @phoneNumber)
        ON DUPLICATE KEY UPDATE firstname=@firstname, lastname=@lastname, profile_image=@avatar, email=@email, address=@address
    ]], {
        ["@contactNumber"] = contact.number,
        ["@firstname"] = contact.firstname or contact.number,
        ["@lastname"] = contact.lastname or "",
        ["@avatar"] = contact.avatar,
        ["@email"] = contact.email,
        ["@address"] = contact.address,
        ["@phoneNumber"] = phoneNumber
    })

    return affectedRows > 0
end


BaseCallback("saveContact", function(source, phoneNumber, contact)
    return CreateContact(phoneNumber, contact)
end, false)

BaseCallback("getContacts", function(source, phoneNumber)
    return MySQL.query.await([[
        SELECT
            contact_phone_number AS number,
            firstname,
            lastname,
            profile_image AS avatar,
            favourite,
            IF(b.blocked_number IS NOT NULL, TRUE, FALSE) AS blocked

        FROM
            phone_phone_contacts c

        LEFT JOIN
            phone_phone_blocked_numbers b
            ON c.phone_number = b.phone_number AND c.contact_phone_number = b.blocked_number

        WHERE
            c.phone_number = ?
    ]], { phoneNumber })
end, {})

BaseCallback("toggleBlock", function(source, phoneNumber, number, blocked)
    local query = "INSERT INTO phone_phone_blocked_numbers (phone_number, blocked_number) VALUES (@phoneNumber, @number) ON DUPLICATE KEY UPDATE phone_number=@phoneNumber"

    if not blocked then
        query = "DELETE FROM phone_phone_blocked_numbers WHERE phone_number=@phoneNumber AND blocked_number=@number"
    end

    MySQL.update.await(query, {
        ["@phoneNumber"] = phoneNumber,
        ["@number"] = number
    })

    return blocked
end, false)

BaseCallback("toggleFavourite", function(source, phoneNumber, number, favourite)
    MySQL.update.await("UPDATE phone_phone_contacts SET favourite=@favourite WHERE contact_phone_number=@number AND phone_number=@phoneNumber", {
        ["@phoneNumber"] = phoneNumber,
        ["@number"] = number,
        ["@favourite"] = favourite == true
    })

    return true
end, false)

BaseCallback("removeContact", function(source, phoneNumber, number)
    MySQL.update.await("DELETE FROM phone_phone_contacts WHERE contact_phone_number=? AND phone_number=?", {
        number,
        phoneNumber
    })

    return true
end, false)

BaseCallback("updateContact", function(source, phoneNumber, contact)
    MySQL.update.await(
        "UPDATE phone_phone_contacts SET firstname=@firstname, lastname=@lastname, profile_image=@avatar, email=@email, address=@address, contact_phone_number=@newNumber WHERE contact_phone_number=@number AND phone_number=@phoneNumber",
        {
            ["@phoneNumber"] = phoneNumber,
            ["@number"] = contact.oldNumber,
            ["@newNumber"] = contact.number,
            ["@firstname"] = contact.firstname,
            ["@lastname"] = contact.lastname or "",
            ["@avatar"] = contact.avatar,
            ["@email"] = contact.email,
            ["@address"] = contact.address
        }
    )

    return true
end, false)

BaseCallback("getRecentCalls", function(source, phoneNumber, missed, lastId)
    missed = missed == true

    local params = { phoneNumber, phoneNumber, phoneNumber, phoneNumber, phoneNumber }
    local query = [[
        SELECT
            c.id,
            c.duration,
            c.answered,
            c.caller = ? AS called,
            IF(c.callee = ?, c.caller, c.callee) AS `number`,
            IF(c.callee = ?, c.hide_caller_id, FALSE) AS hideCallerId,
            (EXISTS (SELECT 1 FROM phone_phone_blocked_numbers b WHERE b.phone_number=? AND b.blocked_number=`number`)) AS blocked,
            c.`timestamp`

        FROM
            phone_phone_calls c

        WHERE
            (c.callee = ? {MISSED_CALLS_CONDITION}) {PAGINATION}

        ORDER BY
            c.id DESC

        LIMIT 25
    ]]

    if missed then
        query = query:gsub("{MISSED_CALLS_CONDITION}", "AND c.answered = 0")
    else
        query = query:gsub("{MISSED_CALLS_CONDITION}", "OR c.caller = ?")
        params[#params + 1] = phoneNumber
    end

    if lastId then
        query = query:gsub("{PAGINATION}", "AND c.id < ?")
        params[#params + 1] = lastId
    else
        query = query:gsub("{PAGINATION}", "")
    end

    local calls = MySQL.query.await(query, params)

    for i = 1, #calls do
        local call = calls[i]

        call.hideCallerId = call.hideCallerId == true
        call.blocked = call.blocked == true
        call.called = call.called == true

        if call.hideCallerId then
            call.number = L("BACKEND.CALLS.NO_CALLER_ID")
        end
    end

    return calls
end, {})

BaseCallback("getBlockedNumbers", function(source, phoneNumber)
    return MySQL.query.await("SELECT blocked_number AS `number` FROM phone_phone_blocked_numbers WHERE phone_number=?", {
        phoneNumber
    })
end, {})

local function logCall(caller, callee, duration, answered, hideCallerId, ownNumber)
    MySQL.insert("INSERT INTO phone_phone_calls (caller, callee, duration, answered, hide_caller_id) VALUES (@caller, @callee, @duration, @answered, @hideCallerId)", {
        ["@caller"] = caller,
        ["@callee"] = callee,
        ["@duration"] = duration,
        ["@answered"] = answered,
        ["@hideCallerId"] = hideCallerId
    })

    if answered or ownNumber == callee then
        return
    end

    local phoneExists = MySQL.scalar.await("SELECT TRUE FROM phone_phones WHERE phone_number = ?", { callee })

    if not phoneExists then
        return
    end

    if hideCallerId then
        SendNotification(callee, {
            app = "Phone",
            title = L("BACKEND.CALLS.NO_CALLER_ID"),
            content = L("BACKEND.CALLS.MISSED_CALL"),
            showAvatar = false
        })

        return
    end

    GetContact(caller, callee, function(contact)
        SendNotification(callee, {
            app = "Phone",
            title = (contact and contact.name) or caller,
            content = L("BACKEND.CALLS.MISSED_CALL"),
            avatar = contact and contact.avatar,
            showAvatar = true
        })
    end)

    SendMessage(caller, callee, "<!CALL-NO-ANSWER!>")
end

RegisterNetEvent("phone:logCall", function(number, duration, answered)
    local source = source
    local phoneNumber = GetEquippedPhoneNumber(source)

    if not (phoneNumber and number) or not duration then
        return
    end

    logCall(phoneNumber, number, duration, answered, false, phoneNumber)
end)

function IsInCall(source)
    for callId, call in pairs(activeCalls) do
        if (call.caller and call.caller.source == source) or (call.callee and call.callee.source == source) then
            return true, callId, call
        end
    end

    return false
end

exports("IsInCall", IsInCall)

function GetCall(callId)
    return activeCalls[callId]
end

exports("GetCall", GetCall)

RegisterNetEvent("phone:phone:disableCompanyCalls", function(disabled)
    local source = source

    if disabled then
        disabledCompanyCalls[source] = true
    else
        disabledCompanyCalls[source] = nil
    end
end)

local function companyExists(company)
    if Config.Companies.Contacts[company] then
        return true, Config.Companies.Contacts[company].name
    end

    for i = 1, #Config.Companies.Services do
        local service = Config.Companies.Services[i]

        if service.job == company then
            return true, service.name
        end
    end

    return false
end

local function sendCallToCompanyEmployees(call, callerNumber, companyLabel, hideCallerId)
    local employees = GetEmployees(call.company)

    debugprint("GetEmployees result:", employees)

    for i = 1, #employees do
        local employee = employees[i]

        if not IsInCall(employee) and employee ~= call.caller.source and not disabledCompanyCalls[employee] then
            TriggerClientEvent("phone:phone:setCall", employee, {
                callId = call.callId,
                number = callerNumber,
                company = call.company,
                companylabel = companyLabel,
                hideCallerId = hideCallerId
            })
        else
            debugprint("employee", employee, "is in call or have disabled company calls")
        end
    end
end

BaseCallback("call", function(source, phoneNumber, data)
    debugprint("phone:phone:call", source, phoneNumber, data)

    if IsInCall(source) then
        debugprint(source, "is in call, returning")
        return false
    end

    local callId = generateCallId()
    local call = {
        started = os.time(),
        answered = false,
        videoCall = data.videoCall == true,
        hideCallerId = data.hideCallerId == true,
        callId = callId,
        caller = {
            source = source,
            number = phoneNumber,
            nearby = {}
        }
    }

    if data.company then
        if not Config.Companies.Enabled or data.videoCall then
            debugprint("company calls are disabled in config or trying to call with video")
            TriggerClientEvent("phone:phone:userBusy", source)
            return false
        end

        local validCompany = companyExists(data.company)

        if not validCompany then
            debugprint("invalid company (does not exist in Config.Companies.Contacts or Config.Companies.Services)")
            return false
        end

        if not Config.Companies.AllowAnonymous then
            call.hideCallerId = false
        end

        call.videoCall = false
        call.company = data.company
        call.callee = {
            nearby = {}
        }

        sendCallToCompanyEmployees(call, phoneNumber, data.companylabel, call.hideCallerId)
    else
        local blocked = MySQL.Sync.fetchScalar([[
            SELECT TRUE FROM phone_phone_blocked_numbers WHERE
                (phone_number = @number1 AND blocked_number = @number2)
                OR (phone_number = @number2 AND blocked_number = @number1)
        ]], {
            ["@number1"] = phoneNumber,
            ["@number2"] = data.number
        })

        if blocked then
            debugprint(source, "tried to call", data.number, "but they are blocked")
            TriggerClientEvent("phone:phone:userBusy", source)
            return false
        end

        if data.number == phoneNumber then
            debugprint(source, "tried to call themselves")
            TriggerClientEvent("phone:phone:userBusy", source)
            return false
        end

        local calleeSource = GetSourceFromNumber(data.number)
        local calleeInCall = calleeSource and IsInCall(calleeSource)
        local canReachCallee = calleeSource
            and not calleeInCall
            and not IsPhoneDead(data.number)
            and not HasAirplaneMode(data.number)

        if not canReachCallee then
            logCall(phoneNumber, data.number, 0, false, data.hideCallerId)

            if calleeInCall then
                debugprint(source, "tried to call", data.number, "but they are in call")
                TriggerClientEvent("phone:phone:userBusy", source)
            else
                local phoneExists = MySQL.scalar.await("SELECT TRUE FROM phone_phones WHERE phone_number = ?", {
                    data.number
                }) ~= nil

                if phoneExists then
                    debugprint(source, "tried to call", data.number, "but they are not online, or their phone is dead")
                    TriggerClientEvent("phone:phone:userUnavailable", source)
                else
                    debugprint(source, "tried to call", data.number, "but that number doesn't exist")
                    return "unknown_number"
                end
            end

            return false
        end

        call.callee = {
            source = calleeSource,
            number = data.number,
            nearby = {}
        }

        debugprint(source, "is calling", data.number, "with callId", callId)

        TriggerClientEvent("phone:phone:setCall", calleeSource, {
            callId = callId,
            number = phoneNumber,
            videoCall = data.videoCall,
            webRTC = data.webRTC,
            hideCallerId = data.hideCallerId
        })
    end

    activeCalls[callId] = call
    TriggerEvent("lb-phone:newCall", call)

    return callId
end)

RegisterCallback("answerCall", function(source, callId)
    debugprint("answerCall", source, callId)

    local call = activeCalls[callId]

    if not call then
        debugprint("answerCall: invalid call id")
        return false
    end

    if call.company then
        if call.callee.source then
            debugprint("answerCall: someone else has already answered this company call")
            return false
        end

        local employees = GetEmployees(call.company)

        for i = 1, #employees do
            local employee = employees[i]

            if not IsInCall(employee) and employee ~= source and not disabledCompanyCalls[employee] then
                TriggerClientEvent("phone:phone:endCall", employee, callId)
            end
        end

        call.callee.source = source
    elseif call.callee.source ~= source then
        debugprint("answerCall: invalid callee source")
        return false
    end

    local callerSource = call.caller.source
    local calleeSource = call.callee.source

    if not calleeSource then
        debugprint("answerCall: no callee source")
        return false
    end

    local callerState = callerSource and Player(callerSource).state
    local calleeState = Player(calleeSource).state

    if callerSource then
        callerState.speakerphone = false
        callerState.mutedCall = false
        callerState.onCallWith = calleeSource
        callerState.callAnswered = true
    end

    calleeState.speakerphone = false
    calleeState.mutedCall = false
    calleeState.onCallWith = callerSource or call.caller.number
    calleeState.callAnswered = true

    call.answered = true

    TriggerClientEvent("phone:phone:connectCall", source, callId)

    if callerSource then
        TriggerClientEvent("phone:phone:connectCall", callerSource, callId, call.exportCall == true)
    end

    if Config.Voice.CallEffects and callerSource then
        TriggerClientEvent("phone:phone:setCallEffect", source, callerSource, true)
        TriggerClientEvent("phone:phone:setCallEffect", callerSource, source, true)
    end

    TriggerEvent("lb-phone:callAnswered", call)
    debugprint("answerCall: answered call", callId)

    return true
end)

local function getOtherCallParticipant(call, source)
    if call.caller.source == source and call.callee.source then
        return call.callee.source
    end

    return call.caller.source
end

BaseCallback("requestVideoCall", function(source, phoneNumber, callId, peerId)
    local call = callId and activeCalls[callId]

    if not call then
        debugprint("requestVideoCall: invalid call id", callId, json.encode(activeCalls, { indent = true }))
        return false
    end

    debugprint("requestVideoCall", source, callId, peerId)

    if not call.videoCall and not call.answered then
        return false
    end

    local target = getOtherCallParticipant(call, source)

    call.videoRequested = true

    if target then
        TriggerClientEvent("phone:phone:videoRequested", target, peerId)
    end
end)

BaseCallback("answerVideoRequest", function(source, phoneNumber, callId, accepted)
    local call = callId and activeCalls[callId]

    if not call then
        debugprint("answerVideoRequest: invalid call id")
        return false
    end

    debugprint("answerVideoRequest", source, callId, accepted)

    local target = getOtherCallParticipant(call, source)

    if not call.videoCall and (not call.answered or not call.videoRequested) then
        return false
    end

    call.videoRequested = false
    call.videoCall = accepted == true

    if target then
        TriggerClientEvent("phone:phone:videoRequestAnswered", target, accepted)
    end

    return true
end)

BaseCallback("stopVideoCall", function(source, phoneNumber, callId)
    local call = callId and activeCalls[callId]

    if not call then
        debugprint("stopVideoCall: invalid call id")
        return false
    end

    local target = getOtherCallParticipant(call, source)

    if not call.videoCall or not call.answered then
        return false
    end

    call.videoCall = false

    TriggerClientEvent("phone:phone:stopVideoCall", source)

    if target then
        TriggerClientEvent("phone:phone:stopVideoCall", target)
    end

    return true
end)

function EndCall(source, callback)
    local inCall, callId = IsInCall(source)

    debugprint("^5EndCall^7:", source, inCall, callId)

    if not inCall or not callId or not activeCalls[callId] then
        if callback then
            callback(false)
        end

        debugprint("^5EndCall^7: not in call/invalid callId")
        return false
    end

    local call = activeCalls[callId]
    local callerSource = call.caller.source
    local calleeSource = call.callee.source

    if calleeSource then
        debugprint("^5EndCall^7: ending call for callee", callId, calleeSource)
        TriggerClientEvent("phone:phone:endCall", calleeSource)

        if Config.Voice.CallEffects and callerSource then
            TriggerClientEvent("phone:phone:setCallEffect", calleeSource, callerSource, false)
            TriggerClientEvent("phone:phone:setCallEffect", callerSource, calleeSource, false)
        end
    elseif call.company then
        local employees = GetEmployees(call.company)

        for i = 1, #employees do
            local employee = employees[i]

            if not IsInCall(employee) and not disabledCompanyCalls[employee] then
                TriggerClientEvent("phone:phone:endCall", employee, callId)
            end
        end
    end

    if callerSource then
        debugprint("^5EndCall^7: ending call for caller", callId, callerSource)
        TriggerClientEvent("phone:phone:endCall", callerSource)
    end

    if callerSource and Player(callerSource) then
        local callerState = Player(callerSource).state

        callerState.onCallWith = nil
        callerState.speakerphone = false
        callerState.mutedCall = false
        callerState.callAnswered = false
    end

    if calleeSource and Player(calleeSource) then
        local calleeState = Player(calleeSource).state

        calleeState.onCallWith = nil
        calleeState.speakerphone = false
        calleeState.mutedCall = false
        calleeState.callAnswered = false
    end

    TriggerEvent("lb-phone:callEnded", call, source)

    Log("Calls", call.caller.source, "info", L("BACKEND.LOGS.CALL_ENDED"), L("BACKEND.LOGS.CALL_DESCRIPTION", {
        duration = os.time() - call.started,
        caller = FormatNumber(call.caller.number),
        callee = (call.callee.number and FormatNumber(call.callee.number)) or call.company,
        answered = call.answered
    }))

    if not call.company then
        logCall(
            call.caller.number,
            call.callee.number,
            os.time() - call.started,
            call.answered,
            call.hideCallerId,
            GetEquippedPhoneNumber(source)
        )
    end

    activeCalls[callId] = nil

    if callback then
        callback(true)
    end

    return true
end

exports("EndCall", EndCall)

RegisterNetEvent("phone:endCall", function()
    EndCall(source)
end)

BaseCallback("getRecentVoicemails", function(source, phoneNumber, page)
    return MySQL.query.await([[
        SELECT id, IF(hide_caller_id, null, caller) AS `number`, url, duration, hide_caller_id AS hideCallerId, `timestamp`
        FROM phone_phone_voicemail
        WHERE callee = ?
        ORDER BY `timestamp` DESC
        LIMIT ?, ?
    ]], {
        phoneNumber,
        (page or 0) * 25,
        25
    })
end, {})

BaseCallback("deleteVoiceMail", function(source, phoneNumber, id)
    return MySQL.update.await("DELETE FROM phone_phone_voicemail WHERE id = ? AND callee = ?", {
        id,
        phoneNumber
    }) > 0
end)

BaseCallback("sendVoicemail", function(source, phoneNumber, data)
    MySQL.insert.await("INSERT INTO phone_phone_voicemail (caller, callee, url, duration, hide_caller_id) VALUES (@caller, @callee, @url, @duration, @hideCallerId)", {
        ["@caller"] = phoneNumber,
        ["@callee"] = data.number,
        ["@url"] = data.src,
        ["@duration"] = data.duration,
        ["@hideCallerId"] = data.hideCallerId == true
    })

    SendNotification(data.number, {
        app = "Phone",
        title = L("BACKEND.CALLS.NEW_VOICEMAIL")
    })

    return true
end)

function HasAirplaneMode(phoneNumber)
    debugprint("checking if", phoneNumber, "has airplane mode enabled")

    local settings = GetSettings(phoneNumber)

    if not settings then
        debugprint("no settings found for", phoneNumber)
        return
    end

    return settings.airplaneMode
end

exports("HasAirplaneMode", HasAirplaneMode)

exports("CreateCall", function(caller, calleeNumber, options)
    options = options or {}

    local callerSource = type(caller) == "table" and caller.source or nil
    local callerNumber = type(caller) == "string" and caller or caller.phoneNumber

    if callerSource then
        if not GetPlayerName(callerSource) then
            return debugprint("CreateCall: callerSrc is not a valid player")
        end

        if options.requirePhone then
            if IsPhoneDead(callerNumber) or not HasPhoneItem(callerSource, callerNumber) then
                return debugprint("CreateCall: caller does not have a phone")
            end
        end

        if IsInCall(callerSource) then
            return debugprint("CreateCall: caller is already in a call")
        end
    end

    if not options.company and not calleeNumber then
        return debugprint("CreateCall: no callee or company provided")
    end

    local callId = generateCallId()
    local call = {
        started = os.time(),
        answered = false,
        videoCall = false,
        hideCallerId = options.hideNumber == true,
        callId = callId,
        caller = {
            source = callerSource,
            number = callerNumber,
            nearby = {}
        },
        exportCall = true
    }

    if options.company then
        if not Config.Companies.Enabled then
            return debugprint("company calls are disabled in config")
        end

        local validCompany, companyLabel = companyExists(options.company)

        if not validCompany then
            return debugprint("invalid company")
        end

        call.company = options.company
        call.callee = {
            nearby = {}
        }

        local employees = GetEmployees(options.company)

        for i = 1, #employees do
            local employee = employees[i]

            if not IsInCall(employee) and employee ~= callerSource and not disabledCompanyCalls[employee] then
                TriggerClientEvent("phone:phone:setCall", employee, {
                    callId = callId,
                    number = callerNumber,
                    company = options.company,
                    companylabel = companyLabel
                })
            end
        end
    elseif calleeNumber then
        local calleeSource = GetSourceFromNumber(calleeNumber)

        if not calleeSource then
            return debugprint("CreateCall: calleeSrc is not a valid player")
        end

        if IsInCall(calleeSource) then
            return debugprint("CreateCall: caller or callee is in call")
        end

        call.callee = {
            source = calleeSource,
            number = calleeNumber,
            nearby = {}
        }

        TriggerClientEvent("phone:phone:setCall", calleeSource, {
            callId = callId,
            number = callerNumber,
            hideCallerId = options.hideNumber == true
        })
    end

    activeCalls[callId] = call
    TriggerEvent("lb-phone:newCall", call)

    if callerSource then
        TriggerClientEvent("phone:phone:enableExportCall", callerSource)
    end

    return callId
end)

exports("AddContact", function(phoneNumber, data)
    assert(type(phoneNumber) == "string", "phoneNumber must be a string")
    assert(type(data) == "table", "data must be a table")

    local success = CreateContact(phoneNumber, data)

    debugprint("AddContact: success", success)

    local source = GetSourceFromNumber(phoneNumber)

    if source and success then
        TriggerClientEvent("phone:phone:contactAdded", source, data)
    end
end)

AddEventHandler("playerDropped", function()
    local source = source

    disabledCompanyCalls[source] = nil
    EndCall(source)
end)
