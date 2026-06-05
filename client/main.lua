-- ─────────────────────────────────────────────────────────────────────────────
-- client/main.lua  —  Duty state, global vars, Notify wrapper, NPC pool seeding
-- ─────────────────────────────────────────────────────────────────────────────

IsOnDuty            = false   -- true when player has manually gone on duty
OperatorRole        = nil     -- 'tow' | 'camera' | nil — set by SetOperatorRole
                              -- (client/duty.lua) when a vehicle is spawned
DutyStartTime       = 0       -- GetGameTimer() at the moment GoOnDuty() ran
ActiveRepoJob       = nil     -- current repo case data (set on accept)
TargetVehicle       = nil     -- entity handle of the vehicle being repossessed
IsHookedUp          = false   -- true after /secure skill check succeeds
IsHookInitiated     = false   -- true after /hook succeeds, before /secure
HookedTowTruck      = nil     -- tow truck entity stored at /hook time
HookedTargetVehicle = nil     -- target vehicle entity stored at /hook time
ActiveDropZone      = nil     -- nearest drop-off zone selected after hookup
TabletOpen          = false   -- true while the /towtab tablet UI is showing
SecureFailCount     = 0       -- v1.4.15: per-job count of failed /secure skill
                              -- checks. 2nd fail honks the target's alarm,
                              -- 3rd fail triggers a d20-driven NPC ambush via
                              -- TriggerAmbush() in client/ambush.lua. Resets
                              -- in ClearJobState() so a new job starts fresh.

-- v1.4.15: client-side mirror of the server's hobo_spawn decorator
-- registration. DecorRegister is idempotent (safe to call alongside the
-- server's registration). Needed so the ground-snap sweep below can read
-- the tag via DecorExistOn / DecorGetBool — without client-side registration
-- those return false even when the server has set the decorator.
local SPAWN_DECOR = 'hobo_spawn'
if DecorRegister then DecorRegister(SPAWN_DECOR, 2) end   -- 2 = BOOL

-- ── hobo-notify wrapper with ox_lib fallback ──────────────────────────────────
function Notify(title, text, ntype, duration, opts)
    if GetResourceState('hobo-notify') == 'started' then
        TriggerEvent('hobo-notify:Notify', title, text or '', ntype or 'info',
            duration or 4000, opts or { position = 'tr' })
    else
        local typeMap = { warn = 'warning', info = 'inform', success = 'success', error = 'error' }
        lib.notify({
            title       = title,
            description = text or '',
            type        = typeMap[ntype] or 'inform',
            duration    = duration or 4000,
            position    = 'top',
        })
    end
end

-- ── Duty system ───────────────────────────────────────────────────────────────

TowModelHashes    = {}   -- global so minigame.lua can reference it
CameraModelHashes = {}   -- camera-car role: scan only, no hook

Citizen.CreateThread(function()
    -- v1.6: Config.TowVehicleModels / CameraCarModels are now { model, label }
    -- tables (the label drives the spawn menus); read the .model field.
    for _, v in ipairs(Config.TowVehicleModels or {}) do
        TowModelHashes[GetHashKey(v.model)] = true
    end
    for _, v in ipairs(Config.CameraCarModels or {}) do
        CameraModelHashes[GetHashKey(v.model)] = true
    end
end)

local function ClearJobState()
    ActiveRepoJob       = nil
    TargetVehicle       = nil
    IsHookedUp          = false
    IsHookInitiated     = false
    HookedTowTruck      = nil
    HookedTargetVehicle = nil
    ActiveDropZone      = nil
    SecureFailCount     = 0   -- v1.4.15: reset escalation counter per job
    ClearGpsPlayerWaypoint()
end

-- v1.4.15: ground-snap sweep. v1.4.14 removed FreezeEntityPosition so gravity
-- would drop CreateVehicle-spawned cars from spot.coords.z (ped-hip height
-- ≈ 1 m above ground) to actual ground. In practice FiveM's physics doesn't
-- always simulate the drop reliably — beta testing showed cars still floating
-- at some lots. SetVehicleOnGroundProperly is the client-side native that
-- snaps a vehicle's wheels onto the actual ground at its current X/Y. It's
-- idempotent (already-grounded vehicles unaffected), so calling it on a 20 s
-- tick across nearby tagged vehicles is cheap and corrective. Only checks
-- entities within ~150 m of the player to skip the whole-map iteration cost.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(20000)
        local ped = PlayerPedId()
        if ped ~= 0 and DoesEntityExist(ped) then
            local pCoords = GetEntityCoords(ped)
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(veh) then
                    local tagged = DecorExistOn and DecorExistOn(veh, SPAWN_DECOR)
                               and DecorGetBool and DecorGetBool(veh, SPAWN_DECOR)
                    if tagged then
                        local d = #(pCoords - GetEntityCoords(veh))
                        if d < 150.0 then
                            SetVehicleOnGroundProperly(veh)
                        end
                    end
                end
            end
        end
    end
end)

