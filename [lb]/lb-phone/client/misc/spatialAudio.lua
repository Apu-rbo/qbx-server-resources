local function RotateVector(vector, rotation)
    local rotationX = math.rad(rotation.x)
    local rotationY = math.rad(rotation.y)
    local rotationZ = math.rad(rotation.z)

    local cosX = math.cos(rotationX)
    local sinX = math.sin(rotationX)
    local cosY = math.cos(rotationY)
    local sinY = math.sin(rotationY)
    local cosZ = math.cos(rotationZ)
    local sinZ = math.sin(rotationZ)

    local rotatedX = vector.x * cosZ - vector.y * sinZ
    local rotatedY = vector.x * sinZ + vector.y * cosZ
    local rotatedZ = vector.z

    local pitchX = rotatedX
    local pitchY = rotatedY * cosX - rotatedZ * sinX
    local pitchZ = rotatedY * sinX + rotatedZ * cosX

    local finalX = pitchX * cosY + pitchZ * sinY
    local finalY = pitchY
    local finalZ = -pitchX * sinY + pitchZ * cosY

    return vector3(finalX, finalY, finalZ)
end

function CalculateSpatialAudio(listenerCoords, listenerRotation, audioCoords, maxDistance, volume)
    volume = math.clamp(volume or 1.0, 0.0, 1.0)

    local offset = audioCoords - listenerCoords
    local distance = #offset

    if distance >= maxDistance then
        return {
            frontLeft = 0.0,
            frontRight = 0.0,
            rearLeft = 0.0,
            rearRight = 0.0
        }
    end

    local inverseRotation = vector3(-listenerRotation.x, -listenerRotation.y, -listenerRotation.z)
    local localOffset = RotateVector(offset, inverseRotation)
    local direction = norm(vector2(localOffset.x, localOffset.y))

    local rightPan = (direction.x + 1.0) * 0.5
    local frontPan = (direction.y + 1.0) * 0.5
    local leftPan = 1.0 - rightPan
    local rearPan = 1.0 - frontPan

    local channelGains = {
        frontLeft = frontPan * leftPan,
        frontRight = frontPan * rightPan,
        rearLeft = rearPan * leftPan,
        rearRight = rearPan * rightPan
    }

    local power =
        channelGains.frontLeft ^ 2 +
        channelGains.frontRight ^ 2 +
        channelGains.rearLeft ^ 2 +
        channelGains.rearRight ^ 2

    if power > 0 then
        local scale = 1.0 / math.sqrt(power)

        channelGains.frontLeft = channelGains.frontLeft * scale
        channelGains.frontRight = channelGains.frontRight * scale
        channelGains.rearLeft = channelGains.rearLeft * scale
        channelGains.rearRight = channelGains.rearRight * scale
    end

    local distanceRatio = distance / maxDistance
    local attenuation = math.clamp((1.0 - distanceRatio) ^ 2, 0.0, 1.0) * volume

    return {
        frontLeft = channelGains.frontLeft * attenuation,
        frontRight = channelGains.frontRight * attenuation,
        rearLeft = channelGains.rearLeft * attenuation,
        rearRight = channelGains.rearRight * attenuation
    }
end
