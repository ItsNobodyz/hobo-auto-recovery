-- ─────────────────────────────────────────────────────────────────────────────
-- server/main.lua  —  Plate checks, CAD sync, auto-pool, owner notifications
-- ─────────────────────────────────────────────────────────────────────────────

local ActiveCases         = {}   -- [src] = caseData
local PlayerPlates        = {}   -- [src] = { plate, ... }
-- v1.6: DutyPlayers / OperatorRoles are not `local` so server/duty.lua can
-- read duty state when authorizing a vehicle spawn. FiveM globals are
-- resource-scoped, so this does not leak to other resources.
DutyPlayers         = {}   -- [src] = true (on-duty operators)
OperatorRoles       = {}   -- [src] = 'tow' | 'camera' | nil (clocked in, no vehicle yet)
local ActiveMarkers       = {}   -- [plate] = camera-car spot, see shape below
local CameraAlertedPlates = {}   -- [src] = { [plate] = true } — per-session camera dedup
local ReposCompletedCount = 0    -- server-wide repos completed since resource start
-- v1.4.3: per-operator set of plates they've sat in the driver seat of since
-- duty-on. Used to reject `checkPlate` calls that would flag an operator's own
-- work vehicle as a repo target (cleared on playerDropped / dutyOff).
local WorkPlates          = {}   -- [src] = { [plate] = true }

-- ActiveMarkers entry shape (v1.4.1):
--   coords     = vector3
--   placedBy   = string (player name)
--   placedAt   = os.time()
--   street     = string (resolved client-side at scan time)
--   postal     = string
--   plateIndex = number (0-5, GTA plate style — drives CSS rendering)
--   poolId     = number | nil (link to CasePool if the hit came from the pool)
--   expiresAt  = os.time() + ttl — inherited from pool.expiresAt when poolId set,
--                otherwise os.time() + Config.MarkerExpirySeconds
--   caseData   = table — copied from the dispatch payload

-- Forward declarations: defined later but referenced from repoComplete (above).
local ClearMarker, BroadcastMarker
-- v1.4.3: EnsureActiveMarker is defined after BroadcastMarker but called from
-- DispatchHit (which lives above it) and from the requestHook pool-claim path.
local EnsureActiveMarker
-- v1.4.3: work-plate set lookup (see WorkPlates table above).
local IsWorkPlate
-- v1.4.5: lightweight push of just CasePool size to open tablets. Called from
-- createPoolCase / repoComplete / pool-expiry sweep so the Hot-List Count
-- updates within ~50 ms instead of waiting up to 10 s for the periodic refresh.
local BroadcastTabletPoolUpdate

-- ── Auto-populate pool ────────────────────────────────────────────────────────
-- [id] = { plate, model, color, ownerName, lienholder, reason,
--          amountOwed, reward, expiresAt, hooked, cadCaseId }
local CasePool  = {}
local PoolIdSeq = 0

-- ── HMAC readiness (validated once at start, gates all CAD HTTP calls) ────────
local HmacOk = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function normPlate(p)
    return (p or ''):gsub('%s+', ''):upper()
end

local function MakeHmacHeaders(body)
    local signature, ts = table.unpack(exports[GetCurrentResourceName()]:hmacSign(body))
    return {
        ['Content-Type']     = 'application/json',
        ['X-Server-ID']      = Config.ServerId,
        ['X-HMAC-Signature'] = signature,
        ['X-HMAC-Timestamp'] = ts,
    }
end

local function CheckForcedList(plate)
    local p = normPlate(plate)
    for _, entry in ipairs(Config.ForcedRepoPlates or {}) do
        if normPlate(entry.plate) == p then
            return {
                plate        = normPlate(entry.plate),
                vehicle_plate = normPlate(entry.plate),
                ownerName    = entry.ownerName   or 'Unknown',
                owner_name   = entry.ownerName   or 'Unknown',
                vehicleMake  = entry.vehicleMake  or '',
                vehicle_make = entry.vehicleMake  or '',
                vehicleColor = entry.vehicleColor or '',
                vehicle_color= entry.vehicleColor or '',
                reason       = entry.reason       or 'Missed payments',
                rewardAmount = entry.reward       or Config.DefaultReward,
                reward_amount= entry.reward       or Config.DefaultReward,
            }
        end
    end
    return nil
end

local function RandomHit()
    return math.random() < (Config.RandomHitChance or 0.05)
end

local function BuildStandaloneCase(plate)
    -- v1.4.2: populate with RandomData so random / forced-fallback hits show
    -- realistic owner / lienholder / reason / amount in the tablet instead of
    -- the old "Unknown Owner / Outstanding balance" placeholders.
    local owner  = RandomData.RandomName()
    local reward = RandomData.RandomReward()
    return {
        plate         = normPlate(plate),
        vehicle_plate = normPlate(plate),
        ownerName     = owner,
        owner_name    = owner,
        lienholder    = RandomData.RandomBank(),
        vehicleMake   = '',
        vehicle_make  = '',
        vehicleColor  = '',
        vehicle_color = '',
        reason        = RandomData.RandomReason(),
        amountOwed    = RandomData.RandomAmount(),
        rewardAmount  = reward,
        reward_amount = reward,
    }
end

-- ── Pool helpers ──────────────────────────────────────────────────────────────

local function poolCount()
    local n = 0
    for _ in pairs(CasePool) do n = n + 1 end
    return n
end

local function CheckCasePool(plate)
    local p = normPlate(plate)
    for id, e in pairs(CasePool) do
        if normPlate(e.plate) == p and not e.hooked then
            return id, e
        end
    end
    return nil, nil
end

