BaseCallback("backup:createBackup", function(source, phoneNumber)
    local affectedRows = MySQL.update.await([[
        INSERT INTO phone_backups (id, phone_number) VALUES (@identifier, @phoneNumber)
        ON DUPLICATE KEY UPDATE phone_number = @phoneNumber
    ]], {
        ["@identifier"] = GetIdentifier(source),
        ["@phoneNumber"] = phoneNumber
    })

    return affectedRows > 0
end)

BaseCallback("backup:applyBackup", function(source, phoneNumber, backupNumber)
    local identifier = GetIdentifier(source)
    local ownsBackup = MySQL.scalar.await(
        "SELECT 1 FROM phone_backups WHERE id = ? AND phone_number = ?",
        { identifier, backupNumber }
    )

    if not ownsBackup or phoneNumber == backupNumber then
        return false
    end

    local queryParams = {
        ["@number"] = backupNumber,
        ["@phoneNumber"] = phoneNumber
    }

    local phones = MySQL.query.await(
        "SELECT settings, pin, face_id, phone_number FROM phone_phones WHERE phone_number = @number OR phone_number = @phoneNumber",
        queryParams
    )

    local currentPhoneData = phones[1] and phones[1].phone_number == phoneNumber and phones[1] or phones[2]
    local backupPhoneData = phones[1] and phones[1].phone_number == phoneNumber and phones[2] or phones[1]

    if not currentPhoneData or not backupPhoneData then
        return false
    end

    currentPhoneData.settings = json.decode(backupPhoneData.settings)

    if currentPhoneData.settings.security.pinCode and not currentPhoneData.pin then
        currentPhoneData.settings.security.pinCode = false
    end

    if currentPhoneData.settings.security.faceId and not currentPhoneData.face_id then
        currentPhoneData.settings.security.faceId = false
    end

    MySQL.update.await(
        "UPDATE phone_phones SET settings = ? WHERE phone_number = ?",
        { json.encode(currentPhoneData.settings), phoneNumber }
    )

    MySQL.update.await([[
        INSERT IGNORE INTO phone_photos (phone_number, link, is_video, size, `timestamp`)
        SELECT @phoneNumber, link, is_video, size, `timestamp`
        FROM phone_photos
        WHERE phone_number = @number AND link NOT IN (SELECT link FROM phone_photos WHERE phone_number = @phoneNumber)
    ]], queryParams)

    MySQL.update.await([[
        INSERT IGNORE INTO phone_phone_contacts (contact_phone_number, firstname, lastname, profile_image, favourite, phone_number)
        SELECT contact_phone_number, firstname, lastname, profile_image, favourite, @phoneNumber
        FROM phone_phone_contacts
        WHERE phone_number = @number AND contact_phone_number NOT IN (SELECT contact_phone_number FROM phone_phone_contacts WHERE phone_number = @phoneNumber)
    ]], queryParams)

    MySQL.update.await([[
        INSERT IGNORE INTO phone_maps_locations (id, phone_number, `name`, x_pos, y_pos)
        SELECT id, @phoneNumber, `name`, x_pos, y_pos
        FROM phone_maps_locations
        WHERE phone_number = @number AND id NOT IN (SELECT id FROM phone_maps_locations WHERE phone_number = @phoneNumber)
    ]], queryParams)

    return true
end)

BaseCallback("backup:deleteBackup", function(source, phoneNumber, backupNumber)
    local affectedRows = MySQL.update.await(
        "DELETE FROM phone_backups WHERE id = ? AND phone_number = ?",
        { GetIdentifier(source), backupNumber }
    )

    return affectedRows > 0
end)

BaseCallback("backup:getBackups", function(source)
    return MySQL.query.await(
        "SELECT phone_number AS `number` FROM phone_backups WHERE id = ?",
        { GetIdentifier(source) }
    )
end)
