-- ─── Per-player account cache ─────────────────────────────────────────────────
-- Key   : player server-id (source)
-- Value : account table { phoneNumber, name, photos, bio, dob, isMale,
--                         showMen, showWomen, active }
local accountCache = {}

-- ============================================================
-- GetOrFetchAccount(source, phoneNumber)
-- Returns the Spark account for the given player source and
-- phone number.  Uses the in-memory cache when possible;
-- otherwise queries the database and populates the cache.
-- Also updates the account's last_seen timestamp on DB load.
--
-- Returns nil if no account exists for that phone number.
-- ============================================================
local function GetOrFetchAccount(source, phoneNumber)
    -- Cache hit: only valid if the cached entry belongs to this phone number
    local cached = accountCache[source]
    if cached and cached.phoneNumber == phoneNumber then
        return cached
    end

    -- Cache miss: query the database
    local row = MySQL.single.await(
        "SELECT `name`, photos, bio, dob, is_male, interested_men, interested_women, `active` FROM phone_tinder_accounts WHERE phone_number = ?",
        { phoneNumber }
    )

    if not row then
        return nil
    end

    -- Update last_seen timestamp (fire-and-forget)
    MySQL.update.await(
        "UPDATE phone_tinder_accounts SET last_seen = NOW() WHERE phone_number = ?",
        { phoneNumber }
    )

    -- Build and cache the account object
    accountCache[source] = {
        phoneNumber  = phoneNumber,
        name         = row.name,
        photos       = json.decode(row.photos),
        bio          = row.bio,
        dob          = row.dob,
        isMale       = row.is_male,
        showMen      = row.interested_men,
        showWomen    = row.interested_women,
        active       = row.active,
    }

    return accountCache[source]
end

-- ============================================================
-- RegisterAccountCallback(callbackName, handler, defaultReturn)
-- Convenience wrapper around BaseCallback that:
--   1. Prefixes the callback name with "spark:"
--   2. Verifies the caller's cached account matches their
--      current phone number before invoking the handler.
--   3. Returns defaultReturn immediately when the account
--      check fails (unauthenticated / mismatched number).
--
-- The wrapped handler receives:
--   (source, phoneNumber, account, ...)
-- where account is the validated cached account object.
-- ============================================================
local function RegisterAccountCallback(callbackName, handler, defaultReturn)
    BaseCallback("spark:" .. callbackName, function(source, phoneNumber, ...)
        -- Auth check: the cache entry must exist AND match the caller's number
        local account = accountCache[source]
        if not account or account.phoneNumber ~= phoneNumber then
            return defaultReturn
        end

        return handler(source, phoneNumber, account, ...)
    end, defaultReturn)
end

-- ============================================================
-- CALLBACK: spark:createAccount
-- Creates a new Spark (Tinder) account for the calling player.
-- Returns false if the account already exists or the INSERT fails.
-- Returns true on success.
-- ============================================================
BaseCallback("spark:createAccount", function(source, phoneNumber, accountData)
    -- Reject if an account already exists for this phone number
    local exists = MySQL.scalar.await(
        "SELECT TRUE FROM phone_tinder_accounts WHERE phone_number = ?",
        { phoneNumber }
    )
    if exists then
        return false
    end

    -- Insert the new account row
    local rowsAffected = MySQL.update.await([[
        INSERT INTO phone_tinder_accounts
            (`name`, phone_number, photos, bio, dob, is_male, interested_men, interested_women)
        VALUES
            (@name, @phoneNumber, @photos, @bio, @dob, @isMale, @showMen, @showWomen)
    ]], {
        name        = accountData.name,
        phoneNumber = phoneNumber,
        photos      = json.encode(accountData.photos),
        bio         = accountData.bio,
        dob         = accountData.dob,
        isMale      = accountData.isMale,
        showMen     = accountData.showMen,
        showWomen   = accountData.showWomen,
    })

    local success = rowsAffected > 0

    -- Populate the cache immediately so subsequent callbacks don't need a DB round-trip
    accountCache[source] = {
        name        = accountData.name,
        phoneNumber = phoneNumber,
        photos      = accountData.photos,
        bio         = accountData.bio,
        dob         = accountData.dob,
        isMale      = accountData.isMale,
        showMen     = accountData.showMen,
        showWomen   = accountData.showWomen,
        active      = true,
    }

    return success
end, false)

