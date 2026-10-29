local cameraConfig = Config.Camera or {}
local vehicleConfig = cameraConfig.Vehicle or {}
local selfieConfig = cameraConfig.Selfie or {}
local freezeConfig = cameraConfig.Freeze or {}

local maxFov = cameraConfig.MaxFOV or 70.0
local defaultFov = cameraConfig.DefaultFOV or 60.0
local minFov = cameraConfig.MinFOV or 10.0
local maxLookUp = cameraConfig.MaxLookUp or 80.0
local maxLookDown = cameraConfig.MaxLookDown or -80.0
local allowRunning = cameraConfig.AllowRunning == true

local vehicleZoomEnabled = vehicleConfig.Zoom == true
local vehicleMaxFov = vehicleConfig.MaxFOV or 80.0
local vehicleDefaultFov = vehicleConfig.DefaultFOV or 60.0
local vehicleMinFov = vehicleConfig.MinFOV or 10.0
local vehicleMaxLookUp = vehicleConfig.MaxLookUp or 50.0
local vehicleMaxLookDown = vehicleConfig.MaxLookDown or -30.0
local vehicleMaxLeftRight = vehicleConfig.MaxLeftRight or 120.0
local vehicleMinLeftRight = vehicleConfig.MinLeftRight or -120.0

local selfieMaxFov = selfieConfig.MaxFOV or 80.0
local selfieDefaultFov = selfieConfig.DefaultFOV or 60.0
local selfieMinFov = selfieConfig.MinFOV or 50.0
local selfieOffset = selfieConfig.Offset or vector3(0.1, 0.55, 0.6)
local selfieRotation = selfieConfig.Rotation or vector3(10.0, 0.0, -180.0)

local freezeEnabled = freezeConfig.Enabled == true
local freezeMaxDistance = freezeConfig.MaxDistance or 10.0
local freezeMaxTime = (freezeConfig.MaxTime or 60) * 1000
local rollEnabled = cameraConfig.Roll == true

local rearCameraOffset = vector3(0.0, 0.5, 0.6)
local cameraPitch = 0.0
local cameraRoll = 0.0
local targetFov = 60.0
local previousPedCamViewMode = 0
local vehicleHeadingOffset = 0.0
local radioControlDisabled = false
local cameraFrozen = false
local freezeTimeout = 0
local playerPed = PlayerPedId()
local selfieMode = false
local movementRotationActive = false
local mouseSensitivity = 0.0
local profileLookSensitivity = GetProfileSetting(754) + 10
local currentZoomDisplay = 1.0
local camera = nil

local cameraModes = {
    REAR = 0,
    SELFIE = 1,
    IN_VEHICLE = 2
}

local currentCameraMode = cameraModes.REAR

local function getFovLimits()
    local inVehicle = IsPedInAnyVehicle(playerPed, true)
    local currentMaxFov = maxFov
    local currentMinFov = minFov
    local currentDefaultFov = defaultFov

    if selfieMode then
        currentMaxFov = selfieMaxFov
        currentMinFov = selfieMinFov
        currentDefaultFov = selfieDefaultFov
    elseif inVehicle then
        currentMaxFov = vehicleMaxFov
        currentDefaultFov = vehicleDefaultFov

        if vehicleZoomEnabled then
            currentMinFov = vehicleMinFov
        else
            currentMinFov = vehicleMaxFov
        end
    end

    return currentMaxFov, currentMinFov, currentDefaultFov
end

function ConvertFovToZoom(fov)
    local currentMaxFov, currentMinFov, currentDefaultFov = getFovLimits()
    local clampedFov = math.clamp(fov, currentMinFov, currentMaxFov)

    if clampedFov == currentDefaultFov then
        return 1.0
    end

    if currentDefaultFov > clampedFov then
        if clampedFov <= 0 then
            return 1.0
        end

        return currentDefaultFov / clampedFov
    end

    local zoomOutPercent = (clampedFov - currentDefaultFov) / (currentMaxFov - currentDefaultFov)

    return 1.0 - zoomOutPercent * 0.5
