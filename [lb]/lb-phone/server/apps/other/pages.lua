BaseCallback("yellowPages:getPosts", function(source, phoneNumber, data)
    local filter = data and data.filter
    local params = {}
    local where = {}

    if filter and filter.search and #filter.search > 0 then
        local search = "%" .. filter.search .. "%"

        params[#params + 1] = search
        params[#params + 1] = search

        if filter.from then
            where[#where + 1] = "(title LIKE ? OR description LIKE ?)"
        else
            where[#where + 1] = "(title LIKE ? OR description LIKE ? OR phone_number LIKE ?)"
            params[#params + 1] = search
        end
    end

    if filter and filter.from then
        where[#where + 1] = "phone_number = ?"
        params[#params + 1] = filter.from
    end

    if data and data.lastId then
        where[#where + 1] = "id < ?"
        params[#params + 1] = data.lastId
    end

    local query = [[
        SELECT
            id,
            phone_number AS `number`,
            title,
            description,
            attachment,
            price,
            `timestamp`
        FROM
            phone_yellow_pages_posts
        {WHERE}
        ORDER BY
            id DESC
        LIMIT ?
    ]]

    query = query:gsub(
        "{WHERE}",
        #where > 0 and ("WHERE " .. table.concat(where, " AND ")) or ""
    )

    params[#params + 1] = 25

    return MySQL.query.await(query, params)
end)

local pagesConfig = Config.Pages or {}
local postCost = pagesConfig.Cost and pagesConfig.Cost > 0 and pagesConfig.Cost or 0
local maxPosts = pagesConfig.MaxPosts and pagesConfig.MaxPosts > 0 and pagesConfig.MaxPosts or nil
local rateLimit = pagesConfig.RateLimit and pagesConfig.RateLimit > 0 and pagesConfig.RateLimit or nil

BaseCallback("yellowPages:createPost", function(source, phoneNumber, data)
    if not (data and data.title and data.description) then
        return { success = false }
    end

    if ContainsBlacklistedWord(source, "Pages", data.title)
        or ContainsBlacklistedWord(source, "Pages", data.description)
    then
        return { success = false }
    end

    local price = math.clamp(tonumber(data.price or 0) or 0, 0, 1000000000)

    if price == 0 then
        price = nil
    end

    data.price = price

    if postCost > 0 and GetBalance(source) < postCost then
        return {
            success = false,
            error = "noMoney"
        }
    end

    if maxPosts then
        local postCount = MySQL.scalar.await(
            "SELECT COUNT(1) FROM phone_yellow_pages_posts WHERE phone_number = ?",
            { phoneNumber }
        ) or 0

        if postCount >= maxPosts then
            return {
                success = false,
                error = "postLimit"
            }
        end
    end

    if rateLimit then
        local lastPostTime = MySQL.scalar.await(
            "SELECT `timestamp` FROM phone_yellow_pages_posts WHERE phone_number = ? ORDER BY id DESC LIMIT 1",
            { phoneNumber }
        )

        if lastPostTime and os.time() - lastPostTime < rateLimit * 60 then
            return {
                success = false,
                error = "rateLimit"
            }
        end
    end

    if not ValidateChecks("postPages", source, data) then
        return { success = false }
    end

    local postId = MySQL.insert.await(
        "INSERT INTO phone_yellow_pages_posts (phone_number, title, description, attachment, price) VALUES (@number, @title, @description, @attachment, @price)",
        {
            number = phoneNumber,
            title = LimitStringLength(data.title, 50),
            description = LimitStringLength(data.description, 1000),
            attachment = data.attachment,
            price = price
        }
    )

    if not postId then
        return { success = false }
    end

    if postCost > 0 then
        RemoveMoney(source, postCost)
        AddTransaction(
            phoneNumber,
            -postCost,
            L("APPS.YELLOWPAGES.TRANSACTION"),
            "./assets/img/icons/apps/YellowPages.jpg"
        )
    end

    data.id = postId
    data.number = phoneNumber
    data.source = source

    TriggerClientEvent("phone:yellowPages:newPost", -1, data)
    TriggerEvent("lb-phone:pages:newPost", data)

    Log(
        "YellowPages",
        source,
        "info",
        L("BACKEND.LOGS.YELLOWPAGES_NEW_TITLE"),
        L("BACKEND.LOGS.YELLOWPAGES_NEW_DESCRIPTION", {
            title = data.title,
            description = data.description,
            attachment = data.attachment or "",
            id = data.id
        })
    )

    return {
        success = true,
        id = postId
    }
end, false, {
    preventSpam = true,
    rateLimit = 6
})

BaseCallback("yellowPages:deletePost", function(source, phoneNumber, postId)
    local params = { postId }
    local query = "DELETE FROM phone_yellow_pages_posts WHERE id = ?"

    if not IsAdmin(source) then
        query = query .. " AND phone_number = ?"
        params[#params + 1] = phoneNumber
    end

    local deleted = MySQL.update.await(query, params) > 0

    if deleted then
        Log(
            "YellowPages",
            source,
            "error",
            L("BACKEND.LOGS.YELLOWPAGES_DELETED"),
            ("**ID**: %s"):format(postId)
        )

        return true
    end

    return false
end)

local deleteOld = pagesConfig.DeleteOld and pagesConfig.DeleteOld > 0 and pagesConfig.DeleteOld or nil

Interval:new(function()
    MySQL.update(
        "DELETE FROM phone_yellow_pages_posts WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL ? HOUR)",
        { deleteOld },
        function(deleted)
            debugprint("Deleted", deleted, "old pages posts")
        end
    )
end, 3600000, deleteOld ~= nil)
