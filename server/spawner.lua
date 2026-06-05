-- ─────────────────────────────────────────────────────────────────────────────
-- server/spawner.lua  —  Ambient parked vehicle spawner (OneSync required)
--
-- v1.4.4 spot lifecycle:
--   EMPTY     → 10 s – 5 min retry (Config.EmptySpotRetry)
--             → on spawn-roll pass → OCCUPIED
--             → on spawn-roll miss → re-schedule empty retry
--   OCCUPIED  → 10 min – 2 hr lifetime (CasePool.expiresAt for repo,
--               Config.SceneryLifetime for scenery)
--             → on expiry → COOLING DOWN
--   COOLING   → 60 – 300 s (Config.ReplacementDelay) before re-rolling
--             → on spawn-roll pass → OCCUPIED
--             → on spawn-roll miss → EMPTY (retry on the short interval)
-- ─────────────────────────────────────────────────────────────────────────────

local SpawnedVehicles    = {}   -- [networkId] = { plate, model, spotIndex, isRepo }
local SpawnedSpotIndices = {}   -- [spotIndex]  = networkId
local RepoEligibleCount  = 0

-- Generate a GTA-style 8-character plate: "ABC 1234"
local function GenPlate()
    local c = 'ABCDEFGHJKLMNPRSTUVWXYZ'
    local n = '0123456789'
    local s = ''
    for _ = 1, 3 do
        local idx = math.random(1, #c)
        s = s .. c:sub(idx, idx)
    end
    s = s .. ' '
    for _ = 1, 4 do
        local idx = math.random(1, #n)
        s = s .. n:sub(idx, idx)
    end
    return s
end

-- v1.4.7: decorator-based wipe replacing v1.4.5/v1.4.6's radius scan. Round-7
-- testing showed the 5 m radius wiped 1292 vehicles at startup — overwhelmingly
-- ambient world traffic, NOT our orphans — and the mass deletion in turn put
-- the server's network layer into a degraded state that caused every immediate
-- CreateVehicle call to return an invalid handle (0 spawns, perpetual
-- poolSize=0). The fix: tag every spawned vehicle with a server-side decorator
-- that survives across resource restarts, and on the next start wipe only
-- vehicles carrying that tag. Catches 100% of our orphans, 0% of ambient
-- traffic. A very tight 1.5 m fallback radius still runs against empty
-- untagged vehicles as a one-time catch for legacy orphans (pre-v1.4.7 spawns
-- in your world right now) and for the rare case of NPC traffic that came to
-- rest exactly inside a spot. After one successful v1.4.7 run, that fallback
-- typically wipes 0 — everything we care about has a decorator.
local SPAWN_DECOR     = 'hobo_spawn'   -- bool decorator key (type 2)
-- v1.4.9: bumped 1.5 → 3.5 m as a ONE-VERSION wider sweep to clear the legacy
-- stacked / tipped chaos seen in round-9 screenshots (cars without our
-- decorator that have been piling up from rounds 5-8). The decorator-primary
-- wipe still catches our tagged spawns regardless of distance; this only
-- widens the EMPTY + untagged fallback. Adoption logic (added below) re-
-- claims wiped GTA ambient cars seconds later as the player drives past
-- spots GTA has re-populated. Drop back to 1.5 in v1.5.0 once the world
-- stays clean for one round.
local FALLBACK_RADIUS = 3.5

-- v1.4.9: adoption radius for CheckSpotState. When SpawnVehicleAtSpot runs,
-- we first look for an empty ambient vehicle (typically a GTA ScenarioPoint
-- spawn) within this radius of the parking spot. If found, we claim it
-- instead of calling CreateVehicle on top.
-- v1.4.11: bumped 2.5 → 4.0 m. Round-10 screenshots showed cars stacked at
-- the airport where parking spaces are wider than at street lots; 2.5 m was
-- too tight to catch GTA cars parked a bit off-center, so adoption missed
-- and CreateVehicle stacked on top.
local ADOPT_RADIUS = 4.0

-- v1.4.11: separate (wider) radius used to BLOCK a CreateVehicle when there's
-- already a vehicle (ours OR GTA's, occupied OR empty) near the spot. Prevents
-- the airport-cluster stacking where 4 m wasn't enough breathing room and the
-- existing v1.4.9 adopt-or-create logic would create new cars on top of an
-- adjacent spot's adoption. With BLOCK_CREATE_RADIUS = 5 m, a spot whose
-- neighbor already covers the area just skips its CreateVehicle and reschedules
-- a retry; if the neighbor's car expires, the retry succeeds next time.
local BLOCK_CREATE_RADIUS = 5.0

-- Register the decorator namespace. DecorRegister is idempotent (safe to call
-- multiple times for the same name + type) and must be called before any
-- DecorSetBool / DecorGetBool. Call at file load AND at onResourceStart for
-- belt-and-suspenders — the call at onResourceStart guards against any
-- environment where decorator state was reset between script reloads.
local function RegisterSpawnDecor()
    if DecorRegister then
        DecorRegister(SPAWN_DECOR, 2)   -- 2 = BOOL
    end
end
RegisterSpawnDecor()

local function VehicleHasAnyOccupant(veh)
    for seatIdx = -1, 7 do   -- driver = -1, passengers 0-7
        local ped = GetPedInVehicleSeat(veh, seatIdx)
        if ped ~= 0 and DoesEntityExist(ped) then return true end
    end
    return false
end

-- v1.4.11: single-pass tristate check for a parking spot. Returns one of:
--   'adopt', vehicle  — an empty untagged GTA vehicle is within ADOPT_RADIUS;
--                        SpawnVehicleAtSpot should claim it.
--   'skip',  nil      — some OTHER vehicle is within BLOCK_CREATE_RADIUS
--                        (occupied, tagged-as-ours from a neighbor spot, or
--                        empty-but-outside-adopt-radius). SpawnVehicleAtSpot
--                        must NOT call CreateVehicle (would stack) and should
--                        reschedule a retry instead.
--   'create', nil     — the area is clear. CreateVehicle is safe.
--
-- This replaces v1.4.9's FindAdoptCandidate which only returned a vehicle or
-- nil. The "skip" signal is what prevents the airport-cluster stacking seen
-- in round-10 screenshots: at tight spot clusters, the first spot adopts
-- the GTA car, then subsequent spots saw no untagged candidate and fell
-- through to CreateVehicle, stacking on top of the adopted car.
local function CheckSpotState(spotIdx)
    local spot = Config.ParkingSpots[spotIdx]
    if not spot then return 'skip', nil end

    local untagged = nil
    local anyVehicleInBlockRadius = false

    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) then
            local d = #(spot.coords - GetEntityCoords(veh))

            if d < BLOCK_CREATE_RADIUS then
                anyVehicleInBlockRadius = true
            end

            if d < ADOPT_RADIUS and not VehicleHasAnyOccupant(veh) then
                local ours = DecorExistOn and DecorExistOn(veh, SPAWN_DECOR)
                         and DecorGetBool and DecorGetBool(veh, SPAWN_DECOR)
                if not ours and not untagged then
                    untagged = veh   -- first eligible candidate; keep scanning to set anyVehicleInBlockRadius correctly
                end
            end
        end
    end

    if untagged then return 'adopt', untagged end
    if anyVehicleInBlockRadius then return 'skip', nil end
    return 'create', nil
end

-- v1.4.7: single-pass world wipe. Iterates GetGamePool('CVehicle') ONCE (not
-- once per spot, as the v1.4.5/v1.4.6 implementation did) and removes:
--   1. Anything carrying the SPAWN_DECOR tag — these are our previous-run
--      cars regardless of where they ended up (catches drifted orphans that
--      a strict radius would miss).
--   2. EMPTY untagged vehicles within FALLBACK_RADIUS of any spot — the
--      one-off catch for pre-v1.4.7 orphans plus stray ambient traffic
--      sitting exactly inside a spot.
-- Occupied vehicles are still never touched, so the player-sitting-in-a-
-- parked-car-at-a-spot scenario stays safe.
local function WipeWorldOrphans()
    local taggedHit, fallbackHit = 0, 0
    local pool = GetGamePool('CVehicle')

    -- Build a flat coords array once so the fallback distance check is a
    -- straight loop, not a per-vehicle Config.ParkingSpots iterator setup.
    local spotCoords = {}
    for i, s in ipairs(Config.ParkingSpots or {}) do spotCoords[i] = s.coords end

    for _, veh in ipairs(pool) do
        if DoesEntityExist(veh) then
            local tagged = DecorExistOn and DecorExistOn(veh, SPAWN_DECOR)
                       and DecorGetBool and DecorGetBool(veh, SPAWN_DECOR)
            if tagged then
                DeleteEntity(veh)
                taggedHit = taggedHit + 1
            elseif not VehicleHasAnyOccupant(veh) then
                local pos = GetEntityCoords(veh)
                for _, c in ipairs(spotCoords) do
                    if #(c - pos) < FALLBACK_RADIUS then
                        DeleteEntity(veh)
                        fallbackHit = fallbackHit + 1
                        break
                    end
                end
            end
        end
    end
    return taggedHit, fallbackHit
end

-- Forward declare so the helpers can mutually reference one another. The actual
-- assignment happens further down; this is just to put the name in scope.
local SpawnVehicleAtSpot

-- v1.4.4: short-interval retry for spots that miss the 75% spawn roll.
-- Recursive: if the retry's own roll also misses, it just schedules another
-- retry. Without this, empty spots stay dead for the resource lifetime.
function ScheduleEmptySpotRetry(spotIdx)
    if not spotIdx or not Config.ParkingSpots[spotIdx] then return end
    if SpawnedSpotIndices[spotIdx] then return end   -- already filled

    local cfg     = Config.EmptySpotRetry or {}
    local minSec  = cfg.min or 10
    local maxSec  = cfg.max or 300
    local delayMs = math.random(minSec, maxSec) * 1000

    Citizen.SetTimeout(delayMs, function()
        if SpawnedSpotIndices[spotIdx] then return end   -- filled while waiting

        local acfg = Config.AmbientSpawn or {}
        if math.random() > (acfg.spawnChance or 0.75) then
            ScheduleEmptySpotRetry(spotIdx)   -- still empty, try again
            return
        end
        SpawnVehicleAtSpot(spotIdx)
    end)
end

-- v1.4.4: lifetime timer for scenery (non-repo) vehicles. Repo cars get this
-- via CasePool.expiresAt + the pool-expiry sweep in server/main.lua, which
-- already calls FreeSpawnedSpot + RespawnAmbientAtSpot. Scenery cars need a
-- parallel path so spots churn regardless of repo/scenery roll outcome.
function ScheduleSceneryExpiry(netId, spotIdx)
    local cfg     = Config.SceneryLifetime or {}
    local minSec  = cfg.min or 600
    local maxSec  = cfg.max or 7200
    local lifeMs  = math.random(minSec, maxSec) * 1000

    Citizen.SetTimeout(lifeMs, function()
        -- Bail if the spot's vehicle was already replaced (e.g. an admin
        -- force-removed it, the resource is shutting down, etc.)
        if not SpawnedVehicles[netId] then return end
        FreeSpawnedSpot(spotIdx)
        RespawnAmbientAtSpot(spotIdx)   -- existing post-expiry path: ReplacementDelay then roll
    end)
end

-- v1.4.4: single source of truth for "spawn a vehicle at this spot". Used by
-- the startup loop, ScheduleEmptySpotRetry, RespawnAmbientAtSpot, and (with
-- forceRepo) SpawnReplacementRepo. Returns netId, isRepo or nil on failure.
SpawnVehicleAtSpot = function(spotIdx, opts)
    opts = opts or {}
    if not spotIdx or not Config.ParkingSpots[spotIdx] then return end
    if SpawnedSpotIndices[spotIdx] then return end   -- already filled

    local spot      = Config.ParkingSpots[spotIdx]
    local models    = Config.SpawnedVehicleModels or { 'sultan' }
    local modelName = models[math.random(#models)]
    local plate     = GenPlate()

    -- v1.4.9: prefer adoption to CreateVehicle. v1.4.11: also explicitly skip
    -- spots where a vehicle is already nearby (ours from a neighbor adoption,
    -- occupied, or just outside ADOPT_RADIUS but inside BLOCK_CREATE_RADIUS).
    -- CheckSpotState returns one of 'adopt' (untagged GTA car within reach),
    -- 'skip' (something already there, don't stack), or 'create' (area clear).
    local state, candidate = CheckSpotState(spotIdx)
    local adopted = false
    local veh

    if state == 'adopt' then
        veh = candidate
        adopted = true
    elseif state == 'skip' then
        -- Something occupies this spot's area but adoption isn't possible.
        -- Reschedule so we retry once the neighbor expires or the occupant
        -- moves. Returning here is what stops the airport-cluster stacking.
        ScheduleEmptySpotRetry(spotIdx)
        return
    else
        veh = CreateVehicle(GetHashKey(modelName),
            spot.coords.x, spot.coords.y, spot.coords.z, spot.heading,
            true,   -- networked
            true)   -- mission entity (v1.4.3: not eligible for memory-pressure despawn)

        if not DoesEntityExist(veh) then
            -- v1.4.8: re-gated behind Config.Debug.
            if Config.Debug then
                print(('[HOBO Auto-Recovery] Spawner: CreateVehicle failed for "%s" at spot %d'):format(
                    modelName, spotIdx))
            end
            ScheduleEmptySpotRetry(spotIdx)
            return
        end
    end

    if adopted then
        -- Adopted: claim the GTA-spawned entity. Locking as a mission entity
        -- prevents GTA from despawning it when the player walks out of scope,
        -- which keeps OUR scheduled lifetime authoritative (ScheduleScenery-
        -- Expiry / pool-expiry sweep) instead of GTA's.
        if SetEntityAsMissionEntity then
            SetEntityAsMissionEntity(veh, true, true)
        end
        -- Use the actual model GTA chose so the tablet's model column matches
        -- what the player sees in-world (our randomly picked modelName above
        -- would otherwise be a lie for adopted vehicles).
        if GetEntityModel then
            modelName = 'hash_' .. tostring(GetEntityModel(veh))
        end
    end

    -- v1.4.7: tag the vehicle so the next restart's WipeWorldOrphans and
    -- FindAdoptCandidate both recognize it as ours. Decorator survives
    -- across resource restarts on the entity itself.
    if DecorSetBool then
        DecorSetBool(veh, SPAWN_DECOR, true)
    end

    SetVehicleNumberPlateText(veh, plate)
    SetVehicleDoorsLocked(veh, 2)
    -- v1.4.10: SetVehicleEngineOn removed (client-only native).
    -- v1.4.14: FreezeEntityPosition removed entirely. Beta testing on the
    -- v1.4.13 deferred freeze showed two problems:
    --   1. Some cars were still locked floating despite the 2 s settle
    --      window (race conditions with adoption replication and ground-Z
    --      stream-in).
    --   2. Frozen entities behave as immovable walls — players ramming a
    --      parked spawn bounced off it like hitting a building, instead of
    --      the natural "nudge and slide" GTA ambient parked cars have.
    -- The car is SetEntityAsMissionEntity (adoption path) AND CreateVehicle
    -- is called with netMissionEntity = true (creation path), so GTA's
    -- auto-despawn won't take it. Gravity drops it to actual ground. Doors
    -- are locked so a griefer can't just enter and drive it off. For parked-
    -- lot scenery this matches GTA's natural ambient behavior.

    local netId = NetworkGetNetworkIdFromEntity(veh)

    -- Decide repo vs scenery. SpawnReplacementRepo passes forceRepo = true
    -- because it's reacting to a completed repo and is required to produce a
    -- new repo case.
    local cfg     = Config.AmbientSpawn or {}
    local maxRepo = cfg.repoEligibleMax
    local isRepo
    if opts.forceRepo then
        isRepo = true
    else
        isRepo = (not maxRepo or RepoEligibleCount < maxRepo)
                 and (math.random() < (cfg.repoChance or 0.20))
    end

    SpawnedVehicles[netId] = {
        plate     = plate,
        model     = modelName,
        spotIndex = spotIdx,
        isRepo    = isRepo,
    }
    SpawnedSpotIndices[spotIdx] = netId

    if isRepo then
        RepoEligibleCount = RepoEligibleCount + 1
        -- Pool entry's own expiresAt (10 min – 2 hr) handles repo lifetime via
        -- the pool-expiry sweep, which calls FreeSpawnedSpot + RespawnAmbientAtSpot.
        createPoolCase({ plate = plate, model = modelName, color = 0, spotIndex = spotIdx })
    else
        -- v1.4.4: scenery cars get the parallel lifetime path.
        ScheduleSceneryExpiry(netId, spotIdx)
    end

    if Config.Debug then
        print(('[HOBO Auto-Recovery] Spawn at spot %d → %s (plate: %s)'):format(
            spotIdx, isRepo and 'repo' or 'scenery', plate))
    end

    return netId, isRepo
end

-- v1.4.8: once-only guard for the startup spawn pass. Multiple paths can
-- trigger it (cold boot waiting for first player, hot restart with players
-- already in-world, late playerJoining firing while another startup is mid-
-- flight) and we only want one pass total.
local DidStartupSpawn = false

local function RunStartupSpawn()
    if DidStartupSpawn then return end
    DidStartupSpawn = true

    math.randomseed(os.time())

    -- v1.4.7: belt-and-suspenders re-register so the decorator is guaranteed
    -- to exist before any DecorGetBool / DecorSetBool call below. Idempotent.
    RegisterSpawnDecor()

    -- v1.4.7: single-pass world wipe — removes only tagged orphans plus a
    -- tight 1.5 m fallback for untagged legacy vehicles. See WipeWorldOrphans
    -- header for the full rationale.
    local taggedHit, fallbackHit = WipeWorldOrphans()
    if taggedHit + fallbackHit > 0 then
        print(('[HOBO Auto-Recovery] Spawner: wiped %d tagged + %d untagged-fallback orphans before spawn'):format(
            taggedHit, fallbackHit))
    end

    local spawnChance = (Config.AmbientSpawn.spawnChance) or 0.75
    local spawned     = 0
    local empty       = 0
    local failed      = 0   -- v1.4.7: separate counter for CreateVehicle nil returns

    for i in ipairs(Config.ParkingSpots) do
        if math.random() <= spawnChance then
            local netId = SpawnVehicleAtSpot(i)
            if netId then
                spawned = spawned + 1
            else
                failed = failed + 1   -- CreateVehicle returned an invalid handle
            end
        else
            -- v1.4.4: empty spots get a 10 s – 5 min retry instead of staying dead
            ScheduleEmptySpotRetry(i)
            empty = empty + 1
        end
        -- v1.4.7: yield one tick per iteration so the server's network layer
        -- isn't flooded with ~500 CreateVehicle calls in a single frame.
        Citizen.Wait(0)
    end

    print(('[HOBO Auto-Recovery] Spawner: %d ambient vehicles spawned, %d repo-eligible, %d failed-create, %d empty (both retrying)'):format(
        spawned, RepoEligibleCount, failed, empty))
end

AddEventHandler('onResourceStart', function(name)
    if GetCurrentResourceName() ~= name then return end
    if not Config.AmbientSpawn or not Config.AmbientSpawn.enabled then return end
    if not Config.ParkingSpots or #Config.ParkingSpots == 0 then
        print('[HOBO Auto-Recovery] Spawner: No parking spots defined — skipping ambient spawn.')
        return
    end

    -- Wait briefly so the server is fully initialised before spawning
    Citizen.Wait(3000)

    -- v1.4.8: server-side CreateVehicle with isNetwork=true requires at least
    -- one player to be in scope of the spawn coords for the entity to be
    -- properly networked. On a cold server boot — when no player is connected
    -- yet — every CreateVehicle in the spawn loop returns an invalid handle
    -- (round-8 logs showed all 489 calls silently failing). Defer the spawn
    -- until the first player is in the world.
    --
    -- Two paths:
    --   • Players already connected (hot restart) → spawn immediately
    --   • No players yet (cold boot) → register a one-shot playerJoining
    --     listener; the first connect triggers the spawn after a 10 s settle
    --     window for the player to fully load in
    if #GetPlayers() > 0 then
        RunStartupSpawn()
    else
        print('[HOBO Auto-Recovery] Spawner: no players connected — deferring startup spawn until first connect')
        AddEventHandler('playerJoining', function()
            if DidStartupSpawn then return end
            -- 10 s settle so the joining player's ped is in the world and
            -- can act as a network scope owner for the spawns near them.
            -- Spots far from the player will still fail-and-retry; subsequent
            -- retries pick them up as the player or others move around.
            Citizen.SetTimeout(10000, RunStartupSpawn)
        end)
    end
end)

-- v1.4.5: delete every vehicle we spawned when the resource stops. Without
-- this, every restart leaves the world littered with mission entities that
-- the next run's SpawnedVehicles table can't see (because Lua state resets).
-- The startup WipeSpotArea pass above is a backstop for unclean shutdowns;
-- this is the proactive cleanup that makes a clean restart actually clean.
AddEventHandler('onResourceStop', function(name)
    if GetCurrentResourceName() ~= name then return end
    local n = 0
    for netId, _ in pairs(SpawnedVehicles) do
        local veh = NetworkGetEntityFromNetworkId(netId)
        if DoesEntityExist(veh) then
            DeleteEntity(veh)
            n = n + 1
        end
    end
    print(('[HOBO Auto-Recovery] Spawner: cleaned up %d vehicles on stop'):format(n))
end)

-- ── Spot management (called from server/main.lua) ─────────────────────────────

-- Mark a parking spot as free and delete its vehicle from the world.
function FreeSpawnedSpot(spotIndex)
    if not spotIndex then return end
    local netId = SpawnedSpotIndices[spotIndex]
    if netId then
        local entry = SpawnedVehicles[netId]
        local veh   = NetworkGetEntityFromNetworkId(netId)
        if DoesEntityExist(veh) then DeleteEntity(veh) end
        SpawnedVehicles[netId] = nil
        -- v1.4.4: only decrement the repo counter when freeing a repo vehicle.
        -- Pre-1.4.4 this decremented unconditionally, which was harmless when
        -- only repo cars went through FreeSpawnedSpot — but now scenery cars
        -- do too (via ScheduleSceneryExpiry), so the counter would over-deplete.
        if entry and entry.isRepo then
            RepoEligibleCount = math.max(0, RepoEligibleCount - 1)
        end
    end
    SpawnedSpotIndices[spotIndex] = nil
end

-- Spawn one replacement repo vehicle at a random currently-empty spot after a
-- random delay (Config.ReplacementDelay.min .. max seconds). Called when a
-- repo is completed, guaranteeing fresh work for operators.
function SpawnReplacementRepo()
    local delayMs = math.random(
        (Config.ReplacementDelay and Config.ReplacementDelay.min or 60),
        (Config.ReplacementDelay and Config.ReplacementDelay.max or 300)
    ) * 1000

    Citizen.SetTimeout(delayMs, function()
        local maxRepo = Config.AmbientSpawn and Config.AmbientSpawn.repoEligibleMax
        if maxRepo and RepoEligibleCount >= maxRepo then return end

        local freeSpots = {}
        for idx = 1, #Config.ParkingSpots do
            if not SpawnedSpotIndices[idx] then
                freeSpots[#freeSpots + 1] = idx
            end
        end
        if #freeSpots == 0 then return end

        local spotIdx = freeSpots[math.random(#freeSpots)]
        SpawnVehicleAtSpot(spotIdx, { forceRepo = true })

        if Config.Debug then
            print(('[HOBO Auto-Recovery] Replacement repo spawned at spot %d'):format(spotIdx))
        end
    end)
end

-- Re-roll an empty parking spot per the spawn/repo chances. Called by the
-- pool-expiry sweep when an unattended pool entry hits its 10 min – 2 hr
-- deadline (server/main.lua), and by ScheduleSceneryExpiry for scenery cars.
function RespawnAmbientAtSpot(spotIdx)
    if not spotIdx or not Config.ParkingSpots[spotIdx] then return end

    local delayMs = math.random(
        (Config.ReplacementDelay and Config.ReplacementDelay.min or 60),
        (Config.ReplacementDelay and Config.ReplacementDelay.max or 300)
    ) * 1000

    Citizen.SetTimeout(delayMs, function()
        if SpawnedSpotIndices[spotIdx] then return end   -- filled while waiting

        local cfg = Config.AmbientSpawn or {}
        if math.random() > (cfg.spawnChance or 0.75) then
            -- v1.4.4: instead of leaving the spot dead, hand off to the short
            -- empty-spot retry. The state machine guarantees every spot is
            -- always either retrying, occupied, or in the ReplacementDelay
            -- window — never permanently dead.
            ScheduleEmptySpotRetry(spotIdx)
            return
        end
        SpawnVehicleAtSpot(spotIdx)
    end)
end