end

local function convertZoomToFov(zoom)
    local currentMaxFov, currentMinFov, currentDefaultFov = getFovLimits()
    local minZoom = 1.0
    local maxZoom = 1.0

    if currentDefaultFov < currentMaxFov then
        minZoom = 0.5
    end

    if currentMinFov < currentDefaultFov and currentMinFov > 0 then
        maxZoom = currentDefaultFov / currentMinFov
    end

    local clampedZoom = math.clamp(zoom, minZoom, maxZoom)

    if clampedZoom == 1.0 then
        return currentDefaultFov
    end

    if clampedZoom > 1.0 then
        return currentDefaultFov / clampedZoom
    end

    return currentDefaultFov + ((1.0 - clampedZoom) * 2.0) * (currentMaxFov - currentDefaultFov)
end

local function sendZoomLevels()
    local currentMaxFov, currentMinFov = getFovLimits()
    local minZoom = ConvertFovToZoom(currentMaxFov)
    local maxZoom = ConvertFovToZoom(currentMinFov)
    local zoomLevels = { 1.0 }

    if minZoom < 1.0 then
        table.insert(zoomLevels, 1, minZoom)
    end

    if maxZoom > 2.0 then
        table.insert(zoomLevels, 2)
    end

    if maxZoom > 5.0 then
        table.insert(zoomLevels, 5)
    elseif maxZoom > 3.0 then
        table.insert(zoomLevels, 3)
    end

    SendNUIAction("camera:setZoomLevels", zoomLevels)
end

function SetCameraZoom(zoom)
    targetFov = convertZoomToFov(zoom)
end

local function updateCameraMode()
    local inVehicle = IsPedInAnyVehicle(playerPed, true)
    local mode = selfieMode and cameraModes.SELFIE or cameraModes.REAR

    if inVehicle then
        mode = mode | cameraModes.IN_VEHICLE
    end

    if currentCameraMode == mode then
        return inVehicle
    end

    local _, _, currentDefaultFov = getFovLimits()

    currentCameraMode = mode
    targetFov = currentDefaultFov

    debugprint("Camera mode changed to: " .. currentCameraMode)
    sendZoomLevels()
    SetCamFov(camera, targetFov)

    return inVehicle
end

local function disableCameraControls()
    SetFollowPedCamViewMode(0)
    SetGameplayCamRelativeHeading(0.0)

    DisableControlAction(0, 1, true)
    DisableControlAction(0, 14, true)
    DisableControlAction(0, 15, true)
    DisableControlAction(0, 16, true)
    DisableControlAction(0, 17, true)
    DisableControlAction(0, 99, true)
    DisableControlAction(0, 100, true)
    DisableControlAction(0, 115, true)
    DisableControlAction(0, 116, true)
    DisableControlAction(0, 261, true)
    DisableControlAction(0, 262, true)

    SetPedResetFlag(playerPed, 47, true)
end

local function updateFreezeState()
    if not cameraFrozen then
        return false
    end

    local distance = #(GetEntityCoords(playerPed) - GetCamCoord(camera))
    local expired = GetGameTimer() > freezeTimeout

    if distance > freezeMaxDistance or expired then
        cameraFrozen = false
        TogglePhoneAnimation(true, "camera")
    end

    return true
end

local function attachRearCamera()
    local cameraCoords = GetOffsetFromEntityInWorldCoords(playerPed, rearCameraOffset.x, rearCameraOffset.y, rearCameraOffset.z)
    local headCoords = GetPedBoneCoords(playerPed, 31086, 0.0, 0.0, 0.0)
    local cameraZ = cameraCoords.z

    if math.abs(headCoords.z - cameraCoords.z) > 0.2 then
        cameraZ = headCoords.z
    end

    DetachCam(camera)
    SetCamCoord(camera, cameraCoords.x, cameraCoords.y, cameraZ)
    SetCamRot(camera, cameraPitch, cameraRoll, GetEntityHeading(playerPed), 2)
end

