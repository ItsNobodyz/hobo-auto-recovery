-- ─────────────────────────────────────────────────────────────────────────────
-- client/scanner.lua  —  Proximity plate scanner with NUI overlay
-- States: off → scan → cursor → scan (toggle) | hold F6 3s → off
-- ─────────────────────────────────────────────────────────────────────────────

local ScannerState   = 'off'   -- 'off' | 'scan' | 'cursor'
local ScanLoopActive = false
local LastScanTime   = 0
local LockOnPlate    = nil     -- plate currently locked (repo alert / hook initiated)
local HoldStart      = nil     -- GetGameTimer() when F6 pressed in scan state

-- Per-plate buffer of which camera-side last saw it. Read by repoAlert /
-- cameraAlert handlers to pick the matching audio callout. Pruned both
-- inside the scan loop AND by a periodic background thread (v1.4.2) so it
-- can't grow unbounded while the operator is off duty.
LastScanSides = LastScanSides or {}   -- [plate] = { side = 'FRONT-LEFT', at = ms }

-- Background prune: ticks every 30 s independent of scan state.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30000)
        local now = GetGameTimer()
        for plate, entry in pairs(LastScanSides) do
            if now - (entry.at or 0) > 10000 then LastScanSides[plate] = nil end
        end
    end
end)

local function normPlate(p)
    return (p or ''):gsub('%s+', ''):upper()
end

-- v1.4.2: mouse-only alert prompt replacing lib.alertDialog.
-- ox_lib's alertDialog grabs full keyboard focus, which blocks WASD and
-- crashes the player when an alert pops mid-drive. This helper uses
-- SetNuiFocusKeepInput so the cursor appears but all game inputs keep
-- firing. Returns 'confirm' | 'cancel'.
local PromptResponses = {}

function PromptAlert(opts)
    local token = tostring(GetGameTimer()) .. ':' .. tostring(math.random(1, 1000000))
    PromptResponses[token] = false   -- false = pending

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true)
    SendNUIMessage({
        action       = 'tablet:prompt',
        token        = token,
        title        = opts.title        or 'Plate hit',
        fields       = opts.fields,
        content      = opts.content,
        confirmLabel = opts.confirmLabel or 'Confirm',
        cancelLabel  = opts.cancelLabel  or 'Cancel',
    })

    -- Block-until-answered with a safety timeout so we never strand the
    -- player with focus grabbed if the NUI side hangs.
    local deadline = GetGameTimer() + (opts.timeoutMs or 30000)
    while PromptResponses[token] == false and GetGameTimer() < deadline do
        Citizen.Wait(50)
    end

    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)

    local result = PromptResponses[token]
    PromptResponses[token] = nil
    -- If we hit the deadline, treat as cancel and dismiss the overlay.
    if result == false or result == nil then
        SendNUIMessage({ action = 'tablet:promptCancel' })
        return 'cancel'
    end
    return result
end

RegisterNUICallback('tabletPromptResult', function(data, cb)
    if data and data.token and PromptResponses[data.token] ~= nil then
        PromptResponses[data.token] = data.choice or 'cancel'
    end
    cb({})
end)

-- Classify a target's position relative to a reference entity (truck or ped)
-- into one of FRONT-LEFT / FRONT-RIGHT / REAR-LEFT / REAR-RIGHT.
function ClassifyRelativeSide(refEntity, targetCoords)
    local refCoords  = GetEntityCoords(refEntity)
    local refForward = GetEntityForwardVector(refEntity)
    local refRight   = vector3(refForward.y, -refForward.x, 0.0)
    local delta      = targetCoords - refCoords
    local longitudinal = delta.x * refForward.x + delta.y * refForward.y
    local lateral      = delta.x * refRight.x   + delta.y * refRight.y
    local fb = longitudinal >= 0 and 'FRONT' or 'REAR'
    local lr = lateral      >= 0 and 'RIGHT' or 'LEFT'
    return fb .. '-' .. lr
end

-- ── NUI callbacks ────────────────────────────────────────────────────────────

RegisterNUICallback('setFocus', function(data, cb)
    SetNuiFocus(data.active, data.active)
    cb({})
end)

