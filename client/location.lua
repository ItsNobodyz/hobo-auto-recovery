-- ─────────────────────────────────────────────────────────────────────────────
-- client/location.lua  —  Street + postal resolution for scan events
--
-- Pattern reused from fivem-hobocad-script/client.lua:88-104. Prefers the
-- `nearest-postal` resource export when running; falls back to the bundled
-- postals.json (nearest-point lookup) so the resource works standalone.
-- ─────────────────────────────────────────────────────────────────────────────

local PostalCodes = nil   -- lazy-loaded from postals.json at first call

local function LoadPostalCodes()
    if PostalCodes ~= nil then return end
    local raw = LoadResourceFile(GetCurrentResourceName(), 'postals.json')
    if not raw then
        PostalCodes = {}
        return
    end
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == 'table' then
        PostalCodes = data
    else
        PostalCodes = {}
    end
end

local function NearestPostalFromBundle(x, y)
    LoadPostalCodes()
    if not PostalCodes or #PostalCodes == 0 then return '' end
    local nearest, minDist = nil, math.huge
    for _, entry in ipairs(PostalCodes) do
        local dx, dy = (entry.x or 0) - x, (entry.y or 0) - y
        local d2 = dx * dx + dy * dy
        if d2 < minDist then
            minDist = d2
            nearest = entry
        end
    end
    return nearest and tostring(nearest.code) or ''
end

-- Postal lookup: prefer the running nearest-postal export, fall back to bundle.
-- v1.4.2: cache the last bundle-lookup keyed by a 100m grid bucket. Scanner
-- can fire 1-3 lookups per second and the bundle sweep is O(2542); caching
-- by grid cell collapses repeated calls within ~100m of movement to O(1).
local PostalCache = { key = nil, value = '' }

local function NearestPostalFromBundleCached(x, y)
    local key = string.format('%d:%d', math.floor(x / 100), math.floor(y / 100))
    if PostalCache.key == key then return PostalCache.value end
    local v = NearestPostalFromBundle(x, y)
    PostalCache.key   = key
    PostalCache.value = v
    return v
end

local function GetPostal(x, y)
    local ok, result = pcall(function()
        return exports['nearest-postal']:getPostal()
    end)
    if ok and result then
        if type(result) == 'table' then
            return tostring(result.code or result[1] or '')
        elseif type(result) == 'number' or type(result) == 'string' then
            return tostring(result)
        end
    end
    return NearestPostalFromBundleCached(x, y)
end

-- Public: resolve street + postal for a world coord. Returns ('', '') on
-- failure rather than nil so callers can always interpolate the result.
function GetScanLocation(coords)
    if not coords then return '', '' end
    local street = ''
    pcall(function()
        if GetStreetNameAtCoord then
            local h1 = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
            street = GetStreetNameFromHashKey(h1) or ''
        end
    end)
    return street, GetPostal(coords.x, coords.y)
end
