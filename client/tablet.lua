-- ─────────────────────────────────────────────────────────────────────────────
-- client/tablet.lua  —  /towtab DRN-style ALPR tablet (standalone mode only)
--
-- Opens an in-game tablet UI with active repo orders, recent plate scans,
-- and a manual "Check Plate" search. Available only when CAD is not linked;
-- CAD-linked servers get the equivalent view inside the CAD Tow Dashboard.
-- ─────────────────────────────────────────────────────────────────────────────

local function CADBlocked()
    -- Client-side fast check; server still re-validates authoritatively.
    -- Only block when CAD is BOTH enabled AND has credentials present.
    return Config.UseHoboCAD and Config.ServerId and Config.ServerId ~= ''
end

local function OpenTablet()
    TriggerServerEvent('hobo-recovery:tablet:open')
end

local function CloseTablet()
    TabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'tablet:hide' })
end

-- ── /towtab command ──────────────────────────────────────────────────────────

TriggerEvent('chat:addSuggestion', '/towtab',
    'Open the tow operator tablet (standalone servers without HOBO CAD)')

RegisterCommand('towtab', function()
    if not IsOnDuty then
        Notify('Tow Tablet', Locale.tablet_duty or 'Must be on duty to open the tablet.',
            'error', 3000)
        return
    end
    if CADBlocked() then
        Notify('Tow Tablet',
            Locale.tablet_cad_linked or 'CAD is active — open the Tow Dashboard → Repo Cases.',
            'info', 4000)
        return
    end
    if TabletOpen then
        CloseTablet()
        return
    end
    OpenTablet()
end, false)

-- ── Server → client: tablet payload arrived, show the UI ─────────────────────

RegisterNetEvent('hobo-recovery:tablet:open')
AddEventHandler('hobo-recovery:tablet:open', function(snapshot)
    TabletOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action  = 'tablet:show',
        snapshot = snapshot,
        version  = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '',
    })
end)

RegisterNetEvent('hobo-recovery:tablet:denied')
AddEventHandler('hobo-recovery:tablet:denied', function(reason)
    Notify('Tow Tablet', reason or 'Tablet unavailable.', 'error', 4000)
end)

RegisterNetEvent('hobo-recovery:tablet:searchResult')
AddEventHandler('hobo-recovery:tablet:searchResult', function(result)
    SendNUIMessage({ action = 'tablet:searchResult', result = result })
end)

-- v1.4.5: server pushes the current CasePool size whenever it changes
-- (createPoolCase / repoComplete / pool-expiry sweep). Forwards to NUI only
-- when the tablet is open — if it's hidden, the next /towtab open will pull
-- a fresh snapshot anyway.
RegisterNetEvent('hobo-recovery:tablet:poolSizeUpdate')
AddEventHandler('hobo-recovery:tablet:poolSizeUpdate', function(size)
    if TabletOpen then
        SendNUIMessage({ action = 'tablet:poolSizeUpdate', size = size })
    end
end)

-- ── NUI callbacks (web → Lua) ────────────────────────────────────────────────

RegisterNUICallback('tabletClose', function(_, cb)
    CloseTablet()
    cb({})
end)

RegisterNUICallback('tabletSearch', function(data, cb)
    local plate = (data and data.plate) or ''
    if plate == '' then cb({}); return end
    TriggerServerEvent('hobo-recovery:tablet:searchPlate', plate)
    cb({})
end)

RegisterNUICallback('tabletRefresh', function(_, cb)
    if TabletOpen then OpenTablet() end
    cb({})
end)

-- Set GPS — fired from an Active Repo Order's "Set GPS" button. The coords
-- come straight from the snapshot the JS already has, so no server roundtrip.
-- v1.4.2: hard-validate that x and y are real numbers; otherwise a corrupted
-- snapshot row would silently set the waypoint to (0, 0) at sea.
RegisterNUICallback('tabletGps', function(data, cb)
    if type(data) == 'table'
        and type(data.x) == 'number' and type(data.y) == 'number'
        and data.x == data.x and data.y == data.y   -- not NaN
    then
        SetNewWaypoint(data.x + 0.0, data.y + 0.0)
        Notify('GPS', 'Waypoint set.', 'success', 3000)
    else
        Notify('GPS', 'Invalid coordinates.', 'error', 3000)
    end
    cb({})
end)

-- Live refresh: when a marker is added/removed/flipped to in-transit while the
-- tablet is open, pull a fresh snapshot so Active Repo Orders updates without
-- the user clicking refresh. v1.4.3 adds the markerInTransit hook so the new
-- "IN TRANSIT" pill appears on the row the moment a tow operator /secure's it.
AddEventHandler('hobo-recovery:markerAdded', function()
    if TabletOpen then OpenTablet() end
end)
AddEventHandler('hobo-recovery:markerRemoved', function()
    if TabletOpen then OpenTablet() end
end)
AddEventHandler('hobo-recovery:markerInTransit', function()
    if TabletOpen then OpenTablet() end
end)

-- v1.4.4: keep snapshot-driven status-bar fields (Hot-List Count, active-order
-- ages, repos-completed) live while the tablet is open. The markerAdded /
-- markerRemoved / markerInTransit hooks above cover operator-driven state
-- changes, but spawner-generated CasePool churn (ScheduleEmptySpotRetry,
-- ScheduleSceneryExpiry, RespawnAmbientAtSpot) doesn't broadcast any marker
-- event — without this periodic refresh, the Hot-List Count could freeze at
-- whatever poolSize was captured at the moment /towtab opened (often 0 if
-- the tablet opens within the spawner's 3 s startup wait). 10 s cadence is
-- loose enough not to spam the server.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(10000)
        if TabletOpen then OpenTablet() end
    end
end)
