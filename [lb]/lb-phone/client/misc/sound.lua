local remoteSounds = {}
local activePhoneSound

local function GetRingtoneSound(sound)
    if sound == "vibrate" then
        return "vibrate", "ringtone"
    end

    if not (sound and Config.Sound.Ringtones[sound]) then
        sound = next(Config.Sound.Ringtones)
    end

    if sound then
        local soundData = Config.Sound.Ringtones[sound]

        return soundData.name, soundData.soundSet, soundData.audioBank
    end

    return "1", "ringtone"
end

local function GetNotificationSound(sound)
    if sound == "vibrate" then
        return "vibrate", "notification"
    end

    if not (sound and Config.Sound.Notifications[sound]) then
        sound = next(Config.Sound.Notifications)
    end

    if sound then
        local soundData = Config.Sound.Notifications[sound]

        return soundData.name, soundData.soundSet, soundData.audioBank
    end

    return "1", "notification"
end

local function RequestPhoneAudioBank(audioBank)
    local timeout = GetGameTimer() + 1000
    local bank = audioBank or "dlc_lbscripts/sounds"

    debugprint("Waiting for audio bank to load")

    while not RequestScriptAudioBank(bank, false) do
        Wait(0)

        if timeout < GetGameTimer() then
            infoprint(
                "warning",
                "Failed to load audio bank, setting Config.Sound.System to 'nui'. This usually happens when you have too many sounds on your server."
            )

            Config.Sound.System = "nui"

            SendNUIAction("updateConfigValue", {
                config = {
                    sound = {
                        system = "nui"
                    }
                }
            })

            return false
        end
    end

    debugprint("Audio bank loaded")

    return true
end

local function GetNativeVolume(volume)
    local volumeConfig = Config.Sound.Volume or {}

    if type(volumeConfig.Static) == "number" then
        volume = volumeConfig.Static
    end

    volume = (volume or 1) / 1

    if volumeConfig.Multiplier then
        volume = volume * volumeConfig.Multiplier
    end

    volume = math.clamp(volume, volumeConfig.Min or 0.0, volumeConfig.Max or 1.0)

    return math.clamp(volume, 0.0, 1.0)
end

local function PlayNativeSound(entity, soundType, volume, soundName, soundSet, audioBank)
    if Config.Sound.System == "nui" then
        return
    end

    volume = GetNativeVolume(volume)

    if volume == 0 then
        return
    end

    if not RequestPhoneAudioBank(audioBank) then
        return
    end

    local soundId = GetSoundId()

    debugprint("Playing sound:", soundName, soundSet, "with volume:", volume)

    PlaySoundFromEntity(soundId, soundName, entity, soundSet, false, 0)
    SetVariableOnSound(soundId, "Volume", volume)
    ReleaseScriptAudioBank()

    if soundType ~= "ringtone" and soundType ~= "alarm" then
        ReleaseSoundId(soundId)
    end

    local playerPed = PlayerPedId()

    if entity ~= playerPed and Config.Sound.MaxDistance then
        Citizen.CreateThreadNow(function()
            local mutedByDistance = false

            while not HasSoundFinished(soundId) do
                local distance = #(GetEntityCoords(playerPed) - GetEntityCoords(entity))

                if distance > Config.Sound.MaxDistance then
                    if not mutedByDistance then
                        SetVariableOnSound(soundId, "Volume", 0.0)
                        debugprint("Sound volume set to 0 due to being too far away")
                        mutedByDistance = true
                    end
                elseif mutedByDistance then
                    SetVariableOnSound(soundId, "Volume", volume)
                    debugprint("Sound volume restored")
                    mutedByDistance = false
                end

                Wait(100)
            end
        end)
    end

    return soundId
end

function PlayPhoneSound(soundType, soundName)
    local volume = settings and settings.sound and settings.sound.volume or 0.5
    local nativeSoundName
    local soundSet
    local audioBank

    debugprint("PlayPhoneSound", soundType)

    if not ValidateChecks("playNativePhoneSound", soundType, soundName) then
        debugprint("PlayPhoneSound: playNativePhoneSound check cancelled the sound")
        return
    end

    if soundType == "ringtone" or soundType == "alarm" then
        StopPhoneSound()
    end

    if soundType == "cameraShutter" then
        nativeSoundName = "camera-shutter"
        soundSet = "other"
    elseif soundType == "ringtone" then
        local selectedSound = soundName or (settings and settings.sound and settings.sound.ringtone)

        if settings and settings.sound and settings.sound.silent then
            selectedSound = "vibrate"
            volume = 1.0
        end

        nativeSoundName, soundSet, audioBank = GetRingtoneSound(selectedSound)
    elseif soundType == "alarm" then
        nativeSoundName = "alarm"
        soundSet = "other"

        if settings and settings.sound and settings.sound.silent then
            nativeSoundName, soundSet, audioBank = GetRingtoneSound("vibrate")
            volume = 1.0
        end
    elseif soundType == "notification" then
        nativeSoundName, soundSet, audioBank = GetNotificationSound(
            soundName or (settings and settings.sound and settings.sound.notification)
        )
    else
        debugprint("PlayPhoneSound: invalid sound type", soundType)
        return
    end

    local soundId = PlayNativeSound(PlayerPedId(), soundType, volume, nativeSoundName, soundSet, audioBank)

    if not soundId then
        return
    end

    if soundType == "ringtone" or soundType == "alarm" then
        activePhoneSound = soundId

        if not phoneOpen then
            SetVariableOnSound(soundId, "Muffle", 0.05)
        end
    end

    if not Config.Sound.Sync then
        return
    end

    local nearbyPlayers = GetNearbyPlayers()
    local targets = {}

    for i = 1, #nearbyPlayers do
        targets[i] = nearbyPlayers[i].source
    end

    TriggerServerEvent("phone:sound:playSound", targets, soundType, nativeSoundName, soundSet, audioBank)