-- ============================================================
-- CALLBACK: spark:deleteAccount
-- Deletes the player's Spark account and all associated data
-- (swipes, matches, messages).
-- Respects the Config.DeleteAccount.Spark flag.
-- Returns false if deletion is disabled or no rows were deleted.
-- Returns true on success.
-- ============================================================
BaseCallback("spark:deleteAccount", function(source, phoneNumber)
    -- Feature gate: must be enabled in config
    if not Config.DeleteAccount or not Config.DeleteAccount.Spark then
        infoprint("warning", ("%%s tried to delete their spark account, but it's not enabled in the config."):format(source))
        return false
    end

    -- Delete the account row
    local rowsAffected = MySQL.update.await(
        "DELETE FROM phone_tinder_accounts WHERE phone_number = ?",
        { phoneNumber }
    )

    if rowsAffected <= 0 then
        return false
    end

    -- Cascade-delete all related data (fire-and-forget; no await needed)
    MySQL.update(
        "DELETE FROM phone_tinder_swipes WHERE swiper = ? OR swipee = ?",
        { phoneNumber, phoneNumber }
    )

    MySQL.update(
        "DELETE FROM phone_tinder_matches WHERE phone_number_1 = ? OR phone_number_2 = ?",
        { phoneNumber, phoneNumber }
    )

    MySQL.update(
        "DELETE FROM phone_tinder_messages WHERE sender = ? OR recipient = ?",
        { phoneNumber, phoneNumber }
    )

    return true
end)

-- ============================================================
-- ACCOUNT CALLBACK: spark:updateAccount   (auth-gated)
-- Merges the provided field updates into the cached account
-- and persists them to the database.
-- Returns true if at least one row was updated.
-- ============================================================
RegisterAccountCallback("updateAccount", function(source, phoneNumber, account, updates)
    -- Merge only keys that already exist in the account object
    for key in pairs(account) do
        if updates[key] ~= nil then
            account[key] = updates[key]
        end
    end

    -- Persist to database
    local rowsAffected = MySQL.update.await([[
        UPDATE phone_tinder_accounts
        SET
            `name`=@name,
            photos=@photos,
            bio=@bio,
            is_male=@isMale,
            interested_men=@showMen,
            interested_women=@showWomen,
            `active`=@active
        WHERE phone_number=@phoneNumber
    ]], {
        name        = updates.name,
        photos      = json.encode(updates.photos),
        bio         = updates.bio,
        isMale      = updates.isMale,
        showMen     = updates.showMen,
        showWomen   = updates.showWomen,
        active      = updates.active,
        phoneNumber = phoneNumber,
    })

    return rowsAffected > 0
end, false)

-- ============================================================
-- CALLBACK: spark:isLoggedIn
-- Returns the cached account object if the player is logged in,
-- or nil/false if they are not.
-- Used by the NUI to check auth state on page load.
-- ============================================================
BaseCallback("spark:isLoggedIn", function(source, phoneNumber)
    return GetOrFetchAccount(source, phoneNumber)
end, false)

-- ============================================================
-- CALLBACK: spark:getFeed
-- Returns a paginated list of potential matches for the player.
--
-- The query filters profiles by:
--   - Not the calling player
--   - Account is active
--   - Gender interest is mutually compatible
--   - The calling player has not already swiped on this profile
--
-- Pagination: 10 profiles per page, page index is zero-based.
-- ============================================================
BaseCallback("spark:getFeed", function(source, phoneNumber, pageIndex)
    local page = (pageIndex or 0) * 10

    return MySQL.query.await([[
        SELECT
            a.`name`, a.phone_number, a.photos, a.bio, a.dob
        FROM
            phone_tinder_accounts a

        JOIN
            phone_tinder_accounts b
        ON
            b.phone_number = @phoneNumber

        WHERE
            a.phone_number != @phoneNumber
            AND a.`active` = 1
            AND (a.is_male = b.interested_men OR a.is_male=(NOT b.interested_women))
            AND (a.interested_men=b.is_male OR a.interested_women=(NOT b.is_male))
            AND NOT EXISTS (SELECT TRUE FROM phone_tinder_swipes WHERE swiper = @phoneNumber AND swipee = a.phone_number)

        ORDER BY a.phone_number

        LIMIT @page, @perPage
    ]], {
        phoneNumber = phoneNumber,
        page        = page,
        perPage     = 10,
    })
end, {})

