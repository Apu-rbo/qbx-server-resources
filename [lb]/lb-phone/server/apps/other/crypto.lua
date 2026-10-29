if not Config.Crypto or not Config.Crypto.Enabled then
    debugprint("crypto disabled")
    return
end

local cryptoLimits = Config.Crypto.Limits or {
    Buy = 1000000,
    Sell = 1000000
}

local coins = {}
local coinHistory = {}
local cryptoLoaded = false
local appOpenPlayers = {}
local refundedIdentifiers = {}

local oldCoinDataJson = GetResourceKvpString("lb-phone:crypto:coins")
local oldCoinData = oldCoinDataJson and json.decode(oldCoinDataJson) or {}


RegisterNetEvent("phone:crypto:setAppOpen", function(isOpen)
    local playerId = source
    local exists, index = table.contains(appOpenPlayers, playerId)

    if exists and not isOpen then
        table.remove(appOpenPlayers, index)
    elseif not exists and isOpen then
        appOpenPlayers[#appOpenPlayers + 1] = playerId
    end
end)

local function broadcastToOpenCryptoApps(eventName, ...)
    if #appOpenPlayers == 0 then
        return
    end

    local payload = msgpack.pack_args(...)
    local payloadLength = #payload

    for i = 1, #appOpenPlayers do
        TriggerLatentClientEventInternal(eventName, appOpenPlayers[i], payload, payloadLength, 1000000.0)
    end
end

local function weightedRandomIndex(weights)
    local totalWeight = 0

    for i = 1, #weights do
        totalWeight = totalWeight + weights[i]
    end

    local roll = math.random() * totalWeight

    for i = 1, #weights do
        roll = roll - weights[i]

        if roll <= 0 then
            return i
        end
    end

    return 1
end

local function calculateChange24h(prices)
    if #prices == 0 then
        return 0
    end

    local firstPrice = prices[1]
    local latestPrice = prices[#prices]

    if firstPrice == 0 then
        return 0
    end

    return (latestPrice - firstPrice) / firstPrice * 100
end

local function addCrypto(identifier, coin, amount, invested)
    MySQL.update.await(
        "INSERT INTO phone_crypto (id, coin, amount, invested) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount), invested = invested + VALUES(invested)",
        { identifier, coin, amount, invested or 0 }
    )
end

local function removeCrypto(identifier, coin, amount)
    local ownedCoin = MySQL.single.await(
        "SELECT amount, invested FROM phone_crypto WHERE id = ? AND coin = ?",
        { identifier, coin }
    )

    if not ownedCoin then
        return false, "NO_COINS"
    end

    if amount > ownedCoin.amount then
        return false, "NOT_ENOUGH_COINS"
    end

    local investedReduction = 0

    if ownedCoin.invested > 0 then
        investedReduction = amount / ownedCoin.amount * ownedCoin.invested
    end

    MySQL.update.await(
        "UPDATE phone_crypto SET amount = GREATEST(amount - ?, 0), invested = GREATEST(invested - ?, 0) WHERE id = ? AND coin = ?",
        { amount, investedReduction, identifier, coin }
    )

    MySQL.update.await(
        "DELETE FROM phone_crypto WHERE id = ? AND coin = ? AND amount <= 0",
        { identifier, coin }
    )

    return true
end

local function getIdentifierAndSource(target)
    if type(target) == "number" then
        return GetIdentifier(target) or target, target
    end

    return target, GetSourceFromIdentifier(target)
end


CreateThread(function()
    if not Config.Crypto.Coins or not next(Config.Crypto.Coins) then
        cryptoLoaded = true
        return
    end

    while not DatabaseCheckerFinished do
        Wait(500)
    end

    if table.type(Config.Crypto.Coins) == "array" then
        infoprint("error", "Config.Crypto.Coins is an array, but it should be an object.")
    end

    local lastUpdated = GetResourceKvpInt("crypto:lastUpdated") or 0
    local lastTrackedPrice = GetResourceKvpInt("crypto:lastTrackedPrice") or 0
    local updateInterval = math.floor((Config.Crypto.UpdateInterval or 5) * 60 * 1000)
    local timeUntilNextUpdate = updateInterval - (os.time() * 1000 - lastUpdated * 1000)
    local trackInterval = math.max(900, math.floor(updateInterval / 1000))
    local maxTrackedPrices = math.floor(86400 / trackInterval)

    for symbol, coinConfig in pairs(Config.Crypto.Coins) do
        coins[symbol] = {
            id = symbol,
            name = coinConfig.name,
            symbol = symbol,
            permissions = coinConfig.permissions,
            change_24h = 0,
            current_price = math.clamp(coinConfig.initialValue, 0.1, math.huge),
            image = coinConfig.icon,
            prices = {}
        }
    end

    local savedCoins = MySQL.query.await("SELECT coin, coin_value FROM phone_crypto_coins")

    for i = 1, #savedCoins do
        local savedCoin = savedCoins[i]
        local coin = coins[savedCoin.coin]

        if not coin then
            debugprint("Unknown coin in database:", savedCoin.coin)
        else
            coin.current_price = savedCoin.coin_value

            local historyJson = GetResourceKvpString("crypto:history:" .. savedCoin.coin)

            if historyJson then
                local history = json.decode(historyJson)
                local cutoff = os.time() - 86400

                coin.prices = {}

                for j = #history, 1, -1 do
                    local entry = history[j]

                    if cutoff <= entry.time then
                        coin.prices[#coin.prices + 1] = entry.value
                    else
                        table.remove(history, j)
                    end
                end

                coinHistory[savedCoin.coin] = history

                if #history >= 2 then
                    local firstPrice = history[1].value
                    local latestPrice = history[#history].value

                    coin.change_24h = firstPrice ~= 0 and ((latestPrice - firstPrice) / firstPrice * 100) or 0
                end
            end
        end
    end

    cryptoLoaded = true

    if timeUntilNextUpdate > 0 and updateInterval > timeUntilNextUpdate then
        debugprint("waiting " .. math.floor(timeUntilNextUpdate / 1000) .. "s until next crypto update")
        Wait(timeUntilNextUpdate)
    end

    local changeWeights = {}

    for symbol, coinConfig in pairs(Config.Crypto.Coins) do
        local weights = {}

        for i = 1, #coinConfig.changes do
            weights[i] = coinConfig.changes[i].weight
        end

        changeWeights[symbol] = weights
    end

    while true do
        local startTime = os.nanotime()

        debugprint("Updating crypto coins")

        local coinValues = {}
        local currentTime = os.time()
        local shouldTrackPrice = trackInterval <= currentTime - lastTrackedPrice

        if shouldTrackPrice then
            lastTrackedPrice = currentTime
            SetResourceKvpInt("crypto:lastTrackedPrice", lastTrackedPrice)
        end

        for symbol, coinConfig in pairs(Config.Crypto.Coins) do
            local coin = coins[symbol]
            local changeConfig = coinConfig.changes[weightedRandomIndex(changeWeights[symbol])]
            local changeRange = changeConfig and changeConfig.change or { 0, 0 }
            local percentChange = changeRange[1] + math.random() * (changeRange[2] - changeRange[1])
            local newPrice = math.max(coin.current_price + coin.current_price * (percentChange / 100), 0.001)

            debugprint(("Coin ^4%s^7: %s%.2f%%^7 -> new price: %s%.2f^7, old price: %s%.2f^7"):format(
                symbol,
                percentChange > 0 and "^2+" or "^1",
                percentChange,
                percentChange > 0 and "^2" or "^1",
                newPrice,
                percentChange > 0 and "^1" or "^2",
                coin.current_price
            ))

            coin.current_price = newPrice

            if shouldTrackPrice then
                coinHistory[symbol] = coinHistory[symbol] or {}

                local history = coinHistory[symbol]

                while maxTrackedPrices <= #coin.prices do
                    table.remove(coin.prices, 1)
                end

                while maxTrackedPrices <= #history do
                    table.remove(history, 1)
                end

                coin.prices[#coin.prices + 1] = coin.current_price
                history[#history + 1] = {
                    time = currentTime,
                    value = coin.current_price
                }

                SetResourceKvp("crypto:history:" .. symbol, json.encode(history))
            end

            coin.change_24h = calculateChange24h(coin.prices)
            coinValues[#coinValues + 1] = { symbol, coin.current_price }
        end

        MySQL.prepare.await(
            "INSERT INTO phone_crypto_coins (coin, coin_value) VALUES (?, ?) ON DUPLICATE KEY UPDATE coin_value = VALUES(coin_value)",
            coinValues
        )

        SetResourceKvpInt("crypto:lastUpdated", os.time())
        broadcastToOpenCryptoApps("phone:crypto:updateCoins", coins)

        local elapsedMs = (os.nanotime() - startTime) / 1000000.0

        debugprint(("Updated crypto coins in %.4fms."):format(elapsedMs))
        Wait(updateInterval)
    end
end)

local function processCryptoRefund(source, identifier, ownedCoins)
    refundedIdentifiers[identifier] = true

    if GetResourceKvpInt("crypto:refund:" .. identifier) == 1 then
        debugprint("refund already processed for identifier", identifier)
        return
    end

    local refundAmount = 0
    local obsoleteCoins = {}
    local phoneNumber = GetEquippedPhoneNumber(source)

    for i = 1, #ownedCoins do
        local ownedCoin = ownedCoins[i]

        if not coins[ownedCoin.coin] and ownedCoin.amount > 0 then
            obsoleteCoins[#obsoleteCoins + 1] = ownedCoin
        end
    end

    if Config.Crypto.Refund == "invested" then
        for i = 1, #obsoleteCoins do
            refundAmount = refundAmount + obsoleteCoins[i].invested
        end
    elseif Config.Crypto.Refund == "lastValue" then
        for i = 1, #obsoleteCoins do
            local ownedCoin = obsoleteCoins[i]
            local oldCoin = oldCoinData[ownedCoin.coin]

            if not oldCoin then
                infoprint(
                    "warning",
                    "no old coin data found for coin",
                    ownedCoin.coin,
                    "- cannot refund last value. Consider changing refund method to 'invested'"
                )
                return
            end

            refundAmount = refundAmount + ownedCoin.amount * oldCoin.current_price
        end
    elseif Config.Crypto.Refund == "convert" then
        if not Config.Crypto.Coins.lbc then
            infoprint("warning", "Config.Crypto.Refund is set to 'convert', but LB Coin is not configured as a crypto coin")
            return
        end

        local lbCoin = coins.lbc

        if not lbCoin then
            infoprint("warning", "LB Coin data not found - cannot convert old crypto to lbc")
            return
        end

        local oldValue = 0

        for i = 1, #obsoleteCoins do
            local ownedCoin = obsoleteCoins[i]
            local oldCoin = oldCoinData[ownedCoin.coin]

            if not oldCoin then
                infoprint(
                    "warning",
                    "no old coin data found for coin",
                    ownedCoin.coin,
                    "- cannot convert to lbc. Consider changing refund method to 'invested'"
                )
                return
            end

            oldValue = oldValue + ownedCoin.amount * oldCoin.current_price
        end

        local lbCoinAmount = oldValue / math.max(lbCoin.current_price, 0.01)

        debugprint("Converting old crypto to LB Coin at rate", lbCoin.current_price, "-> refund amount in LBC:", lbCoinAmount)
        addCrypto(identifier, "lbc", lbCoinAmount, oldValue)

        if phoneNumber then
            SendNotification(phoneNumber, {
                app = "Crypto",
                title = L("APPS.CRYPTO.CONVERT_NOTIFICATION.TITLE"),
                content = L("APPS.CRYPTO.CONVERT_NOTIFICATION.DESCRIPTION", {
                    amount = math.round(lbCoinAmount, 3),
                    coinName = lbCoin.name
                })
            })
        end
    end

    if refundAmount > 0 then
        refundAmount = math.floor(refundAmount + 0.5)

        debugprint("Refund", source, "with amount", refundAmount)
        AddMoney(source, refundAmount)

        if phoneNumber then
            AddTransaction(phoneNumber, refundAmount, L("APPS.CRYPTO.REFUND_TRANSACTION"), "./assets/img/icons/apps/Crypto.jpg")
        end
    end

    local coinsToDelete = {}

    for i = 1, #obsoleteCoins do
        coinsToDelete[#coinsToDelete + 1] = obsoleteCoins[i].coin
    end

    if #coinsToDelete > 0 then
        MySQL.update.await(
            "DELETE FROM phone_crypto WHERE id = ? AND coin IN (?)",
            { identifier, coinsToDelete }
        )
    end

    SetResourceKvpInt("crypto:refund:" .. identifier, 1)
end


RegisterCallback("crypto:get", function(source)
    local identifier = GetIdentifier(source)

    if not identifier then
        return {}
    end

    while not cryptoLoaded or not DatabaseCheckerFinished do
        Wait(500)
    end

    local ownedCoins = MySQL.query.await(
        "SELECT coin, amount, invested FROM phone_crypto WHERE id = ?",
        { identifier }
    )

    local clonedCoins = table.deep_clone(coins)

    for i = 1, #ownedCoins do
        local ownedCoin = ownedCoins[i]
        local coin = ownedCoin and clonedCoins[ownedCoin.coin]

        if coin then
            coin.owned = ownedCoin.amount
            coin.invested = ownedCoin.invested
        end
    end

    if Config.Crypto.Refund and not refundedIdentifiers[identifier] then
        processCryptoRefund(source, identifier, ownedCoins)
    end

    return clonedCoins
end, {
    preventSpam = true
})

RegisterCallback("crypto:buy", function(source, coinId, moneyAmount)
    local identifier = GetIdentifier(source)
    local balance = GetBalance(source)

    if moneyAmount <= 0 then
        return { success = false, msg = "INVALID_AMOUNT" }
    end

    if moneyAmount > cryptoLimits.Buy then
        debugprint(moneyAmount, "is above crypto buy limit")
        return { success = false, msg = "INVALID_AMOUNT" }
    end

    if moneyAmount > balance then
        return { success = false, msg = "NO_MONEY" }
    end

    local coin = coins[coinId]

    if not coin then
        return { success = false, msg = "INVALID_COIN" }
    end

    if coin.permissions and coin.permissions.buy == false then
        return { success = false, msg = "BUY_DISABLED" }
    end

    if not identifier then
        return { success = false, msg = "NO_IDENTIFIER" }
    end

    if not ValidateChecks("buyCrypto", source, coinId, moneyAmount) then
        return { success = false, msg = "CHECK_FAILED" }
    end

    if coin.current_price <= 0 then
        debugprint("current price for coin", coinId, "is less than 0:", coin.current_price)
        return { success = false, msg = "INVALID_COIN_PRICE" }
    end

    local cryptoAmount = moneyAmount / coin.current_price

    addCrypto(identifier, coinId, cryptoAmount, moneyAmount)
    RemoveMoney(source, moneyAmount)

    Log("Crypto", source, "info", L("BACKEND.LOGS.BOUGHT_CRYPTO"), L("BACKEND.LOGS.CRYPTO_DETAILS", {
        coin = coinId,
        amount = cryptoAmount,
        price = moneyAmount
    }))

    return { success = true }
end, {
    preventSpam = true
})

RegisterCallback("crypto:sell", function(source, coinId, amount)
    local identifier = GetIdentifier(source)

    if amount <= 0 then
        return { success = false, msg = "INVALID_AMOUNT" }
    end

    if not identifier then
        return { success = false, msg = "NO_IDENTIFIER" }
    end

    local coin = coins[coinId]

    if not coin then
        return { success = false, msg = "INVALID_COIN" }
    end

    if coin.permissions and coin.permissions.sell == false then
        return { success = false, msg = "SELL_DISABLED" }
    end

    local ownedCoin = MySQL.single.await(
        "SELECT amount, invested FROM phone_crypto WHERE id = ? AND coin = ?",
        { identifier, coinId }
    )

    if not ownedCoin then
        return { success = false, msg = "NO_COINS" }
    end

    if amount > ownedCoin.amount then
        return { success = false, msg = "NOT_ENOUGH_COINS" }
    end

    local payout = amount * coin.current_price
    local investedReduction = 0

    if ownedCoin.invested > 0 then
        investedReduction = amount / ownedCoin.amount * ownedCoin.invested
    end

    if payout > cryptoLimits.Sell then
        debugprint(payout, "is above crypto sell limit")
        return { success = false, msg = "INVALID_AMOUNT" }
    end

    if not ValidateChecks("sellCrypto", source, coinId, amount) then
        return { success = false, msg = "CHECK_FAILED" }
    end

    MySQL.update.await(
        "UPDATE phone_crypto SET amount = GREATEST(amount - ?, 0), invested = GREATEST(invested - ?, 0) WHERE id = ? AND coin = ?",
        { amount, investedReduction, identifier, coinId }
    )

    MySQL.update.await(
        "DELETE FROM phone_crypto WHERE id = ? AND coin = ? AND amount <= 0",
        { identifier, coinId }
    )

    AddMoney(source, payout)

    Log("Crypto", source, "info", L("BACKEND.LOGS.SOLD_CRYPTO"), L("BACKEND.LOGS.CRYPTO_DETAILS", {
        coin = coinId,
        amount = amount,
        price = payout
    }))

    return { success = true }
end, {
    preventSpam = true
})

BaseCallback("crypto:transfer", function(source, senderNumber, coinId, amount, targetNumber)
    local coin = coins[coinId]

    if not coin then
        return { success = false, msg = "INVALID_COIN" }
    end

    if coin.permissions and coin.permissions.transfer == false then
        return { success = false, msg = "TRANSFER_DISABLED" }
    end

    if not ValidateChecks("transferCrypto", source, targetNumber, coinId, amount) then
        return { success = false, msg = "CHECK_FAILED" }
    end

    local targetSource = GetSourceFromNumber(targetNumber)
    local targetIdentifier

    if targetSource then
        targetIdentifier = GetIdentifier(targetSource)
    elseif not Config.Item.Unique then
        targetIdentifier = MySQL.scalar.await("SELECT id FROM phone_phones WHERE phone_number = ?", { targetNumber })
    else
        targetIdentifier = MySQL.scalar.await("SELECT owned_id FROM phone_phones WHERE phone_number = ?", { targetNumber })
    end

    if not targetIdentifier then
        return { success = false, msg = "INVALID_NUMBER" }
    end

    local senderIdentifier = GetIdentifier(source)

    if not senderIdentifier then
        return { success = false, msg = "NO_IDENTIFIER" }
    end

    if amount <= 0 then
        return { success = false, msg = "INVALID_AMOUNT" }
    end

    local removed, errorMessage = removeCrypto(senderIdentifier, coinId, amount)

    if not removed then
        return { success = false, msg = errorMessage or "TRANSFER_FAILED" }
    end

    addCrypto(targetIdentifier, coinId, amount)

    SendNotification(targetNumber, {
        app = "Crypto",
        title = L("BACKEND.CRYPTO.RECEIVED_TRANSFER_TITLE", {
            coin = coin.name
        }),
        content = L("BACKEND.CRYPTO.RECEIVED_TRANSFER_DESCRIPTION", {
            amount = amount,
            coin = coin.name,
            value = math.floor(amount * coin.current_price + 0.5)
        })
    })

    Log("Crypto", source, "info", L("BACKEND.LOGS.TRANSFERRED_CRYPTO"), L("BACKEND.LOGS.TRANSFERRED_CRYPTO_DETAILS", {
        coin = coinId,
        amount = amount,
        to = targetNumber,
        from = senderNumber
    }))

    if targetSource then
        TriggerClientEvent("phone:crypto:changeOwnedAmount", targetSource, coinId, amount)
    end

    return { success = true }
end, {
    preventSpam = true
})

RegisterNetEvent("phone:crypto:fetchCoins", function()
    TriggerLatentClientEvent("phone:crypto:updateCoins", source, 1000000.0, coins)
end)

exports("AddCrypto", function(target, coinId, amount)
    local identifier, targetSource = getIdentifierAndSource(target)

    if not coins[coinId] then
        print("AddCrypto: invalid coin", coinId)
        return false
    end

    if not identifier then
        print("AddCrypto: failed to get identifier", identifier)
        return false
    end

    addCrypto(identifier, coinId, amount)

    if targetSource then
        TriggerClientEvent("phone:crypto:changeOwnedAmount", targetSource, coinId, amount)
    end

    return true
end)

exports("RemoveCrypto", function(target, coinId, amount)
    local identifier, targetSource = getIdentifierAndSource(target)

    if not coins[coinId] then
        print("RemoveCrypto: invalid coin", coinId)
        return false
    end

    if not identifier then
        print("RemoveCrypto: failed to get identifier", identifier, target)
        return false
    end

    local removed, errorMessage = removeCrypto(identifier, coinId, amount)

    if not removed then
        return print("RemoveCrypto:", errorMessage or "failed to remove crypto")
    end

    if targetSource then
        TriggerClientEvent("phone:crypto:changeOwnedAmount", targetSource, coinId, -amount)
    end

    return true
end)

exports("GetOwnedCoin", function(target, coinId)
    local identifier = getIdentifierAndSource(target)

    if not coins[coinId] then
        print("GetOwnedCoin: invalid coin", coinId)
        return false
    end

    if not identifier then
        print("GetOwnedCoin: failed to get identifier", identifier)
        return false
    end

    local ownedCoin = MySQL.single.await(
        "SELECT amount, invested FROM phone_crypto WHERE id = ? AND coin = ?",
        { identifier, coinId }
    ) or {
        amount = 0,
        invested = 0
    }

    local coin = table.clone(coins[coinId])

    coin.owned = ownedCoin.amount
    coin.invested = ownedCoin.invested

    return coin
end)

exports("AddCustomCoin", function(id, name, symbol, image, currentPrice, prices, change24h, permissions)
    assert(type(id) == "string", "id must be a string")
    assert(type(name) == "string", "name must be a string")
    assert(type(symbol) == "string", "symbol must be a string")
    assert(type(image) == "string", "image must be a string")
    assert(type(currentPrice) == "number", "currentPrice must be a number")
    assert(type(prices) == "table", "prices must be a table")
    assert(type(change24h) == "number", "change24h must be a number")
    assert(permissions == nil or type(permissions) == "table", "permissions must be a table or nil")

    if permissions then
        assert(permissions.buy == nil or type(permissions.buy) == "boolean", "permissions.buy must be a boolean or nil")
        assert(permissions.sell == nil or type(permissions.sell) == "boolean", "permissions.sell must be a boolean or nil")
        assert(permissions.transfer == nil or type(permissions.transfer) == "boolean", "permissions.transfer must be a boolean or nil")
    end

    coins[id] = {
        id = id,
        name = name,
        symbol = symbol,
        image = image,
        current_price = currentPrice,
        prices = prices,
        change_24h = change24h,
        permissions = permissions
    }

    broadcastToOpenCryptoApps("phone:crypto:updateCoins", coins)
end)

exports("GetCoin", function(coinId)
    return coins[coinId]
end)

AddEventHandler("playerDropped", function()
    local exists, index = table.contains(appOpenPlayers, source)

    if index then
        table.remove(appOpenPlayers, index)
    end
end)