-- v1.6: GoOnDuty is now called by the impound clock-in zone (client/duty.lua)
-- with NO role — the operator role is set later by SetOperatorRole (also in
-- client/duty.lua) when they spawn a tow truck or camera car. The `role`
-- parameter is kept for safety but is normally nil here. Promoted from
-- `local` so client/duty.lua can call it.
function GoOnDuty(role)
    IsOnDuty      = true
    OperatorRole  = role           -- nil until a vehicle is spawned
    DutyStartTime = GetGameTimer()

    Notify('HOBO Auto-Recovery',
        (OperatorRole == 'camera' and (Locale.on_duty_camera or 'On duty — Camera Car'))
        or (OperatorRole == 'tow' and Locale.on_duty)
        or Locale.duty_clocked_on,
        'success', 4000, { position = 'tc' })

    -- One-time grace-period notice so operators know why scans aren't reporting
    local graceMs = Config.DutyGracePeriod or 30000
    if graceMs > 0 then
        Notify('📡 Scanner',
            ('Scanner calibrating — repo checks active in %ds'):format(math.floor(graceMs / 1000)),
            'info', 5000, { position = 'tc' })
    end

    TriggerServerEvent('hobo-recovery:dutyOn', OperatorRole)

    -- Replay existing markers so map blips appear immediately. The server
    -- filters the broadcast by the operator's current role.
    Citizen.SetTimeout(500, function()
        if IsOnDuty then
            TriggerServerEvent('hobo-recovery:replayMarkers')
        end
    end)
end

-- v1.6: promoted from `local` so client/duty.lua's clock-in zone can call it.
function GoOffDuty()
    IsOnDuty      = false
    OperatorRole  = nil
    DutyStartTime = 0
    Notify('HOBO Auto-Recovery', Locale.off_duty, 'info', 4000, { position = 'tc' })
    TriggerServerEvent('hobo-recovery:dutyOff')

    -- v1.4.2: orphan-vehicle cleanup. If the operator is mid-tow (vehicle is
    -- attached to their truck via /secure but not yet dropped off), detach
    -- and delete the towed vehicle so we don't leave a floating wreck. Same
    -- pattern as dropoff.lua's cleanup but without the payout side.
    if IsHookedUp and TargetVehicle and DoesEntityExist(TargetVehicle) then
        DetachEntity(TargetVehicle, true, true)
        FreezeEntityPosition(TargetVehicle, false)
        Citizen.SetTimeout(500, function()
            if DoesEntityExist(TargetVehicle) then
                DeleteEntity(TargetVehicle)
            end
        end)
    end

    if ActiveRepoJob then
        TriggerServerEvent('hobo-recovery:cancelRepo')
        ClearJobState()
    end
    -- Clear any spotter blips left on the map
    if ClearMarkerBlips then ClearMarkerBlips() end

    -- v1.4.3: clear the work-plate set both client + server side. Without this,
    -- a vehicle the operator drove this session would stay protected forever
    -- (only an issue if Config.RandomHitChance is re-enabled, but cheap to fix).
    OwnPlates = {}
    TriggerServerEvent('hobo-recovery:clearWorkPlates')
end

-- v1.6: the /ondutytow and /ondutycam commands were removed. Duty is now
-- toggled by pressing E at an impound clock-in zone (client/duty.lua), and
-- the operator role is set by which vehicle the player spawns there.

-- ── NPC vehicle scanner (seeds the auto-populate pool, parked vehicles only) ──

function SendNpcVehicleList()
    local myVeh = GetVehiclePedIsIn(PlayerPedId(), false)
    local list  = {}

    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if veh ~= myVeh and DoesEntityExist(veh) then
            local driver = GetPedInVehicleSeat(veh, -1)
            -- Only include parked vehicles (empty driver seat, no NPC or player)
            if driver == 0 or not DoesEntityExist(driver) then
                local plate = GetVehicleNumberPlateText(veh):gsub('%s+', ''):upper()
                if plate ~= '' then
                    local primaryColor = GetVehicleColours(veh)
                    list[#list + 1] = {
                        plate = plate,
                        model = GetDisplayNameFromVehicleModel(GetEntityModel(veh)),
                        color = primaryColor,
                    }
                end
            end
        end
        if #list >= 60 then break end
    end

    if #list > 0 then
        TriggerServerEvent('hobo-recovery:npcVehicleList', list)
    end
