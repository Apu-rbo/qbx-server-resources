-- ============================================================
-- Deobfuscated "Tinder" (Spark) NUI callback handler for FiveM
-- ============================================================

local callbackActions       -- table of action names that require interaction check
local createAccountName     -- "createAccount"
local saveProfileName       -- "saveProfile"
local sendMessageName       -- "sendMessage"

callbackActions = {}
createAccountName = "createAccount"
saveProfileName = "saveProfile"
sendMessageName = "sendMessage"

callbackActions[1] = createAccountName
callbackActions[2] = saveProfileName
callbackActions[3] = sendMessageName

-- ------------------------------------------------------------
-- getMatchesOrMessages(isRecentMessages, page)
--
-- Fetches matches from the server ("spark:getMatches") and
-- reformats each match's data into a cleaner table for the NUI.
-- ------------------------------------------------------------
function getMatchesOrMessages(isRecentMessages, page)
    local rawMatches
    local formattedMatches
    local i
    local rawMatch
    local match
    local value

    rawMatches = AwaitCallback("spark:getMatches", isRecentMessages, page)

    formattedMatches = {}

    for i = 1, #rawMatches, 1 do
        rawMatch = rawMatches[i]
        match = {}

        -- Basic profile info
        value = rawMatch.name
        match.name = value

        value = rawMatch.phone_number
        match.number = value

        -- Decode photos JSON array
        value = json.decode(rawMatch.photos)
        match.photos = value

        value = rawMatch.dob
        match.dob = value

        value = rawMatch.bio
        match.bio = value

        value = rawMatch.is_male
        match.isMale = value

        value = rawMatch.latest_message_timestamp
        match.timestamp = value

        -- Convert "unread" to a real boolean
        value = rawMatch.unread
        value = (true == value)
        match.unread = value

        -- If there's a latest message, include it and its sender
        value = rawMatch.latest_message
        if value then
            value = rawMatch.latest_message
            match.lastMessage = value

            value = rawMatch.latest_sender
            match.lastSender = value
        end

        formattedMatches[i] = match
    end

    return formattedMatches
end

-- ------------------------------------------------------------
-- Main NUI callback handler for the "Tinder" app
-- ------------------------------------------------------------
RegisterNUICallback("Tinder", function(data, cb)
    local phone
    local action
    local logMessage
    local actionLogText
    local isCallbackAction
    local result
    local feed
    local i
    local rawEntry
    local formattedEntry
    local value
    local messages
    local attachments

    -- Make sure the player currently has a phone instance
    phone = currentPhone
    if not phone then
        return
    end

    action = data.action

    -- Debug log the action being processed
    actionLogText = "Spark:"
    actionLogText = actionLogText .. (action or "")
    debugprint(actionLogText)

    -- Check if this action requires the player to be able to interact
    isCallbackAction = table.contains(callbackActions, action)
    if isCallbackAction then
        if not CanInteract() then
            return cb(false)
        end
    end

    if "createAccount" == action then
        -- Create a new Spark/Tinder account
        return TriggerCallback("spark:createAccount", cb, data.data)

    elseif "deleteAccount" == action then
        -- Delete the player's Spark account
        return TriggerCallback("spark:deleteAccount", cb)

    elseif "saveProfile" == action then
        -- Update/save the player's profile data
        return TriggerCallback("spark:updateAccount", cb, data.data)

    elseif "isLoggedIn" == action then
        -- Check if the given phone number is logged in to Spark
        result = AwaitCallback("spark:isLoggedIn", data.phoneNumber)
        return cb(result or false)

    elseif "getFeed" == action then
        -- Fetch the swipe feed for the given page
        feed = AwaitCallback("spark:getFeed", data.page)

        result = {}
        for i = 1, #feed, 1 do
            rawEntry = feed[i]
            formattedEntry = {}

            value = rawEntry.name
            formattedEntry.name = value

            value = rawEntry.dob
            formattedEntry.dob = value

            value = rawEntry.bio
            formattedEntry.bio = value

            -- Decode photos JSON array
            value = json.decode(rawEntry.photos)
            formattedEntry.photos = value

            value = rawEntry.phone_number
            formattedEntry.number = value

            result[i] = formattedEntry
        end

        cb(result)

    elseif "swipe" == action then
        -- Send a swipe (like/dislike) on a given number
        TriggerCallback("spark:swipe", cb, data.number, data.like)

    elseif "getNewMatchesCount" == action then
        -- Get the count of new (unseen) matches
        TriggerCallback("spark:getNewMatchesCount", cb)

    elseif "getMatches" == action then
        -- Get all matches (isRecentMessages = false)
        return cb(getMatchesOrMessages(false, data.page))

    elseif "getRecentMessages" == action then
        -- Get matches sorted/filtered by recent messages (isRecentMessages = true)
        return cb(getMatchesOrMessages(true, data.page))

    elseif "sendMessage" == action then
        -- Send a chat message, optionally with attachments
        data = data.data

        -- Normalize attachments: if it's a table but empty, remove it entirely
        if "table" == type(data.attachments) then
            if 0 ~= #data.attachments then
                goto lbl_150
            end
        end
        data.attachments = nil
        ::lbl_150::

        attachments = data.attachments
        if attachments then
            attachments = data.attachments
        end

        TriggerCallback("spark:sendMessage", cb, data.recipient, data.content, attachments)

    elseif "getMessages" == action then
        -- Get message history with a given number, after lastId
        messages = AwaitCallback("spark:getMessages", data.number, data.lastId)

        -- Decode attachments JSON for each message, or default to empty table
        for i = 1, #messages, 1 do
            if messages[i].attachments then
                messages[i].attachments = json.decode(messages[i].attachments)
            else
                messages[i].attachments = {}
            end
        end

        cb(messages)

    elseif "markAsRead" == action then
        -- Mark conversation with a number as read
        TriggerCallback("spark:markAsRead", cb, data.number)
    end
end)

-- ------------------------------------------------------------
-- Net event: incoming new message from the server
-- Forwards the message to the NUI as "tinder:newMessage"
-- ------------------------------------------------------------
RegisterNetEvent("phone:spark:newMessage", function(messageData)
    local attachments

    attachments = messageData.attachments
    if not attachments then
        attachments = {}
    end
    messageData.attachments = attachments

    SendNUIAction("tinder:newMessage", messageData)
end)