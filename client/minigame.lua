-- ─────────────────────────────────────────────────────────────────────────────
-- client/minigame.lua  —  Two-phase hookup: /hook (in truck) + /secure (on foot)
-- ─────────────────────────────────────────────────────────────────────────────


-- ── /hook — player in tow truck, backs up to target ──────────────────────────
-- v1.4.3 rewrite: no longer pre-checks `ActiveRepoJob`. The server is the
-- source of truth — client just identifies the nearest vehicle within
-- Config.HookupRadius and asks the server to auto-claim it (from camera
-- markers, the case pool, or echo an already-assigned case). The server
-- responds with `hookResponse` and the actual attach setup happens there.

-- Track the truck + vehicle we asked about so the response handler can wire
-- them up without re-running FindTargetVehicle.
local PendingHookTruck   = nil
local PendingHookVehicle = nil

TriggerEvent('chat:addSuggestion', '/hook', 'Back your tow truck to the repo vehicle and confirm position')

RegisterCommand('hook', function()
    if not IsOnDuty then
        Notify('Hook', Locale.not_on_duty or 'Must be on duty.', 'error', 3000)
        return
    end
    if IsHookedUp then
        Notify('Hook', Locale.vehicle_already_attached, 'info', 3000)
        return
    end
    if IsHookInitiated then
        Notify('Hook', Locale.hook_initiated, 'info', 3000)
        return
    end

    local ped      = PlayerPedId()
    local towTruck = GetVehiclePedIsIn(ped, false)
    if towTruck == 0 or not TowModelHashes[GetEntityModel(towTruck)] then
        Notify('Hook', Locale.must_be_in_tow or Locale.hook_wrong_vehicle, 'error', 3000)
        return
    end

    -- Find the nearest vehicle (other than my truck) within hookup radius.
    -- Server validates the plate against ActiveMarkers / CasePool, so we
    -- don't pre-check ActiveRepoJob anymore.
    local myCoords = GetEntityCoords(towTruck)
    local nearestVeh, nearestPlate, nearestDist
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if veh ~= towTruck and DoesEntityExist(veh) then
            local d = #(myCoords - GetEntityCoords(veh))
            if d < Config.HookupRadius and (not nearestDist or d < nearestDist) then
                nearestVeh   = veh
                nearestDist  = d
                nearestPlate = GetVehicleNumberPlateText(veh):gsub('%s+', ''):upper()
            end
        end
    end

    if not nearestVeh then
        Notify('Hook', Locale.no_vehicle_in_range or Locale.not_near_target, 'error', 3000)
        return
    end

    PendingHookTruck   = towTruck
    PendingHookVehicle = nearestVeh

    TriggerServerEvent('hobo-recovery:requestHook', nearestPlate, GetEntityCoords(nearestVeh))
end, false)

