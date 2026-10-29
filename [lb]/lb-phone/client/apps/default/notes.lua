RegisterNUICallback("Notes", function(data, callback)
    if not currentPhone then
        return
    end

    local action = data.action
    local note = data.data or data

    debugprint("Notes:" .. (action or ""))

    if action == "create" then
        TriggerCallback("notes:createNote", callback, note.title, note.content)
    elseif action == "save" then
        TriggerCallback("notes:saveNote", callback, note.id, note.title, note.content)
    elseif action == "fetch" then
        TriggerCallback("notes:getNotes", callback)
    elseif action == "remove" then
        TriggerCallback("notes:removeNote", callback, note.id)
    end
end)
