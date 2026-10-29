local batteryLevels = {}

RegisterNetEvent("phone:battery:setBattery", function(batteryLevel)
    local playerId = source

    if not Config.Battery.Enabled or type(batteryLevel) ~= "number" or batteryLevel < 0 or batteryLevel > 100 then
        return debugprint("setBattery: invalid battery")
    end

    local phoneNumber = GetEquippedPhoneNumber(playerId)

    if not phoneNumber then
        return
    end

    batteryLevels[phoneNumber] = batteryLevel
end)

function IsPhoneDead(phoneNumber)
    if not Config.Battery.Enabled then
        return false
    end

    return batteryLevels[phoneNumber] == 0
end

exports("IsPhoneDead", IsPhoneDead)

function SaveBattery(playerId)
    local phoneNumber = GetEquippedPhoneNumber(playerId)

    if not phoneNumber or batteryLevels[phoneNumber] == nil then
        return
    end

    debugprint(("saving battery level (%s) for %s"):format(batteryLevels[phoneNumber], phoneNumber))

    MySQL.update("UPDATE phone_phones SET battery = ? WHERE phone_number = ?", {
        batteryLevels[phoneNumber],
        phoneNumber
    }, function()
        batteryLevels[phoneNumber] = nil
    end)
end

exports("SaveBattery", SaveBattery)

local function SaveAllBatteries()
    debugprint("saving all battery levels")

    local players = GetPlayers()

    for i = 1, #players do
        local playerId = tonumber(players[i])

        if playerId then
            SaveBattery(playerId)
        end
    end
end

exports("SaveAllBatteries", SaveAllBatteries)

AddEventHandler("playerDropped", function()
    SaveBattery(source)
end)

AddEventHandler("txAdmin:events:scheduledRestart", function(eventData)
    if eventData.secondsRemaining == 60 then
        SaveAllBatteries()
    end
end)

AddEventHandler("txAdmin:events:serverShuttingDown", SaveAllBatteries)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName == GetCurrentResourceName() then
        SaveAllBatteries()
    end
end)
