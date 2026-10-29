if not (Config.Crypto and Config.Crypto.Enabled) then
    return
end

local coins = {}
local cryptoBusy = false

local function FindCoin(coinId)
    for i = 1, #coins do
        local coin = coins[i]

        if coin.id == coinId then
            return i, coin
        end
    end

    return false
end

local function UpdateQBitCoin()
    if not (Config.Crypto.QBit and Config.Framework == "qb") then
        return
    end

    local index = FindCoin("qbit") or (#coins + 1)
    local qbit = GetQBit()
    local prices = {}

    for i = 1, #qbit.History do
        prices[#prices + 1] = qbit.History[i].PreviousWorth
        prices[#prices + 1] = qbit.History[i].NewWorth
    end

    if #qbit.History == 0 then
        for i = 1, 10 do
            prices[i] = qbit.Worth + math.random(-10, 10)
        end
    end

    local change24h = 0

    if #qbit.History > 0 then
        change24h = qbit.History[#qbit.History].NewWorth - qbit.History[1].PreviousWorth
    end

    coins[index] = {
        change_24h = change24h,
        current_price = qbit.Worth,
        id = "qbit",
        image = "https://avatars.githubusercontent.com/u/81791099?s=200&v=4",
        name = "QBit",
        prices = prices,
        symbol = "qbit",
        owned = qbit.Portfolio
    }
end

local function FinishCryptoOperation(result)
    cryptoBusy = false

    return result or {
        success = false
    }
end

local function BuyCoin(coinId, amount)
    local result

    if coinId == "qbit" then
        if BuyQBit then
            result = BuyQBit(amount)
        end
    else
        result = AwaitCallback("crypto:buy", coinId, amount)
    end

    result = FinishCryptoOperation(result)

    if not result.success then
        return result
    end

    local _, coin = FindCoin(coinId)

    if coin then
        coin.owned = (coin.owned or 0) + amount / coin.current_price
        coin.invested = (coin.invested or 0) + amount
    end

    return result
end

local function SellCoin(coinId, amount)
    local result

    if coinId == "qbit" then
        if SellQBit then
            result = SellQBit(amount)
        end
    else
        result = AwaitCallback("crypto:sell", coinId, amount)
    end

    result = FinishCryptoOperation(result)

    if not result.success then
        return result
    end

    local _, coin = FindCoin(coinId)

    if coin and coin.invested and coin.owned then
        coin.invested = coin.invested - amount * coin.current_price
        coin.owned = coin.owned - amount
    end

    return result
end

local function TransferCoin(coinId, amount, number)
    local result

    if coinId == "qbit" then
        if TransferQBit then
            result = TransferQBit(amount)
        end
    else
        result = AwaitCallback("crypto:transfer", coinId, amount, number)
    end

    result = FinishCryptoOperation(result)

    if not result.success then
        return result
    end

    local _, coin = FindCoin(coinId)

    if coin and coin.invested and coin.owned then
        coin.invested = coin.invested - amount * coin.current_price
        coin.owned = coin.owned - amount
    end

    return result
end

RegisterNUICallback("Crypto", function(data, cb)
    local action = data.action

    debugprint("Crypto:" .. (action or ""))

    if action == "buy" or action == "sell" or action == "transfer" then
        if cryptoBusy then
            return cb({
                success = false,
                msg = "BUSY"
            })
        end

        cryptoBusy = true
    end

    if action == "buy" then
        return cb(BuyCoin(data.coin, data.amount))
    elseif action == "sell" then
        return cb(SellCoin(data.coin, data.amount))
    elseif action == "transfer" then
        return cb(TransferCoin(data.coin, data.amount, data.number))
    elseif action == "get" then
        UpdateQBitCoin()
        TriggerServerEvent("phone:crypto:fetchCoins")

        return cb(coins)
    elseif action == "openedApp" then
        TriggerServerEvent("phone:crypto:setAppOpen", true)
    elseif action == "closedApp" then
        TriggerServerEvent("phone:crypto:setAppOpen", false)
    end

    cb("ok")
end)

function FetchCryptoCoins()
    local fetchedCoins = AwaitCallback("crypto:get")

    if not fetchedCoins then
        return
    end

    table.wipe(coins)

    for _, coin in pairs(fetchedCoins) do
        coins[#coins + 1] = coin
    end

    SendNUIAction("crypto:updateCoins", coins)
end

CreateThread(function()
    while not FrameworkLoaded do
        Wait(500)
    end

    FetchCryptoCoins()
end)

RegisterNetEvent("phone:crypto:updateCoins", function(updatedCoins)
    for i = 1, #coins do
        local coin = coins[i]
        local updatedCoin = updatedCoins[coin.id]

        if updatedCoin then
            coin.current_price = updatedCoin.current_price
            coin.change_24h = updatedCoin.change_24h
            coin.prices = updatedCoin.prices
        end
    end

    for coinId, coin in pairs(updatedCoins) do
        if not FindCoin(coinId) then
            coins[#coins + 1] = coin
        end
    end

    debugprint("updated crypto cache")
    SendNUIAction("crypto:updateCoins", coins)
end)

RegisterNetEvent("phone:crypto:changeOwnedAmount", function(coinId, amount)
    local _, coin = FindCoin(coinId)

    if not coin then
        return
    end

    coin.owned = (coin.owned or 0) + amount

    debugprint("updated crypto cache", coinId, amount, coin.owned)
    SendNUIAction("crypto:updateCoins", coins)
end)

exports("GetCoinValue", function(coinId)
    local _, coin = FindCoin(coinId)

    return coin and coin.current_price
end)

exports("GetCryptoWallet", function()
    return coins
end)

exports("GetOwnedCoin", function(coinId)
    local _, coin = FindCoin(coinId)

    return coin
end)
