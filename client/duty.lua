-- ─────────────────────────────────────────────────────────────────────────────
-- client/duty.lua  —  v1.6 Impound duty zones
--
-- Replaces the /ondutytow and /ondutycam commands with physical press-E zones
-- at each impound (see Config.Impounds):
--   • clockIn  — toggle on/off duty. Discord-gated (server/duty.lua decides).
--   • towMenu  — opens a context menu of tow trucks; selecting one spawns it.
--   • camMenu  — opens a context menu of camera cars; selecting one spawns it.
--
-- The operator role follows the vehicle: spawning a tow truck makes you a tow
-- operator, a camera car makes you a camera operator (SetOperatorRole below).
-- Clock-in alone marks you on-duty with no role.
--
-- Reuses GoOnDuty / GoOffDuty (client/main.lua, promoted to globals in v1.6).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── [E] text-prompt helpers (pattern from hobo-fuel/client/facility.lua) ──────
local shownText
local function showPrompt(text)
    if shownText ~= text then
        shownText = text
        lib.showTextUI(text, { position = 'left-center' })
    end
end
local function hidePrompt()
    if shownText then
        shownText = nil
        lib.hideTextUI()
    end
end

-- ── Operator role (set when a vehicle is spawned, not at clock-in) ────────────
local autoPopRunning = false

local function SetOperatorRole(role)
    OperatorRole = role
    -- mirror to the server (server/main.lua hobo-recovery:setOperatorRole)
    TriggerServerEvent('hobo-recovery:setOperatorRole', role)

    if role == 'camera' then
        Notify('HOBO Auto-Recovery', Locale.duty_role_camera, 'success', 4000, { position = 'tc' })
    elseif role == 'tow' then
        Notify('HOBO Auto-Recovery', Locale.duty_role_tow, 'success', 4000, { position = 'tc' })
    end

    -- Refresh map markers for the new role (server filters by role).
    if IsOnDuty then
        TriggerServerEvent('hobo-recovery:replayMarkers')
    end

    -- Tow operators seed the NPC pool when Config.AutoPopulate is enabled.
    -- This used to live in GoOnDuty; it moved here because the role is no
    -- longer known at clock-in time. The flag stops a second tow-truck spawn
    -- from starting a duplicate seed thread.
    if role == 'tow' and Config.AutoPopulate and not autoPopRunning then
        autoPopRunning = true
        Citizen.CreateThread(function()
            Citizen.Wait(2500)
            while IsOnDuty and OperatorRole == 'tow' do
                if SendNpcVehicleList then SendNpcVehicleList() end
                Citizen.Wait(45000)
            end
            autoPopRunning = false
        end)
    end
end

-- ── Vehicle spawn menu (ox_lib context menu) ─────────────────────────────────
local function openVehMenu(kind, impoundIndex)
    local list  = (kind == 'tow') and Config.TowVehicleModels or Config.CameraCarModels
    local title = (kind == 'tow') and Locale.duty_menu_tow_title or Locale.duty_menu_cam_title
    local icon  = (kind == 'tow') and 'truck-pickup' or 'video'

    local options = {}
    for _, entry in ipairs(list or {}) do
        options[#options + 1] = {
            title    = entry.label or entry.model,
            icon     = icon,
            onSelect = function()
                TriggerServerEvent('hobo-recovery:spawnDutyVehicle', kind, entry.model, impoundIndex)
            end,
        }
    end

    lib.registerContext({
        id      = 'hobo_recovery_veh_menu',
        title   = title,
        options = options,
    })
    lib.showContext('hobo_recovery_veh_menu')
end

