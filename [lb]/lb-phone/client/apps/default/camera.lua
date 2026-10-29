cameraOpen = false

local selfieCamera = false
local videoRecording = false
local hudHidden = false
local recordingPeerId = nil

local mediaTypeMap = {
    selfies = "selfie",
    screenshots = "screenshot",
    imports = "import"
}

local function startNativeCamera()
    TogglePhoneAnimation(false, "camera")
    CreateMobilePhone(0)
    CellCamActivate(true, true)
    CellCamActivateSelfieMode(selfieCamera)

    SetTimeout(500, function()
        local objects = GetGamePool("CObject")
        local playerCoords = GetEntityCoords(PlayerPedId())

        for i = 1, #objects do
            local object = objects[i]
            local distance = #(playerCoords - GetEntityCoords(object))

            if distance < 4.0 and GetEntityModel(object) == 413312110 then
                SetEntityAsMissionEntity(object, true, true)
                DeleteObject(object)
            end
        end
    end)

    while phoneOpen and cameraOpen and not IsWalkingCamEnabled() do
        Wait(250)
        InvalidateIdleCam()
        InvalidateVehicleIdleCam()
    end

    if cameraOpen then
        TogglePhoneAnimation(true, "camera")
    elseif phoneOpen then
        TogglePhoneAnimation(true)
    end

    DestroyMobilePhone()

    if cameraOpen and not IsWalkingCamEnabled() then
        while not phoneOpen do
            Wait(500)
        end

        startNativeCamera()
    end
end

local function normalizeGalleryFilter(filter)
    if filter.album == "recents" then
        filter.album = nil
    elseif filter.album == "favourites" then
        filter.album = nil
        filter.favourites = true
    end

    if filter.type == "videos" then
        filter = {
            showPhotos = false,
            showVideos = true
        }
    end

    if filter.type then
        filter.album = nil

        if mediaTypeMap[filter.type] then
            filter.type = mediaTypeMap[filter.type]
        else
            filter.type = nil
            filter.duplicates = true
        end
    end

    if not filter.showPhotos and not filter.showVideos then
        filter.showPhotos = true
        filter.showVideos = true
    end

    return filter
end

local function getUploadConfig(uploadType)
    local uploadConfig

    if CustomGetUploadMethod then
        uploadConfig = CustomGetUploadMethod(uploadType)
    else
        if not UploadMethods then
            infoprint("error", "Upload methods not found")
            return "No upload methods found. The server devs have broken the upload.lua file. Tell the server devs to reinstall lb-phone."
        end

        local methodName = Config.UploadMethod[uploadType]
        local methodConfig = UploadMethods[methodName]

        if not methodConfig then
            infoprint("error", "Upload methods not found for ", uploadType)
            return "No upload methods found for '" .. tostring(methodName) .. "'. Tell the server devs to reinstall lb-phone."
        end

        uploadConfig = methodConfig[uploadType] or methodConfig.Default

        if not uploadConfig then
            infoprint("error", "Upload method not found for ", uploadType)
            return "No upload method found for '" .. uploadType .. "' using '" .. tostring(methodName) .. "'. Tell the server devs to reinstall lb-phone."
        end
    end

    if not uploadConfig.method then
        uploadConfig.method = Config.UploadMethod[uploadType]
    end

    if uploadConfig.sendPlayer and not uploadConfig.player then
        uploadConfig.player = {
            identifier = GetIdentifier(),
            name = GetPlayerName(PlayerId())
        }
    end

    local needsApiKey = uploadConfig.url:find("API_KEY") ~= nil

    if not needsApiKey and uploadConfig.headers then
        for _, headerValue in pairs(uploadConfig.headers) do
            if headerValue:find("API_KEY") then
                needsApiKey = true
                break
            end
        end
    end

    if needsApiKey then
        local apiKey = AwaitCallback("camera:getUploadApiKey", uploadType)

        uploadConfig.url = uploadConfig.url:gsub("API_KEY", apiKey)

        if uploadConfig.headers then
            for headerName, headerValue in pairs(uploadConfig.headers) do
                uploadConfig.headers[headerName] = headerValue:gsub("API_KEY", apiKey)
            end
        end
    end

    if uploadConfig.url:find("PRESIGNED_URL") then
        local presignedUrl = AwaitCallback("camera:getPresignedUrl", uploadType)

        if not presignedUrl then
            infoprint("error", "Failed to get presigned url for " .. uploadType)
            return "Failed to get presigned url for '" .. uploadType .. "'. The devs have most likely not set a valid token in lb-phone/server/apiKeys.lua. Tell the server devs to check the console for errors."
        end

        uploadConfig.presignedUrl = presignedUrl
    end

    return uploadConfig
