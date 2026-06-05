-- ─────────────────────────────────────────────────────────────────────────────
-- client/dropoff.lua  —  Drop-off zone detection, blips, CompleteRepo
-- ─────────────────────────────────────────────────────────────────────────────

function GetNearestDropZone(coords)
    if not Config.DropOffZones or #Config.DropOffZones == 0 then return nil end
    local nearest, nearestDist = nil, math.huge
    for _, zone in ipairs(Config.DropOffZones) do
        local dist = #(coords - zone.coords)
        if dist < nearestDist then
            nearest     = zone
            nearestDist = dist
        end
    end
    return nearest
end

-- ── Arrival detection thread ──────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        if IsHookedUp and ActiveDropZone and ActiveRepoJob and IsOnDuty then
            local dist = #(GetEntityCoords(PlayerPedId()) - ActiveDropZone.coords)
            if dist < ActiveDropZone.radius then
                CompleteRepo()
            end
            Citizen.Wait(500)
        else
            Citizen.Wait(1000)
        end
    end
end)

-- ── /detachvehicle command (manual completion at drop-off) ────────────────────

TriggerEvent('chat:addSuggestion', '/detachvehicle', 'Detach the towed vehicle and complete the repossession')

RegisterCommand('detachvehicle', function()
    if not IsHookedUp or not ActiveRepoJob then
        Notify('Repo', Locale.no_active_repo, 'error', 3000)
        return
    end

    if ActiveDropZone then
        local dist = #(GetEntityCoords(PlayerPedId()) - ActiveDropZone.coords)
        if dist > ActiveDropZone.radius then
            Notify('Drop-Off', ('Must be at drop-off zone: %s'):format(ActiveDropZone.label), 'error', 4000)
            return
        end
    end

    CompleteRepo()
end, false)

-- ── Drop-off blips ────────────────────────────────────────────────────────────

local DropOffBlips = {}

Citizen.CreateThread(function()
    for _, zone in ipairs(Config.DropOffZones or {}) do
        local blip = AddBlipForCoord(zone.coords.x, zone.coords.y, zone.coords.z)
        SetBlipSprite(blip, 68)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, 0.8)
        SetBlipColour(blip, 5)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(zone.label)
        EndTextCommandSetBlipName(blip)
        DropOffBlips[#DropOffBlips + 1] = blip
    end
    while true do Citizen.Wait(60000) end
end)

AddEventHandler('onResourceStop', function(name)
    if GetCurrentResourceName() ~= name then return end
    for _, blip in ipairs(DropOffBlips) do RemoveBlip(blip) end
end)

-- ── CompleteRepo ──────────────────────────────────────────────────────────────

function CompleteRepo()
    if not ActiveRepoJob then return end

    local plate    = ActiveRepoJob.vehicle_plate or ActiveRepoJob.plate or ''
    local zoneName = ActiveDropZone and ActiveDropZone.label or 'Impound'

    if TargetVehicle and DoesEntityExist(TargetVehicle) then
        DetachEntity(TargetVehicle, true, true)
        FreezeEntityPosition(TargetVehicle, true)
        -- v1.4.12: delete instead of unfreeze. Pre-v1.4.12 the vehicle was
        -- left at the impound forever — and the unfreeze occasionally left
        -- it floating in the air over uneven ground. 1.5 s freeze gives the
        -- player a moment to see the detach settle, then it vanishes cleanly.
        local vehToDelete = TargetVehicle
        Citizen.SetTimeout(1500, function()
            if DoesEntityExist(vehToDelete) then
                DeleteEntity(vehToDelete)
            end
        end)
    end

    local coords = GetEntityCoords(PlayerPedId())
    local streetHash, _ = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local streetName    = GetStreetNameFromHashKey(streetHash) or zoneName

    TriggerServerEvent('hobo-recovery:repoComplete', plate, zoneName, streetName, GetPlayerName(PlayerId()))

    lib.progressBar({
        duration      = 3000,
        label         = 'Completing repo paperwork...',
        useWhileDead  = false,
        canCancel     = false,
        disable       = { move = true, car = false, combat = true },
        anim          = { dict = 'missfam4', clip = 'base' },
    })
end
