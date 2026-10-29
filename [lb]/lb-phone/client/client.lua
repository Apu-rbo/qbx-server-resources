if not OnDeath then function OnDeath() end end
-- ─── Native aliases ──────────────────────────────────────────
local DisableControlAction = DisableControlAction
local IsNuiFocused         = IsNuiFocused
local DisablePlayerFiring  = DisablePlayerFiring

-- ─── Global state ────────────────────────────────────────────
phoneData    = nil    -- full phone data table sent to NUI
currentPhone = nil    -- current player phone number
settings     = nil    -- current phone settings table
phoneOpen    = false  -- is the phone currently open?

SavedLocations = {}   -- saved map locations for the player
PhoneOnScreen  = false -- is the phone currently visible on screen?

-- ─── Module-level upvalues ───────────────────────────────────
local phoneLoaded       = nil   -- true once phone data has been fetched at least once
local isFetchingPhone   = nil   -- true while FetchPhone() is running
local configReceivedByUI = nil  -- true once the NUI has acknowledged receiving config

-- ============================================================
-- WaitForConfig()
-- Blocks until the NUI has acknowledged receiving the config.
-- ============================================================
local function WaitForConfig()
    if configReceivedByUI then
        return
    end

    debugprint("waiting for config to be received")

    while true do
        if configReceivedByUI then
            break
        end
        Wait(0)
    end

    debugprint("config received")
end

-- ============================================================
-- FetchPhone()
-- Loads all phone data for the current player:
--   - retrieves or generates a phone number
--   - loads default settings
--   - loads phone data from server
--   - sends everything to the NUI via setPhoneData
-- ============================================================
local function FetchPhone()
    debugprint("FetchPhone triggered")

    if isFetchingPhone then
        debugprint("already fetching phone")
        return
    end

    if not configReceivedByUI then
        debugprint("config has not been received by the UI yet")
        return
    end

    isFetchingPhone = true

    -- Wait for the game framework (ESX/QBCore/etc.) to finish loading
    while true do
        if FrameworkLoaded then
            break
        end
        debugprint("waiting for framework to load")
        Wait(500)
    end

    debugprint("triggering phone:playerLoaded")

    local phoneNumber = nil

    -- Reuse existing number if already loaded
    if phoneLoaded and currentPhone then
        -- Jump to using the already-stored number
        phoneNumber = SavedLocations  -- NOTE: at this point SavedLocations holds the phone number from a prior fetch
        goto useExistingNumber
    end

    -- First-time load: ask server for the player's number
    do
        local result = AwaitCallback("playerLoaded")
        phoneNumber  = result
        SavedLocations = phoneNumber   -- cache the raw number value temporarily
        phoneLoaded  = true
    end
    goto afterNumberFetch

    ::useExistingNumber::
    phoneNumber = SavedLocations

    ::afterNumberFetch::
    debugprint("got number", phoneNumber)

    -- No number returned; check if player has the phone item
    if not phoneNumber then
        debugprint("no number, checking if player has item")

        if HasPhoneItem() then
            debugprint("player has item; triggering phone:generatePhoneNumber")
            phoneNumber = AwaitCallback("generatePhoneNumber")
            debugprint("got number", phoneNumber)
        else
            debugprint("player does not have item")
        end
    end

    -- Still no number → clean up and abort
    if not phoneNumber then
        isFetchingPhone = false

        if currentPhone then
            debugprint("no number. using SetPhone")
            SetPhone()
        end

        debugprint("no number, returning")
        return
    end

    -- ── Load default settings from JSON file ─────────────────
    local defaultSettings = json.decode(GetConfigFile("defaultSettings.json"))

    -- ── Get latest version info from server ──────────────────
    local latestVersion  = AwaitCallback("getLatestVersion")
    local currentVersion = GetResourceMetadata(GetCurrentResourceName(), "version", 0)

    if not latestVersion then
        latestVersion = currentVersion
    end

    defaultSettings.locale        = Config.DefaultLocale
    defaultSettings.version       = currentVersion
    defaultSettings.latestVersion = latestVersion

    -- ── Fetch full phone data from server ────────────────────
    local isSetup = false
    debugprint("fetching phone data")
    local phoneDataFromServer = AwaitCallback("getPhone", phoneNumber)
    debugprint("got phone data", json.encode(phoneDataFromServer))

    if phoneDataFromServer then
        -- Use server-supplied settings if available, otherwise fall back to defaults
        if phoneDataFromServer.settings then
            defaultSettings = phoneDataFromServer.settings
        end

        -- Resolve display name
        if phoneDataFromServer.name then
            defaultSettings.name = phoneDataFromServer.name
        else
            -- Generate name from character firstname/lastname
            local charName = AwaitCallback("getCharacterName")
            defaultSettings.name = L("BACKEND.MISC.X_PHONE", {
                name     = charName.firstname,
                lastname = charName.lastname,
            })
        end

        defaultSettings.version       = currentVersion
        defaultSettings.latestVersion = latestVersion

        -- Fetch saved map locations
        local savedLocs = AwaitCallback("maps:getSavedLocations")
        SavedLocations  = savedLocs

        -- Determine setup status
        isSetup = phoneDataFromServer.is_setup or isSetup
        if not phoneDataFromServer.is_setup then
            isSetup = false
        end

        currentPhone = phoneNumber

        -- Build the phoneData table that will be sent to NUI
        local newPhoneData = {
            isSetup          = isSetup,
            phoneNumber      = phoneNumber,
            settings         = defaultSettings,
        }

        -- Battery level
        local batteryLevel
        if Config.Battery and Config.Battery.Enabled then
            batteryLevel = phoneDataFromServer.battery
        end
        if not batteryLevel then
            batteryLevel = 100
        end
        newPhoneData.battery = batteryLevel

        -- Server endpoint identifier
        newPhoneData.serverIdentifier = GetCurrentServerEndpoint()

        phoneData = newPhoneData

        -- Wait for config to arrive then push phone data to NUI
        WaitForConfig()

        debugprint("triggering phone:setPhoneData")
        SendNUIAction("setPhoneData", phoneData)

        TriggerEvent("lb-phone:numberChanged", phoneNumber)

        Wait(250)
    end

    -- Fetch crypto coin data if the module exists
    if FetchCryptoCoins then
        FetchCryptoCoins()
    end

    settings        = defaultSettings
    isFetchingPhone = false
