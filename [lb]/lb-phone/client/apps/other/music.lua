local function GetPlaylists()
    local rows = AwaitCallback("music:getPlaylists")
    local playlists = {}
    local playlistsById = {}

    for i = 1, #rows do
        local row = rows[i]
        local playlist = playlistsById[row.id]

        if not playlist then
            playlist = {
                Id = row.id,
                Title = row.name,
                Cover = row.cover,
                IsOwner = row.phone_number == currentPhone,
                Songs = {}
            }

            playlistsById[row.id] = playlist
            playlists[#playlists + 1] = playlist
        end

        if row.song_id then
            playlist.Songs[#playlist.Songs + 1] = row.song_id
        end
    end

    return playlists
end

RegisterNUICallback("Music", function(data, callback)
    local action = data.action

    debugprint("Music:" .. (action or ""))

    if action == "getConfig" then
        callback(Music)
    elseif action == "createPlaylist" then
        TriggerCallback("music:createPlaylist", callback, data.name)
    elseif action == "editPlaylist" then
        TriggerCallback("music:editPlaylist", callback, data.id, data.title, data.cover)
    elseif action == "getPlaylists" then
        callback(GetPlaylists())
    elseif action == "deletePlaylist" then
        TriggerCallback("music:deletePlaylist", callback, data.id)
    elseif action == "savePlaylist" then
        TriggerCallback("music:savePlaylist", callback, data.id)
    elseif action == "addSong" then
        TriggerCallback("music:addSong", callback, data.id, data.song)
    elseif action == "removeSong" then
        TriggerCallback("music:removeSong", callback, data.id, data.song)
    end
end)