-- ============================================================
-- ACCOUNT CALLBACK: spark:swipe   (auth-gated)
-- Records a swipe (like or dislike) and handles match creation.
--
-- Arguments:
--   source      – calling player's server id
--   phoneNumber – caller's phone number
--   account     – caller's cached account object
--   targetNumber – phone number of the profile being swiped
--   liked        – true = right swipe (like), false = left swipe (dislike)
--
-- Returns true  if a new match was created.
-- Returns false if the swipe was a dislike, or no mutual like yet.
-- ============================================================
RegisterAccountCallback("swipe", function(source, phoneNumber, account, targetNumber, liked)
    -- Record the swipe (upsert so the player can change their mind)
    local result = MySQL.query.await(
        "INSERT INTO phone_tinder_swipes (swiper, swipee, liked) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE liked = ?",
        { phoneNumber, targetNumber, liked, liked }
    )

    -- No rows changed, or this was a dislike → no match possible
    if result == 0 or not liked then
        return false
    end

    -- Check whether the other person has already liked the caller back
    local theyLikedUs = MySQL.scalar.await(
        "SELECT liked FROM phone_tinder_swipes WHERE swiper = ? AND swipee = ?",
        { targetNumber, phoneNumber }
    )

    theyLikedUs = (theyLikedUs == true)

    if not theyLikedUs then
        return false
    end

    -- Mutual like confirmed → check if a match row already exists
    local matchExists = MySQL.scalar.await([[
        SELECT TRUE
        FROM phone_tinder_matches
        WHERE
            (phone_number_1 = @phoneNumber AND phone_number_2 = @number)
            OR (phone_number_2 = @phoneNumber AND phone_number_1 = @number)
    ]], {
        phoneNumber = phoneNumber,
        number      = targetNumber,
    })

    if not matchExists then
        -- Create the match row
        MySQL.update.await(
            "INSERT INTO phone_tinder_matches (phone_number_1, phone_number_2) VALUES (?, ?)",
            { phoneNumber, targetNumber }
        )

        -- Send a push notification to the other player
        SendNotification(targetNumber, {
            app       = "Tinder",
            title     = L("BACKEND.TINDER.NEW_MATCH"),
            content   = L("BACKEND.TINDER.MATCHED_WITH", { name = account.name }),
            thumbnail = account.photos[1],
        })
    end

    return true
end)