local function attachSelfieCamera()
    AttachCamToPedBone_2(
        camera,
        playerPed,
        0,
        selfieRotation.x + cameraPitch,
        selfieRotation.y,
        selfieRotation.z,
        selfieOffset.x,
        selfieOffset.y,
        selfieOffset.z,
        true
    )
end

local function attachVehicleSelfieCamera()
    AttachCamToPedBone_2(
        camera,
        playerPed,
        0,
        80.0 + cameraPitch,
        0.0,
        -180.0,
        0.0,
        0.2,
        0.5,
        true
    )
end

local function attachVehicleRearCamera()
    local phoneObject = GetPhoneObject()

    if phoneObject then
        SetEntityLocallyInvisible(phoneObject)
    end

    SetEntityLocallyInvisible(playerPed)

    AttachCamToPedBone_2(
        camera,
        playerPed,
        GetPedBoneIndex(playerPed, 11816),
        cameraPitch,
        0.0,
        vehicleHeadingOffset,
        0.0,
        0.0,
        0.55,
        true
    )
end

local function updateCameraAttachment(inVehicle)
    if selfieMode and not inVehicle then
        attachSelfieCamera()
    elseif not selfieMode and not inVehicle then
        attachRearCamera()
    elseif selfieMode and inVehicle then
        attachVehicleSelfieCamera()
    elseif not selfieMode and inVehicle then
        attachVehicleRearCamera()
    end
end

local function updateVehicleRadioState(inVehicle)
    if inVehicle then
        if not radioControlDisabled then
            radioControlDisabled = true
            SetUserRadioControlEnabled(false)
        end
    elseif radioControlDisabled then
        radioControlDisabled = false
        SetUserRadioControlEnabled(true)
        vehicleHeadingOffset = 0.0
    else
        vehicleHeadingOffset = 0.0
    end
end

local function updateTargetFov(inVehicle)
    local currentFov = GetCamFov(camera)
    local currentMaxFov, currentMinFov = getFovLimits()

    targetFov = math.clamp(targetFov, currentMinFov, currentMaxFov)

    local zoomDisplay = math.round(ConvertFovToZoom(currentFov), 1)

    if zoomDisplay ~= currentZoomDisplay then
        debugprint("Zoom changed to: " .. zoomDisplay, ConvertFovToZoom(currentFov), currentFov)

        currentZoomDisplay = zoomDisplay
        SendNUIAction("camera:setZoom", zoomDisplay)
    end

    if math.abs(currentFov - targetFov) > 0.05 then
        SetCamFov(camera, currentFov + (targetFov - currentFov) / 25)
    end

    if IsNuiFocused() then
        return
    end

    mouseSensitivity = (profileLookSensitivity * (math.max(targetFov, 1.0) / maxFov)) / 5

    local horizontalInput = GetDisabledControlNormal(0, 1)

    if inVehicle then
        vehicleHeadingOffset = math.clamp(vehicleHeadingOffset - horizontalInput * mouseSensitivity, vehicleMinLeftRight, vehicleMaxLeftRight)
    elseif horizontalInput ~= 0.0 then
        SetEntityHeading(playerPed, GetEntityHeading(playerPed) - horizontalInput * mouseSensitivity)
    end

    if IsDisabledControlPressed(0, 180) then
        targetFov = targetFov + 5
    elseif IsDisabledControlPressed(0, 181) then
        targetFov = targetFov - 5
    end

    local verticalInput = GetDisabledControlNormal(0, 2)

    if verticalInput ~= 0.0 then
        local pitch = cameraPitch - verticalInput * mouseSensitivity

        if inVehicle then
            cameraPitch = math.clamp(pitch, vehicleMaxLookDown, vehicleMaxLookUp)
        else
            cameraPitch = math.clamp(pitch, maxLookDown, maxLookUp)
        end
    end
end