-- Server response: success → wire up the attach setup the same way the old
-- client-side /hook used to (HookedTowTruck + HookedTargetVehicle + the
-- IsHookInitiated flag + the hookInitiated event). Failure → just toast.
RegisterNetEvent('hobo-recovery:hookResponse')
AddEventHandler('hobo-recovery:hookResponse', function(success, reason, caseData)
    if not success then
        local msg
        if reason == 'not_tow' then
            msg = Locale.only_tow or 'Only tow drivers can hook.'
        elseif reason == 'claimed' then
            msg = Locale.already_claimed or 'That case is already claimed by another operator.'
        else
            msg = Locale.no_active_repo
        end
        Notify('Hook', msg, 'error', 3500)
        PendingHookTruck   = nil
        PendingHookVehicle = nil
        return
    end

    -- Server gave us the case data (whether new claim or echo of an existing
    -- ActiveCases entry). Mirror it into the existing client state so all the
    -- /secure / proximity HUD / dropoff flows just work.
    ActiveRepoJob       = caseData
    HookedTowTruck      = PendingHookTruck
    HookedTargetVehicle = PendingHookVehicle
    IsHookInitiated     = true
    PendingHookTruck    = nil
    PendingHookVehicle  = nil

    TriggerEvent('hobo-recovery:hookInitiated')

    PlaySoundFrontend(-1, 'WAYPOINT_SET', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    Notify('Hook', Locale.hook_success, 'success', 5000)
end)

-- ── /secure — player on foot, triggers skill check and attaches ───────────────

TriggerEvent('chat:addSuggestion', '/secure', 'Stand between both vehicles and attach the repo target')

RegisterCommand('secure', function()
    if not IsOnDuty or not ActiveRepoJob then
        Notify('Secure', Locale.no_active_repo, 'error', 3000)
        return
    end
    if IsHookedUp then
        Notify('Secure', Locale.vehicle_already_attached, 'info', 3000)
        return
    end
    if not IsHookInitiated then
        Notify('Secure', Locale.hook_not_initiated, 'error', 3000)
        return
    end

    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= 0 then
        Notify('Secure', Locale.secure_exit_truck, 'error', 3000)
        return
    end

    -- v1.4.14: re-find the target vehicle by plate before validating anything
    -- else. Beta testing showed the stale entity handle from /hook can point
    -- to a different vehicle by the time /secure fires (FiveM entity handle
    -- pool recycling when the original despawns or moves out of scope) —
    -- symptom was a different model + plate appearing on the truck bed than
    -- what the operator originally hooked. The server-validated plate in
    -- ActiveRepoJob is the authoritative key; HookedTargetVehicle from /hook
    -- is treated as a hint, overridden if a fresher match is in scope.
    do
        local targetPlate = ((ActiveRepoJob.vehicle_plate or ActiveRepoJob.plate or '')
                             :gsub('%s+', ''):upper())
        if targetPlate ~= '' then
            local myCoords = GetEntityCoords(ped)
            local bestVeh, bestDist
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(veh) and veh ~= HookedTowTruck then
                    local p = (GetVehicleNumberPlateText(veh) or '')
                               :gsub('%s+', ''):upper()
                    if p == targetPlate then
                        local vCoords = GetEntityCoords(veh)
                        local dx, dy = myCoords.x - vCoords.x, myCoords.y - vCoords.y
                        local d2 = math.sqrt(dx * dx + dy * dy)
                        if not bestDist or d2 < bestDist then
                            bestVeh, bestDist = veh, d2
                        end
                    end
                end
            end
            if bestVeh then
                HookedTargetVehicle = bestVeh
            end
        end
    end

    if not DoesEntityExist(HookedTowTruck) or not DoesEntityExist(HookedTargetVehicle) then
        Notify('Secure', Locale.hookup_fail, 'error', 3000)
        IsHookInitiated     = false
        HookedTowTruck      = nil
        HookedTargetVehicle = nil
        return
    end

    -- v1.4.14: 2D distance check (x,y only). The old 3D check failed when a
    -- vehicle's Z was even slightly off ground — diagonal could exceed
    -- HookupRadius even when the operator stood right next to it.
    local myCoords = GetEntityCoords(ped)
    local vCoords  = GetEntityCoords(HookedTargetVehicle)
    local dx, dy   = myCoords.x - vCoords.x, myCoords.y - vCoords.y
    if math.sqrt(dx * dx + dy * dy) > Config.HookupRadius then
        Notify('Secure', Locale.not_near_target, 'error', 3000)
        return
    end

    Notify('Secure', Locale.hookup_start, 'info', 2000)

    local success = lib.skillCheck(
        Config.HookupSkillCheck.difficulty,
        Config.HookupSkillCheck.inputs,
        Config.HookupSkillCheck.duration
    )
    Citizen.Wait(150)

    if not success then
        Notify('Secure', Locale.hookup_fail, 'error', 3000)
        -- v1.4.15: escalating consequences for repeated /secure failures on
        -- the same repo job. 1st fail: just the notify. 2nd fail: car alarm
        -- fires (audible warning). 3rd fail: NPC ambush via two d20 rolls
        -- (count + weapon severity) in client/ambush.lua, then the counter
        -- resets so the next sequence starts fresh. Counter is also reset
        -- in ClearJobState() on cancel/payout/duty-off.
        SecureFailCount = (SecureFailCount or 0) + 1
        if SecureFailCount == 2 and HookedTargetVehicle and DoesEntityExist(HookedTargetVehicle) then
            -- v1.5.1: StartVehicleAlarm is a no-op unless the vehicle has an
            -- alarm system enabled. Ambient/CreateVehicle-spawned cars don't
            -- have one by default, which is why v1.5 testing showed no honk.
            -- SetVehicleAlarm installs the alarm, SetVehicleAlarmTimeLeft picks
            -- a duration, and StartVehicleAlarm finally triggers it.
            SetVehicleAlarm(HookedTargetVehicle, true)
            SetVehicleAlarmTimeLeft(HookedTargetVehicle, 30000)
            StartVehicleAlarm(HookedTargetVehicle)
        elseif SecureFailCount >= 3 then
            SecureFailCount = 0
            -- v1.5.1: guarded call. v1.5 testing produced "attempt to call a
            -- nil value (global 'TriggerAmbush')" despite ambush.lua being in
            -- the manifest. If it ever happens again the player won't get a
            -- script error — they'll just lose the ambush escalation that
            -- round and a diagnostic shows up in F8.
            if TriggerAmbush then
                TriggerAmbush()
            else
                print('[hobo] ERROR: TriggerAmbush nil — client/ambush.lua did not load')
            end
        end
        return
    end

    -- Re-validate entities after the 8-second skill check window
    if not DoesEntityExist(HookedTowTruck) then
        Notify('Secure', Locale.tow_truck_gone, 'error', 3000)
        IsHookInitiated = false
        return
    end
    if not DoesEntityExist(HookedTargetVehicle) then
        Notify('Secure', Locale.hookup_fail, 'error', 3000)
        IsHookInitiated = false
        return
    end

    local minDim, maxDim = GetModelDimensions(GetEntityModel(HookedTowTruck))
    local towLength = math.abs(maxDim.y - minDim.y)

    -- Per-model lift: clears the towed vehicle's wheels off the ground so it
    -- doesn't fight the truck's traction. Flatbed sits lower; boom wreckers
    -- need a bit more for the bumper.
    local liftByModel = {
        [GetHashKey('towtruck')]       = 1.10,
        [GetHashKey('towtruck2')]      = 1.10,
        [GetHashKey('ram5500wrecker')] = 1.20,
        [GetHashKey('flatbed')]        = 0.95,
    }
    local zLift = liftByModel[GetEntityModel(HookedTowTruck)] or 1.10

    AttachEntityToEntity(
        HookedTargetVehicle, HookedTowTruck,
        0,
        0.0, -(towLength * 0.5 + 1.0), zLift,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true
    )

    -- Kill entity-vs-entity physics fight (must be set both ways)
    SetEntityNoCollisionEntity(HookedTargetVehicle, HookedTowTruck, true)
    SetEntityNoCollisionEntity(HookedTowTruck, HookedTargetVehicle, true)

    -- Lock the towed vehicle's wheels and freeze its body in the truck's frame.
    -- FreezeEntityPosition on an attached child pins it to its parent's transform
    -- and disables the child's physics — it does not drag the parent.
    SetVehicleEngineOn(HookedTargetVehicle, false, true, true)
    SetVehicleUndriveable(HookedTargetVehicle, true)
    SetVehicleHandbrake(HookedTargetVehicle, true)
    FreezeEntityPosition(HookedTargetVehicle, true)

    IsHookedUp    = true
    TargetVehicle = HookedTargetVehicle

    PlaySoundFrontend(-1, 'WAYPOINT_SET', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    Notify('Secure', Locale.hookup_success, 'success', 5000)

    TriggerServerEvent('hobo-recovery:hookedUp',
        ActiveRepoJob.vehicle_plate or ActiveRepoJob.plate)

    local dropZone = GetNearestDropZone(GetEntityCoords(ped))
    if dropZone then
        ActiveDropZone = dropZone
        SetNewWaypoint(dropZone.coords.x, dropZone.coords.y)
        Notify('GPS', Locale.route_to_dropoff:format(dropZone.label), 'info', 5000)
    else
        Notify('GPS', Locale.no_drop_zones, 'warn', 5000)
    end
end, false)

-- ── Proximity HUD (two-phase contextual prompt) ───────────────────────────────
-- v1.4.4 (P3) rewrite. Pre-1.4.4 this loop:
--   • Showed the text UI then immediately Wait(0)'d + hid it inside the for-loop
--     body, causing visible flicker every frame the target was in range
--   • Had no Citizen.Wait at the top of the iteration when ActiveRepoJob was
--     set, so it ran on every frame
--   • Didn't early-exit when it found the target — kept scanning the rest of
--     GetGamePool('CVehicle') (50–200+ entities) for nothing
-- New version: 100 ms tick, show/hide ONCE per state change (no flicker),
-- early-exit on plate match.

Citizen.CreateThread(function()
    local hudShown = false
    while true do
        if ActiveRepoJob and not IsHookedUp and IsOnDuty then
            local ped      = PlayerPedId()
            local myCoords = GetEntityCoords(ped)
            local plate    = (ActiveRepoJob.vehicle_plate or ActiveRepoJob.plate or ''):gsub('%s+', ''):upper()
            local curVeh   = GetVehiclePedIsIn(ped, false)
            local inTruck  = curVeh ~= 0 and TowModelHashes[GetEntityModel(curVeh)]

            local found, prompt, icon
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                local vPlate = GetVehicleNumberPlateText(veh):gsub('%s+', ''):upper()
                if vPlate == plate then
                    -- Only spend the distance + coord cost on the matching plate.
                    local dist = #(myCoords - GetEntityCoords(veh))
                    if dist < Config.HookupRadius * 1.5 then
                        found = true
                        if not IsHookInitiated and inTruck then
                            prompt, icon = 'Back up to vehicle  [/hook]', 'truck-pickup'
                        elseif IsHookInitiated and not inTruck then
                            prompt, icon = 'Stand between vehicles  [/secure]', 'link'
                        else
                            prompt, icon = Locale.hookup_prompt, 'truck-pickup'
                        end
                    end
                    break   -- target plate is unique; stop iterating either way
                end
            end

            if found then
                -- Re-issue showTextUI every tick is fine — ox_lib treats it as
                -- idempotent (same text + same opts = no-op). The win is that
                -- we no longer call hideTextUI() in the same iteration.
                lib.showTextUI(prompt, { position = 'right-center', icon = icon })
                hudShown = true
            elseif hudShown then
                lib.hideTextUI()
                hudShown = false
            end
            Citizen.Wait(100)
        else
            if hudShown then
                lib.hideTextUI()
                hudShown = false
            end
            Citizen.Wait(1000)
        end
    end
end)