end

local function addInstruction(instructions, keybinds, name, localeKey)
    local keybind = keybinds[name]

    if keybind and keybind.Command and keybind.bindData then
        instructions[#instructions + 1] = L(localeKey, {
            key = keybind.bindData.instructional
        })
    end
end

local function addPairedInstruction(instructions, keybinds, firstName, secondName, localeKey)
    local firstKeybind = keybinds[firstName]
    local secondKeybind = keybinds[secondName]

    if firstKeybind and firstKeybind.Command and firstKeybind.bindData and secondKeybind and secondKeybind.Command and secondKeybind.bindData then
        instructions[#instructions + 1] = L(localeKey, {
            key = firstKeybind.bindData.instructional,
            key2 = secondKeybind.bindData.instructional
        })
    end
end

local function getCameraInstructions()
    local instructions = {}
    local keybinds = Config.KeyBinds

    addInstruction(instructions, keybinds, "TakePhoto", "BACKEND.CAMERA.TAKE_PHOTO")
    addInstruction(instructions, keybinds, "FlipCamera", "BACKEND.CAMERA.FLIP_CAMERA")
    addInstruction(instructions, keybinds, "ToggleFlash", "BACKEND.CAMERA.TOGGLE_FLASH")
    addPairedInstruction(instructions, keybinds, "LeftMode", "RightMode", "BACKEND.CAMERA.CHANGE_MODE")
    addPairedInstruction(instructions, keybinds, "RollLeft", "RollRight", "BACKEND.CAMERA.ROLL")

    if Config.Camera and Config.Camera.Freeze and Config.Camera.Freeze.Enabled then
        addInstruction(instructions, keybinds, "FreezeCamera", "BACKEND.CAMERA.FREEZE")
    end

    addInstruction(instructions, keybinds, "Focus", "BACKEND.CAMERA.TOGGLE_CURSOR")

    return instructions
end

