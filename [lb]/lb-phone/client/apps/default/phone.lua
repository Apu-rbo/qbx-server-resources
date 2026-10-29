InExportCall = false

local isVideoCall = false
local inCall = false
local currentCallId = nil
local customNumbers = {}
local currentCustomCall = nil
local customCallStartedAt = 0
local customCallAnswered = false
local dynamicCustomNumbers = {}
local dynamicCustomNumberId = 0


local function endCustomCall()
    debugprint("EndCustomCall triggered")

    if currentCustomCall then
        local duration = math.floor((GetGameTimer() - customCallStartedAt) / 1000 + 0.5)

        debugprint(
            "Custom call to",
            currentCustomCall.number,
            "ended after",
            duration,
            "seconds",
            "answered:",
            customCallAnswered
        )

        TriggerServerEvent("phone:logCall", currentCustomCall.number, duration)
    end

    inCall = false
    currentCustomCall = nil
    currentCallId = nil
    customCallStartedAt = 0
    customCallAnswered = false

    SetPhoneAction("default")
    SendNUIAction("call:endCall")

    if not phoneOpen then
        PlayCloseAnim()
    end
end

local function startCustomNumberCall(number)
    local customNumber = customNumbers[number]

    if not customNumber then
        for id, dynamicNumber in pairs(dynamicCustomNumbers) do
            local ok, valid = pcall(function()
                return dynamicNumber.isValid(number)
            end)

            if ok and valid then
                customNumber = dynamicNumber.customNumber
                break
            elseif not ok then
                local stackTrace = Citizen.InvokeNative(3607903178, nil, 0, Citizen.ResultAsString())

                print(([[
^1SCRIPT ERROR: Dynamic number validator (id %i, by resource '%s') failed: %s^7
%s]]):format(id, dynamicNumber.resource, valid or "", stackTrace or ""))
            end
        end
    end

    if not customNumber then
        return false
    end

    local callId = "CUSTOM_NUMBER_" .. math.random(9999999)

    inCall = true
    currentCallId = callId
    currentCustomCall = customNumber
    customCallStartedAt = GetGameTimer()
    customCallAnswered = false

    Citizen.CreateThreadNow(function()
        customNumber.onCall({
            id = callId,
            number = number,
            accept = function()
                if customCallAnswered or currentCallId ~= callId then
                    return
                end

                customCallAnswered = true
                SetPhoneAction("call")
                SendNUIAction("call:connected")
            end,
            deny = function()
                if currentCallId == callId then
                    endCustomCall()
                end
            end,
            setName = function(name)
                if currentCallId == callId then
                    SendNUIAction("call:setContactData", {
                        name = name
                    })
                end
            end,
            hasEnded = function()
                return currentCallId ~= callId
            end
        })
    end)

    return true
end

local function handleCustomCallAction(action)
    if not currentCustomCall then
        return
    end

    if action == "end" then
        if currentCustomCall.onEnd then
            Citizen.CreateThreadNow(currentCustomCall.onEnd)
        end

        endCustomCall()
        return
    end

    if action:find("keypad_") then
        if not currentCustomCall.onKeypad then
            return
        end

        local key = action:sub(8)

        if not key then
            return
        end

        Citizen.CreateThreadNow(function()
            currentCustomCall.onKeypad(key)
        end)

        return
    end

    if currentCustomCall.onAction then
        currentCustomCall.onAction(action)
    end
end


