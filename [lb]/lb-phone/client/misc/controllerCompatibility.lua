local cursorX = 0.5
local cursorY = 0.5
local cursorSpeed = 0.005
local keyboardVisible = false

local function IsUsingController()
    return IsUsingKeyboard(0) == false
end

local function GetAnalogInput(control)
    local value = GetDisabledControlNormal(0, control)
    local deadzone = 0.1

    if value < -deadzone or value > deadzone then
        return value
    end

    return 0.0
end

RegisterNUICallback("toggleInput", function(enabled)
    if not IsUsingController() then
        return
    end

    keyboardVisible = enabled == true

    if not enabled then
        Wait(250)

        if keyboardVisible then
            return
        end
    end

    SendNUIAction("controller:toggleKeyboard", keyboardVisible)
end)

local function HandleControllerInput()
    local lookX = GetAnalogInput(1)
    local lookY = GetAnalogInput(2)
    local scroll = GetAnalogInput(31)

    cursorX = math.min(0.99999, math.max(0, cursorX + lookX * cursorSpeed))
    cursorY = math.min(1.0, math.max(0, cursorY + lookY * cursorSpeed))

    if IsDisabledControlJustPressed(0, 18) then
        SendNUIAction("controller:press", {
            x = cursorX,
            y = cursorY
        })
    elseif IsDisabledControlJustReleased(0, 18) then
        SendNUIAction("controller:release", {
            x = cursorX,
            y = cursorY
        })
    elseif IsDisabledControlJustReleased(0, 199) or IsDisabledControlJustReleased(0, 177) then
        ToggleOpen(false)
    end

    if lookX ~= 0.0 or lookY ~= 0.0 then
        SetCursorLocation(cursorX, cursorY)
    end

    if scroll ~= 0.0 then
        SendNUIAction("controller:scroll", {
            amount = math.floor(scroll * 25),
            x = cursorX,
            y = cursorY
        })
    end

    DisableAllControlActions(0)
    DisableAllControlActions(1)
    DisableAllControlActions(2)
    InvalidateIdleCam()
end

function ControllerThread()
    while phoneOpen do
        Wait(0)

        if IsUsingController() then
            if IsNuiFocused() then
                HandleControllerInput()
            end
        else
            Wait(500)
        end
    end

    cursorX = 0.5
    cursorY = 0.5

    if IsUsingController() then
        SetCursorLocation(cursorX, cursorY)
    end
end