-- Pure read of case data for a plate. Shared by the live `checkPlate` alert
-- path AND the tablet's "Check Plate" search — guarantees both return the
-- same shape. NEVER mutates ActiveCases / CasePool.
local function ReadCaseForPlate(plate)
    local p = normPlate(plate)

    local forced = CheckForcedList(p)
    if forced then return forced, 'forced' end

    local _, pool = CheckCasePool(p)
    if pool then
        return {
            plate         = pool.plate,
            vehicle_plate = pool.plate,
            ownerName     = pool.ownerName,
            owner_name    = pool.ownerName,
            lienholder    = pool.lienholder,
            vehicleMake   = pool.model,
            vehicle_make  = pool.model,
            vehicleColor  = pool.color,
            vehicle_color = pool.color,
            reason        = pool.reason,
            amountOwed    = pool.amountOwed,
            rewardAmount  = pool.reward,
            reward_amount = pool.reward,
        }, 'pool'
    end

    -- v1.4.2: also report plates that have been spotted + marked but whose
    -- pool entry has aged out or that were forced/CAD/random-only. Without
    -- this, "Check Plate" returned CLEAR for plates visible on the map.
    if ActiveMarkers and ActiveMarkers[p] and ActiveMarkers[p].caseData then
        local c = ActiveMarkers[p].caseData
        return {
            plate         = p,
            vehicle_plate = p,
            ownerName     = c.ownerName or c.owner_name,
            owner_name    = c.ownerName or c.owner_name,
            lienholder    = c.lienholder,
            vehicleMake   = c.vehicleMake or c.vehicle_make or c.model,
            vehicle_make  = c.vehicleMake or c.vehicle_make or c.model,
            vehicleColor  = c.vehicleColor or c.vehicle_color or c.color,
            vehicle_color = c.vehicleColor or c.vehicle_color or c.color,
            reason        = c.reason,
            amountOwed    = c.amountOwed,
            rewardAmount  = c.rewardAmount or c.reward_amount or c.reward,
            reward_amount = c.rewardAmount or c.reward_amount or c.reward,
        }, 'marker'
    end

    return nil, nil
end

function createPoolCase(info)
    PoolIdSeq = PoolIdSeq + 1
    local id  = PoolIdSeq

    local entry = {
        plate      = normPlate(info.plate),
        model      = info.model or '',
        color      = RandomData.GetColorName(info.color or 0),
        ownerName  = RandomData.RandomName(),
        lienholder = RandomData.RandomBank(),
        reason     = RandomData.RandomReason(),
        amountOwed = RandomData.RandomAmount(),
        reward     = RandomData.RandomReward(),
        expiresAt  = os.time() + math.random(600, 7200),
        hooked     = false,
        cadCaseId  = nil,
        spotIndex  = info.spotIndex or nil,
    }

    CasePool[id] = entry

    -- v1.4.11: re-gated behind Config.Debug now that the spawn → pool → count
    -- chain is verified working (round-10 logs showed pool growing past 45+).
    -- Was always-on in v1.4.6-v1.4.10 as a diagnostic; the user complained
    -- this is filling customer FiveM consoles. Flip Config.Debug if you ever
    -- need to trace pool growth again.
    if Config.Debug then
        print(('[HOBO Auto-Recovery] createPoolCase: id=%d plate=%s spotIdx=%s poolSize=%d'):format(
            id, entry.plate, tostring(info.spotIndex), poolCount()))
    end

    -- v1.4.5: notify open tablets of the new Hot-List Count immediately.
    BroadcastTabletPoolUpdate()

    -- Push to HOBO CAD if enabled and HMAC is ready
    if Config.UseHoboCAD and HmacOk and Config.ServerId ~= '' then
        local body = json.encode({
            serverId     = Config.ServerId,
            vehiclePlate = entry.plate,
            vehicleMake  = entry.model,
            vehicleColor = entry.color,
            ownerName    = entry.ownerName,
            lienholder   = entry.lienholder,
            reason       = entry.reason,
            amountOwed   = entry.amountOwed,
            rewardAmount = entry.reward,
            createdBy    = 'HOBO Auto-Recovery',
        })
        PerformHttpRequest(Config.CADApiUrl .. '/fivem/repo-populate',
            function(status, resp)
                if status == 201 then
                    local ok, parsed = pcall(json.decode, resp or '{}')
                    if ok and parsed and parsed.id and CasePool[id] then
                        CasePool[id].cadCaseId = parsed.id
                    end
                end
            end, 'POST', body, MakeHmacHeaders(body))
    end

    return id
end

-- ── Receive NPC vehicle list from client ──────────────────────────────────────
-- v1.4.3.1 — Config.AutoPopulate is OFF by default now. The whole drive-by
-- NPC seeding path was an earlier-design holdover that competed with the
-- spawner: every plate the operator drove past was being added to the case
-- pool with no probability roll, so within seconds of going on duty every
-- ambient car was a repo target. THAT was the candy bug.
--
-- The intended model is spawner-only: each parking spot rolls once on spawn
-- (75% spawn × 10% repo), the spawned vehicle has a 10 min – 2 hr lifetime,
-- and when the timer expires the spot frees and re-rolls fresh. No drive-by
-- ingestion. This handler stays defined so a custom server can flip
-- AutoPopulate back on (e.g. no parking spots configured), but the default
-- never reaches it.

RegisterNetEvent('hobo-recovery:npcVehicleList')
AddEventHandler('hobo-recovery:npcVehicleList', function(list)
    if not Config.AutoPopulate then return end
    -- v1.4.2: Config.PoolTarget = nil → uncapped; treat as "always need more".
    local needed = Config.PoolTarget and (Config.PoolTarget - poolCount()) or math.huge
    if needed <= 0 then return end

    -- Fisher-Yates shuffle so we don't always grab the first N
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end

    local added = 0
    for _, info in ipairs(list) do
        if added >= needed then break end
        local plate = normPlate(info.plate or '')
        if plate ~= '' then
            local _, existing = CheckCasePool(plate)
            if not existing then
                createPoolCase(info)
                added = added + 1
            end
        end
    end

    if Config.Debug and added > 0 then
        print(('[HOBO Auto-Recovery] Added %d pool cases (total: %d)'):format(added, poolCount()))
    end
end)