RegisterNUICallback("Phone", function(data, callback)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("Phone:" .. (action or ""))

    if action == "getContacts" then
        TriggerCallback("getContacts", function(contacts)
            if Config.Companies.Enabled then
                for company, companyData in pairs(Config.Companies.Contacts) do
                    contacts[#contacts + 1] = {
                        firstname = companyData.name,
                        avatar = companyData.photo,
                        company = company
                    }
                end
            end

            callback(contacts)
        end)
    elseif action == "toggleFavourite" then
        TriggerCallback("toggleFavourite", callback, data.number, data.favourite)
    elseif action == "toggleBlock" then
        TriggerCallback("toggleBlock", callback, data.number, data.blocked)
    elseif action == "removeContact" then
        TriggerCallback("removeContact", callback, data.number)
    elseif action == "updateContact" then
        TriggerCallback("updateContact", callback, data.data)
    elseif action == "saveContact" then
        TriggerCallback("saveContact", callback, data.data)
    elseif action == "getRecent" then
        TriggerCallback("getRecentCalls", callback, data.missed == true, data.lastId)
    elseif action == "getBlockedNumbers" then
        TriggerCallback("getBlockedNumbers", function(blockedContacts)
            local blockedNumbers = {}

            for index, contact in pairs(blockedContacts) do
                blockedNumbers[index] = contact.number
            end

            callback(blockedNumbers)
        end)
    elseif action == "toggleMute" then
        if not currentCallId then
            return callback(false)
        end

        if currentCustomCall then
            handleCustomCallAction(data.toggle and "mute" or "unmute")
            return callback(data.toggle)
        end

        SetCallMuted(data.toggle, currentCallId)
        callback(data.toggle)
    elseif action == "toggleSpeaker" then
        if not currentCallId then
            return callback(false)
        end

        if currentCustomCall then
            handleCustomCallAction(data.toggle and "enable_speaker" or "disable_speaker")
            return callback(data.toggle)
        end

        TriggerServerEvent("phone:phone:toggleSpeaker", data.toggle)
        ToggleSpeaker(data.toggle)
        callback(data.toggle)
    elseif action == "sendVoicemail" then
        TriggerCallback("sendVoicemail", callback, data.data)
    elseif action == "getVoiceMails" then
        TriggerCallback("getRecentVoicemails", callback, data.page)
    elseif action == "deleteVoiceMail" then
        TriggerCallback("deleteVoiceMail", callback, data.id)
    elseif action == "keypad" then
        callback("ok")

        if currentCustomCall then
            handleCustomCallAction("keypad_" .. data.key)
        end
    end

    if action == "call" then
        if data.company then
            if not Config.Companies.Enabled or data.videoCall then
                return callback(false)
            end

            if not Config.Companies.Contacts[data.company] then
                local companyExists = false

                for i = 1, #Config.Companies.Services do
                    if Config.Companies.Services[i].job == data.company then
                        companyExists = true
                        break
                    end
                end

                if not companyExists then
                    return callback(false)
                end
            end
        end

        isVideoCall = data.videoCall

        local response = AwaitCallback("call", data)

        if response == "unknown_number" then
            if startCustomNumberCall(data.number) then
                return callback("CUSTOM_NUMBER")
            end

            SendNUIAction("call:userUnavailable")
            return callback(false)
        end

        return callback(response)
    elseif action == "answerCall" then
        if IsInCall() then
            debugprint("answerCall: Already in call")
            return
        end

        if IsLive() then
            debugprint("answerCall: Ending live")
            TriggerCallback("instagram:endLive")
        elseif IsWatchingLive() then
            debugprint("answerCall: Leaving live")
            SendNUIAction("instagram:liveEnded", IsWatchingLive())
        end

        debugprint("Answering call", data.callId)
        TriggerServerEvent("phone:sound:stopSound")
        TriggerCallback("answerCall", callback, data.callId)
        callback("ok")
    elseif action == "endCall" then
        EndCall()
        callback("ok")
    elseif action == "flipCamera" then
        ToggleSelfieCam(not IsSelfieCam())
    elseif action == "requestVideoCall" then
        TriggerCallback("requestVideoCall", callback, data.callId, data.peerId)
    elseif action == "answerVideoRequest" then
        TriggerCallback("answerVideoRequest", callback, data.callId, data.accept)

        if data.accept then
            isVideoCall = true
            EnableWalkableCam()
        end
    elseif action == "stopVideoCall" then
        TriggerCallback("stopVideoCall", callback, data.callId)
    elseif action == "stopRingtone" then
        StopPhoneSound()
    end
end)


function EndCall()
    TriggerServerEvent("phone:sound:stopSound")
    TriggerServerEvent("phone:endCall")

    if currentCustomCall then
        handleCustomCallAction("end")
    end
end