end

-- Expose as a global
FetchPhone = FetchPhone  -- re-assign the local to the global name declared above

-- ============================================================
-- RefreshPhone(onlyConfig)
-- Refreshes the NUI config (called on resource start or when
-- WebRTC credentials change).  When onlyConfig is true it does
-- NOT trigger a full FetchPhone() afterwards.
-- ============================================================
local function RefreshPhone(onlyConfig)
    debugprint("RefreshPhone triggered")

    -- If a fetch is already in progress, wait for it to finish first
    if isFetchingPhone then
        debugprint("phone is being fetched, waiting before refreshing")
        while true do
            if not isFetchingPhone then
                break
            end
            Wait(0)
        end
    end

    -- ── Optional: refresh dynamic WebRTC credentials ─────────
    if Config.DynamicWebRTC and Config.DynamicWebRTC.Enabled then
        local iceServers = AwaitCallback("getWebRTCCredentials")

        -- Remove STUN-only entries (entries without a credential) if configured
        if Config.DynamicWebRTC.RemoveStun and iceServers then
            for i = #iceServers, 1, -1 do
                if not iceServers[i].credential then
                    table.remove(iceServers, i)
                end
            end
        end

        -- Apply new ICE servers to Config.RTCConfig
        if iceServers then
            if not Config.RTCConfig then
                Config.RTCConfig = {}
            end
            Config.RTCConfig.iceServers = iceServers
        end
    end

    -- Mark config as not yet received so WaitForConfig() will block appropriately
    configReceivedByUI = false

    -- ── Decode config.json and build the full config object ───
    local configData = json.decode(GetConfigFile("config.json"))

    -- Valet settings
    local valetConfig = {}
    valetConfig.enabled      = Config.Valet and Config.Valet.Enabled and true or false
    valetConfig.price        = Config.Valet and Config.Valet.Price or 0
    valetConfig.vehicleTypes = (Config.Valet and Config.Valet.VehicleTypes) or {"car"}
    configData.valet = valetConfig

    -- Map locations
    configData.locations = Config.Locations

    -- External URL settings
    configData.AllowExternal             = Config.AllowExternal
    configData.ExternalBlacklistedDomains = Config.ExternalBlacklistedDomains
    configData.ExternalWhitelistedDomains = Config.ExternalWhitelistedDomains

    -- Misc config options passed verbatim to NUI
    configData.EmailDomain        = Config.EmailDomain
    configData.RealTime           = Config.RealTime
    configData.CurrencyFormat     = Config.CurrencyFormat
    configData.DeleteMessages     = Config.DeleteMessages
    configData.Battery            = Config.Battery
    configData.rtc                = Config.RTCConfig
    configData.PromoteBirdy       = Config.PromoteBirdy
    configData.Verified           = Config.Verified
    configData.LiveTray           = Config.LiveTray
    configData.SetupScreen        = Config.SetupScreen
    configData.MaxTransferAmount  = Config.MaxTransferAmount
    configData.EnableMessagePay   = Config.EnableMessagePay
    configData.EnableGIFs         = Config.EnableGIFs
    configData.GIFsFilter         = Config.GIFsFilter or "low"
    configData.EnableVoiceMessages = Config.EnableVoiceMessages
    configData.DefaultLocale      = Config.DefaultLocale
    configData.DateLocale         = Config.DateLocale
    configData.Debug              = Config.Debug

    -- TikTok TTS voices (fallback to English US female if not configured)
    configData.TikTokTTS = Config.TrendyTTS or {{"English (US) - Female", "en_us_001"}}

    -- Voice settings
    configData.recordNearbyVoices = Config.Voice and Config.Voice.RecordNearby

    -- Phone frame appearance
    configData.frameColor           = Config.FrameColor
    configData.allowFrameColorChange = Config.AllowFrameColorChange

    -- Unlock keybind
    configData.unlockPhoneKey = Config.KeyBinds
        and Config.KeyBinds.UnlockPhone
        and Config.KeyBinds.UnlockPhone.Bind
        or nil

    -- Account management flags
    configData.DeleteMail     = Config.DeleteMail
    configData.ChangePassword = Config.ChangePassword
    configData.DeleteAccount  = Config.DeleteAccount

    -- Camera walkable mode
    configData.CustomCamera = (Config.Camera and Config.Camera.Walkable) or false

    -- Username regex filter
    configData.UsernameFilter = (Config.UsernameFilter and Config.UsernameFilter.Regex) or "[a-zA-Z0-9]+"

    -- Crypto limits
    if Config.Crypto and Config.Crypto.Limits then
        configData.CryptoLimit = Config.Crypto.Limits
    else
        configData.CryptoLimit = {Buy = 1000000, Sell = 1000000}
    end

    -- Browser & custom maps
    configData.Browser    = Config.Browser
    configData.CustomMaps = Config.CustomMaps

    -- Sound configuration
    configData.sound = {
        system           = Config.Sound and Config.Sound.System,
        ringtones        = Config.Sound and Config.Sound.Ringtones,
        notifications    = Config.Sound and Config.Sound.Notifications,
        appNotifications = Config.Sound and Config.Sound.AppNotifications,
    }

    -- App store / marketplace settings
    configData.AppDownloadTime = Config.AppDownloadTime
    configData.Pages           = Config.Pages
    configData.Marketplace     = Config.Marketplace

    -- Phone number length (digits + prefix length)
    local numberLength = (Config.PhoneNumber and Config.PhoneNumber.Length) or 7
    local prefixLength = 0
    if Config.PhoneNumber
        and Config.PhoneNumber.Prefixes
        and #Config.PhoneNumber.Prefixes > 0
    then
        local firstPrefix = Config.PhoneNumber.Prefixes[1]
        if firstPrefix then
            prefixLength = #firstPrefix
        end
    end
    configData.PhoneNumberLength = numberLength + prefixLength
    configData.Format            = Config.PhoneNumber and Config.PhoneNumber.Format

    -- Image capture options
    configData.imageOptions = {
        mime    = (Config.Image and Config.Image.Mime) or "image/png",
        quality = (Config.Image and Config.Image.Quality) or 1.0,
    }

    -- Video recording options
    configData.videoOptions = {
        bitrate       = (Config.Video and Config.Video.Bitrate) or 250,
        audioBitrate  = (Config.Video and Config.Video.AudioBitrate) or 128,
        variableBitrate = (Config.Video and Config.Video.VariableBitrate) or false,
        size          = (Config.Video and Config.Video.MaxSize) or 10,
        duration      = (Config.Video and Config.Video.MaxDuration) or 60,
        fps           = (Config.Video and Config.Video.FrameRate) or 24,
    }

    -- Companies / services (deep-cloned so NUI changes don't affect Config)
    configData.Companies = table.deep_clone(Config.Companies)

    -- Strip onCustomIconClick callbacks (functions can't be serialized to NUI)
    if configData.Companies and configData.Companies.Services then
        for i = 1, #configData.Companies.Services do
            local service = configData.Companies.Services[i]
            if service.onCustomIconClick then
                service.onCustomIconClick = true  -- replace function with bool flag
            end
        end
    end

    -- Inject custom apps defined in Config.CustomApps
    if Config.CustomApps then
        for appKey, appData in pairs(Config.CustomApps) do
            configData.apps[appKey] = FormatCustomAppDataForUI(appData)
        end
    end

    -- Apply job-based app access flags
    for appKey, appData in pairs(configData.apps) do
        appData.access = HasAccessToApp(appKey)
    end

    -- Load default settings JSON for the NUI
    configData.defaultSettings = json.decode(GetConfigFile("defaultSettings.json"))

    -- ── Helper: remove an app from defaultSettings.apps pages ─
    local function RemoveFromDefaultSettingsApps(appName)
        local pages = configData.defaultSettings.apps
        for pageIndex = 1, #pages do
            local page = pages[pageIndex]
            for slotIndex = 1, #page do
                if page[slotIndex] == appName then
                    table.remove(page, slotIndex)
                    break
                end
            end
        end
    end

    -- ── Remove inapplicable apps based on framework / config ──

    -- Standalone framework without CustomFramework: strip economy/job apps
    if Config.Framework == "standalone" and not Config.CustomFramework then
        configData.apps.Wallet   = nil
        configData.apps.Home     = nil
        configData.apps.Garage   = nil
        configData.apps.Services = nil
        RemoveFromDefaultSettingsApps("Wallet")
        RemoveFromDefaultSettingsApps("Home")
        RemoveFromDefaultSettingsApps("Garage")
        RemoveFromDefaultSettingsApps("Services")
    end

    -- No house script → remove Home app
    if not Config.HouseScript then
        configData.apps.Home = nil
        debugprint("No Config.HouseScript, removed home app")
        RemoveFromDefaultSettingsApps("Home")
    end

    -- Crypto disabled → remove Crypto app
    if not (Config.Crypto and Config.Crypto.Enabled) then
        configData.apps.Crypto = nil
        debugprint("Config.Crypto not enabled, removed crypto app")
        RemoveFromDefaultSettingsApps("Crypto")
    end

    -- Apply hidden-app flags from GetHiddenApps()
    for appKey, isHidden in pairs(GetHiddenApps()) do
        if configData.apps[appKey] then
            configData.apps[appKey].hidden = isHidden
        end
    end

    -- ── Send final config to NUI ──────────────────────────────
    SendNUIAction("setConfig", configData)

    WaitForConfig()

    -- If we already have phone data, just resend it; don't re-fetch
    if phoneData then
        debugprint("phoneData is defined")
        SendNUIAction("setPhoneData", phoneData)
        return
    end

    -- onlyConfig=true means caller just wants the config pushed, not a full fetch
    if onlyConfig then
        return
    end

    FetchPhone()
end

-- Expose as global
RefreshPhone = RefreshPhone

-- ============================================================
-- NET EVENT: lb-phone:jobUpdated
-- Fired by the framework when the player's job/grade changes.
-- Updates per-app access flags in the NUI.
-- ============================================================
RegisterNetEvent("lb-phone:jobUpdated")
AddEventHandler("lb-phone:jobUpdated", function(jobInfo)
    -- Only act if whitelist or blacklist app config is present
    if not Config.WhitelistApps and not Config.BlacklistApps then
        return
    end

    debugprint("Job updated, refreshing whitelisted & blacklisted apps")

    local accessMap = {}

    -- Re-evaluate whitelisted apps
    for appKey in pairs(Config.WhitelistApps) do
        accessMap[appKey] = HasAccessToApp(appKey, jobInfo.job, jobInfo.grade)
    end

    -- Re-evaluate blacklisted apps
    for appKey in pairs(Config.BlacklistApps) do
        accessMap[appKey] = HasAccessToApp(appKey, jobInfo.job, jobInfo.grade)
    end

    -- Re-evaluate custom apps
    for appKey in pairs(Config.CustomApps) do
        accessMap[appKey] = HasAccessToApp(appKey, jobInfo.job, jobInfo.grade)
    end

    SendNUIAction("app:setHasAccess", accessMap)
end)

-- ============================================================
-- NUI CALLBACK: configReceived
-- The NUI fires this when it has successfully received and
-- processed the config sent by RefreshPhone().
-- ============================================================
RegisterNUICallback("configReceived", function(data, cb)
    debugprint("UI has received the config (configReceived triggered)")
    configReceivedByUI = true
    cb("ok")
end)

-- ============================================================
-- NUI CALLBACK: getPhoneData
-- The NUI requests phone data on first load.
-- Waits for the framework, then triggers RefreshPhone().
-- ============================================================
RegisterNUICallback("getPhoneData", function(data, cb)
    debugprint("getPhoneData triggered")

    while true do
        if FrameworkLoaded then
            break
        end
        Wait(500)
    end

    Wait(1000)
    RefreshPhone()

    if not cb then
        debugprint("cb is not defined in getPhoneData", data)
        return
    end

    cb(true)
end)

-- ============================================================
-- DisableControlsWhileOpen()  (local, unnamed thread function)
-- Runs in a thread while the phone is open.
-- Disables GTA controls so the player can interact with the NUI.
-- Also handles the walking-camera state when the phone closes.
-- ============================================================
local function DisableControlsWhileOpen()
    local playerId = PlayerId()

    -- ── Main loop: disable controls every frame while phone is open ──
    while phoneOpen do
        Wait(0)

        -- Movement / combat controls to block
        DisableControlAction(0, 199, true)  -- aim
        DisableControlAction(0, 200, true)  -- attack
        DisableControlAction(0, 24,  true)  -- attack (melee)
        DisableControlAction(0, 25,  true)  -- aim (melee)
        DisableControlAction(0, 69,  true)  -- special ability
        DisableControlAction(0, 70,  true)  -- special ability secondary
        DisableControlAction(0, 91,  true)  -- vehicle attack
        DisableControlAction(0, 92,  true)  -- vehicle attack 2
        DisableControlAction(0, 106, true)  -- vehicle mouse control override
        DisableControlAction(0, 114, true)  -- vehicle fly attack
        DisableControlAction(0, 140, true)  -- melee attack light
        DisableControlAction(0, 141, true)  -- melee attack heavy
        DisableControlAction(0, 142, true)  -- melee attack alternate
        DisableControlAction(0, 257, true)  -- attack 2
        DisableControlAction(0, 263, true)  -- melee attack 1
        DisableControlAction(0, 264, true)  -- melee attack 2
        DisableControlAction(0, 330, true)  -- phone camera
        DisableControlAction(0, 331, true)  -- phone camera secondary

        -- Disable player firing
        DisablePlayerFiring(playerId, true)

        -- If NUI has focus, also disable additional actions
        if IsNuiFocused() then
            DisableControlAction(0, 1,   true)  -- look left-right
            DisableControlAction(0, 2,   true)  -- look up-down
            DisableControlAction(0, 245, true)  -- cinematic camera
            DisableControlAction(0, 14,  true)  -- select next weapon
            DisableControlAction(0, 15,  true)  -- select prev weapon
            DisableControlAction(0, 16,  true)  -- skip cutscene
            DisableControlAction(0, 17,  true)  -- phone
            DisableControlAction(0, 37,  true)  -- select weapon
            DisableControlAction(0, 50,  true)  -- cinematic slowmo
            DisableControlAction(0, 99,  true)  -- aim in vehicle
            DisableControlAction(0, 115, true)  -- radio wheel
            DisableControlAction(0, 180, true)  -- special ability primary
            DisableControlAction(0, 181, true)  -- special ability secondary
            DisableControlAction(0, 198, true)  -- phone
            DisableControlAction(0, 241, true)  -- sprint
            DisableControlAction(0, 242, true)  -- jump
            DisableControlAction(0, 261, true)  -- talk
            DisableControlAction(0, 262, true)  -- talk 2
            DisableControlAction(0, 85,  true)  -- vehicle handbrake
        end
    end

    -- ── Post-loop: keep disabling attack control until released ──
    while true do
        local stillPressed = IsDisabledControlPressed(0, 200)
        if not stillPressed then
            break
        end
        DisableControlAction(0, 200, true)
        Wait(0)
    end

    -- ── Handle walkable camera cleanup when phone closes ─────
    if cameraOpen then
        if IsWalkingCamEnabled() then
            local wasSelfie = IsSelfieCam()
            DisableWalkableCam()

            -- Wait until phone re-opens
            while true do
                if phoneOpen then
                    break
                end
                Wait(500)
            end

            -- Restore camera if still applicable
            if cameraOpen then
                SetPhoneAction("camera")
                EnableWalkableCam(wasSelfie)
            end
        end
    end
end

-- ============================================================
-- ToggleOpen(open, keepFocus)
-- The main function to open or close the phone.
--   open       – boolean (or nil to toggle)
--   keepFocus  – if true, NUI focus is NOT set (caller manages it)
-- ============================================================
local isTogglingOpen = false  -- re-entrancy guard (L9_1)

function ToggleOpen(open, keepFocus)
    local calledBy = GetInvokingResource()

    -- Re-entrancy guard
    if isTogglingOpen then
        return
    end

    -- Resolve boolean: nil/non-bool → toggle current state
    if type(open) ~= "boolean" then
        open = not phoneOpen
    end
    open = (open == true)

    debugprint("ToggleOpen(" .. tostring(open) .. ", " .. tostring(keepFocus) .. ")", "triggered by", calledBy)

    -- ── Pre-condition guards ──────────────────────────────────

    -- Phone is disabled
    if phoneDisabled and open then
        debugprint("phone is disabled, returning")
        return
    end

    -- Already in desired state
    if phoneOpen == open then
        debugprint("phoneOpen & open are both the same value, returning")
        return
    end

    -- Framework not yet loaded
    if not FrameworkLoaded and open then
        infoprint("warning", "Framework not loaded")
        return
    end

    -- Player ped is dead/dying
    if open then
        local ped  = PlayerPedId()
        local dead = IsPedDeadOrDying(ped, true)
        if dead then
            debugprint("player ped is dead/dying, returning")
            return
        end
    end

    -- CanOpenPhone check
    if open then
        if CanOpenPhone then
            if not CanOpenPhone() then
                debugprint("CanOpenPhone returned false, returning")
                return
            end
        end
    end

    -- ValidateChecks (server-side validation hook)
    if open then
        if not ValidateChecks("openPhone") then
            debugprint("ValidateChecks returned false for openPhone, returning")
            return
        end
    end

    -- Don't open while another resource has NUI focus
    if open then
        if IsNuiFocused() then
            if Config.DisableOpenNUI then
                infoprint("info", "Not opening the phone as another script has NUI focus. You can disable this behavior by setting Config.DisableOpenNUI to false.")
                return
            end
        end
    end

    -- Don't open if lb-tablet is open
    if open then
        if GetResourceState("lb-tablet") == "started" then
            if not Config.DisableTabletOpenPhone then
                local ok, tabletOpen = pcall(function()
                    return exports["lb-tablet"]:IsOpen()
                end)
                if ok and tabletOpen then
                    infoprint("info", "Not opening the phone as the tablet is open. You can disable this behavior by adding Config.DisableTabletOpenPhone = true to the config.")
                    return
                end
            end
        end
    end

    -- ── Wait for any in-progress fetch to complete ────────────
    if isFetchingPhone then
        isTogglingOpen = true
        while true do
            if not isFetchingPhone then
                break
            end
            Wait(0)
        end
        isTogglingOpen = false
    end

    -- ── Ensure a phone number exists before opening ───────────
    if open then
        if not currentPhone then
            debugprint("no phone, fetching")
            FetchPhone()
            if not currentPhone then
                debugprint("still no phone after fetching, returning")
                return
            end
        end
    end

    -- ── Verify the player still has the phone item ────────────
    if open then
        local hasItem = HasPhoneItem(currentPhone)
        if not hasItem then
            debugprint("HasPhoneItem returned false. Phone number:", tostring(currentPhone))
            TriggerServerEvent("phone:togglePhone")
            SendNUIAction("closePhone")
            return
        end
    end

    -- ── Selfie cam cleanup on close ───────────────────────────
    if not open then
        if IsWalkingCamEnabled() then
            if IsSelfieCam() then
                ToggleSelfieCam(false)
            end
        end
    end

    -- ── End live stream on close (if configured) ──────────────
    if not open then
        if Config.EndLiveClose then
            local liveData = IsWatchingLive()
            EndLive()
            if liveData then
                SendNUIAction("instagram:liveEnded", liveData)
            end
        end
    end

    -- ─────────────────────────────────────────────────────────
    phoneOpen      = open
    isTogglingOpen = true

    if open then
        -- ── OPEN ─────────────────────────────────────────────
        debugprint("should open phone. sending openPhone event to ui")
        SendNUIAction("openPhone")

        if not keepFocus then
            SetNuiFocus(true, true)
            SetNuiFocusKeepInput(Config.KeepInput)
        end

        -- Start the control-disable thread
        if Config.KeepInput then
            CreateThread(DisableControlsWhileOpen)
        end

        -- Start controller input thread (optional, defined elsewhere)
        if ControllerThread then
            CreateThread(ControllerThread)
        end

        debugprint("setting animation action")

        -- Choose the correct hand animation
        if IsWalkingCamEnabled() then
            SetPhoneAction("camera")
        elseif IsInCall() then
            SetPhoneAction("call")
        else
            SetPhoneAction("default")
        end
    else
        -- ── CLOSE ────────────────────────────────────────────
        debugprint("sending closePhone event to ui")
        PlayCloseAnim()
        SetNuiFocus(false, false)
        SetNuiFocusKeepInput(false)
        SendNUIAction("closePhone")
    end

    TriggerServerEvent("phone:togglePhone", open)
    TriggerEvent("lb-phone:phoneToggled", open)

    isTogglingOpen = false
end

-- Expose as global
ToggleOpen = ToggleOpen

-- ============================================================
-- NUI CALLBACK: toggleInput
-- Called by the NUI to enable/disable KeepInput mode
-- (e.g. when the player focuses a text field).
-- ============================================================
RegisterNUICallback("toggleInput", function(hasFocus, cb)
    cb("ok")

    if not Config.KeepInput then
        return
    end

    -- ── Push-To-Talk (PTT) awareness ─────────────────────────
    -- If DisableFocusTalking is enabled, check whether the PTT key
    -- (control 249) is currently held.  If so, wait until it is
    -- released before toggling focus to avoid accidentally muting
    -- voice chat.

    local function isPttActive()
        if Config.DisableFocusTalking then
            if IsDisabledControlPressed(0, 249) then
                return true
            end
        end
        return IsDisabledControlJustReleased(0, 249)
    end

    if isPttActive() then
        if hasFocus then
            -- PTT pressed while gaining focus → ignore this toggle entirely
            debugprint("PTT is pressed, ignoring toggle focus")
            return
        end

        -- PTT pressed while losing focus → wait for key release first
        debugprint("PTT is pressed, waiting before toggling focus")
        while true do
            local stillActive = isPttActive()
            if not stillActive then
                break
            end
            Wait(100)
        end
    end

    -- Small delay when gaining focus so input doesn't bleed
    if hasFocus then
        Wait(200)
    end

    -- Invert: hasFocus=true  → SetNuiFocusKeepInput(false)
    --         hasFocus=false → SetNuiFocusKeepInput(true)
    SetNuiFocusKeepInput(not hasFocus)
end)

-- ============================================================
-- Flag used to debounce the Focus keybind when PTT is also held
-- ============================================================
local focusTogglePending = false  -- (L10_1 in the keybind section)

-- ============================================================
-- EVENT: lb-phone:keyPressed
-- Receives all key actions from keybind / command handlers.
-- ============================================================
AddEventHandler("lb-phone:keyPressed", function(action)
    -- Ignore key presses while the pause menu is active
    if IsPauseMenuActive() then
        return
    end

    -- ── Open / Close ─────────────────────────────────────────
    if action == "Open" then
        debugprint("Pressed open keybind")
        ToggleOpen(not phoneOpen)

    -- ── Toggle NUI focus (used with KeepInput mode) ───────────
    elseif action == "Focus" then
        -- Only valid while phone is open; also bail if already pending
        if not phoneOpen or focusTogglePending then
            return
        end

        -- Wait for PTT to be released if it is held
        local function isPttPressed()
            if Config.DisableFocusTalking then
                if IsDisabledControlPressed(0, 249) then
                    return true
                end
            end
            return IsDisabledControlJustReleased(0, 249)
        end

        if isPttPressed() then
            debugprint("PTT is pressed, waiting before toggling focus")
            focusTogglePending = true
            while true do
                if not IsDisabledControlPressed(0, 249)
                   and not IsDisabledControlJustReleased(0, 249)
                then
                    break
                end
                Wait(0)
            end
            focusTogglePending = false
        end

        local nuiFocused = IsNuiFocused()
        SetNuiFocus(not nuiFocused, not nuiFocused)

        if not nuiFocused then
            -- Gaining focus
            SetNuiFocusKeepInput(Config.KeepInput)
        else
            -- Losing focus
            SetNuiFocusKeepInput(false)
        end

    -- ── Stop all NUI sounds ───────────────────────────────────
    elseif action == "StopSounds" then
        SendNUIAction("stopSounds")
    end

    -- ── Call controls ─────────────────────────────────────────
    if action == "AnswerCall" or action == "DeclineCall" then
        -- Validate that the player is allowed to answer
        if CanOpenPhone then
            if not CanOpenPhone() then
                debugprint("CanOpenPhone returned false, not answering/declining call")
                return
            end
        else
            if not ValidateChecks("openPhone") then
                debugprint("ValidateChecks returned false for openPhone, not answering/declining call")
                return
            end
        end

        if action == "AnswerCall" then
            SendNUIAction("usedCommand", "answer")
        elseif action == "DeclineCall" then
            SendNUIAction("usedCommand", "decline")
        end
    end

    -- ── Camera controls ───────────────────────────────────────
    if action == "TakePhoto" then
        SendNUIAction("camera:usedCommand", "toggleTaking")
    elseif action == "ToggleFlash" then
        SendNUIAction("camera:usedCommand", "toggleFlash")
    elseif action == "LeftMode" then
        SendNUIAction("camera:usedCommand", "leftMode")
    elseif action == "RightMode" then
        SendNUIAction("camera:usedCommand", "rightMode")
    elseif action == "FlipCamera" then
        SendNUIAction("camera:usedCommand", "toggleFlip")
    end
end)

-- ============================================================
-- Register all keybinds / commands defined in Config.KeyBinds
-- ============================================================
for keyName, keyConfig in pairs(Config.KeyBinds) do
    if keyConfig.Command then
        -- Normalise command to lowercase
        keyConfig.Command = keyConfig.Command:lower()

        if keyConfig.Bind then
            -- ── Keybind-based registration ────────────────────
            keyConfig.bindData = AddKeyBind({
                name            = keyConfig.Command,
                description     = keyConfig.Description or "no description",
                defaultKey      = keyConfig.Bind,
                defaultMapper   = keyConfig.Mapper,
                secondaryKey    = keyConfig.SecondaryBind,
                secondaryMapper = keyConfig.SecondaryMapper,

                onPress = function()
                    TriggerEvent("lb-phone:keyPressed", keyName)
                end,

                onRelease = function(duration)
                    -- Also forward release events to lb-tablet if present
                    TriggerEvent("lb-tablet:keyReleased", keyName, duration)
                end,
            })
        else
            -- ── Command-based registration ────────────────────
            RegisterCommand(keyConfig.Command, function()
                TriggerEvent("lb-phone:keyPressed", keyName)
                Wait(0)
                TriggerEvent("lb-phone:keyReleased", keyName, 0)
            end, false)
        end
    end
end

-- ============================================================
-- NUI CALLBACK: finishedSetup
-- Called when the player completes the first-time phone setup screen.
-- ============================================================
RegisterNUICallback("finishedSetup", function(setupData, cb)
    if phoneData then
        phoneData.isSetup = true
    end

    SendNUIAction("setName", setupData.name)
    TriggerServerEvent("phone:setName", setupData.name)
    TriggerServerEvent("phone:togglePhone", phoneOpen)
    TriggerServerEvent("phone:finishedSetup", setupData)

    if Config.AutoBackup then
        TriggerCallback("backup:createBackup")
    end

    cb("ok")
end)

-- ============================================================
-- NUI CALLBACK: isAdmin
-- Checks if the local player is an admin (server-side).
-- ============================================================
RegisterNUICallback("isAdmin", function(data, cb)
    TriggerCallback("isAdmin", cb)
end)

-- ============================================================
-- NUI CALLBACK: setPhoneName
-- Updates the player's display name (only if setup is complete).
-- ============================================================
RegisterNUICallback("setPhoneName", function(name, cb)
    local isSetup = phoneData and phoneData.isSetup

    if isSetup then
        if settings then
            settings.name = name
        end
        TriggerServerEvent("phone:setName", name)
    end

    cb("ok")
end)

-- ============================================================
-- NUI CALLBACK: setSettings
-- Persists the player's phone settings to the server and
-- notifies other client-side systems of the change.
-- ============================================================
RegisterNUICallback("setSettings", function(newSettings, cb)
    debugprint("setSettings triggered")
    cb("ok")

    if not phoneData then
        print("setSettings triggered, but phoneData is nil")
        return
    end

    settings           = newSettings
    phoneData.settings = settings

    AwaitCallback("setSettings", settings)

    -- Update in-call audio volume
    SetCallVolume(settings and settings.sound and settings.sound.callVolume)

    -- Broadcast to other client modules
    TriggerEvent("lb-phone:settingsUpdated", newSettings)

    -- Notify any custom apps that settings have changed
    SendNUIAction("customApp:sendMessage", {
        identifier = "any",
        message    = {
            type    = "settingsUpdated",
            settings = settings,
            action  = "settingsUpdated",
            data    = newSettings,
        },
    })
end)

-- ============================================================
-- NUI CALLBACK: setCursorLocation
-- Moves the system cursor to match the NUI cursor position.
-- Used when KeepInput mode is active so clicks register.
-- ============================================================
RegisterNUICallback("setCursorLocation", function(pos, cb)
    local screenX, screenY = GetActiveScreenResolution()
    SetCursorLocation(pos.x / screenX, pos.y / screenY)
    cb("ok")
end)

-- ============================================================
-- NUI CALLBACK: exitFocus
-- Closes NUI focus and closes the phone entirely.
-- ============================================================
RegisterNUICallback("exitFocus", function(data, cb)
    debugprint("exitFocus triggered")
    SetNuiFocus(false, false)
    ToggleOpen(false)
    cb("ok")
end)

-- ============================================================
-- NUI CALLBACK: getLocales
-- Returns the list of available locales to the NUI.
-- ============================================================
RegisterNUICallback("getLocales", function(data, cb)
    local locales = Config.Locales or {en = "English"}
    cb(locales)
end)

-- ============================================================
-- NUI CALLBACK: setOnScreen
-- Tracks whether the phone is visible on screen and fires a
-- client event when that state changes.
-- ============================================================
RegisterNUICallback("setOnScreen", function(onScreen, cb)
    onScreen = (onScreen == true)

    if onScreen ~= PhoneOnScreen then
        TriggerEvent("lb-phone:setOnScreen", onScreen)
        PhoneOnScreen = onScreen
    end

    cb("ok")
end)

-- ============================================================
-- NUI CALLBACK: restartPhone
-- Closes and re-opens the phone (soft restart).
-- ============================================================
RegisterNUICallback("restartPhone", function(data, cb)
    cb("ok")
    ToggleOpen(false)
    Wait(1000)
    ToggleOpen(true)
end)

-- ============================================================
-- EXPORT: IsPhoneOnScreen
-- Returns true if the phone UI is currently visible.
-- ============================================================
exports("IsPhoneOnScreen", function()
    return PhoneOnScreen
end)

-- ============================================================
-- THREAD: Time & Service updater
-- Waits for the phone number to be set, then continuously
-- sends the current in-game time to the NUI.
-- Also sends the initial service-bar level.
-- ============================================================
CreateThread(function()
    local lastTime = {}

    debugprint("Waiting for currentPhone to be set before updating time & service")

    -- Wait until the player's phone number is available
    while true do
        if currentPhone then
            break
        end
        Wait(500)
    end

    -- Send initial service bars
    local serviceBars, _ = GetServiceBars()
    SendNUIAction("updateService", serviceBars)

    debugprint("currentPhone is set, updating time & service")

    -- Time update loop
    while true do
        -- Real-time mode: the NUI handles clock display itself
        if Config.RealTime then
            break  -- exit the update loop; NUI uses JS Date
        end

        -- Custom time function provided by another resource
        local currentTime
        if Config.CustomTime then
            currentTime = Config.CustomTime()
        end

        if not currentTime then
            currentTime = {
                hour   = GetClockHours(),
                minute = GetClockMinutes(),
            }
        end

        -- Only push an update when the time actually changes
        if currentTime.hour ~= lastTime.hour or currentTime.minute ~= lastTime.minute then
            lastTime.hour   = currentTime.hour
            lastTime.minute = currentTime.minute
            SendNUIAction("updateTime", currentTime)
        end

        Wait(1000)
    end
end)

-- ============================================================
-- GetConfigFile(filename)
-- Reads a file from the resource's config/ folder.
-- Returns the raw file contents as a string.
-- ============================================================
local function GetConfigFile(filename)
    return LoadResourceFile(GetCurrentResourceName(), "config/" .. filename)
end

-- Expose as global
GetConfigFile = GetConfigFile

-- ============================================================
-- NUI CALLBACK: getConfigFile
-- Reads a JSON config file and returns the decoded table.
-- ============================================================
RegisterNUICallback("getConfigFile", function(fileName, cb)
    local rawContent = GetConfigFile(fileName .. ".json")
    local decoded    = json.decode(rawContent)
    cb(decoded)
end)

-- ============================================================
-- Nearby-player cache
--   nearbyPlayers      – cached list of players within 50 m
--   lastPlayerPos      – position when the cache was last rebuilt
--   lastCacheTime      – game timer value at last cache rebuild
-- ============================================================
local nearbyPlayers  = {}
local lastPlayerPos  = vector3(0.0, 0.0, 0.0)
local lastCacheTime  = 0

-- ── Internal: rebuild the nearby-player list ─────────────────
local function RebuildNearbyPlayers()
    local myCoords  = GetEntityCoords(PlayerPedId())
    local allPlayers = GetActivePlayers()
    local result    = {}

    for i = 1, #allPlayers do
        local player = allPlayers[i]

        -- Skip self
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

    nearbyPlayers = result
end

-- ============================================================
-- GetNearbyPlayers()
-- Returns the cached list of nearby players, rebuilding it
-- when the player has moved more than 25 m or 5 s have passed.
-- ============================================================
local function GetNearbyPlayers()
    local now      = GetGameTimer()
    local elapsed  = now - lastCacheTime
    local myCoords = GetEntityCoords(PlayerPedId())
    local moved    = #(myCoords - lastPlayerPos)

    if elapsed > 5000 or moved > 25.0 then
        lastCacheTime  = now
        lastPlayerPos  = myCoords
        RebuildNearbyPlayers()
    end

    return nearbyPlayers
end

-- Expose as global
GetNearbyPlayers = GetNearbyPlayers

-- ============================================================
-- LogOut()
-- Clears all phone state when the player logs out / changes
-- character.  Waits for any in-progress fetch to finish first.
-- ============================================================
local function LogOut()
    debugprint("LogOut triggered")

    while true do
        if not isFetchingPhone then
            break
        end
        debugprint("LogOut triggered, waiting for fetchingPhone to finish...")
        Wait(500)
    end

    ResetSecurity()
    OnDeath()

    phoneData    = nil
    currentPhone = nil
    settings     = nil

    TriggerEvent("lb-phone:numberChanged", nil)
    TriggerCallback("setLastPhone")
end

-- Expose as global
LogOut = LogOut

-- ============================================================
-- SetPhone(phoneNumber, forceRefetch)
-- Switches the active phone number.  Resets phone state,
-- notifies the server, and optionally triggers a new fetch.
-- ============================================================
function SetPhone(phoneNumber, forceRefetch)
    debugprint("SetPhone triggered", phoneNumber, forceRefetch)

    while true do
        if not isFetchingPhone then
            break
        end
        debugprint("SetPhone triggered, waiting for fetchingPhone to finish...")
        Wait(500)
    end

    OnDeath()
    AwaitCallback("setLastPhone", phoneNumber)
    ResetSecurity(true)
    ToggleCharging(false)

    phoneData    = nil
    currentPhone = nil
    settings     = nil

    TriggerEvent("lb-phone:numberChanged", nil)

    -- Fetch data for the new number (or forceRefetch flag is set)
    if phoneNumber or forceRefetch then
        FetchPhone()
    end

    -- If called with nil and no forceRefetch, check for another number
    if phoneNumber == nil and not forceRefetch then
        local firstNumber = GetFirstNumber()
        if firstNumber then
            SetPhone(firstNumber)
        end
    end
end

-- Expose as global
SetPhone = SetPhone

-- ============================================================
-- OnDeath()
-- Cleans up active sessions when the player dies:
--   - ends any active live stream
--   - turns off flashlight
--   - ends any active call
--   - closes the phone
-- ============================================================
local function OnDeath()
    debugprint("OnDeath triggered")

    -- End live stream
    local liveData = IsWatchingLive()
    EndLive()
    if liveData then
        SendNUIAction("instagram:liveEnded", liveData)
    end

    -- Turn off flashlight
    if flashlightEnabled then
        flashlightEnabled = false
        TriggerServerEvent("phone:toggleFlashlight", false)
    end

    EndCall()
    ToggleOpen(false)
end

-- Expose as global
OnDeath = OnDeath

-- ============================================================
-- NET EVENT: phone:toggleOpen
-- Allows server-side scripts to open/close the phone remotely.
-- ============================================================
RegisterNetEvent("phone:toggleOpen", ToggleOpen)

-- ============================================================
-- EXPORTS (public API surface)
-- ============================================================

exports("ToggleOpen", ToggleOpen)

exports("IsOpen", function()
    return phoneOpen
end)

exports("IsDisabled", function()
    return phoneDisabled
end)

exports("ToggleDisabled", function(disabled)
    phoneDisabled = (disabled == true)
    debugprint("ToggleDisabled triggered", phoneDisabled)

    if phoneDisabled and phoneOpen then
        ToggleOpen(false)
    end
end)

exports("GetSettings", function()
    return settings
end)

exports("GetAirplaneMode", function()
    return settings and settings.airplaneMode
end)

exports("GetStreamerMode", function()
    return settings and settings.streamerMode
end)

exports("GetEquippedPhoneNumber", function()
    return currentPhone
end)

-- ============================================================
-- End of client.lua
-- ============================================================