end

RegisterNetEvent('hobo-recovery:requestNpcList', function()
    if IsOnDuty then
        SendNpcVehicleList()
    end
end)

-- ── Payout notifications ──────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:payoutSuccess')
AddEventHandler('hobo-recovery:payoutSuccess', function(amount)
    Notify('Repo Complete', Locale.repo_complete:format(amount), 'success', 8000, { position = 'tc' })
    ClearJobState()
end)

RegisterNetEvent('hobo-recovery:receivePayout')
AddEventHandler('hobo-recovery:receivePayout', function(amount, rewardType)
    Notify('Repo Payout',
        ('$%d deposited (%s)'):format(amount, rewardType or 'cash'),
        'success', 8000, { position = 'tc' })
end)

-- ── Camera-car map markers (tow-side blip rendering) ─────────────────────────
-- A camera car places a marker for a spotted repo plate; every on-duty tow
-- operator sees a car-style blip at the vehicle's location until it expires,
-- gets repo'd, or the duty session ends.

MarkerBlips = {}   -- [plate] = blipHandle

-- v1.4.3: plates the operator has sat in the driver seat of since dutyOn.
-- Globalized so scanner.lua can skip them in its scan loop without an import.
-- Cleared by GoOffDuty (above). The server keeps a mirror via setWorkPlate
-- so other operators' scanners can't flag this operator's parked work vehicle
-- either. A 1s polling thread (below) is enough — operators don't swap
-- vehicles within a 1s window often enough for it to matter.
OwnPlates = {}

