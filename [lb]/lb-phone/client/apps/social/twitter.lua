local function FormatBirdyPost(post)
    if not post then
        return {}
    end

    local attachments = post.attachments

    if type(attachments) == "string" then
        attachments = json.decode(attachments)
    end

    if attachments and (type(attachments) ~= "table" or table.type(attachments) ~= "array") then
        attachments = nil
        debugprint("Malformed attachments for birdy post", post.id)
    end

    return {
        user = {
            profile_picture = post.profile_image,
            name = post.display_name,
            username = post.username,
            verified = post.verified,
            private = post.private == true
        },
        tweet = {
            id = post.id,
            content = post.content,
            date_created = post.timestamp,
            replies = post.reply_count,
            likes = post.like_count,
            retweets = post.retweet_count,
            attachments = attachments,
            replyToId = post.reply_to,
            liked = post.liked == true,
            retweeted = post.retweeted == true,
            replyToAuthor = post.replyToAuthor,
            retweetedByName = post.retweeted_by_display_name,
            retweetedByUsername = post.retweeted_by_username
        }
    }
end

local function FormatAccount(account)
    return {
        username = account.username,
        name = account.display_name,
        profile_picture = account.profile_image,
        verified = account.verified,
        private = account.private == true
    }
end

local function GetBirdyPosts(filter, page)
    local rows = AwaitCallback("birdy:getPosts", filter, page) or {}
    local posts = {}

    for i = 1, #rows do
        posts[i] = FormatBirdyPost(rows[i])
    end

    if Config.PromoteBirdy and Config.PromoteBirdy.Enabled and #rows > 1 then
        local promotedPost = AwaitCallback("birdy:getRandomPromoted")

        if promotedPost then
            promotedPost = FormatBirdyPost(promotedPost)
            promotedPost.tweet.promoted = true

            local index = math.random(3, 6)

            if index >= #posts then
                index = #posts - 1
            end

            table.insert(posts, index, promotedPost)
        end
    end

    return posts
end

local interactionActions = {
    "login",
    "toggleFollow",
    "toggleLike",
    "toggleRetweet",
    "sendMessage"
}

