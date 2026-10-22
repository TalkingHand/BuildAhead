-- Planned site list, kept in global ModData "BuildAhead".
-- Single player: the client changes it directly and it is saved with the world.
-- Multiplayer: only the server changes it (BuildAhead_Server.lua, on client
-- commands) and transmits it to every client.

BuildAheadSites = BuildAheadSites or {}

BuildAheadSites.KEY = "BuildAhead"
BuildAheadSites.CLAIM_HOURS = 0.5 -- in-game hours a "being built" mark holds the site for its player

function BuildAheadSites.data()
    local data = ModData.getOrCreate(BuildAheadSites.KEY)
    data.sites = data.sites or {}
    data.nextId = data.nextId or 1
    return data
end

-- stack: the level of a stackable object (a crate) planned on a square that
-- already has planned ones (nil for everything else)
function BuildAheadSites.find(data, name, x, y, z, nSprite, stack)
    for _, s in ipairs(data.sites) do
        if s.x == x and s.y == y and s.z == z and s.name == name and s.nSprite == nSprite and s.stack == stack then
            return s
        end
    end
end

function BuildAheadSites.get(data, id)
    for _, s in ipairs(data.sites) do
        if s.id == id then return s end
    end
end

-- returns the new site, or nil when the same site is already planned
function BuildAheadSites.add(data, name, x, y, z, nSprite, by, stack)
    if type(name) ~= "string" or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    nSprite = tonumber(nSprite) or 1
    stack = tonumber(stack)
    if BuildAheadSites.find(data, name, x, y, z, nSprite, stack) then return nil end
    local site = { id = data.nextId, name = name, x = x, y = y, z = z, nSprite = nSprite, by = by, stack = stack }
    data.nextId = data.nextId + 1
    table.insert(data.sites, site)
    return site
end

function BuildAheadSites.remove(data, id)
    for i = #data.sites, 1, -1 do
        if data.sites[i].id == id then
            table.remove(data.sites, i)
            return true
        end
    end
    return false
end

function BuildAheadSites.claim(data, id, by, worldHours)
    local s = BuildAheadSites.get(data, id)
    if not s then return false end
    s.claimBy = by
    s.claimAt = worldHours
    return true
end

-- claimed by someone else, recently enough that they are probably building it
function BuildAheadSites.isClaimedByOther(site, me, worldHours)
    return site.claimBy ~= nil and site.claimBy ~= me
        and site.claimAt ~= nil and worldHours - site.claimAt < BuildAheadSites.CLAIM_HOURS
end
