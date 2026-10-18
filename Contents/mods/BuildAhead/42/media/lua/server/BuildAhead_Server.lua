-- Multiplayer: the server owns the planned site list. Clients send
-- "add" / "remove" / "claim" / "unclaim" commands; after each change the whole list is
-- transmitted to every client (BuildAhead.lua replaces its copy on receive).
-- It also keeps each player's material bans ("bans" / "getBans", in the
-- server's copy of the player's ModData) and applies them when it performs a
-- build: the client's choice of inputs does not reach the server.

if not isServer() then return end

require "BuildAhead_Sites"
require "BuildAhead_Inputs"

local BAN_KEY = "BuildAheadBans"

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAhead] server " .. table.concat(parts, " "))
end

local function onClientCommand(module, command, player, args)
    if module ~= "BuildAhead" or type(args) ~= "table" then return end
    local data = BuildAheadSites.data()
    local who = player and player:getUsername() or "?"
    local changed = false
    if command == "add" then
        local site = BuildAheadSites.add(data, args.name, args.x, args.y, args.z, args.nSprite, who)
        changed = site ~= nil
        if site then log("site added", site.id, site.name, site.x, site.y, site.z, "by", who) end
    elseif command == "remove" then
        changed = BuildAheadSites.remove(data, args.id)
        if changed then log("site removed", args.id, "by", who) end
    elseif command == "claim" then
        -- a site the client added a moment ago has only a local id: find it by square
        local site = (type(args.id) == "number" and args.id > 0) and BuildAheadSites.get(data, args.id)
            or BuildAheadSites.find(data, args.name, args.x, args.y, args.z, tonumber(args.nSprite) or 1)
        changed = site ~= nil and BuildAheadSites.claim(data, site.id, who, getGameTime():getWorldAgeHours())
    elseif command == "unclaim" then
        -- the player stopped building it: only their own claim is released
        local site = (type(args.id) == "number" and args.id > 0) and BuildAheadSites.get(data, args.id)
            or BuildAheadSites.find(data, args.name, args.x, args.y, args.z, tonumber(args.nSprite) or 1)
        if site and site.claimBy == who then
            site.claimBy, site.claimAt = nil, nil
            changed = true
            log("site unclaimed", site.id, "by", who)
        end
    elseif command == "bans" and player then
        local bans = {}
        if type(args.bans) == "table" then
            for k, v in pairs(args.bans) do
                if type(k) == "string" and v then bans[k] = true end
            end
        end
        player:getModData()[BAN_KEY] = bans
        local list = {}
        for k in pairs(bans) do list[#list + 1] = k end
        log("bans of", who, table.concat(list, ","))
    elseif command == "getBans" and player then
        sendServerCommand(player, "BuildAhead", "bans", { bans = player:getModData()[BAN_KEY] or {} })
    end
    if changed then
        ModData.transmit(BuildAheadSites.KEY)
    end
end

-- the containers the server-side entity got from the client, or the player's inventory
local function buildContainers(entity)
    local c = entity.containers
    if c and type(c) ~= "table" and pcall(function() return c:size() end) then return c end
    local list = ArrayList.new()
    list:add(entity.character:getInventory())
    return list
end

local function hookCreate()
    if BuildAheadServerHooked or not ISBuildIsoEntity then return end
    BuildAheadServerHooked = true
    local origCreate = ISBuildIsoEntity.create
    function ISBuildIsoEntity:create(...)
        local character = self.character
        local bans = character and character:getModData()[BAN_KEY]
        if self.buildPanelLogic and BuildAheadInputs.hasAny(bans) and not character:isBuildCheat() then
            local ok, err = pcall(function()
                local containers = buildContainers(self)
                self.buildPanelLogic:setContainers(containers)
                BuildAheadInputs.fill(self.buildPanelLogic, bans, containers)
                log("inputs filled without banned types for", character:getUsername(), self.name)
            end)
            if not ok then log("ban fill error", err) end
        end
        return origCreate(self, ...)
    end
end

Events.OnInitGlobalModData.Add(function() BuildAheadSites.data() end)
hookCreate()
Events.OnGameBoot.Add(hookCreate)
if Events.OnServerStarted then Events.OnServerStarted.Add(hookCreate) end
Events.OnClientCommand.Add(onClientCommand)
