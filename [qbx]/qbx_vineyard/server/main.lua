local config = require 'config.server'
local clientConfig = require 'config.client'
local sharedConfig = require 'config.shared'
local picked = {}
local processing = {}

local function isNear(source, coords, maxDistance)
    local ped = GetPlayerPed(source)
    return ped ~= 0 and #(GetEntityCoords(ped) - coords) <= maxDistance
end

local function isNearGrapes(source)
    for i = 1, #clientConfig.grapeLocations do
        if isNear(source, clientConfig.grapeLocations[i], 3.0) then return true end
    end
    return false
end

local function startProcessing(source, item, requirement, reward)
    if processing[source] and GetGameTimer() > processing[source].expiresAt then
        processing[source] = nil
    end
    if processing[source] or not isNear(source, clientConfig.locations.vineyardProcessing.coords, 4.0) then return false end
    if exports.ox_inventory:GetItem(source, item, nil, true) < requirement then return false end
    if not exports.ox_inventory:RemoveItem(source, item, requirement) then return false end

    processing[source] = {
        reward = reward,
        earliestCompletion = GetGameTimer() + 5000,
        expiresAt = GetGameTimer() + 30000,
    }
    return true
end

local function finishProcessing(source, reward, amount)
    local session = processing[source]
    if not session or session.reward ~= reward then return end

    local now = GetGameTimer()
    if now < session.earliestCompletion then return end
    if now > session.expiresAt then
        processing[source] = nil
        return
    end
    if not isNear(source, clientConfig.locations.vineyardProcessing.coords, 4.0) then return end

    processing[source] = nil
    exports.ox_inventory:AddItem(source, reward, amount)
end

lib.callback.register('qbx_vineyard:server:grapeJuicesNeeded', function(source)
    return startProcessing(source, 'grapejuice', sharedConfig.grapeJuicesNeeded, 'wine')
end)

lib.callback.register('qbx_vineyard:server:grapesNeeded', function(source)
    return startProcessing(source, 'grape', sharedConfig.grapesNeeded, 'grapejuice')
end)

RegisterNetEvent('qbx_vineyard:server:getGrapes', function()
    local src = source
    local now = GetGameTimer()
    if picked[src] and now - picked[src] < 6000 then return end
    if not isNearGrapes(src) then return end

    picked[src] = now
    exports.ox_inventory:AddItem(src, 'grape', math.random(config.grapeAmount.min, config.grapeAmount.max))
end)

RegisterNetEvent('qbx_vineyard:server:receiveWine', function()
    finishProcessing(source, 'wine', math.random(config.wineAmount.min, config.wineAmount.max))
end)

RegisterNetEvent('qbx_vineyard:server:receiveGrapeJuice', function()
    finishProcessing(source, 'grapejuice', math.random(config.grapeJuiceAmount.min, config.grapeJuiceAmount.max))
end)

RegisterNetEvent('qbx_vineyard:server:cancelProcessing', function()
    processing[source] = nil
end)

AddEventHandler('playerDropped', function()
    picked[source] = nil
    processing[source] = nil
end)
