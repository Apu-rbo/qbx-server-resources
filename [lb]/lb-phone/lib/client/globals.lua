-- ============================================================
-- globals.lua  (lb-phone fix)
-- Pre-defines GetConfigFile and GetNearbyPlayers as globals so
-- they are available when client.lua and client/misc/*.lua run.
-- These are later overwritten by client.lua's own definitions.
-- ============================================================

-- ── GetConfigFile ────────────────────────────────────────────
-- Reads a file from the resource's config/ folder and returns
-- the raw string content.
function GetConfigFile(filename)
    return LoadResourceFile(GetCurrentResourceName(), "config/" .. filename)
end

-- ── Nearby-player cache (mirrors client.lua implementation) ──
local _nearbyPlayers = {}
local _lastPlayerPos = vector3(0.0, 0.0, 0.0)
local _lastCacheTime = 0

local function _RebuildNearbyPlayers()
    local myCoords   = GetEntityCoords(PlayerPedId())
    local allPlayers = GetActivePlayers()
    local result     = {}

    for i = 1, #allPlayers do
        local player = allPlayers[i]

        if player ~= PlayerId() then
            local ped    = GetPlayerPed(player)
            local coords = GetEntityCoords(ped)
            local dist   = #(myCoords - coords)

            if dist <= 50.0 then
                result[#result + 1] = {
                    player = player,
                    source = GetPlayerServerId(player),
                    ped    = ped,
                    coords = coords,
                }
            end
        end
    end

    _nearbyPlayers = result
end

-- Returns a cached list of nearby players, refreshing when the
-- player moves more than 25 m or 5 seconds have elapsed.
function GetNearbyPlayers()
    local now     = GetGameTimer()
    local elapsed = now - _lastCacheTime
    local pos     = GetEntityCoords(PlayerPedId())
    local moved   = #(pos - _lastPlayerPos)

    if elapsed > 5000 or moved > 25.0 then
        _lastCacheTime = now
        _lastPlayerPos = pos
        _RebuildNearbyPlayers()
    end

    return _nearbyPlayers
end