-- ── Pool maintenance (expiry + refill) ───────────────────────────────────────
-- v1.4.3.1: NO LONGER gated by AutoPopulate. The expiry sweep + spawner-spot
-- re-roll has to keep running even when AutoPopulate is off (the new default),
-- otherwise spawner-generated pool entries never expire and parking spots
-- never churn. The npcVehicleList refill block at the bottom of the loop IS
-- still gated on AutoPopulate so we don't drive-by-seed unwanted plates.

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.PoolCheckInterval or 60000)

        local now     = os.time()
        local expired = {}

        -- v1.4.4 (P4): index ActiveCases by poolId so the expiry check is O(1)
        -- per pool entry instead of O(M) (inner pairs over ActiveCases). Drops
        -- the sweep from O(N×M) to O(N+M). Negligible at current scale but the
        -- pattern is cleaner and matches the indexed lookups elsewhere.
        local activePoolIds = {}
        for _, caseData in pairs(ActiveCases) do
            if caseData.poolId then activePoolIds[caseData.poolId] = true end
        end

        for id, e in pairs(CasePool) do
            if not e.hooked and not activePoolIds[id] and now >= e.expiresAt then
                expired[#expired + 1] = id
            end
        end

        for _, id in ipairs(expired) do
            local e = CasePool[id]
            -- Remove from CAD silently
            if e and e.cadCaseId and Config.UseHoboCAD and HmacOk and Config.ServerId ~= '' then
                local body = json.encode({ serverId = Config.ServerId, plate = e.plate })
                PerformHttpRequest(Config.CADApiUrl .. '/fivem/repo-expire',
                    function() end, 'POST', body, MakeHmacHeaders(body))
            end
            -- Marker (if any) dies with its pool entry — blip off the map for
            -- everyone, row removed from Active Repo Orders.
            if e then ClearMarker(e.plate) end
            -- v1.4.2: also free the world vehicle + re-roll the parking spot
            -- so the world keeps churning instead of leaving an aged-out repo
            -- vehicle parked as scenery forever. RespawnAmbientAtSpot rolls
            -- spawnChance and repoChance again, so the spot may stay empty,
            -- become scenery, or become a new repo case.
            if e and e.spotIndex then
                FreeSpawnedSpot(e.spotIndex)
                RespawnAmbientAtSpot(e.spotIndex)
            end
            CasePool[id] = nil
        end

        -- v1.4.5: if anything was expired this tick, notify open tablets so
        -- the Hot-List Count drops without waiting for the 10 s periodic refresh.
        if #expired > 0 then BroadcastTabletPoolUpdate() end

        -- Refill from an on-duty player. v1.4.3.1: still gated on
        -- AutoPopulate (default off). Spawner-only servers never reach this
        -- block; if AutoPopulate is on (server with no parking spots
        -- configured), drive-by NPCs feed the pool the old way.
        if Config.AutoPopulate then
            local current   = poolCount()
            local needRefill = (not Config.PoolTarget) or current < Config.PoolTarget
            if needRefill then
                for pid, _ in pairs(DutyPlayers) do
                    if GetPlayerName(pid) then   -- verify player is still connected
                        TriggerClientEvent('hobo-recovery:requestNpcList', pid)
                        break
                    else
                        DutyPlayers[pid] = nil   -- clean up stale entry
                    end
                end
            end
        end

        if Config.Debug and #expired > 0 then
            print(('[HOBO Auto-Recovery] Expired %d cases, pool now: %d'):format(#expired, poolCount()))
        end
    end
end)

-- ── Duty tracking ─────────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:dutyOn')
AddEventHandler('hobo-recovery:dutyOn', function(role)
    DutyPlayers[source]   = true
    -- v1.6: role may be nil (clocked in at an impound, no vehicle spawned
    -- yet). Store it as-is; setOperatorRole below fills it in on spawn.
    OperatorRoles[source] = (role == 'tow' or role == 'camera') and role or nil
end)

RegisterNetEvent('hobo-recovery:dutyOff')
AddEventHandler('hobo-recovery:dutyOff', function()
    DutyPlayers[source]         = nil
    OperatorRoles[source]       = nil
    CameraAlertedPlates[source] = nil   -- reset per-session dedup
    WorkPlates[source]          = nil   -- v1.4.3: drop work-plate set on duty-off
end)

-- v1.6: the operator's role is set when they spawn a tow truck / camera car
-- from an impound spawn zone (server/duty.lua decides this after a successful
-- spawn). client/duty.lua's SetOperatorRole mirrors it here.
RegisterNetEvent('hobo-recovery:setOperatorRole')
AddEventHandler('hobo-recovery:setOperatorRole', function(role)
    if not DutyPlayers[source] then return end
    OperatorRoles[source] = (role == 'tow' or role == 'camera') and role or nil
end)

-- ── Plate Check ───────────────────────────────────────────────────────────────

-- Dispatch a confirmed hit to the operator. Tow operators get the existing
-- accept/cancel repo flow; camera cars get the place-marker prompt.
local function DispatchHit(src, plate, caseData, coords, source_label)
    if OperatorRoles[src] == 'camera' then
        -- Skip if this plate is already in the system (another spotter marked it)
        if ActiveMarkers[plate] then return end

        -- Skip if THIS spotter has already been alerted on this plate (any choice,
        -- including Ignore, consumes the alert until they go off duty).
        CameraAlertedPlates[src] = CameraAlertedPlates[src] or {}
        if CameraAlertedPlates[src][plate] then return end
        CameraAlertedPlates[src][plate] = true

        -- Camera cars never get ActiveCases set — they're spotters, not workers.
        TriggerClientEvent('hobo-recovery:cameraAlert', src, caseData, coords)
        Bridge.Log(('%s camera-car spot: %s (player %d)'):format(source_label, plate, src))
    else
        ActiveCases[src] = caseData
        -- v1.4.3: direct-scan tow cases also get an ActiveMarkers entry so the
        -- case is visible to every operator on the map + tablet (red blip,
        -- "Active Repo Orders" row). Without this, /secure → hookedUp has no
        -- marker to flip to in-transit, and no other operator sees the case.
        EnsureActiveMarker(plate, src, caseData, coords)
        TriggerClientEvent('hobo-recovery:repoAlert', src, caseData)
        Bridge.Log(('%s repo alert: %s (player %d)'):format(source_label, plate, src))
    end
end

RegisterNetEvent('hobo-recovery:checkPlate')
AddEventHandler('hobo-recovery:checkPlate', function(rawPlate, coords)
    local src   = source
    local plate = normPlate(rawPlate)
    if plate == '' then return end
    -- v1.6: a player who has clocked in but not yet spawned a tow truck or
    -- camera car has no role — they're still walking to the spawn pad. Don't
    -- let their scanner generate repo cases until they have a work vehicle.
    if not OperatorRoles[src] then return end
    -- Tow operators with an active job stop scanning. Camera cars never get
    -- ActiveCases set, so they keep spotting freely.
    if OperatorRoles[src] ~= 'camera' and ActiveCases[src] then return end
    -- v1.4.3: never flag a vehicle ANY operator has driven this session — defense
    -- in depth so even if RandomHitChance is re-enabled, an operator's parked
    -- tow truck or camera car can't be flipped to a repo case by another's scan.
    if IsWorkPlate(plate) then return end

    -- 1. Forced config list
    local forced = CheckForcedList(plate)
    if forced then
        DispatchHit(src, plate, forced, coords, 'Forced')
        return
    end

    -- 2. Auto-generated pool
    local poolId, poolEntry = CheckCasePool(plate)
    if poolEntry then
        local caseData = {
            plate         = poolEntry.plate,
            vehicle_plate = poolEntry.plate,
            ownerName     = poolEntry.ownerName,
            owner_name    = poolEntry.ownerName,
            vehicleMake   = poolEntry.model,
            vehicle_make  = poolEntry.model,
            vehicleColor  = poolEntry.color,
            vehicle_color = poolEntry.color,
            reason        = poolEntry.reason,
            rewardAmount  = poolEntry.reward,
            reward_amount = poolEntry.reward,
            cadCaseId     = poolEntry.cadCaseId,
            poolId        = poolId,
        }
        DispatchHit(src, plate, caseData, coords, 'Pool')
        return
    end

    -- 3. CAD lookup (if enabled)
    if Config.UseHoboCAD and Config.ServerId ~= '' then
        local requestData = json.encode({ plate = plate, serverId = Config.ServerId })
        -- v1.4.2: timeout guard. If CAD doesn't respond within
        -- Config.CADRequestTimeoutMs, fall through to the random-chance path so
        -- the scan loop doesn't stall per-plate forever.
        local resolved = false
        local function FallthroughRandom(reason)
            if RandomHit() then
                DispatchHit(src, plate, BuildStandaloneCase(plate), coords, reason)
            end
        end

        PerformHttpRequest(Config.CADApiUrl .. '/fivem/repo-check',
            function(statusCode, resultData)
                if resolved then return end
                resolved = true
                if not GetPlayerName(src) then return end
                if statusCode == 200 then
                    local ok, result = pcall(json.decode, resultData or '{}')
                    if ok and result and result.hit and result.case then
                        DispatchHit(src, plate, result.case, coords, 'CAD')
                        return
                    end
                end
                FallthroughRandom('Random')
            end, 'POST', requestData, MakeHmacHeaders(requestData))

        Citizen.SetTimeout(Config.CADRequestTimeoutMs or 3000, function()
            if resolved then return end
            resolved = true
            if Config.Debug then
                Bridge.Log(('CAD timeout on plate %s, falling through to random'):format(plate))
            end
            if not GetPlayerName(src) then return end
            FallthroughRandom('Random-CADTimeout')
        end)
        return
    end

    -- 4. Standalone random chance
    if RandomHit() then
        DispatchHit(src, plate, BuildStandaloneCase(plate), coords, 'Random')
    end
end)

-- ── Accept Repo ───────────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:acceptRepo')
AddEventHandler('hobo-recovery:acceptRepo', function(plate)
    local src      = source
    local caseData = ActiveCases[src]
    if not caseData then return end

    -- Mark pool entry as hooked so timer won't expire it
    if caseData.poolId then
        local e = CasePool[caseData.poolId]
        if e then e.hooked = true end
    end

    -- Update CAD status to in_progress via HMAC-protected endpoint
    if Config.UseHoboCAD and HmacOk and Config.ServerId ~= '' then
        local body = json.encode({
            serverId         = Config.ServerId,
            plate            = normPlate(caseData.vehicle_plate or caseData.plate),
            status           = 'in_progress',
            assignedOperator = tostring(src),
        })
        PerformHttpRequest(Config.CADApiUrl .. '/fivem/repo-update',
            function(code)
                if Config.Debug then
                    Bridge.Log(('repo-update: HTTP %d'):format(code or 0))
                end
            end, 'POST', body, MakeHmacHeaders(body))
    end

    -- v1.4.13: blue-blip broadcast for the direct-scan accept-prompt path.
    -- The marker already exists (EnsureActiveMarker placed it from
    -- DispatchHit before the prompt fired); we just need to flip its color
    -- on every operator's map AND stamp claimedBy so late-joining operators
    -- see the blue state through BuildTabletSnapshot's existing claimedBy
    -- field. v1.4.12 added the same broadcast at the two requestHook paths
    -- for the tablet→/hook workflow; this completes coverage for scan→accept,
    -- which is the primary in-game path the user actually uses.
    local normPlateStr = normPlate(caseData.vehicle_plate or caseData.plate or plate or '')
    if normPlateStr ~= '' then
        if ActiveMarkers[normPlateStr] then
            ActiveMarkers[normPlateStr].claimedBy = src
        end
        BroadcastMarker('hobo-recovery:markerHooked', normPlateStr, src)
    end
end)

-- ── /hook auto-claim (v1.4.3) ─────────────────────────────────────────────────
-- Solves the v1.4.2 bug where a tow driver could see a camera-marked case on
-- the map + tablet but `/hook` rejected with "no active repo job". Client sends
-- the nearest plate it found within Config.HookupRadius; server validates and
-- atomically claims the case from ActiveMarkers or CasePool. NOTE: Lua's
-- single-threaded event loop makes the check+set on `claimedBy` / `claimed`
-- atomic without a mutex — DO NOT introduce a Wait() between the read and the
-- write or two operators could double-claim the same case.

RegisterNetEvent('hobo-recovery:requestHook')
AddEventHandler('hobo-recovery:requestHook', function(rawPlate, coords)
    local src   = source
    local plate = normPlate(rawPlate or '')
    if plate == '' then return end

    if not DutyPlayers[src] or OperatorRoles[src] ~= 'tow' then
        TriggerClientEvent('hobo-recovery:hookResponse', src, false, 'not_tow')
        return
    end

    -- Already has a case loaded server-side (direct-scan hit they accepted) →
    -- just echo it back so the client can wire up TargetVehicle and proceed.
    if ActiveCases[src] then
        TriggerClientEvent('hobo-recovery:hookResponse', src, true, 'existing', ActiveCases[src])
        return
    end

    -- Auto-claim from ActiveMarkers (camera-confirmed spot OR direct-scan
    -- marker placed by EnsureActiveMarker above).
    local m = ActiveMarkers[plate]
    if m then
        if m.claimedBy and m.claimedBy ~= src then
            TriggerClientEvent('hobo-recovery:hookResponse', src, false, 'claimed')
            return
        end
        m.claimedBy      = src
        ActiveCases[src] = m.caseData
        -- v1.4.12: blip turns blue on every operator's map so others see the
        -- case is en route. Mirrors the markerInTransit broadcast in hookedUp
        -- (which flips it green when /secure succeeds).
        BroadcastMarker('hobo-recovery:markerHooked', plate, src)
        TriggerClientEvent('hobo-recovery:hookResponse', src, true, 'marker', m.caseData)
        return
    end

    -- Fall back to the case pool (forced/spawner-rolled but never alerted).
    -- NOTE: we use `pool.claimedBy` (assignment tracking) and DO NOT touch
    -- `pool.claimed` — that flag is reserved by repoComplete as the duplicate
    -- payment guard. Mixing them would let the assignment flag short-circuit
    -- payout.
    local _, pool = CheckCasePool(plate)
    if pool then
        if pool.claimedBy and pool.claimedBy ~= src then
            TriggerClientEvent('hobo-recovery:hookResponse', src, false, 'claimed')
            return
        end
        pool.claimedBy = src
        local caseData = {
            plate         = pool.plate,
            vehicle_plate = pool.plate,
            ownerName     = pool.ownerName,
            owner_name    = pool.ownerName,
            lienholder    = pool.lienholder,
            vehicleMake   = pool.model,
            vehicle_make  = pool.model,
            vehicleColor  = pool.color,
            vehicle_color = pool.color,
            reason        = pool.reason,
            amountOwed    = pool.amountOwed,
            rewardAmount  = pool.reward,
            reward_amount = pool.reward,
            cadCaseId     = pool.cadCaseId,
            poolId        = pool.id,
        }
        ActiveCases[src] = caseData
        EnsureActiveMarker(plate, src, caseData, coords)
        -- v1.4.12: same blue-blip broadcast as the marker auto-claim path
        -- above. Stamp claimedBy on the ActiveMarkers entry too so
        -- BuildTabletSnapshot's existing claimedBy field replays this state
        -- for late-joining operators.
        if ActiveMarkers[plate] then
            ActiveMarkers[plate].claimedBy = src
        end
        BroadcastMarker('hobo-recovery:markerHooked', plate, src)
        TriggerClientEvent('hobo-recovery:hookResponse', src, true, 'pool', caseData)
        return
    end

    TriggerClientEvent('hobo-recovery:hookResponse', src, false, 'unknown')
end)

-- ── Hooked Up ────────────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:hookedUp')
AddEventHandler('hobo-recovery:hookedUp', function(plate)
    local src = source
    plate = normPlate(plate)

    -- Mark pool entry hooked if not already done in acceptRepo
    local poolId, _ = CheckCasePool(plate)
    if poolId and CasePool[poolId] then
        CasePool[poolId].hooked = true
    end

    -- v1.4.2: marker (if any) flips to "in transit" — broadcast so every
    -- on-duty operator's blip turns green and starts following the tow truck
    -- carrying it. ActiveMarkers gets the inTransitBy stamp so a late-joining
    -- operator's replayMarkers handler can pick up the in-transit state too.
    if ActiveMarkers[plate] then
        ActiveMarkers[plate].inTransitBy = src
        BroadcastMarker('hobo-recovery:markerInTransit', plate, src)
    end
end)

-- ── Repo Complete ─────────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:repoComplete')
AddEventHandler('hobo-recovery:repoComplete', function(plate, zoneName, streetName, operatorName)
    local src      = source
    local caseData = ActiveCases[src]
    local reward   = caseData and tonumber(caseData.reward_amount or caseData.rewardAmount) or Config.DefaultReward

    -- Remove from pool and free the parking spot for reuse.
    -- ATOMIC CLAIM: the check + set on `claimed` below relies on Lua's
    -- single-threaded event loop for atomicity (no real mutex). DO NOT
    -- introduce a Wait() or yield between the check and the set — that opens
    -- a window where two simultaneous repoComplete events could both pass
    -- the guard and double-pay the operator. Same pattern is used by the
    -- requestHook handler's `pool.claimedBy` assignment.
    local poolId, _ = CheckCasePool(normPlate(plate))
    if poolId then
        if CasePool[poolId] and CasePool[poolId].claimed then return end  -- duplicate payment guard
        if CasePool[poolId] then CasePool[poolId].claimed = true end
        local poolEntry = CasePool[poolId]
        if poolEntry and poolEntry.spotIndex then
            FreeSpawnedSpot(poolEntry.spotIndex)
        end
        CasePool[poolId] = nil
        -- v1.4.5: pool just shrank — push the new count to open tablets.
        BroadcastTabletPoolUpdate()
    end

    -- Schedule a replacement repo vehicle at a random free spot
    SpawnReplacementRepo()

    -- Log to HOBO CAD
    if Config.UseHoboCAD and HmacOk and Config.ServerId ~= '' then
        local requestData = json.encode({
            plate           = normPlate(plate),
            serverId        = Config.ServerId,
            towOperator     = operatorName or tostring(src),
            pickupLocation  = streetName or 'Unknown',
            dropDestination = zoneName or 'Impound',
            rewardAmount    = reward,
        })
        PerformHttpRequest(Config.CADApiUrl .. '/fivem/repo-complete',
            function(code)
                if code ~= 200 and code ~= 201 then
                    Bridge.Log(('repo-complete API failed: HTTP %d'):format(code or 0))
                end
            end, 'POST', requestData, MakeHmacHeaders(requestData))
    end

    Bridge.PayPlayer(src, reward, Config.RewardType)
    TriggerClientEvent('hobo-recovery:payoutSuccess', src, reward)
    ActiveCases[src] = nil

    -- Camera-car marker (if any) is now stale — wipe it from every tow map
    ClearMarker(plate)

    -- v1.4.2: server-wide repo counter for the tablet status bar
    ReposCompletedCount = ReposCompletedCount + 1

    Bridge.Log(('Repo complete — player %d — plate %s — $%d'):format(src, plate, reward))
end)

-- ── Cancel / cleanup ──────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:cancelRepo')
AddEventHandler('hobo-recovery:cancelRepo', function()
    ActiveCases[source] = nil
end)

AddEventHandler('playerDropped', function()
    local src = source
    ActiveCases[src]         = nil
    PlayerPlates[src]        = nil
    DutyPlayers[src]         = nil
    OperatorRoles[src]       = nil
    CameraAlertedPlates[src] = nil
    WorkPlates[src]          = nil   -- v1.4.3
end)

-- ── Camera-car marker store ──────────────────────────────────────────────────
-- Helper: broadcast a marker event to every on-duty operator (tow + camera).
-- Camera cars also see markers now so they can dedupe spatially and not waste
-- a scan trip on a plate someone else already flagged.
-- Assigned to the forward-declared locals at the top so repoComplete can call them.
function BroadcastMarker(eventName, ...)
    for pid, _ in pairs(DutyPlayers) do
        local r = OperatorRoles[pid]
        if r == 'tow' or r == 'camera' then
            TriggerClientEvent(eventName, pid, ...)
        end
    end
end

-- v1.4.5: fire just the Hot-List Count to every on-duty operator (open tablet
-- or not — client ignores it when the tablet is hidden). Cheap enough to send
-- on every CasePool change. The full snapshot refresh still fires every 10 s
-- from client/tablet.lua's periodic thread as the catch-all for everything
-- else (active-order ages, repos-completed counter, etc.).
function BroadcastTabletPoolUpdate()
    local size = poolCount()
    local n = 0
    for pid, _ in pairs(DutyPlayers) do
        TriggerClientEvent('hobo-recovery:tablet:poolSizeUpdate', pid, size)
        n = n + 1
    end
    -- v1.4.11: re-gated behind Config.Debug. Fired on every CasePool change
    -- which made it the noisiest line in the log — pool changes ~50 times at
    -- startup plus once per repo completion. Flip Config.Debug if you need
    -- to trace push delivery.
    if Config.Debug then
        print(('[HOBO Auto-Recovery] BroadcastTabletPoolUpdate: poolSize=%d → %d operators'):format(size, n))
    end
end

-- v1.4.11: re-gated behind Config.Debug. The 30 s heartbeat was the v1.4.6
-- diagnostic that proved the spawn → pool → count chain works; now that
-- it's confirmed, the only reason to print is debugging. The thread still
-- runs (so flipping Config.Debug at runtime would start surfacing it) but
-- it's silent by default to keep customer FiveM consoles clean.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30000)
        if Config.Debug then
            local nDuty = 0
            for _ in pairs(DutyPlayers) do nDuty = nDuty + 1 end
            local nMarkers = 0
            for _ in pairs(ActiveMarkers or {}) do nMarkers = nMarkers + 1 end
            print(('[HOBO Auto-Recovery] heartbeat: poolSize=%d dutyOperators=%d activeMarkers=%d'):format(
                poolCount(), nDuty, nMarkers))
        end
    end
end)

function ClearMarker(plate)
    plate = normPlate(plate)
    if not ActiveMarkers[plate] then return end
    ActiveMarkers[plate] = nil
    BroadcastMarker('hobo-recovery:markerRemoved', plate)
end

-- v1.4.3: place an ActiveMarkers entry for any active case that doesn't have
-- one yet. Called from DispatchHit's tow branch (direct-scan path) and from
-- the /hook pool-claim branch. Camera operators still go through placeMarker
-- which writes its own entry (street + postal + their placedBy name) — this
-- helper is the minimal version for paths that bypass placeMarker.
function EnsureActiveMarker(plate, src, caseData, coords)
    plate = normPlate(plate)
    if plate == '' or not coords then return end
    if ActiveMarkers[plate] then return end   -- already exists, don't double-place

    local cx, cy, cz = coords.x, coords.y, coords.z
    if not cx or not cy or not cz then return end

    -- Inherit the pool entry's expiry timer if this came from the pool, otherwise
    -- fall back to MarkerExpirySeconds (same rule as placeMarker uses).
    local poolId, poolEntry
    for id, e in pairs(CasePool) do
        if normPlate(e.plate) == plate and not e.hooked then
            poolId, poolEntry = id, e
            break
        end
    end
    local expiresAt = poolEntry and poolEntry.expiresAt
        or (os.time() + (Config.MarkerExpirySeconds or 600))

    local placedBy = GetPlayerName(src) or ('id:' .. src)
    ActiveMarkers[plate] = {
        coords     = vector3(cx, cy, cz),
        placedBy   = placedBy,
        placedAt   = os.time(),
        street     = '',                       -- direct-scan path has no street resolved
        postal     = '',
        plateIndex = (caseData and tonumber(caseData.plateIndex)) or 0,
        poolId     = poolId,
        expiresAt  = expiresAt,
        caseData   = caseData or {},
    }
    BroadcastMarker('hobo-recovery:markerAdded',
        plate, ActiveMarkers[plate].coords, placedBy, ActiveMarkers[plate].plateIndex)
end

-- v1.4.3: server-side work-plate guard. Each on-duty operator's set of plates
-- they've sat in the driver seat of accumulates across DRIVING vehicles this
-- session; cleared on playerDropped / dutyOff. IsWorkPlate is a union test
-- across all operators so plate "ABC 1234" being operator A's truck means
-- operator B's scanner can't flag it either.
function IsWorkPlate(plate)
    for _, set in pairs(WorkPlates) do
        if set[plate] then return true end
    end
    return false
end

RegisterNetEvent('hobo-recovery:setWorkPlate')
AddEventHandler('hobo-recovery:setWorkPlate', function(plate)
    local src = source
    if not DutyPlayers[src] then return end
    local p = normPlate(plate or '')
    if p == '' then return end
    WorkPlates[src] = WorkPlates[src] or {}
    WorkPlates[src][p] = true
end)

RegisterNetEvent('hobo-recovery:clearWorkPlates')
AddEventHandler('hobo-recovery:clearWorkPlates', function()
    WorkPlates[source] = nil
end)

RegisterNetEvent('hobo-recovery:placeMarker')
AddEventHandler('hobo-recovery:placeMarker', function(rawPlate, coords, street, postal, plateIndex, caseData)
    local src = source
    if OperatorRoles[src] ~= 'camera' then return end
    local plate = normPlate(rawPlate)
    if plate == '' then return end
    if type(coords) ~= 'vector3' and type(coords) ~= 'table' then return end

    local cx, cy, cz = coords.x, coords.y, coords.z
    if not cx or not cy or not cz then return end

    -- Inherit the pool entry's expiry timer when this hit came from the pool.
    -- For forced / CAD / random standalone plates, use the fallback timer.
    local poolId, poolEntry
    for id, e in pairs(CasePool) do
        if normPlate(e.plate) == plate and not e.hooked then
            poolId, poolEntry = id, e
            break
        end
    end
    local expiresAt = poolEntry and poolEntry.expiresAt
        or (os.time() + (Config.MarkerExpirySeconds or 600))

    local placedBy = GetPlayerName(src) or ('id:' .. src)
    ActiveMarkers[plate] = {
        coords     = vector3(cx, cy, cz),
        placedBy   = placedBy,
        placedAt   = os.time(),
        street     = type(street) == 'string' and street or '',
        postal     = type(postal) == 'string' and postal or '',
        plateIndex = tonumber(plateIndex) or 0,
        poolId     = poolId,
        expiresAt  = expiresAt,
        caseData   = type(caseData) == 'table' and caseData or {},
    }

    BroadcastMarker('hobo-recovery:markerAdded',
        plate, ActiveMarkers[plate].coords, placedBy, ActiveMarkers[plate].plateIndex)

    Bridge.Log(('Camera marker placed: %s by player %d (%s) — %s'):format(
        plate, src, placedBy, ActiveMarkers[plate].street ~= '' and ActiveMarkers[plate].street or 'unknown loc'))
end)

-- On-join (or duty toggle): replay existing markers to the caller.
-- Both tow and camera roles get markers now (camera for dedup awareness).
RegisterNetEvent('hobo-recovery:replayMarkers')
AddEventHandler('hobo-recovery:replayMarkers', function()
    local src = source
    local role = OperatorRoles[src]
    if role ~= 'tow' and role ~= 'camera' then return end
    for plate, m in pairs(ActiveMarkers) do
        TriggerClientEvent('hobo-recovery:markerAdded', src,
            plate, m.coords, m.placedBy, m.plateIndex)
        -- v1.4.2: also restore in-transit state if a tow operator picked it up
        -- before the new client came on duty.
        if m.inTransitBy then
            TriggerClientEvent('hobo-recovery:markerInTransit', src, plate, m.inTransitBy)
        end
    end
end)

-- Periodic expiry sweep — non-pool markers only. Pool-backed markers are
-- cleared in the same pass that removes their pool entry (see pool thread).
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30000)
        local now   = os.time()
        local stale = {}
        for plate, m in pairs(ActiveMarkers) do
            if (m.expiresAt or 0) > 0 and now > m.expiresAt then
                stale[#stale + 1] = plate
            end
        end
        for _, plate in ipairs(stale) do ClearMarker(plate) end
    end
end)

