BaseCallback("music:createPlaylist", function(source, phoneNumber, name)
    local playlistId = MySQL.insert.await(
        "INSERT INTO phone_music_playlists (`name`, phone_number) VALUES (?, ?)",
        { name, phoneNumber }
    )

    if not playlistId then
        return false
    end

    MySQL.update.await(
        "INSERT INTO phone_music_saved_playlists (playlist_id, phone_number) VALUES (?, ?)",
        { playlistId, phoneNumber }
    )

    return playlistId
end)

BaseCallback("music:editPlaylist", function(source, phoneNumber, playlistId, title, cover)
    local affectedRows = MySQL.update.await(
        "UPDATE phone_music_playlists SET `name` = ?, cover = ? WHERE id = ? AND phone_number = ?",
        { title, cover, playlistId, phoneNumber }
    )

    return affectedRows > 0
end)

BaseCallback("music:getPlaylists", function(source, phoneNumber)
    return MySQL.query.await([[
        SELECT s.song_id, p.id, p.`name`, p.cover, p.phone_number
        FROM phone_music_playlists p
        LEFT JOIN phone_music_saved_playlists p2 ON p2.playlist_id = p.id
        LEFT JOIN phone_music_songs s ON s.playlist_id = p.id

        WHERE p2.phone_number = ?

        ORDER BY p.`name` ASC
    ]], { phoneNumber })
end)

BaseCallback("music:deletePlaylist", function(source, phoneNumber, playlistId)
    local affectedRows = MySQL.update.await(
        "DELETE FROM phone_music_playlists WHERE id = ? AND phone_number = ?",
        { playlistId, phoneNumber }
    )

    return affectedRows > 0
end)

BaseCallback("music:savePlaylist", function(source, phoneNumber, playlistId)
    local affectedRows = MySQL.update.await(
        "INSERT INTO phone_music_saved_playlists (playlist_id, phone_number) VALUES (?, ?) ON DUPLICATE KEY UPDATE phone_number = phone_number",
        { playlistId, phoneNumber }
    )

    return affectedRows > 0
end)

BaseCallback("music:addSong", function(source, phoneNumber, playlistId, songId)
    local ownsPlaylist = MySQL.scalar.await(
        "SELECT 1 FROM phone_music_playlists WHERE id = ? AND phone_number = ?",
        { playlistId, phoneNumber }
    )

    if not ownsPlaylist then
        return false
    end

    local affectedRows = MySQL.update.await(
        "INSERT INTO phone_music_songs (playlist_id, song_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE song_id = song_id",
        { playlistId, songId }
    )

    return affectedRows > 0
end)

BaseCallback("music:removeSong", function(source, phoneNumber, playlistId, songId)
    local ownsPlaylist = MySQL.scalar.await(
        "SELECT 1 FROM phone_music_playlists WHERE id = ? AND phone_number = ?",
        { playlistId, phoneNumber }
    )

    if not ownsPlaylist then
        return false
    end

    local affectedRows = MySQL.update.await(
        "DELETE FROM phone_music_songs WHERE playlist_id = ? AND song_id = ?",
        { playlistId, songId }
    )

    return affectedRows > 0
end)