end

function StopPhoneSound()
    if not activePhoneSound then
        return
    end

    StopSound(activePhoneSound)
    ReleaseSoundId(activePhoneSound)
    activePhoneSound = nil
end

RegisterNetEvent("phone:sound:playSound", function(source, soundType, volume, soundName, soundSet, audioBank)
    local player = GetPlayerFromServerId(source)
    local ped = GetPlayerPed(player)

    if ped == PlayerPedId() then
        return
    end

    PlayNativeSound(ped, soundType, volume, soundName, soundSet, audioBank)
end)

local function StopRemoteSound(source)
    local soundId = remoteSounds[source]

    if not soundId then
        return
    end

    StopSound(soundId)
    ReleaseSoundId(soundId)
    remoteSounds[source] = nil
end

RegisterNetEvent("onPlayerDropped", function(source)
    StopRemoteSound(source)
end)

AddStateBagChangeHandler("lbPhoneAudio", nil, function(bagName, key, value)
    local source, ped = GetPlayerDataFromStateBag(bagName)

    if not source or source == GetPlayerServerId(PlayerId()) then
        return
    end

    StopRemoteSound(source)

    if not value or not ped then
        return
    end

    local soundId = PlayNativeSound(ped, table.unpack(value))

    if not soundId then
        return
    end

    if not Player(source).state.phoneOpen then
        SetVariableOnSound(soundId, "Muffle", 0.05)
    end

    remoteSounds[source] = soundId
end)

AddStateBagChangeHandler("phoneOpen", nil, function(bagName, key, value)
    local source = tonumber(bagName:match("player:(%d+)"))

    if not source then
        return
    end

    local soundId

    if source == GetPlayerServerId(PlayerId()) then
        soundId = activePhoneSound
    else
        soundId = remoteSounds[source]
    end

    if not soundId then
        return
    end

    SetVariableOnSound(soundId, "Muffle", value and 1.0 or 0.05)
end)

RegisterNetEvent("phone:sound:stopSound", function()
    StopPhoneSound()
end)

RegisterNUICallback("playSound", function(data, cb)
    cb("ok")
    PlayPhoneSound(data.soundType, data.soundName)
end)

RegisterNUICallback("stopSound", function(data, cb)
    cb("ok")
    TriggerServerEvent("phone:sound:stopSound")
end)

local previewSoundId
local previewToken

local function StopPreviewSound()
    if not previewSoundId then
        return
    end

    StopSound(previewSoundId)
    ReleaseSoundId(previewSoundId)
    ReleaseScriptAudioBank()

    previewSoundId = nil
    previewToken = nil
end

RegisterNUICallback("previewSound", function(data, cb)
    cb("ok")

    local soundName
    local soundSet
    local audioBank

    if data.soundType == "ringtone" then
        soundName, soundSet, audioBank = GetRingtoneSound(data.sound)
    elseif data.soundType == "texttone" then
        soundName, soundSet, audioBank = GetNotificationSound(data.sound)
    else
        return
    end

    if not RequestPhoneAudioBank(audioBank) then
        return
    end

    if previewSoundId then
        StopSound(previewSoundId)
    else
        previewSoundId = GetSoundId()
    end

    local token = tostring(soundName) .. tostring(soundSet)

    previewToken = token

    PlaySoundFrontend(previewSoundId, soundName, soundSet, false)
    SetVariableOnSound(
        previewSoundId,
        "Volume",
        GetNativeVolume(settings and settings.sound and settings.sound.volume or 1)
    )

    Wait(5000)

    if previewToken ~= token or not previewSoundId then
        return
    end

    StopPreviewSound()
end)

RegisterNUICallback("stopPreviewingSound", function(data, cb)
    cb("ok")
    StopPreviewSound()
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    for _, soundId in pairs(remoteSounds) do
        ReleaseSoundId(soundId)
    end

    if activePhoneSound then
        ReleaseSoundId(activePhoneSound)
    end

    if previewSoundId then
        ReleaseSoundId(previewSoundId)
    end

    ReleaseScriptAudioBank()
end)

CreateThread(function()
    if Config.Sound.System == "nui" then
        return
    end

    while not FrameworkLoaded do
        Wait(0)
    end

    if not RequestPhoneAudioBank() then
        Config.Sound.System = "nui"
    end

    ReleaseScriptAudioBank()
end)
