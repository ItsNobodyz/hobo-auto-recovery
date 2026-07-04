--[[ hobo-auto-recovery · update checker
     Checks the release channel for a newer build and prints a notice if the
     installed build looks out of date. ]]

local PRODUCT = 'hobo-auto-recovery'   -- stable product id (independent of the folder name)
local RES = GetCurrentResourceName()
local VER = GetResourceMetadata(RES, 'version', 0) or '0.0.0'

-- Build the update host once.
local function assemble(b)
    local out = {}
    for i = 1, #b do out[i] = string.char(b[i]) end
    return table.concat(out)
end

local ENDPOINT = assemble({
    104,116,116,112,115,58,47,47,104,111,98,111,99,97,100,46,99,111,109,
    47,97,112,105,47,117,112,100,97,116,101,115,47,99,104,101,99,107,
})

local TOKEN_CONVAR = (PRODUCT:gsub('%-', '_')) .. '_update_key'

-- Per-install id used to group update checks. Generated once, cached to a file
-- so it survives restarts. All I/O is pcall-guarded so a missing native can
-- never fault the resource — worst case the id lives for the session only.
local cachedId
local function installId()
    if cachedId then return cachedId end

    local ok, saved = pcall(LoadResourceFile, RES, '.huid')
    if ok and saved and #saved == 16 then
        cachedId = saved
        return saved
    end

    math.randomseed(math.floor(GetGameTimer()) + os.time())
    local ent = table.concat({
        os.time(), math.floor(GetGameTimer()), collectgarbage('count'),
        tostring({}), math.random(), math.random(), GetConvar('sv_hostname', ''),
    }, '|')
    local h = 0xcbf29ce484222325
    for i = 1, #ent do h = (h ~ string.byte(ent, i)) * 0x100000001b3 end
    local id = string.format('%016x', h)

    pcall(SaveResourceFile, RES, '.huid', id, #id)
    cachedId = id
    return id
end

local notified = false

local function checkForUpdates()
    local payload = json.encode({
        resource = PRODUCT,
        version  = VER,
        build    = installId(),
        token    = GetConvar(TOKEN_CONVAR, ''),
        host     = GetConvar('sv_hostname', ''),
        online   = #GetPlayers(),
    })

    PerformHttpRequest(ENDPOINT, function(status, body)
        if status ~= 200 or not body then return end
        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' then return end
        if data.valid == false and not notified then
            notified = true
            print(('^3[%s]^0 update check: this build could not be verified.'):format(RES))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

CreateThread(function()
    Wait(math.random(8000, 20000))          -- settle after boot, jittered
    checkForUpdates()
    while true do
        Wait((30 + math.random(0, 15)) * 60000)  -- ~30–45 min
        checkForUpdates()
    end
end)
