-- ─────────────────────────────────────────────────────────────────────────────
-- client/ambush.lua  —  v1.4.15 NPC ambush on 3rd failed /secure
--
-- When a tow operator fails the /secure skillCheck three times on the same
-- repo job (counter in client/main.lua, incremented in client/minigame.lua),
-- TriggerAmbush() rolls two d20s D&D-style to determine the punishment:
--
--   Count d20  → linear buckets: 1-4 = 1 NPC, 5-8 = 2, 9-12 = 3,
--                                13-16 = 4, 17-20 = 5
--   Weapon d20 → linear buckets: 1-4 = fists, 5-8 = knife, 9-12 = bottle,
--                                13-16 = pistol, 17-20 = SMG
--
-- All NPCs in the encounter share the same weapon (single weapon roll per
-- ambush). They spawn 15-25 m from the player in random directions and
-- aggro the player, then persist until killed or out of scope (mission
-- entity flag prevents auto-despawn).
-- ─────────────────────────────────────────────────────────────────────────────

local AMBUSH_PED_MODELS = {
    'g_m_y_lost_01',     'g_m_y_lost_02',     'g_m_y_lost_03',
    'g_m_y_ballaorig_01', 'g_m_y_ballasout_01',
    'g_m_y_famca_01',    'g_m_y_famfor_01',
}

-- {min, max, count}
local COUNT_BUCKETS = {
    { 1,  4,  1 },
    { 5,  8,  2 },
    { 9,  12, 3 },
    { 13, 16, 4 },
    { 17, 20, 5 },
}

-- {min, max, weaponHashName, displayName}
local WEAPON_BUCKETS = {
    { 1,  4,  'WEAPON_UNARMED', 'fists'  },
    { 5,  8,  'WEAPON_KNIFE',   'knife'  },
    { 9,  12, 'WEAPON_BOTTLE',  'bottle' },
    { 13, 16, 'WEAPON_PISTOL',  'pistol' },
    { 17, 20, 'WEAPON_SMG',     'SMG'    },
}

local function resolveBucket(buckets, roll)
    for _, b in ipairs(buckets) do
        if roll >= b[1] and roll <= b[2] then return b end
    end
    return buckets[#buckets]   -- fallback to top bucket
end

local function spawnAmbusher(spawnCoords, headingToPlayer, weaponHash)
    local modelName = AMBUSH_PED_MODELS[math.random(#AMBUSH_PED_MODELS)]
    local modelHash = GetHashKey(modelName)
    RequestModel(modelHash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(modelHash) and GetGameTimer() < deadline do
        Citizen.Wait(10)
    end
    if not HasModelLoaded(modelHash) then return nil end

    local ped = CreatePed(4, modelHash, spawnCoords.x, spawnCoords.y, spawnCoords.z,
                          headingToPlayer, true, true)
    SetModelAsNoLongerNeeded(modelHash)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    -- Mission entity so GTA's auto-despawn doesn't clean them while they
    -- chase the player around a corner.
    SetEntityAsMissionEntity(ped, true, true)

    GiveWeaponToPed(ped, GetHashKey(weaponHash), 240, false, true)
    SetPedAccuracy(ped, 35)               -- not too lethal — this is a beta feature, not punishment
    SetPedCombatAttributes(ped, 46, true) -- can use cover
    SetPedFleeAttributes(ped, 0, false)   -- don't flee
    SetPedCombatRange(ped, 2)             -- engage at range, not just melee
    SetPedRelationshipGroupHash(ped, GetHashKey('HATES_PLAYER'))
    SetRelationshipBetweenGroups(5, GetHashKey('HATES_PLAYER'), GetHashKey('PLAYER'))
    TaskCombatPed(ped, PlayerPedId(), 0, 16)

    return ped
end

-- Exported as a global so client/minigame.lua can call it on the 3rd /secure
-- fail. Defined in this file so the ambush feature is self-contained and easy
-- to disable (just remove this file from fxmanifest's client_scripts).
--
-- v1.5.1: explicit _G assignment. v1.5 used `function TriggerAmbush()` which
-- should create a global, but beta testing showed minigame.lua hitting a nil
-- global despite ambush.lua being in fxmanifest's client_scripts. Going
-- through _G removes any ambiguity about scope and survives any quirks of
-- the FiveM Lua 5.4 environment.
_G.TriggerAmbush = function()
    math.randomseed(GetGameTimer())

    local countRoll  = math.random(1, 20)
    local weaponRoll = math.random(1, 20)
    local countB     = resolveBucket(COUNT_BUCKETS,  countRoll)
    local weaponB    = resolveBucket(WEAPON_BUCKETS, weaponRoll)
    local count      = countB[3]
    local weaponHash = weaponB[3]
    local weaponName = weaponB[4]

    Notify('🎲 Ambush',
        ('d20 count=%d → %d NPCs · d20 weapon=%d → %s'):format(
            countRoll, count, weaponRoll, weaponName),
        'error', 6000)

    local ped     = PlayerPedId()
    local pCoords = GetEntityCoords(ped)
    for i = 1, count do
        local angle  = math.random() * math.pi * 2
        local dist   = 15.0 + math.random() * 10.0   -- 15-25 m radius
        local sx, sy = pCoords.x + math.cos(angle) * dist,
                       pCoords.y + math.sin(angle) * dist
        local _, gz  = GetGroundZFor_3dCoord(sx, sy, pCoords.z + 50.0, false)
        local sz     = (gz and gz ~= 0.0) and gz or pCoords.z
        -- Lua 5.4 removed math.atan2; the two-arg form of math.atan replaces it.
        local heading = math.deg(math.atan(pCoords.y - sy, pCoords.x - sx))
        spawnAmbusher(vector3(sx, sy, sz + 1.0), heading, weaponHash)
        Citizen.Wait(50)   -- stagger so the model loader doesn't thrash
    end
end

-- v1.5.1: load-confirmation print. If this line does not appear in the
-- F8 client console at resource start, ambush.lua did not load — check
-- that fxmanifest's client_scripts includes 'client/ambush.lua' and that
-- the file is present in the deployed resource directory.
print('[hobo-ambush] loaded — TriggerAmbush registered globally')
