RegisterNUICallback("YellowPages", function(data, callback)
    local action = data.action

    debugprint("Pages:" .. (action or ""))

    if action == "getPosts" then
        TriggerCallback("yellowPages:getPosts", callback, data)
    elseif action == "sendPost" then
        TriggerCallback("yellowPages:createPost", callback, data.data)
    elseif action == "deletePost" then
        TriggerCallback("yellowPages:deletePost", callback, data.id)
    end
end)

RegisterNetEvent("phone:yellowPages:newPost", function(post)
    TriggerEvent("lb-phone:pages:newPost", post)
    SendNUIAction("yellowPages:newPost", post)
end)
