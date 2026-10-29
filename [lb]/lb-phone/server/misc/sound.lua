if not Config.Sound.Sync then
    return
end

local validSoundTypes = {
    cameraShutter = true,
    notification = true,
    ringtone = true,
    alarm = true
}

local validSounds = {
    vibrate_ringtone_ = true,
    alarm_other_ = true,
    ["camera-shutter_other_"] = true
}

local function AddSoundToAllowList(sound)
    local audioBank = sound.audioBank or ""

    validSounds[sound.name .. "_" .. sound.soundSet .. "_" .. audioBank] = true
end

for _, sound in pairs(Config.Sound.Ringtones) do
    AddSoundToAllowList(sound)
end

for _, sound in pairs(Config.Sound.Notifications) do
    AddSoundToAllowList(sound)
end

RegisterNetEvent("phone:sound:playSound", function(targets, soundType, soundName, soundSet, audioBank)
    local playerId = source
    local phoneNumber = GetEquippedPhoneNumber(playerId)

    if not phoneNumber then
        return
    end

    if not validSoundTypes[soundType] then
        infoprint("warning", DebugPlayerName(playerId) .. " tried to play an invalid sound type: " .. tostring(soundType))
        return
    end

    local soundKey = soundName .. "_" .. (soundSet or "") .. "_" .. (audioBank or "")

    if not validSounds[soundKey] then
        infoprint("warning", DebugPlayerName(playerId) .. " tried to play an invalid sound: " .. soundKey)
        return
    end

    local settings = GetSettings(phoneNumber)
    local volume = settings and settings.sound and settings.sound.volume or 1.0

    if soundType == "ringtone" or soundType == "alarm" then
        Player(playerId).state.lbPhoneAudio = { soundType, volume, soundName, soundSet, audioBank }
        return
    end

    if not targets then
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(playerId))

    for i = 1, #targets do
        local target = targets[i]
        local shouldPlay = true

        if Config.Sound.DistanceCheck == true and playerCoords then
            local targetCoords = GetEntityCoords(GetPlayerPed(target))
            local distance = #(playerCoords - targetCoords)

            if distance > 100.0 then
                debugprint("Skipping sound for source:", target, "due to distance check.")
                shouldPlay = false
            end
        end

        if shouldPlay then
            TriggerClientEvent("phone:sound:playSound", target, playerId, soundType, volume, soundName, soundSet, audioBank)
        end
    end
end)

RegisterNetEvent("phone:sound:stopSound", function()
    local playerId = source

    Player(playerId).state.lbPhoneAudio = nil
    TriggerClientEvent("phone:sound:stopSound", playerId)
end)
