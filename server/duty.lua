-- ─────────────────────────────────────────────────────────────────────────────
-- server/duty.lua  —  v1.6 Impound duty: Discord-gated clock-in + vehicle spawn
--
-- Authorizes the two client actions from client/duty.lua:
--   • requestClockOn   — checks Discord-role eligibility (Config.RepoAccess).
--   • spawnDutyVehicle — validates on-duty + the requested model + a clear pad,
--                        then CreateVehicle's it at the impound spawn pad.
--
-- DutyPlayers / OperatorRoles live in server/main.lua (made non-local in v1.6).
-- Discord eligibility mirrors hobo-fuel/server/tanker.lua.
-- ─────────────────────────────────────────────────────────────────────────────

local eligCache = {}   -- [src] = { value = bool, expires = ms }

-- ── Discord-role eligibility (soft dependency — works without the resource) ───

local function getDiscordRoles(src)
    local res = Config.RepoAccess and Config.RepoAccess.DiscordResource
    if not res or res == '' or GetResourceState(res) ~= 'started' then return nil end
    local ok, roles = pcall(function() return exports[res]:GetDiscordRoles(src) end)
    if not ok or type(roles) ~= 'table' then return nil end
    return roles
end

local function rolesIntersect(playerRoles, allowed)
    if not playerRoles or not allowed then return false end
    for i = 1, #playerRoles do
        local pr = tostring(playerRoles[i])
        for j = 1, #allowed do
            if pr == tostring(allowed[j]) then return true end
        end
    end
    return false
end

--- True if the player may clock on duty.
--- Gate disabled (empty Roles) → allow. ACE bypass → allow. Discord role → allow.
local function isRepoEligible(src)
    if not src or src <= 0 then return false end
    local access = Config.RepoAccess or {}

    -- Empty Roles list = gate disabled, so the resource works standalone
    -- before an admin configures Discord role IDs.
    if not access.Roles or #access.Roles == 0 then return true end

    local ace = access.AceBypass
    if ace and ace ~= '' and IsPlayerAceAllowed(src, ace) then return true end

    local cached = eligCache[src]
    if cached and cached.expires > GetGameTimer() then return cached.value end

    local allowed = rolesIntersect(getDiscordRoles(src), access.Roles)
    eligCache[src] = {
        value   = allowed,
        expires = GetGameTimer() + (access.CacheTtlMs or 60000),
    }
    return allowed
end

-- ── Clock-in request ─────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:requestClockOn', function()
    local src = source
    if isRepoEligible(src) then
        TriggerClientEvent('hobo-recovery:clockOnApproved', src)
    else
        TriggerClientEvent('hobo-recovery:clockOnDenied', src)
    end
end)

-- ── Vehicle spawn ────────────────────────────────────────────────────────────

--- False if any vehicle is sitting on the impound's spawn pad.
local function padClear(impound)
    local pad = impound.vehSpawn.coords
    local r   = impound.vehSpawn.clearRadius or 4.5
    for _, veh in ipairs(GetAllVehicles()) do
        if DoesEntityExist(veh) and #(GetEntityCoords(veh) - pad) < r then
            return false
        end
    end
    return true
end

--- True if `modelName` is one of the configured models for `kind`.
--- Never trust the client-sent model string — it must be in the config list.
local function modelAllowed(kind, modelName)
    local list = (kind == 'tow') and Config.TowVehicleModels or Config.CameraCarModels
    for _, entry in ipairs(list or {}) do
        if entry.model == modelName then return true end
    end
    return false
end

RegisterNetEvent('hobo-recovery:spawnDutyVehicle', function(kind, modelName, impoundIndex)
    local src = source

    if not DutyPlayers[src] then return end                       -- must be on duty
    if kind ~= 'tow' and kind ~= 'camera' then return end
    if type(modelName) ~= 'string' or not modelAllowed(kind, modelName) then return end

    local impound = Config.Impounds and Config.Impounds[impoundIndex]
    if not impound or not impound.vehSpawn then return end

    -- proximity guard: the player must actually be at this impound
    local ped = GetPlayerPed(src)
    if ped == 0 then return end
    if #(GetEntityCoords(ped) - impound.vehSpawn.coords) > 50.0 then return end

    if not padClear(impound) then
        TriggerClientEvent('hobo-recovery:dutyVehicleBlocked', src)
        return
    end

    local s   = impound.vehSpawn.coords
    local h   = impound.vehSpawn.heading or 0.0
    local veh = CreateVehicle(GetHashKey(modelName), s.x, s.y, s.z, h, true, true)

    local tries = 0
    while not DoesEntityExist(veh) and tries < 50 do
        Wait(20)
        tries = tries + 1
    end
    if not DoesEntityExist(veh) then
        TriggerClientEvent('hobo-recovery:dutyVehicleBlocked', src)
        return
    end

    -- Role follows the vehicle. The client's SetOperatorRole mirrors this
    -- back via hobo-recovery:setOperatorRole; setting it here too removes any
    -- race for server-side role checks that fire before that round-trip.
    OperatorRoles[src] = kind

    TriggerClientEvent('hobo-recovery:dutyVehicleSpawned', src,
        NetworkGetNetworkIdFromEntity(veh), kind)
end)

AddEventHandler('playerDropped', function()
    eligCache[source] = nil
end)
