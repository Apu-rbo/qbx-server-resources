local fallbackGetPasswordHash = GetPasswordHash
local fallbackVerifyPasswordHash = VerifyPasswordHash

function GetPasswordHash(password)
    if GetResourceState("loaf_bcrypt") ~= "started" then
        return fallbackGetPasswordHash(password)
    end

    debugprint("Using loaf_bcrypt for password hashing")

    return exports.loaf_bcrypt:GetPasswordHash(password)
end

function VerifyPasswordHash(password, hash)
    if GetResourceState("loaf_bcrypt") ~= "started" then
        return fallbackVerifyPasswordHash(password, hash)
    end

    debugprint("Using loaf_bcrypt for password verification")

    return exports.loaf_bcrypt:VerifyPasswordHash(password, hash)
end