RegisterNetEvent("phone:phone:setCall", function(callData)
    if not HasPhoneItem(currentPhone) then
        debugprint("no phone, not showing call")
        return
    end

    if phoneDisabled then
        debugprint("phone is disabled, not showing call")
        return
    end

    if IsPhoneDead() then
        debugprint("phone is dead, not showing call")
        return
    end

    if currentCustomCall or inCall then
        debugprint("in a (custom?) call", tostring(currentCustomCall), tostring(inCall))
        return
    end

    if IsPedDeadOrDying(PlayerPedId(), false) then
        debugprint("player is dead, not showing call")
        return
    elseif CanOpenPhone and not CanOpenPhone() then
        debugprint("can't open phone, not showing call")
        return
    end

    isVideoCall = callData.videoCall

    local ringtone = nil

    if not callData.hideCallerId and settings and settings.sound and settings.sound.ringtones and callData.number then
        ringtone = settings.sound.ringtones[callData.number]
    end

    PlayPhoneSound("ringtone", ringtone)
    SendNUIAction("incomingCall", callData)
end)

RegisterNetEvent("phone:phone:enableExportCall", function()
    InExportCall = true
end)

RegisterNetEvent("phone:phone:connectCall", function(callId, skipUi)
    debugprint("phone:phone:connectCall", callId, skipUi)

    inCall = true
    currentCallId = callId
    AddToCall(callId)

    if skipUi then
        return
    end

    StopPhoneSound()
    SetPhoneAction("call")
    SendNUIAction("call:connected")

    if isVideoCall then
        EnableWalkableCam()
    end
end)

RegisterNetEvent("phone:phone:endCall", function()
    debugprint("phone:phone:endCall")

    local wasInCall = inCall

    inCall = false
    isVideoCall = false

    SetPhoneAction("default")
    DisableWalkableCam()

    if not phoneOpen and wasInCall then
        debugprint("close anim")
        PlayCloseAnim()
    end

    StopPhoneSound()
    RemoveFromCall(currentCallId)

    currentCallId = nil
    InExportCall = false

    TriggerServerEvent("phone:sound:stopSound")
    SendNUIAction("call:endCall")
end)

RegisterNetEvent("phone:phone:userUnavailable", function()
    debugprint("phone:phone:userUnavailable")
    SendNUIAction("call:userUnavailable")
end)

RegisterNetEvent("phone:phone:userBusy", function()
    debugprint("phone:phone:userBusy")
    SendNUIAction("call:userBusy")
end)


function IsInCall()
    return inCall
end

exports("IsInCall", IsInCall)

exports("AddContact", function(contact)
    assert(type(contact) == "table", "contact must be a table")
    assert(type(contact.number) == "string", "contact.number must be a string")
    assert(type(contact.firstname) == "string", "contact.firstname must be a string")

    local saved = AwaitCallback("saveContact", contact)

    if saved then
        SendNUIAction("phone:contactAdded", contact)
    end

    return saved
end)

exports("UpdateContact", function(contact)
    assert(type(contact) == "table", "contact must be a table")
    assert(type(contact.number) == "string", "contact.number must be a string")
    assert(type(contact.firstname) == "string", "contact.firstname must be a string")

    local updatedContact = table.clone(contact)

    updatedContact.oldNumber = updatedContact.oldNumber or updatedContact.number

    TriggerCallback("updateContact", nil, updatedContact)
    SendNUIAction("phone:contactUpdated", contact)

    return true
end)

exports("RemoveContact", function(phoneNumber)
    assert(type(phoneNumber) == "string", "phoneNumber must be a string")

    TriggerCallback("removeContact", nil, phoneNumber)
    SendNUIAction("phone:contactRemoved", phoneNumber)

    return true
end)

RegisterNetEvent("phone:phone:videoRequested", function(data)
    debugprint("phone:phone:videoRequested", data)
    SendNUIAction("call:videoRequested", data)
end)

RegisterNetEvent("phone:phone:videoRequestAnswered", function(accepted)
    debugprint("phone:phone:videoRequestAnswered", accepted)
    SendNUIAction("call:videoRequestAnswered", accepted)

    if accepted then
        isVideoCall = true
        EnableWalkableCam()
    end
end)

RegisterNetEvent("phone:phone:stopVideoCall", function()
    debugprint("phone:phone:stopVideoCall")
    SendNUIAction("call:stopVideoCall")

    isVideoCall = false
    DisableWalkableCam()
end)

