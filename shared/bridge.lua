-- Framework detection and payment bridge.
-- Detects ESX or QBCore at resource start; falls back to a custom event
-- so servers without either framework can hook in their own economy.

Bridge = {}

local Framework     = nil
local ESX           = nil
local QBCore        = nil

-- Detect framework once on server start.
-- Client-side this table is available but PayPlayer is server-only.
if IsDuplicityVersion() then
    Citizen.CreateThread(function()
        if GetResourceState('es_extended') == 'started' then
            Framework = 'ESX'
            TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
            if not ESX then
                local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
                if ok then ESX = obj end
            end
        elseif GetResourceState('qb-core') == 'started' then
            Framework = 'QBCore'
            local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok then QBCore = obj end
        end

        if Framework then
            print(('[HOBO Auto-Recovery] Framework detected: %s'):format(Framework))
        else
            print('[HOBO Auto-Recovery] No framework detected — using standalone payout events')
        end
    end)
end

-- Pay a player on repo completion.
-- @param playerId  FiveM player source
-- @param amount    Dollar amount to pay
-- @param rewardType  'bank' or 'cash'
function Bridge.PayPlayer(playerId, amount, rewardType)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    if Framework == 'ESX' and ESX then
        local xPlayer = ESX.GetPlayerFromId(playerId)
        if xPlayer then
            if rewardType == 'bank' then
                xPlayer.addAccountMoney('bank', amount)
            else
                xPlayer.addMoney(amount)
            end
            return
        end
    end

    if Framework == 'QBCore' and QBCore then
        local Player = QBCore.Functions.GetPlayer(playerId)
        if Player then
            if rewardType == 'bank' then
                Player.Functions.AddMoney('bank', amount)
            else
                Player.Functions.AddMoney('cash', amount)
            end
            return
        end
    end

    -- Standalone fallback: fire a client event that server owners can hook
    TriggerClientEvent('hobo-recovery:receivePayout', playerId, amount, rewardType)
end

-- Debug helper — available on both sides
function Bridge.Log(msg)
    if Config.Debug then
        print(('[HOBO Auto-Recovery] %s'):format(msg))
    end
end