local function updateCamera()
    local inVehicle = updateCameraMode()

    movementRotationActive = not selfieMode
        and not inVehicle
        and (
            IsDisabledControlPressed(0, 33)
            or IsDisabledControlPressed(0, 34)
            or IsDisabledControlPressed(0, 35)
        )

    disableCameraControls()

    if cameraFrozen and not inVehicle then
        updateFreezeState()
        return
    end

    if not allowRunning then
        DisableControlAction(0, 21, true)
    end

    updateCameraAttachment(inVehicle)
    updateVehicleRadioState(inVehicle)

    if movementRotationActive then
        SetPedResetFlag(playerPed, 69, true)
    elseif not selfieMode and not inVehicle then
        DisableControlAction(0, 30, true)
    end

    updateTargetFov(inVehicle)
end

local function rotatePedFromMouse()
    local horizontalInput = GetDisabledControlNormal(0, 1)

    if horizontalInput ~= 0.0 then
        SetEntityHeading(playerPed, GetEntityHeading(playerPed) - horizontalInput * mouseSensitivity)
    end
end

function EnableWalkableCam(selfie)
    if camera then
        return
    end

    selfieMode = selfie == true
    movementRotationActive = false
    targetFov = selfieMode and selfieDefaultFov or defaultFov
    playerPed = PlayerPedId()
    previousPedCamViewMode = GetFollowPedCamViewMode()
    cameraPitch = 0.0
    vehicleHeadingOffset = 0.0
    cameraRoll = 0.0
    cameraFrozen = false
    camera = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    profileLookSensitivity = GetProfileSetting(754) + 10
    currentZoomDisplay = 1.0

    SetPhoneAction("camera")

    CreateThread(function()
        while camera do
            Wait(0)

            if (movementRotationActive or cameraFrozen) and not IsNuiFocused() then
                rotatePedFromMouse()
            end
        end
    end)

    CreateThread(function()
        while camera do
            Wait(0)
            updateCamera()
        end

        if radioControlDisabled then
            radioControlDisabled = false
            SetUserRadioControlEnabled(true)
        end
    end)

    SetCamFov(camera, targetFov)
    RenderScriptCams(true, false, 0, true, true)
    SetCamActive(camera, true)
    SendNUIAction("camera:setZoom", 1.0)
    sendZoomLevels()
    RefreshAnimationsInterval()
end

function DisableWalkableCam()
    if not camera then
        return
    end

    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(camera, false)
    SetFollowPedCamViewMode(previousPedCamViewMode)
    SetPhoneAction(IsInCall() and "call" or "default")

    camera = nil

    if cameraFrozen then
        TogglePhoneAnimation(true, "camera")
    end

    RefreshAnimationsInterval()
end

function ToggleSelfieCam(selfie)
    local wasSelfie = selfieMode

    selfieMode = selfie == true

    if wasSelfie ~= selfieMode then
        cameraRoll = 0.0
        cameraPitch = 0.0
    end
end

function ToggleCameraFrozen()
    if not freezeEnabled or not camera or selfieMode then
        return
    end

    cameraFrozen = not cameraFrozen

    if cameraFrozen then
        TogglePhoneAnimation(false, "camera")
        freezeTimeout = GetGameTimer() + freezeMaxTime
    end
end

function IsWalkingCamEnabled()
    return camera ~= nil
end

function IsSelfieCam()
    return selfieMode
end

AddEventHandler("lb-phone:keyPressed", function(key)
    if not camera then
        return
    end

    if key == "FreezeCamera" then
        if not freezeEnabled or selfieMode then
            return
        end

        ToggleCameraFrozen()
    elseif key == "RollLeft" or key == "RollRight" then
        if not rollEnabled then
            return
        end

        local delta = key == "RollLeft" and -0.5 or 0.5
        local bindData = Config.KeyBinds[key].bindData

        while bindData.pressed do
            Wait(0)
            cameraRoll = cameraRoll + delta
        end
    end
end)

exports("EnableWalkableCam", EnableWalkableCam)
exports("DisableWalkableCam", DisableWalkableCam)
exports("ToggleSelfieCam", ToggleSelfieCam)
exports("ToggleCameraFrozen", ToggleCameraFrozen)
exports("IsWalkingCamEnabled", IsWalkingCamEnabled)
exports("IsSelfieCam", IsSelfieCam)
