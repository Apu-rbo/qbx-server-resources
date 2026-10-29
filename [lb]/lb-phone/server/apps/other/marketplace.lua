BaseCallback("marketplace:getPosts", function(source, phoneNumber, data)
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
            attachments,
            price,
            `timestamp`
        FROM
            phone_marketplace_posts
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

local marketplaceConfig = Config.Marketplace or {}
local postCost = marketplaceConfig.Cost and marketplaceConfig.Cost > 0 and marketplaceConfig.Cost or 0
local maxPosts = marketplaceConfig.MaxPosts and marketplaceConfig.MaxPosts > 0 and marketplaceConfig.MaxPosts or nil
local rateLimit = marketplaceConfig.RateLimit and marketplaceConfig.RateLimit > 0 and marketplaceConfig.RateLimit or nil

BaseCallback("marketplace:createPost", function(source, phoneNumber, data)
    if not data then
        return { success = false }
    end

    local title = data.title
    local description = data.description
    local attachments = data.attachments
    local price = tonumber(data.price)

    if not (title and description and attachments and price) or price < 0 then
        return { success = false }
    end

    if ContainsBlacklistedWord(source, "Marketplace", title)
        or ContainsBlacklistedWord(source, "Marketplace", description)
    then
        return { success = false }
    end

    if postCost > 0 and GetBalance(source) < postCost then
        return {
            success = false,
            error = "noMoney"
        }
    end

    if maxPosts then
        local postCount = MySQL.scalar.await(
            "SELECT COUNT(1) FROM phone_marketplace_posts WHERE phone_number = ?",
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
            "SELECT `timestamp` FROM phone_marketplace_posts WHERE phone_number = ? ORDER BY id DESC LIMIT 1",
            { phoneNumber }
        )

        if lastPostTime and os.time() - lastPostTime < rateLimit * 60 then
            return {
                success = false,
                error = "rateLimit"
            }
        end
    end

    if not ValidateChecks("postMarketplace", source, data) then
        return { success = false }
    end

    local postId = MySQL.insert.await(
        "INSERT INTO phone_marketplace_posts (phone_number, title, description, attachments, price) VALUES (?, ?, ?, ?, ?)",
        {
            phoneNumber,
            LimitStringLength(title, 50),
            LimitStringLength(description, 1000),
            json.encode(attachments),
            math.clamp(price, 0, 1000000000)
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
            L("APPS.MARKETPLACE.TRANSACTION"),
            "./assets/img/icons/apps/MarketPlace.jpg"
        )
    end

    data.number = phoneNumber
    data.id = postId
    data.source = source

    TriggerClientEvent("phone:marketplace:newPost", -1, data)
    TriggerEvent("lb-phone:marketplace:newPost", data)

    Log(
        "Marketplace",
        source,
        "info",
        L("BACKEND.LOGS.MARKETPLACE_NEW_TITLE"),
        L("BACKEND.LOGS.MARKETPLACE_NEW_DESCRIPTION", {
            seller = FormatNumber(phoneNumber),
            title = title,
            price = price,
            description = description,
            attachments = json.encode(attachments),
            id = postId
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

BaseCallback("marketplace:deletePost", function(source, phoneNumber, postId)
    local params = { postId }
    local query = "DELETE FROM phone_marketplace_posts WHERE id = ?"

    if not IsAdmin(source) then
        query = query .. " AND phone_number = ?"
        params[#params + 1] = phoneNumber
    end

    local deleted = MySQL.update.await(query, params) > 0

    if deleted then
        Log(
            "Marketplace",
            source,
            "error",
            L("BACKEND.LOGS.MARKETPLACE_DELETED"),
            ("**ID**: %s"):format(postId)
        )

        return true
    end

    return false
end)

local deleteOld = marketplaceConfig.DeleteOld and marketplaceConfig.DeleteOld > 0 and marketplaceConfig.DeleteOld or nil

Interval:new(function()
    MySQL.update(
        "DELETE FROM phone_marketplace_posts WHERE `timestamp` < DATE_SUB(NOW(), INTERVAL ? HOUR)",
        { deleteOld },
        function(deleted)
            debugprint("Deleted", deleted, "old marketplace posts")
        end
    )
end, 3600000, deleteOld ~= nil)
