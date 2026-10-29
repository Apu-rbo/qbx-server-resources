local battery = 100
local charging = false

local function SetBattery(batteryLevel)
    if not Config.Battery.Enabled then
        return
    end

    assert(type(batteryLevel) == "number", "setBattery: battery must be a number")
    assert(batteryLevel >= 0 and batteryLevel <= 100, "setBattery: battery must be between 0 and 100")

    battery = batteryLevel

    if batteryLevel == 0 then
        OnDeath()
        TriggerEvent("lb-phone:phoneDied")
    end

    TriggerServerEvent("phone:battery:setBattery", batteryLevel)
end

RegisterNUICallback("setBattery", function(data, callback)
    SetBattery(data)
    callback("ok")
end)

exports("SetBattery", function(batteryLevel)
    SetBattery(batteryLevel)
    SendNUIAction("battery:setBattery", batteryLevel)
end)

exports("GetBattery", function()
    return battery
end)

function ToggleCharging(enabled)
    assert(type(enabled) == "boolean", "ToggleCharging: toggle must be a boolean")

    if charging == enabled then
        debugprint("ToggleCharging: charging is already set to", enabled)
        return
    end

    charging = enabled
    SendNUIAction("battery:toggleCharging", enabled)
end

exports("ToggleCharging", ToggleCharging)

exports("IsCharging", function()
    return charging
end)

function IsPhoneDead()
    if not Config.Battery.Enabled then
        return false
    end

    return battery == 0
end

exports("IsPhoneDead", IsPhoneDead)