-- ============================================================
-- CALLBACK: spark:getNewMatchesCount
-- Returns the number of matches that have no messages yet
-- (i.e. brand-new matches the player hasn't interacted with).
-- ============================================================
BaseCallback("spark:getNewMatchesCount", function(source, phoneNumber)
    local count = MySQL.scalar.await([[
        SELECT COUNT(*) FROM phone_tinder_matches
        WHERE
            (
                (phone_number_1 = @phoneNumber)
                OR (phone_number_2 = @phoneNumber)
            )
            AND latest_message IS NULL
    ]], { phoneNumber = phoneNumber })

    return count or 0
end)

-- ============================================================
-- CALLBACK: spark:getMatches
-- Returns paginated match list for the player.
--
-- Arguments:
--   phoneNumber   – caller's phone number
--   withMessages  – true  → return matches that have messages
--                   false → return new (message-less) matches
--   pageIndex     – zero-based page number (25 per page)
--
-- Returns a list of match rows joined with account profile data
-- and the latest-message metadata.
-- ============================================================
BaseCallback("spark:getMatches", function(source, phoneNumber, withMessages, pageIndex)
    -- Dynamically inject the NULL / NOT NULL clause
    local messagesClause = withMessages and "IS NOT NULL" or "IS NULL"

    local query = ([[
        SELECT
            `account`.`name`,
            `account`.phone_number,
            `account`.photos,
            `account`.dob,
            `account`.bio,
            `account`.is_male,

            `match`.latest_sender,
            `match`.latest_message,
            `match`.latest_message_timestamp,

            CASE
                WHEN `match`.phone_number_1 = @phoneNumber THEN `match`.phone_number_1_has_unread
                ELSE `match`.phone_number_2_has_unread
            END as unread
        FROM
            phone_tinder_accounts `account`

        JOIN
            phone_tinder_matches `match`
        ON
            (
                `match`.phone_number_1 = @phoneNumber
                AND `match`.phone_number_2 = `account`.phone_number
            )
            OR
            (
                `match`.phone_number_2 = @phoneNumber
                AND `match`.phone_number_1 = `account`.phone_number
            )

        WHERE latest_message {MESSAGES}

        ORDER BY `match`.latest_message_timestamp DESC

        LIMIT @page, @perPage
    ]]):gsub("{MESSAGES}", messagesClause)

    local page = (pageIndex or 0) * 25

    return MySQL.query.await(query, {
        phoneNumber = phoneNumber,
        page        = page,
        perPage     = 25,
    })
end)

-- ============================================================
-- ACCOUNT CALLBACK: spark:sendMessage   (auth-gated)
-- Sends a message to a matched player.
--
-- Arguments:
--   source          – calling player's server id
--   phoneNumber     – sender's phone number
--   account         – sender's cached account object
--   recipientNumber – recipient's phone number
--   content         – message text
--   attachments     – optional array of attachment URLs
--
-- Workflow:
--   1. Check content against blacklisted words
--   2. Insert message row
--   3. Update the match's latest_message metadata
--   4. Fire a real-time client event if the recipient is online
--   5. Send a push notification
--
-- Returns the new message row's insert ID, or false on failure.
-- ============================================================
RegisterAccountCallback("sendMessage", function(source, phoneNumber, account, recipientNumber, content, attachments)
    -- Content moderation check
    if ContainsBlacklistedWord(source, "Spark", content) then
        return false
    end

    -- Insert the message
    local messageId = MySQL.insert.await(
        "INSERT INTO phone_tinder_messages (sender, recipient, content, attachments) VALUES (?, ?, ?, ?)",
        { phoneNumber, recipientNumber, content, json.encode(attachments) }
    )

    if not messageId then
        return false
    end

    -- Update the match row's latest-message snapshot and unread flags
    MySQL.update([[
        UPDATE
            phone_tinder_matches
        SET
            latest_message = @content,
            latest_sender = @sender,
            latest_message_timestamp = CURRENT_TIMESTAMP,
            phone_number_1_has_unread = CASE WHEN phone_number_1 = @recipient THEN 1 ELSE 0 END,
            phone_number_2_has_unread = CASE WHEN phone_number_2 = @recipient THEN 1 ELSE 0 END
        WHERE
            (phone_number_1 = @sender AND phone_number_2 = @recipient)
            OR (phone_number_2 = @sender AND phone_number_1 = @recipient)
    ]], {
        content   = content,
        sender    = phoneNumber,
        recipient = recipientNumber,
    })

    -- Real-time delivery: fire client event if the recipient is currently online
    local recipientSource = GetSourceFromNumber(recipientNumber)
    if recipientSource then
        TriggerClientEvent("phone:spark:newMessage", recipientSource, {
            sender      = phoneNumber,
            recipient   = recipientNumber,
            content     = content,
            attachments = attachments,
            timestamp   = os.time() * 1000,  -- milliseconds for JS compatibility
        })
    end

    -- Push notification to the recipient (shown even when phone is closed)
    SendNotification(recipientNumber, {
        app       = "Tinder",
        title     = account.name,
        content   = content,
        thumbnail = attachments and attachments[1] or nil,
        avatar    = account.photos[1],
        showAvatar = true,
    })

    return messageId
end)

-- ============================================================
-- CALLBACK: spark:getMessages
-- Returns the most recent 25 messages in a conversation thread.
-- Marks the conversation as read unless a pagination cursor
-- (lastId) is provided (indicating a "load more" request).
--
-- Arguments:
--   phoneNumber – caller's phone number
--   otherNumber – the other party's phone number
--   lastId      – (optional) cursor for older-message pagination;
--                 when provided, fetch messages with id < lastId
-- ============================================================
BaseCallback("spark:getMessages", function(source, phoneNumber, otherNumber, lastId)
    -- Mark conversation as read only on the initial load (no cursor)
    if not lastId then
        MySQL.update([[
            UPDATE
                phone_tinder_matches
            SET
                phone_number_1_has_unread = CASE WHEN phone_number_1 = @phoneNumber THEN 0 ELSE phone_number_1_has_unread END,
                phone_number_2_has_unread = CASE WHEN phone_number_2 = @phoneNumber THEN 0 ELSE phone_number_2_has_unread END
            WHERE
                (phone_number_1 = @phoneNumber AND phone_number_2 = @number)
                OR (phone_number_2 = @phoneNumber AND phone_number_1 = @number)
        ]], {
            phoneNumber = phoneNumber,
            number      = otherNumber,
        })
    end

    -- Build query: inject pagination clause if a cursor was given
    local paginationClause = lastId and "AND id < @lastId" or ""

    local query = ([[
        SELECT
            id,
            sender,
            recipient,
            content,
            attachments,
            timestamp
        FROM
            phone_tinder_messages
        WHERE
            (
                (sender = @phoneNumber AND recipient = @number)
                OR (recipient = @phoneNumber AND sender = @number)
            ) {PAGINATION}
        ORDER BY id DESC
        LIMIT 25
    ]]):gsub("{PAGINATION}", paginationClause)

    return MySQL.query.await(query, {
        phoneNumber = phoneNumber,
        number      = otherNumber,
        lastId      = lastId,
    })
end)

-- ============================================================
-- CALLBACK: spark:markAsRead
-- Clears the unread flag on a conversation for the calling player.
-- Used when the player opens a chat thread without loading messages
-- (e.g. NUI marks it read separately from fetching messages).
-- ============================================================
BaseCallback("spark:markAsRead", function(source, phoneNumber, otherNumber)
    MySQL.update([[
        UPDATE
            phone_tinder_matches
        SET
            phone_number_1_has_unread = CASE WHEN phone_number_1 = @phoneNumber THEN 0 ELSE phone_number_1_has_unread END,
            phone_number_2_has_unread = CASE WHEN phone_number_2 = @phoneNumber THEN 0 ELSE phone_number_2_has_unread END
        WHERE
            (phone_number_1 = @phoneNumber AND phone_number_2 = @number)
            OR (phone_number_2 = @phoneNumber AND phone_number_1 = @number)
    ]], {
        phoneNumber = phoneNumber,
        number      = otherNumber,
    })
end)

-- ============================================================
-- THREAD: Auto-disable inactive Spark accounts
-- Runs every hour and sets active = 0 for any account whose
-- last_seen timestamp is older than Config.AutoDisableSparkAccounts
-- days (default: 7 days).
--
-- The thread is skipped entirely if the config option is falsy.
-- Waits for DatabaseCheckerFinished before first run.
-- ============================================================
CreateThread(function()
    if not Config.AutoDisableSparkAccounts then
        return
    end

    local intervalMs  = 3600000  -- 1 hour in milliseconds
    local inactiveDays = 7        -- default: disable after 7 days of inactivity

    -- Allow the config value to be a custom number of days (minimum 1)
    if type(Config.AutoDisableSparkAccounts) == "number" then
        inactiveDays = math.max(Config.AutoDisableSparkAccounts, 1)
    end

    -- Wait until the database schema checker has finished running
    while true do
        if DatabaseCheckerFinished then
            break
        end
        Wait(500)
    end

    -- Hourly cleanup loop
    while true do
        MySQL.update(
            "UPDATE phone_tinder_accounts SET active = 0 WHERE active = 1 AND last_seen < NOW() - INTERVAL ? DAY",
            { inactiveDays },
            function(rowsDisabled)
                debugprint("Disabled " .. rowsDisabled .. " inactive Spark accounts.")
            end
        )

        Wait(intervalMs)
    end
end)

-- ============================================================
-- EVENT: playerDropped
-- Evicts the disconnected player's account from the cache
-- to prevent stale data being returned for a future player
-- who is assigned the same server source id.
-- ============================================================
AddEventHandler("playerDropped", function()
    local playerSource = source
    accountCache[playerSource] = nil
end)

-- ============================================================
-- End of tinder.lua (Spark module – server side)
-- ============================================================