Citizen.CreateThread(function()
    while true do
        if IsOnDuty then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                local p = (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', ''):upper()
                if p ~= '' and not OwnPlates[p] then
                    OwnPlates[p] = true
                    TriggerServerEvent('hobo-recovery:setWorkPlate', p)
                end
            end
        end
        Citizen.Wait(1000)
    end
end)

function ClearMarkerBlips()
    for _, blip in pairs(MarkerBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    MarkerBlips = {}
end

RegisterNetEvent('hobo-recovery:markerAdded')
AddEventHandler('hobo-recovery:markerAdded', function(plate, coords, placedBy)
    -- Both roles render markers. Tow operators use them to find the vehicle;
    -- camera cars use them as spatial dedup ("don't re-scan this one").
    if OperatorRole ~= 'tow' and OperatorRole ~= 'camera' then return end
    if not coords then return end
    plate = (plate or ''):upper()

    if MarkerBlips[plate] and DoesBlipExist(MarkerBlips[plate]) then
        RemoveBlip(MarkerBlips[plate])
    end

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip,  Config.MarkerBlipSprite or 225)
    SetBlipColour(blip,  Config.MarkerBlipColor  or 1)
    SetBlipScale(blip,   0.9)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Repo Spotted: ' .. plate)
    EndTextCommandSetBlipName(blip)
    MarkerBlips[plate] = blip

    -- Don't notify on bulk replay (called via replayMarkers). Heuristic: skip
    -- the toast when no `placedBy` is supplied OR it's the initial duty-up replay
    -- (we don't know yet, so just keep the toast — the user can mute it later).
    Notify('📷 Camera Car',
        ('%s spotted by %s'):format(plate, placedBy or 'unknown'),
        'info', 5000, { position = 'tc' })
end)

-- v1.4.2: in-transit follow blip. When a tow operator /secure's a marked
-- vehicle, the server broadcasts markerInTransit(plate, ownerSrc) and every
-- on-duty operator's blip flips red → green and starts following the tow
-- operator's ped position. Thread runs until the blip is removed (drop-off,
-- expiry, off-duty).
InTransitBlips = {}   -- [plate] = { ownerSrc = number } sentinel for follow-thread

-- v1.4.12: blip turns BLUE the moment a tow operator runs /hook (claim,
-- but not yet attached to the truck). markerInTransit below flips it GREEN
-- when /secure succeeds. No follow-thread needed — the blip stays parked at
-- the vehicle's last known coords until /secure, then markerInTransit takes
-- over the live tracking.
RegisterNetEvent('hobo-recovery:markerHooked')
AddEventHandler('hobo-recovery:markerHooked', function(plate, ownerSrc)
    if OperatorRole ~= 'tow' and OperatorRole ~= 'camera' then return end
    plate = (plate or ''):upper()
    local blip = MarkerBlips[plate]
    if not blip or not DoesBlipExist(blip) then return end

    SetBlipColour(blip, Config.MarkerHookedColor or 3)   -- blue
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Repo Hooked: ' .. plate)
    EndTextCommandSetBlipName(blip)
end)

RegisterNetEvent('hobo-recovery:markerInTransit')
AddEventHandler('hobo-recovery:markerInTransit', function(plate, ownerSrc)
    if OperatorRole ~= 'tow' and OperatorRole ~= 'camera' then return end
    plate = (plate or ''):upper()
    local blip = MarkerBlips[plate]
    if not blip or not DoesBlipExist(blip) then return end

    SetBlipColour(blip, Config.MarkerInTransitColor or 2)   -- green
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Repo In Transit: ' .. plate)
    EndTextCommandSetBlipName(blip)

    InTransitBlips[plate] = { ownerSrc = ownerSrc }

    Citizen.CreateThread(function()
        while InTransitBlips[plate] do
            local b = MarkerBlips[plate]
            if not b or not DoesBlipExist(b) then break end
            local pid = GetPlayerFromServerId(ownerSrc)
            if pid ~= -1 then
                local ped = GetPlayerPed(pid)
                if ped ~= 0 and DoesEntityExist(ped) then
                    local c = GetEntityCoords(ped)
                    SetBlipCoords(b, c.x, c.y, c.z)
                end
            end
            -- Out of OneSync range → ped is unavailable locally. The blip
            -- just stops updating until the tow operator comes back into range.
            Citizen.Wait(1000)
        end
    end)

    Notify('📦 Tow',
        ('%s is now in transit'):format(plate),
        'info', 4000, { position = 'tc' })
end)

RegisterNetEvent('hobo-recovery:markerRemoved')
AddEventHandler('hobo-recovery:markerRemoved', function(plate)
    plate = (plate or ''):upper()
    if MarkerBlips[plate] and DoesBlipExist(MarkerBlips[plate]) then
        RemoveBlip(MarkerBlips[plate])
    end
    MarkerBlips[plate] = nil
    InTransitBlips[plate] = nil   -- stops the follow-thread on next tick
end)

-- ── Bulk parking spot collector ───────────────────────────────────────────────
-- Usage: drive/walk to each spot → /markspot  (repeat)
--        when done → /dumpspots → open F8 → copy block → paste into config.lua
--        /clearspots to reset for a new session

local MarkedSpots = {}

TriggerEvent('chat:addSuggestion', '/markspot', 'Mark current position as a Config.ParkingSpots entry')
RegisterCommand('markspot', function()
    local ped     = PlayerPedId()
    local coords  = GetEntityCoords(ped)
    local veh     = GetVehiclePedIsIn(ped, false)
    local heading = veh ~= 0 and GetEntityHeading(veh) or GetEntityHeading(ped)
    MarkedSpots[#MarkedSpots + 1] = { coords = coords, heading = heading }
    Notify('Coords', ('Spot %d marked'):format(#MarkedSpots), 'info', 1500)
end, false)

TriggerEvent('chat:addSuggestion', '/dumpspots', 'Print all marked spots to F8 console — copy block into config.lua')
RegisterCommand('dumpspots', function()
    if #MarkedSpots == 0 then
        Notify('Coords', 'No spots marked. Use /markspot first.', 'warn', 3000)
        return
    end
    print('[HOBO Auto-Recovery] ── Paste into Config.ParkingSpots ──')
    for _, s in ipairs(MarkedSpots) do
        print(('    { coords = vector3(%.1f, %.1f, %.1f), heading = %.1f },'):format(
            s.coords.x, s.coords.y, s.coords.z, s.heading))
    end
    print(('[HOBO Auto-Recovery] ── %d spots above ──'):format(#MarkedSpots))
    Notify('Coords', ('%d spots printed to F8 — open F8 to copy.'):format(#MarkedSpots), 'success', 4000)
end, false)

TriggerEvent('chat:addSuggestion', '/clearspots', 'Clear the marked parking spots list')
RegisterCommand('clearspots', function()
    local count = #MarkedSpots
    MarkedSpots = {}
    Notify('Coords', ('Cleared %d spots.'):format(count), 'info', 2000)
end, false)