-- ── Tablet (/towtab) — standalone-only operator dashboard ─────────────────────
-- Available when CAD isn't linked (Config.UseHoboCAD = false OR HMAC broken).
-- When CAD IS linked, operators are expected to use the CAD Tow Dashboard.

local function CADActive()
    return Config.UseHoboCAD and HmacOk and Config.ServerId ~= ''
end

local function BuildTabletSnapshot()
    local now = os.time()

    -- v1.4.1: Active Repo Orders is now driven by ActiveMarkers (camera-car
    -- confirmed spots) rather than the auto-populated CasePool. The pool is
    -- still consulted internally for plate-pattern matching during scans, but
    -- the operator-facing "active orders" list only shows MARKED plates.
    local activeOrders = {}
    for plate, m in pairs(ActiveMarkers) do
        local c = m.caseData or {}
        activeOrders[#activeOrders + 1] = {
            plate       = plate,
            plateIndex  = m.plateIndex or 0,
            ownerName   = c.ownerName or c.owner_name,
            lienholder  = c.lienholder,
            model       = c.vehicleMake or c.vehicle_make or c.model,
            color       = c.vehicleColor or c.vehicle_color or c.color,
            reason      = c.reason,
            amountOwed  = c.amountOwed,
            reward      = c.rewardAmount or c.reward_amount or c.reward,
            placedBy    = m.placedBy,
            placedAt    = m.placedAt,
            age         = now - m.placedAt,
            street      = m.street or '',
            postal      = m.postal or '',
            coords      = m.coords,
            expiresIn   = m.expiresAt and math.max(0, m.expiresAt - now) or nil,
            -- v1.4.3: lets the tablet render "IN TRANSIT" pills and (later)
            -- "Claimed by X" hints so other operators see live case state.
            inTransitBy = m.inTransitBy or nil,
            claimedBy   = m.claimedBy or nil,
        }
    end

    local poolSize = poolCount()

    -- v1.4.11: re-gated behind Config.Debug. Fires on every /towtab open AND
    -- every 10 s while the tablet is open AND every time the belt-and-
    -- suspenders push at the end of this function runs — far too noisy for
    -- production. Flip Config.Debug if you need to verify what's shipped.
    if Config.Debug then
        print(('[HOBO Auto-Recovery] BuildTabletSnapshot: poolSize=%d markerCount=%d'):format(
            poolSize, #activeOrders))
    end

    -- v1.4.6: belt-and-suspenders push. Even if the createPoolCase /
    -- repoComplete / pool-expiry pushes were silently failing, every snapshot
    -- rebuild now guarantees a fresh count on the wire. Snapshots fire on
    -- /towtab open and every 10 s thereafter while the tablet is open (the
    -- periodic refresh in client/tablet.lua), so the count is at most 10 s
    -- stale even if every other push site breaks.
    BroadcastTabletPoolUpdate()

    return {
        activeOrders   = activeOrders,
        serverTime     = now,
        poolSize       = poolSize,
        markerCount    = #activeOrders,
        reposCompleted = ReposCompletedCount,   -- v1.4.2 status-bar counter
    }
end

RegisterNetEvent('hobo-recovery:tablet:open')
AddEventHandler('hobo-recovery:tablet:open', function()
    local src = source
    if not DutyPlayers[src] then
        TriggerClientEvent('hobo-recovery:tablet:denied', src, 'Must be on duty.')
        return
    end
    if CADActive() then
        TriggerClientEvent('hobo-recovery:tablet:denied', src,
            'CAD is active — use the Tow Dashboard.')
        return
    end
    local snapshot = BuildTabletSnapshot()
    snapshot.operatorName = GetPlayerName(src) or ('id:' .. src)
    snapshot.role         = OperatorRoles[src] or 'tow'
    TriggerClientEvent('hobo-recovery:tablet:open', src, snapshot)
end)

RegisterNetEvent('hobo-recovery:tablet:searchPlate')
AddEventHandler('hobo-recovery:tablet:searchPlate', function(rawPlate)
    local src = source
    if not DutyPlayers[src] then return end
    if CADActive() then return end   -- gated; client also blocks the search box

    local plate = normPlate(rawPlate)
    if plate == '' then
        TriggerClientEvent('hobo-recovery:tablet:searchResult', src,
            { plate = '', hit = false })
        return
    end

    local caseData, srcType = ReadCaseForPlate(plate)
    if caseData then
        TriggerClientEvent('hobo-recovery:tablet:searchResult', src,
            { plate = plate, hit = true, case = caseData, source = srcType })
    else
        TriggerClientEvent('hobo-recovery:tablet:searchResult', src,
            { plate = plate, hit = false })
    end
end)

-- ── Resource lifecycle ────────────────────────────────────────────────────────

AddEventHandler('onResourceStart', function(name)
    if GetCurrentResourceName() ~= name then return end

    -- Validate HMAC secret once so we never spam the console
    if Config.UseHoboCAD then
        local sig, _ = table.unpack(exports[GetCurrentResourceName()]:hmacSign('probe'))
        HmacOk = sig ~= ''
        if not HmacOk then
            print('[HOBO Auto-Recovery] !! CAD sync is OFF — HOBOCAD_HMAC_SECRET convar not found.')
            print('[HOBO Auto-Recovery] !! Add this line to server.cfg then restart the resource:')
            print('[HOBO Auto-Recovery] !!   set HOBOCAD_HMAC_SECRET "paste_your_secret_here"')
        end
    end

    math.randomseed(os.time() * 1234567 + GetGameTimer())

    local ver = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '?'
    print('[HOBO Auto-Recovery] v' .. ver .. ' Started — CAD: ' .. tostring(Config.UseHoboCAD and HmacOk)
        .. ' | AutoPopulate: ' .. tostring(Config.AutoPopulate))

    -- Version check against HOBO CAD. Only warns when the published version is
    -- strictly NEWER than what's installed — comparing component-by-component
    -- so a stale or older endpoint value can never tell a server to
    -- "downgrade" (the old `~=` check did exactly that).
    local function versionNewer(remote, installed)
        local function parts(v)
            local t = {}
            for n in tostring(v):gmatch('%d+') do t[#t + 1] = tonumber(n) end
            return t
        end
        local r, i = parts(remote), parts(installed)
        for n = 1, math.max(#r, #i) do
            local a, b = r[n] or 0, i[n] or 0
            if a ~= b then return a > b end
        end
        return false
    end

    PerformHttpRequest(Config.CADApiUrl .. '/fivem/auto-recovery-version',
        function(code, body)
            if code ~= 200 then return end
            local ok, data = pcall(json.decode, body or '{}')
            if not ok or not data or not data.version then return end
            if versionNewer(data.version, ver) then
                print(('[HOBO Auto-Recovery] !! Update available: v%s → v%s'):format(ver, data.version))
                print('[HOBO Auto-Recovery] !! Download the latest version at: ' .. (data.downloadUrl or 'https://hobocad.com/scripts'))
            end
        end, 'GET', '', { ['Content-Type'] = 'application/json' })
end)

AddEventHandler('onResourceStop', function(name)
    if GetCurrentResourceName() ~= name then return end
    print('[HOBO Auto-Recovery] Stopped')
end)