-- ── Interaction thread — clock-in + spawn-menu zones ─────────────────────────
Citizen.CreateThread(function()
    local RENDER_DIST = 15.0

    while true do
        local sleep  = 1000
        local ped    = PlayerPedId()
        local pc     = GetEntityCoords(ped)
        local onFoot = not IsPedInAnyVehicle(ped, false)
        local zoneRadius = Config.DutyZoneRadius or 2.5
        local prompt, action

        for impoundIndex, imp in ipairs(Config.Impounds or {}) do
            local zones = {
                { coords = imp.clockIn, kind = 'clockIn' },
                { coords = imp.towMenu, kind = 'towMenu' },
                { coords = imp.camMenu, kind = 'camMenu' },
            }
            for _, z in ipairs(zones) do
                if z.coords then
                    local d = #(pc - z.coords)
                    if d < RENDER_DIST then
                        sleep = 0
                        DrawMarker(1,
                            z.coords.x, z.coords.y, z.coords.z - 1.0,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            1.5, 1.5, 1.0,
                            60, 140, 220, 100,
                            false, false, 2, false, nil, nil, false)

                        if onFoot and d < zoneRadius then
                            if z.kind == 'clockIn' then
                                prompt = IsOnDuty and Locale.duty_prompt_clock_off
                                                  or  Locale.duty_prompt_clock_on
                                action = function()
                                    if IsOnDuty then
                                        GoOffDuty()
                                    else
                                        TriggerServerEvent('hobo-recovery:requestClockOn')
                                    end
                                end
                            elseif z.kind == 'towMenu' then
                                prompt = Locale.duty_prompt_tow
                                action = function()
                                    if not IsOnDuty then
                                        Notify('HOBO Auto-Recovery', Locale.duty_need_clock_in,
                                            'error', 4000, { position = 'tc' })
                                    else
                                        openVehMenu('tow', impoundIndex)
                                    end
                                end
                            elseif z.kind == 'camMenu' then
                                prompt = Locale.duty_prompt_cam
                                action = function()
                                    if not IsOnDuty then
                                        Notify('HOBO Auto-Recovery', Locale.duty_need_clock_in,
                                            'error', 4000, { position = 'tc' })
                                    else
                                        openVehMenu('camera', impoundIndex)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if prompt then
            showPrompt(prompt)
            if IsControlJustPressed(0, 38) then   -- 38 = E
                hidePrompt()
                if action then action() end
            end
        else
            hidePrompt()
        end

        Citizen.Wait(sleep)
    end
end)

-- ── Impound map blips ────────────────────────────────────────────────────────
Citizen.CreateThread(function()
    for _, imp in ipairs(Config.Impounds or {}) do
        local b = imp.blip
        if b and imp.clockIn then
            local blip = AddBlipForCoord(imp.clockIn.x, imp.clockIn.y, imp.clockIn.z)
            SetBlipSprite(blip, b.sprite or 68)
            SetBlipColour(blip, b.color or 5)
            SetBlipScale(blip, b.scale or 0.8)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(imp.label or 'HOBO Impound')
            EndTextCommandSetBlipName(blip)
        end
    end
end)

-- ── Server replies ───────────────────────────────────────────────────────────

-- Discord check passed — clock on with no role (role is set on vehicle spawn).
RegisterNetEvent('hobo-recovery:clockOnApproved', function()
    if IsOnDuty then return end
    GoOnDuty(nil)
end)

-- Discord check failed.
RegisterNetEvent('hobo-recovery:clockOnDenied', function()
    Notify('HOBO Auto-Recovery', Locale.duty_denied_role, 'error', 5000, { position = 'tc' })
end)

-- A vehicle was already on the spawn pad — the operator must move it.
RegisterNetEvent('hobo-recovery:dutyVehicleBlocked', function()
    Notify('HOBO Auto-Recovery', Locale.duty_pad_blocked, 'error', 5000, { position = 'tc' })
end)

-- The server spawned the requested vehicle — warp the player in and set role.
RegisterNetEvent('hobo-recovery:dutyVehicleSpawned', function(netId, kind)
    Citizen.CreateThread(function()
        local veh
        local tries = 0
        while tries < 120 do
            veh = NetworkGetEntityFromNetworkId(netId)
            if veh and veh ~= 0 and DoesEntityExist(veh) then break end
            Citizen.Wait(50)
            tries = tries + 1
        end
        if not veh or veh == 0 or not DoesEntityExist(veh) then return end

        -- Warp in first so this client takes ownership, then the entity
        -- natives below actually apply.
        SetPedIntoVehicle(PlayerPedId(), veh, -1)
        SetVehicleOnGroundProperly(veh)
        SetVehicleEngineOn(veh, true, true, false)
        SetOperatorRole(kind)
    end)
end)