-- Called by app.js when F6 short-pressed while cursor mode is active
RegisterNUICallback('cursorToggle', function(_, cb)
    ScannerState = 'scan'
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'scanMode' })
    Notify('📡 Scanner', 'Cursor locked.', 'info', 2000)
    cb({})
end)

-- Called by app.js when F6 held 3s while cursor mode is active
RegisterNUICallback('scannerOff', function(_, cb)
    ScannerState = 'off'
    LockOnPlate  = nil
    HoldStart    = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'hide' })
    Notify('📡 Scanner', Locale.scanner_off, 'info', 2000)
    cb({})
end)

-- ── Keybind registration ──────────────────────────────────────────────────────
-- +/- prefix enables keydown (press) / keyup (release) pair for hold detection.

RegisterKeyMapping('+scanner_toggle', 'Toggle Plate Scanner', 'keyboard', Config.ScannerKeybind or 'F6')

RegisterCommand('+scanner_toggle', function()   -- key DOWN
    if ScannerState == 'off' then
        if not IsOnDuty then
            Notify('Scanner', Locale.scanner_duty, 'warn', 3000)
            return
        end
        ScannerState = 'scan'
        SendNUIMessage({
            action  = 'show',
            keybind = Config.ScannerKeybind or 'F6',
            version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '',
        })
        Notify('📡 Scanner', Locale.scanner_on, 'info', 2000)
        if not ScanLoopActive then
            StartScanLoop()
        end
    elseif ScannerState == 'scan' then
        HoldStart = GetGameTimer()   -- will decide tap vs hold on key-up
    end
    -- 'cursor': NUI owns keyboard; +scanner_toggle does NOT fire in this state
end, false)

RegisterCommand('-scanner_toggle', function()   -- key UP
    if HoldStart == nil then return end
    local held = GetGameTimer() - HoldStart
    HoldStart = nil

    if held >= 3000 then
        -- Long press → turn off scanner
        ScannerState = 'off'
        LockOnPlate  = nil
        SendNUIMessage({ action = 'hide' })
        Notify('📡 Scanner', Locale.scanner_off, 'info', 2000)
    elseif ScannerState == 'scan' then
        -- Short tap → enter cursor mode
        ScannerState = 'cursor'
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'cursorMode' })
        Notify('📡 Scanner', 'Cursor unlocked. [F6] to lock.', 'info', 2000)
    end
end, false)

-- ── Scan loop ─────────────────────────────────────────────────────────────────