RegisterNUICallback("Twitter", function(data, cb)
    if not currentPhone then
        return
    end

    local action = data.action

    debugprint("Birdy:" .. (action or ""))

    if table.contains(interactionActions, action) and not CanInteract() then
        return cb(false)
    end

    if action == "createAccount" then
        local accountData = data.data

        TriggerCallback("birdy:createAccount", cb, accountData.name, accountData.username, accountData.password)
    elseif action == "changePassword" then
        TriggerCallback("birdy:changePassword", cb, data.oldPassword, data.newPassword)
    elseif action == "deleteAccount" then
        TriggerCallback("birdy:deleteAccount", cb, data.password)
    elseif action == "login" then
        local loginData = data.data

        TriggerCallback("birdy:login", cb, loginData.username, loginData.password)
    elseif action == "isLoggedIn" then
        TriggerCallback("birdy:isLoggedIn", cb)
    elseif action == "sendTweet" then
        local tweetData = data.data

        TriggerCallback(
            "birdy:sendPost",
            cb,
            tweetData.content,
            tweetData.attachments,
            tweetData.replyTo,
            tweetData.hashtags
        )
    elseif action == "updateProfile" then
        TriggerCallback("birdy:updateProfile", cb, data.data)
    elseif action == "searchAccounts" then
        TriggerCallback("birdy:searchAccounts", function(accounts)
            local formattedAccounts = {}

            for i = 1, #accounts do
                formattedAccounts[i] = FormatAccount(accounts[i])
            end

            cb(formattedAccounts)
        end, data.query, data.page)
    elseif action == "searchTweets" then
        TriggerCallback("birdy:searchTweets", function(posts)
            local formattedPosts = {}

            for i = 1, #posts do
                formattedPosts[i] = FormatBirdyPost(posts[i])
            end

            cb(formattedPosts)
        end, data.query, data.page)
    elseif action == "getProfile" then
        TriggerCallback("birdy:getProfile", function(profile)
            if not profile then
                debugprint("Birdy: failed to get profile", data.data.username)
                return cb()
            end

            if profile.pinnedTweet then
                profile.pinnedTweet = FormatBirdyPost(profile.pinnedTweet)
            end

            cb(profile)
        end, data.data.username)
    elseif action == "getFollowers" then
        TriggerCallback("birdy:getData", cb, "followers", data.data.username, data.data.page)
    elseif action == "getFollowing" then
        TriggerCallback("birdy:getData", cb, "following", data.data.username, data.data.page)
    elseif action == "getLikes" then
        TriggerCallback("birdy:getData", cb, "likes", data.data.tweet_id, data.data.page)
    elseif action == "getRetweeters" then
        TriggerCallback("birdy:getData", cb, "retweeters", data.data.tweet_id, data.data.page)
    elseif action == "getTweets" then
        data.filter = data.filter or data.filters

        if data.filter and next(data.filter) == nil then
            data.filter = nil
        end

        cb(GetBirdyPosts(data.filter, data.page))
    elseif action == "getTweet" then
        TriggerCallback("birdy:getPost", function(post)
            cb(FormatBirdyPost(post))
        end, data.tweetId)
    elseif action == "getAuthor" then
        TriggerCallback("birdy:getAuthor", cb, data.tweetId)
    elseif action == "toggleFollow" then
        TriggerCallback("birdy:toggleFollow", cb, data.data.username, data.data.following)
    elseif action == "toggleNotifications" then
        TriggerCallback("birdy:toggleNotifications", cb, data.data.username, data.data.toggle)
    elseif action == "toggleLike" then
        TriggerCallback("birdy:toggleInteraction", cb, "like", data.tweet_id, data.liked)
    elseif action == "toggleRetweet" then
        TriggerCallback("birdy:toggleInteraction", cb, "retweet", data.tweet_id, data.retweeted)
    elseif action == "deleteTweet" then
        TriggerCallback("birdy:deletePost", cb, data.tweet_id)
    elseif action == "promoteTweet" then
        TriggerCallback("birdy:promotePost", cb, data.tweet_id)
    elseif action == "sendMessage" then
        local messageData = data.data

        TriggerCallback(
            "birdy:sendMessage",
            cb,
            messageData.recipient,
            messageData.content,
            messageData.attachments
        )
    elseif action == "getMessages" then
        local messageData = data.data

        TriggerCallback("birdy:getMessages", function(messages)
            for i = 1, #messages do
                if messages[i].attachments then
                    messages[i].attachments = json.decode(messages[i].attachments)
                end
            end

            cb(messages)
        end, messageData.username, messageData.page)
    elseif action == "getRecentMessages" then
        TriggerCallback("birdy:getRecentMessages", cb, data.page)
    elseif action == "signOut" then
        TriggerCallback("birdy:signOut", cb)
    elseif action == "getNotifications" then
        TriggerCallback("birdy:getNotifications", function(result)
            for _, notification in pairs(result.notifications) do
                if notification.attachments then
                    notification.attachments = json.decode(notification.attachments)
                end
            end

            cb(result)
        end, data.page)
    elseif action == "getRecentHashtags" then
        TriggerCallback("birdy:getRecentHashtags", cb)
    elseif action == "pinTweet" then
        TriggerCallback("birdy:pinPost", cb, data.toggle and data.tweet_id or nil)
    elseif action == "getFollowRequests" then
        TriggerCallback("birdy:getFollowRequests", cb, data.page or 0)
    elseif action == "handleFollowRequest" then
        TriggerCallback("birdy:handleFollowRequest", cb, data.username, data.accept)
    end
end)

RegisterNetEvent("phone:twitter:updateTweetData", function(tweetId, data, increment)
    debugprint("updateTweetData", tweetId, data, increment)

    SendNUIAction("twitter:updateTweetData", {
        tweetId = tweetId,
        data = data,
        increment = increment
    })
end)

RegisterNetEvent("phone:twitter:updateProfileData", function(username, data, increment)
    debugprint("updateProfileData", username, data, increment)

    SendNUIAction("twitter:updateProfileData", {
        username = username,
        data = data,
        increment = increment
    })
end)

RegisterNetEvent("phone:twitter:newMessage", function(data)
    SendNUIAction("twitter:newMessage", data)
end)

RegisterNetEvent("phone:twitter:newtweet", function(data)
    TriggerEvent("lb-phone:birdy:newPost", data)
    SendNUIAction("twitter:newTweet", FormatBirdyPost(data))
end)

function SendTweet(data)
    assert(type(data) == "table", "Expected table for data, got " .. type(data))
    assert(type(data.content) == "string", "Expected string for data.content, got " .. type(data.content))
    assert(data.attachments == nil or type(data.attachments) == "table", "Expected table / nil for data.attachments, got " .. type(data.attachments))
    assert(data.replyTo == nil or type(data.replyTo) == "string", "Expected string / nil for data.replyTo, got " .. type(data.replyTo))
    assert(data.hashtags == nil or type(data.hashtags) == "table", "Expected table / nil for data.hashtags, got " .. type(data.hashtags))

    if not CanInteract() then
        return
    end

    return AwaitCallback("birdy:sendPost", data.content, data.attachments, data.replyTo, data.hashtags)
end

exports("SendTweet", SendTweet)
exports("PostBirdy", SendTweet)