RegisterNUICallback("Camera", function(data, callback)
    if not currentPhone then
        return
    end

    if not data then
        return debugprint("Camera data is nil")
    end

    local action = data.action

    debugprint("Camera:" .. (action or ""))

    if action == "open" then
        callback("ok")

        cameraOpen = true
        DisplayCameraButtons(getCameraInstructions())

        if Config.Camera and Config.Camera.Walkable then
            debugprint("Using walkable cam")
            EnableWalkableCam()
        else
            debugprint("Using native GTA cam")
            startNativeCamera()
        end
    elseif action == "saveToGallery" then
        TriggerCallback("camera:saveToGallery", callback, data.link, data.size, data.isVideo and true or false, data.type, data.shouldLog)
    elseif action == "updateImage" then
        TriggerCallback("camera:updateImage", callback, data.id, data.src, data.size)
    elseif action == "deleteFromGallery" then
        if type(data.ids) ~= "table" then
            data.ids = { data.ids }
        end

        TriggerCallback("camera:deleteFromGallery", callback, data.ids)
    elseif action == "getLastImage" then
        TriggerCallback("camera:getLastImage", callback)
    elseif action == "getImages" then
        local filter = normalizeGalleryFilter(data.filter or {})
        local images = AwaitCallback("camera:getImages", filter, data.page or 0)
        local gallery = {}

        for i = 1, #images do
            local image = images[i]

            gallery[i] = {
                id = image.id,
                src = image.link,
                isVideo = image.is_video,
                type = image.metadata,
                favourite = image.is_favourite,
                timestamp = image.timestamp,
                size = image.size or 0
            }
        end

        callback(gallery)
    elseif action == "getAlbums" then
        TriggerCallback("camera:getHomePageData", callback)
    elseif action == "createAlbum" then
        TriggerCallback("camera:createAlbum", callback, data.title)
    elseif action == "renameAlbum" then
        TriggerCallback("camera:renameAlbum", callback, data.id, data.title)
    elseif action == "addToAlbum" then
        TriggerCallback("camera:addToAlbum", callback, data.album, data.ids)
    elseif action == "removeFromAlbum" then
        TriggerCallback("camera:removeFromAlbum", callback, data.album, data.ids)
    elseif action == "deleteAlbum" then
        TriggerCallback("camera:deleteAlbum", callback, data.id)
    elseif action == "removeMemberFromAlbum" then
        TriggerCallback("camera:removeMemberFromAlbum", callback, data.number, data.album)
    elseif action == "leaveSharedAlbum" then
        TriggerCallback("camera:leaveSharedAlbum", callback, data.id)
    elseif action == "getAlbumMembers" then
        TriggerCallback("camera:getAlbumMembers", callback, data.id)
    elseif action == "toggleFavourites" then
        TriggerCallback("camera:toggleFavourites", callback, data.favourite, data.ids)
    elseif action == "toggleVideo" then
        if videoRecording == data.toggled then
            return callback("ok")
        end

        videoRecording = data.toggled
        cameraOpen = true

        callback("ok")
        SendNUIAction("camera:toggleMicrophone", IsTalking())

        if videoRecording or (Config.Camera and Config.Camera.Walkable) then
            EnableWalkableCam(selfieCamera)
        else
            DisableWalkableCam()
            startNativeCamera()
        end
    elseif action == "toggleHud" then
        hudHidden = not data.toggled

        TriggerEvent("lb-phone:toggleHud", hudHidden)
        ToggleHudComponents(not data.toggled)
        Wait(100)
        callback(true)
    elseif action == "getUploadApi" then
        callback(getUploadConfig(data.uploadType) or false)
    elseif action == "toggleLandscape" then
        LocalPlayer.state:set("phoneLandscape", data.toggled == true and true or nil, true)

        if data.toggled then
            AttachPhone({
                landscape = true
            })
        else
            AttachPhone()
        end

        callback("ok")
    elseif action == "flipCamera" then
        data.value = data.value == true

        if selfieCamera == data.value then
            return callback("ok")
        end

        selfieCamera = data.value

        if IsWalkingCamEnabled() then
            ToggleSelfieCam(selfieCamera)
        else
            CellCamActivateSelfieMode(selfieCamera)
        end

        callback("ok")
    elseif action == "setQuickZoom" then
        if IsWalkingCamEnabled() then
            SetCameraZoom(data.value)
        end

        callback(true)
    elseif action == "setRecordingPeerId" then
        TriggerServerEvent("phone:camera:setPeer", data.peerId)

        recordingPeerId = data.peerId
        callback("ok")
    elseif action == "endedRecording" then
        if recordingPeerId then
            TriggerServerEvent("phone:camera:endedRecording", recordingPeerId)

            recordingPeerId = nil
            callback("ok")
        end
    elseif action == "close" then
        cameraOpen = false
        videoRecording = false
        selfieCamera = false

        StopDisplayingCameraButtons()
        DisableWalkableCam()

        if LocalPlayer.state.phoneLandscape then
            LocalPlayer.state:set("phoneLandscape", nil, true)
        end

        callback("ok")
    end
end)

RegisterNUICallback("isExternalImageAllowed", function(data, callback)
    local allowed, message = IsMediaLinkAllowed(data.url)

    return callback(allowed, message)
end)

exports("SaveToGallery", function(link)
    assert(type(link) == "string", "Expected string for link, got " .. type(link))

    SendNUIAction("saveMedia", link)
end)

RegisterNetEvent("phone:photos:addMemberToAlbum", function(albumId, phoneNumber)
    SendNUIAction("photos:addMemberToAlbum", {
        albumId = albumId,
        phoneNumber = phoneNumber
    })
end)

RegisterNetEvent("phone:photos:removeMemberFromAlbum", function(albumId, phoneNumber)
    SendNUIAction("photos:removeMemberFromAlbum", {
        albumId = albumId,
        phoneNumber = phoneNumber
    })
end)

RegisterNetEvent("phone:photos:addSharedAlbum", function(album)
    SendNUIAction("photos:addSharedAlbum", album)
end)

RegisterNetEvent("phone:photos:updateAlbum", function(album)
    debugprint("phone:photos:updateAlbum", album)
    SendNUIAction("photos:updateAlbum", album)
end)

exports("IsCameraOpen", function()
    return cameraOpen
end)
