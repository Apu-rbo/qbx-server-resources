flashlightEnabled = false

local drawFlashlight = DrawFlashlight

local function ToggleFlashlightState(enabled)
    local previousState = flashlightEnabled

    flashlightEnabled = enabled == true

    if flashlightEnabled == previousState then
        return
    end

    TriggerServerEvent("phone:toggleFlashlight", flashlightEnabled)

    if not flashlightEnabled then
        return
    end

    Citizen.CreateThreadNow(function()
        local ped = PlayerPedId()

        while flashlightEnabled do
            if phoneOpen then
                drawFlashlight(ped)
            else
                Wait(500)
            end

            Wait(0)
        end
    end)
end

RegisterNUICallback("toggleFlashlight", function(data, callback)
    ToggleFlashlightState(data.toggled)

    SetTimeout(100, function()
        callback(flashlightEnabled)
    end)
end)

exports("ToggleFlashlight", function(enabled)
    if not phoneOpen then
        return
    end

    ToggleFlashlightState(enabled)
    SendNUIAction("toggleFlashlight", flashlightEnabled)
end)

exports("GetFlashlight", function()
    return flashlightEnabled == true
end)

if not Config.SyncFlash then
    return
end

local syncedFlashlights = {}

local flashlightInterval = Interval:new(function()
    for _, ped in pairs(syncedFlashlights) do
        drawFlashlight(ped)
    end
end, 0, false)

function flashlightInterval.onStart()
    debugprint("Started drawing flashlights")
end

function flashlightInterval.onStop()
    debugprint("Stopped drawing flashlights")
end

AddStateBagChangeHandler("flashlight", nil, function(bagName, key, value)
    local serverId, ped = GetPlayerDataFromStateBag(bagName)

    if not serverId or serverId == GetPlayerServerId(PlayerId()) then
        return
    end

    if value then
        syncedFlashlights[serverId] = ped
    else
        syncedFlashlights[serverId] = nil
    end

    flashlightInterval:toggle(next(syncedFlashlights) ~= nil)
end)

RegisterNetEvent("onPlayerDropped", function(serverId)
    syncedFlashlights[serverId] = nil
    flashlightInterval:toggle(next(syncedFlashlights) ~= nil)
end)
