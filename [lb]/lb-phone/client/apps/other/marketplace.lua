RegisterNUICallback("Marketplace", function(data, callback)
    local action = data.action

    debugprint("Marketplace:" .. (action or ""))

    if action == "getPosts" then
        local posts = AwaitCallback("marketplace:getPosts", data)

        for i = 1, #posts do
            posts[i].attachments = json.decode(posts[i].attachments)
        end

        callback(posts)
    elseif action == "sendPost" then
        TriggerCallback("marketplace:createPost", callback, data.data)
    elseif action == "deletePost" then
        TriggerCallback("marketplace:deletePost", callback, data.id)
    end
end)

RegisterNetEvent("phone:marketplace:newPost", function(post)
    TriggerEvent("lb-phone:marketplace:newPost", post)
    SendNUIAction("marketPlace:newPost", post)
end)