function StartScanLoop()
    ScanLoopActive = true
    Citizen.CreateThread(function()
        while IsOnDuty do
            if ScannerState == 'off' or ScannerState == 'cursor' then
                -- Idle / cursor mode — no scanning
                Citizen.Wait(300)

            elseif IsHookInitiated then
                -- After /hook: freeze display on locked plate only
                local plate = LockOnPlate or normPlate(
                    (ActiveRepoJob and (ActiveRepoJob.vehicle_plate or ActiveRepoJob.plate)) or ''
                )
                if plate ~= '' then
                    SendNUIMessage({ action = 'updatePlates', plates = {
                        { plate = plate, status = 'lockon' },
                    }})
                end
                Citizen.Wait(500)

            else
                -- Normal scan mode ('scan')
                local now      = GetGameTimer()
                local ped      = PlayerPedId()
                local myVeh    = GetVehiclePedIsIn(ped, false)
                local myCoords = GetEntityCoords(ped)

                -- v1.4.3: on-foot gate. The scanner only operates when the player
                -- is sitting in the driver seat. Off duty isn't toggled — they
                -- just can't scan plates while out. Panel hides via NUI so the
                -- on-screen UI matches the live behavior.
                if myVeh == 0 or GetPedInVehicleSeat(myVeh, -1) ~= ped then
                    if ScanPanelVisible ~= false then
                        SendNUIMessage({ action = 'scanner:hide' })
                        ScanPanelVisible = false
                    end
                    Citizen.Wait(500)   -- slow poll while on foot
                    goto scan_continue
                end
                if ScanPanelVisible == false then
                    SendNUIMessage({ action = 'scanner:show' })
                    ScanPanelVisible = true
                end

                local found = {}
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if veh ~= myVeh and DoesEntityExist(veh) then
                        -- v1.4.2: skip vehicles with a driver (NPC or player) so
                        -- only truly parked vehicles can be marked for repo.
                        -- Matches the parked-check in SendNpcVehicleList.
                        local driver = GetPedInVehicleSeat(veh, -1)
                        if driver == 0 or not DoesEntityExist(driver) then
                            local plate = normPlate(GetVehicleNumberPlateText(veh))
                            -- v1.4.3: skip plates of any vehicle the operator
                            -- has driven this session — see OwnPlates tracker
                            -- in client/main.lua. Without this, an operator who
                            -- steps out of their tow truck and the truck has
                            -- a forced plate gets their own truck flagged.
                            if plate ~= '' and not (OwnPlates and OwnPlates[plate]) then
                                -- v1.4.4 (P1): cache vCoords once. Previously
                                -- GetEntityCoords(veh) ran here, again in the
                                -- metadata loop below, AND again on dispatch.
                                local vCoords = GetEntityCoords(veh)
                                local d = #(myCoords - vCoords)
                                if d <= Config.ScanRadius then
                                    found[#found + 1] = {
                                        plate   = plate,
                                        dist    = d,
                                        veh     = veh,
                                        vCoords = vCoords,
                                    }
                                end
                            end
                        end
                    end
                end

                table.sort(found, function(a, b) return a.dist < b.dist end)
                -- v1.4.5: per-tick cap REMOVED from `found`. Pre-1.4.5 this
                -- truncated to the top 3 closest, which then propagated to
                -- BOTH the 2-row scanner overlay AND the tablet feed — so
                -- vehicles #4+ in radius never reached the tablet's scan log
                -- at all. The overlay still caps at top 2 (panel design); the
                -- tablet now sees every nearby plate so the permanent per-
                -- plate log can actually log them.

                -- Compute the camera-side for each detected plate and stash it
                -- so the alert handlers can pick the right audio callout when
                -- the server responds. Also capture plate style, street, postal,
                -- and operator name for the tablet's scan-history row.
                local refEntity = (myVeh ~= 0) and myVeh or ped
                local driver    = GetPlayerName(PlayerId()) or 'Unknown'
                for _, f in ipairs(found) do
                    -- v1.4.4 (P1): reuse the vCoords cached during proximity
                    -- check — no second GetEntityCoords call here.
                    f.side             = ClassifyRelativeSide(refEntity, f.vCoords)
                    f.plateIndex       = GetVehicleNumberPlateTextIndex(f.veh) or 0
                    f.street, f.postal = GetScanLocation(f.vCoords)
                    f.driver           = driver
                    f.coords           = f.vCoords
                    LastScanSides[f.plate] = {
                        side       = f.side,
                        plateIndex = f.plateIndex,
                        street     = f.street,
                        postal     = f.postal,
                        driver     = f.driver,
                        coords     = f.vCoords,
                        at         = now,
                    }
                end

                -- v1.4.4 (P2): in-tick LastScanSides prune removed. The
                -- background thread at the top of this file (Citizen.Wait
                -- 30 s) handles pruning for both on-duty AND off-duty
                -- operators, which is why it was added in v1.4.2 in the
                -- first place. Doing it again here every 100 ms was pure
                -- redundancy on the hot path.

                -- Duty grace period: gate server reporting, not visual rendering.
                local graceMs     = Config.DutyGracePeriod or 30000
                local gracePassed = DutyStartTime > 0 and (now - DutyStartTime) >= graceMs
                local graceLeft   = math.max(0, math.ceil((graceMs - (now - DutyStartTime)) / 1000))

                -- v1.4.5: scanner overlay panel has 2 rows by design. Cap
                -- here (instead of upstream) so the tablet feed below can
                -- still get every nearby plate.
                local plateData = {}
                for i = 1, math.min(2, #found) do
                    local f = found[i]
                    plateData[i] = {
                        plate  = f.plate,
                        status = (f.plate == LockOnPlate) and 'lockon'
                              or (not gracePassed and 'calibrating')
                              or  'scanning',
                    }
                end
                SendNUIMessage({
                    action      = 'updatePlates',
                    plates      = plateData,
                    gracePeriod = not gracePassed,
                    graceLeft   = graceLeft,
                })

                -- v1.4.6: TabletOpen gate removed. Scans always pump to NUI so
                -- state.scans accumulates continuously while the operator is on
                -- duty — opening /towtab later shows everything seen since duty
                -- start instead of only what was scanned with the tablet open.
                -- JS-side renderScanTable() is skipped while the tablet element
                -- is hidden (cheap DOM optimization); showTablet flushes the
                -- accumulated rows on open. Grace period still applies to the
                -- server checkPlate call below, not the tablet log.
                if #found > 0 then
                    local scans = {}
                    for i, f in ipairs(found) do
                        scans[i] = {
                            plate      = f.plate,
                            plateIndex = f.plateIndex,
                            side       = f.side,
                            street     = f.street,
                            postal     = f.postal,
                            driver     = f.driver,
                            at         = now,
                        }
                    end
                    SendNUIMessage({ action = 'tablet:appendScan', scans = scans })
                end

                if now - LastScanTime >= Config.ScanCooldown and #found > 0 and gracePassed then
                    LastScanTime = now
                    for _, f in ipairs(found) do
                        -- v1.4.4 (P1): reuse cached vCoords.
                        TriggerServerEvent('hobo-recovery:checkPlate', f.plate, f.vCoords)
                    end
                end

                Citizen.Wait(100)
                ::scan_continue::
            end
        end

        -- Duty ended — release NUI focus if cursor mode was active
        if ScannerState == 'cursor' then
            SetNuiFocus(false, false)
        end
        HoldStart    = nil
        ScannerState = 'off'
        LockOnPlate  = nil
        ScanLoopActive = false
        SendNUIMessage({ action = 'hide' })
    end)
end

-- ── Hook-initiated: lock scanner display onto repo plate ──────────────────────

AddEventHandler('hobo-recovery:hookInitiated', function()
    if not ActiveRepoJob then return end
    local plate = normPlate(ActiveRepoJob.vehicle_plate or ActiveRepoJob.plate or '')
    if plate == '' then return end
    LockOnPlate = plate
    SendNUIMessage({ action = 'updatePlates', plates = {
        { plate = plate, status = 'lockon' },
    }})
end)

-- ── Repo alert handler ────────────────────────────────────────────────────────

RegisterNetEvent('hobo-recovery:repoAlert', function(caseData)
    if not IsOnDuty then return end
    if ActiveRepoJob then return end

    local plate = normPlate(caseData.plate)

    LockOnPlate = plate
    SendNUIMessage({ action = 'updatePlates', plates = {
        { plate = plate, status = 'lockon' },
    }})

    -- Side-specific audio callout for the camera that scored the hit
    local sideEntry = LastScanSides and LastScanSides[plate]
    local side      = sideEntry and sideEntry.side or 'FRONT-RIGHT'
    SendNUIMessage({ action = 'tablet:hitCallout', side = side, plate = plate })

    -- Always feed the tablet's hit-list when an alert fires — the operator can
    -- look it up later whether or not they accept the repo. Server-side
    -- ActiveCases[src] gate still ensures only one accept-flow at a time.
    SendNUIMessage({
        action = 'tablet:appendHit',
        hit    = {
            plate      = plate,
            plateIndex = sideEntry and sideEntry.plateIndex or 0,
            side       = side,
            street     = sideEntry and sideEntry.street or '',
            postal     = sideEntry and sideEntry.postal or '',
            driver     = sideEntry and sideEntry.driver or '',
            case       = caseData,
            at         = GetGameTimer(),
        },
    })

    PlaySoundFrontend(-1, 'PURCHASE', 'HUD_FREEMODE_SOUNDSET', true)

    Notify(
        '🔒 ' .. Locale.repo_alert_title,
        ('Plate: %s  |  %s  |  $%d reward'):format(
            plate,
            caseData.ownerName or 'Unknown Owner',
            caseData.rewardAmount or Config.DefaultReward
        ),
        'warn', 7000
    )

    local vehicleDesc = table.concat({
        caseData.vehicleColor or '',
        caseData.vehicleMake  or '',
        caseData.vehicleModel or '',
    }, ' '):match('^%s*(.-)%s*$')

    -- v1.4.2: PromptAlert keeps WASD alive so the operator doesn't crash mid-drive.
    local result = PromptAlert({
        title  = '🔒 Repo Confirmed — ' .. plate,
        fields = {
            { label = 'Plate',   value = plate },
            { label = 'Owner',   value = caseData.ownerName or 'Unknown' },
            { label = 'Vehicle', value = vehicleDesc ~= '' and vehicleDesc or 'Unknown' },
            { label = 'Reason',  value = caseData.reason or 'Repossession order' },
            { label = 'Reward',  value = ('$%d'):format(caseData.rewardAmount or Config.DefaultReward) },
        },
        confirmLabel = 'Accept Repo',
        cancelLabel  = 'Decline',
    })

    if result ~= 'confirm' then
        LockOnPlate = nil
        SendNUIMessage({ action = 'updatePlates', plates = {} })
        -- Critical: clear server-side ActiveCases[src] so future scans aren't ignored.
        -- Without this, declining one alert silently bricks all future repo offers.
        TriggerServerEvent('hobo-recovery:cancelRepo')
        Notify('Repo', Locale.repo_declined, 'info', 3000)
        return
    end

    ActiveRepoJob = caseData
    TriggerServerEvent('hobo-recovery:acceptRepo', plate)
    Notify('Repo', Locale.repo_accepted, 'success', 4000)

    if caseData.vehicleCoords then
        SetNewWaypoint(caseData.vehicleCoords.x, caseData.vehicleCoords.y)
        Notify('GPS', Locale.route_to_vehicle, 'info', 3000)
    end
end)

-- ── Camera-car alert handler ─────────────────────────────────────────────────
-- Fired by the server when a camera car (OperatorRole == 'camera') scans a
-- plate that's up for repo. Offers to drop a map marker that all on-duty tow
-- operators can see; no hookup flow, no ActiveRepoJob is set.

RegisterNetEvent('hobo-recovery:cameraAlert', function(caseData, coords)
    if not IsOnDuty then return end
    if OperatorRole ~= 'camera' then return end
    if not caseData then return end

    local plate = normPlate(caseData.plate or caseData.vehicle_plate or '')
    if plate == '' then return end

    -- Audio callout for the side that scored the hit
    local sideEntry  = LastScanSides and LastScanSides[plate]
    local side       = sideEntry and sideEntry.side or 'FRONT-RIGHT'
    local plateIndex = sideEntry and sideEntry.plateIndex or 0
    local street     = sideEntry and sideEntry.street or ''
    local postal     = sideEntry and sideEntry.postal or ''
    SendNUIMessage({ action = 'tablet:hitCallout', side = side, plate = plate })

    -- Always feed the tablet hit list regardless of Mark/Ignore choice.
    SendNUIMessage({
        action = 'tablet:appendHit',
        hit    = {
            plate      = plate,
            plateIndex = plateIndex,
            side       = side,
            street     = street,
            postal     = postal,
            driver     = sideEntry and sideEntry.driver or '',
            case       = caseData,
            at         = GetGameTimer(),
        },
    })

    PlaySoundFrontend(-1, 'ATM_WINDOW', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)

    Notify('📷 Camera Hit',
        ('Plate: %s  |  %s  |  %s'):format(plate, side, caseData.ownerName or 'Unknown'),
        'warn', 6000)

    -- v1.4.15: auto-mark — was a PromptAlert with "Mark on Map" / "Ignore"
    -- buttons (which the operator had to click for every hit). Beta feedback
    -- was that camera operators want the marker dropped automatically the
    -- moment the scanner hits a repo plate. The server's placeMarker handler
    -- is the same as the old Confirm path; we just call it directly now.
    -- The audio callout + tablet hit row + 📷 Camera Hit notification above
    -- already give the operator visual/audio feedback that a hit happened.
    if coords then
        TriggerServerEvent('hobo-recovery:placeMarker',
            plate, coords, street, postal, plateIndex, caseData)
        Notify('📷 Marker',
            ('Auto-marked %s — tow trucks alerted.'):format(plate),
            'success', 4000)
    end
end)