RegisterNetEvent("phone:phone:contactAdded", function(contact)
    debugprint("phone:phone:contactAdded", contact)
    SendNUIAction("phone:contactAdded", contact)
end)


function CreateCall(options)
    assert(type(options) == "table", "options must be a table")
    assert(options.number or options.company, "options must contain either a number or company")

    if not currentPhone then
        return debugprint("no phone")
    end

    if options.hideNumber == nil then
        local showCallerId = settings and settings.phone and settings.phone.showCallerId

        if showCallerId == false then
            options.hideNumber = true
        end
    end

    if options.company then
        if not Config.Companies.Enabled then
            return debugprint("company calls are disabled in config")
        end

        local validCompany = false
        local companyLabel = options.company
        local companyContact = Config.Companies.Contacts[options.company]

        if companyContact then
            companyLabel = companyContact.name
            validCompany = true
        else
            for i = 1, #Config.Companies.Services do
                local service = Config.Companies.Services[i]

                if service.job == options.company then
                    validCompany = true
                    companyLabel = service.name
                    break
                end
            end
        end

        if not validCompany then
            return debugprint("invalid company")
        end

        debugprint("CreateCall: company", options)

        SendNUIAction("call", {
            company = options.company,
            companylabel = companyLabel,
            hideCallerId = options.hideNumber == true
        })
    else
        debugprint("CreateCall: number", options)

        SendNUIAction("call", {
            number = options.number,
            videoCall = options.videoCall == true,
            hideCallerId = options.hideNumber == true
        })
    end
end

exports("CreateCall", CreateCall)

exports("CreateCustomNumber", function(number, data)
    local resource = GetInvokingResource()

    assert(type(number) == "string", "number must be a string")
    assert(type(data) == "table", "data must be a table")
    assert(type(data.onCall) == "function", "data.onCall must be a function")

    if customNumbers[number] then
        return false, "Number already exists"
    end

    customNumbers[number] = {
        resource = resource,
        number = number,
        onCall = data.onCall,
        onEnd = data.onEnd,
        onAction = data.onAction,
        onKeypad = data.onKeypad
    }

    return true
end)

exports("RemoveCustomNumber", function(number)
    local resource = GetInvokingResource()

    assert(type(number) == "string", "number must be a string")

    if not customNumbers[number] then
        return false, "Number does not exist"
    end

    if customNumbers[number].resource ~= resource then
        return false, "Number was not created by " .. resource
    end

    customNumbers[number] = nil

    return true
end)

exports("EndCustomCall", function()
    if currentCustomCall then
        endCustomCall()
        return true
    end

    return false
end)

exports("CreateDynamicCustomNumber", function(validator, data)
    local resource = GetInvokingResource()

    assert(type(validator) == "function", "validator must be a function")
    assert(type(data) == "table", "data must be a table")
    assert(type(data.onCall) == "function", "data.onCall must be a function")

    dynamicCustomNumberId = dynamicCustomNumberId + 1

    dynamicCustomNumbers[dynamicCustomNumberId] = {
        isValid = validator,
        customNumber = data,
        resource = resource
    }

    return dynamicCustomNumberId
end)

exports("RemoveDynamicCustomNumber", function(id)
    local resource = GetInvokingResource()

    assert(type(id) == "number", "id must be a number")

    local dynamicNumber = dynamicCustomNumbers[id]

    if not dynamicNumber then
        return false, "Dynamic number does not exist"
    end

    if dynamicNumber.resource ~= resource then
        return false, "Dynamic number was not created by " .. resource
    end

    dynamicCustomNumbers[id] = nil

    return true
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName == GetCurrentResourceName() then
        return
    end

    for number, customNumber in pairs(customNumbers) do
        if customNumber.resource == resourceName then
            debugprint("Removed custom number", number, "due to resource stopping")

            if currentCustomCall == customNumber then
                handleCustomCallAction("end")
            end

            customNumbers[number] = nil
        end
    end

    for id, dynamicNumber in pairs(dynamicCustomNumbers) do
        if dynamicNumber.resource == resourceName then
            debugprint("Removed dynamic custom number id", id, "due to resource stopping")
            dynamicCustomNumbers[id] = nil
        end
    end
end)
