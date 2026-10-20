-- Build Ahead
-- Every click with the build cursor stores a planned site (object name,
-- square, rotation) and draws it as a ghost: blue when it can be built now,
-- yellow when the materials are missing, red when the square is blocked.
-- A scheduler does all the building: after a click, if the player is idle, it
-- walks to the nearest buildable site; each time a build finishes, the nearest
-- buildable site in range is built next. Right-click a ghost to build from
-- there or to cancel it.
-- The scheduler picks the inputs itself and never uses item types the player
-- banned (per player, see "material bans" below and BuildAhead_BanUI.lua).
--
-- How it hooks into vanilla (B42 build entities, ISBuildIsoEntity):
--   - The build panel sets cursor.blockBuild while a craft action runs and
--     when materials are missing, which makes isValid() false. isValid()
--     ignores blockBuild so the cursor accepts clicks, and tryBuild() stores a
--     site instead of building.
--   - A site is built the same way ISEntityBuildMenu.onBuildEntity does:
--     ISBuildIsoEntity:new() without the panel creates its own BuildLogic,
--     and fillInputs() picks the materials (autoPopulateInputs() without bans).
--   - ISBuildAction:perform() is wrapped to start the next site.
--   - ISBuildAction:start() is wrapped to take the containers at hand where the
--     player stands when the build starts, not where the site was picked.
--
-- Stage 2 (BuildAhead_Fetch.lua): materials that are not at hand are fetched
-- from up to RANGE tiles around the site and dropped where the player builds.
--
-- Self-enclosure (BuildAhead_Trap.lua): before a site is started, the result is
-- simulated; if building it from where the player would stand walls the player
-- in, the player builds from the other side, and a site that traps from every
-- side is skipped ("would wall you in", ghost drawn orange).
--
-- Sites live in global ModData (BuildAhead_Sites.lua): saved with a
-- single-player world, or owned by the server in multiplayer and shared with
-- every player (BuildAhead_Server.lua). Any player's chain builds any site.

-- ISBuildIsoEntity is a server/ file, which is only loaded when a game starts:
-- the hooks are installed on OnGameStart.

require "BuildAhead_Sites"
require "BuildAhead_Inputs"
require "BuildAhead_Fetch"
require "BuildAhead_Trap"

BuildAhead = BuildAhead or {}

BuildAhead.RANGE = 20              -- tiles from the last build to the next site
BuildAhead.START_WAIT_MS = 5000    -- after a build: give up starting the next site if the queue stays busy this long
BuildAhead.CLICK_WAIT_MS = 30000   -- after a click: same, while the player finishes another action
BuildAhead.VALIDITY_EVERY_MS = 500 -- how often ghost state is rechecked
BuildAhead.COLOR = { 0.35, 0.65, 1.0 }         -- buildable now
BuildAhead.COLOR_MISSING = { 1.0, 0.85, 0.25 } -- valid, materials missing
BuildAhead.COLOR_BLOCKED = { 1.0, 0.35, 0.3 }  -- square blocked
BuildAhead.COLOR_TRAP = { 1.0, 0.55, 0.1 }     -- building it would wall the player in

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAhead] " .. table.concat(parts, " "))
end
BuildAhead.log = log

-- ---------------------------------------------------------------- storage

local cache = {} -- site id -> { entity, valid, checkedAt }

local function myName()
    local p = getSpecificPlayer(0)
    return p and p:getUsername() or ""
end

function BuildAhead.getSites()
    return BuildAheadSites.data().sites
end

local function objectInfoByName(name)
    BuildAhead.infoByName = BuildAhead.infoByName or {}
    local info = BuildAhead.infoByName[name]
    if info then return info end
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        BuildAhead.infoByName[i:getName()] = i
    end
    return BuildAhead.infoByName[name]
end

-- In multiplayer the server owns the list: changes are sent as commands and
-- also applied locally right away, so the ghost shows without waiting. The
-- server's copy replaces the local one when it arrives.
local localId = 0

function BuildAhead.addSite(name, x, y, z, nSprite)
    local data = BuildAheadSites.data()
    if BuildAheadSites.find(data, name, x, y, z, nSprite) then return nil end
    local site
    if isClient() then
        sendClientCommand(getSpecificPlayer(0), "BuildAhead", "add", { name = name, x = x, y = y, z = z, nSprite = nSprite })
        localId = localId - 1
        site = { id = localId, name = name, x = x, y = y, z = z, nSprite = nSprite, by = myName() }
        table.insert(data.sites, site)
    else
        site = BuildAheadSites.add(data, name, x, y, z, nSprite, myName())
    end
    log("site added", site.id, name, x, y, z, "nSprite", nSprite)
    return site
end

function BuildAhead.removeSite(id)
    if isClient() and id > 0 then
        sendClientCommand(getSpecificPlayer(0), "BuildAhead", "remove", { id = id })
    end
    cache[id] = nil
    local removed = BuildAheadSites.remove(BuildAheadSites.data(), id)
    if removed then log("site removed", id) end
    return removed
end

-- mark a site as being built by this player, so other players' chains leave it alone
local function claimSite(site)
    local hours = getGameTime():getWorldAgeHours()
    site.claimBy, site.claimAt = myName(), hours
    if isClient() then
        -- a site added a moment ago has no server id yet: the server finds it by square
        sendClientCommand(getSpecificPlayer(0), "BuildAhead", "claim", {
            id = site.id, name = site.name, x = site.x, y = site.y, z = site.z, nSprite = site.nSprite })
    end
end

-- the player stopped working on the site (moved, another action, gave up): other
-- players' chains may build it again right away, not only when the claim runs out
local function unclaimSite(site)
    if not site or site.claimBy ~= myName() then return end
    site.claimBy, site.claimAt = nil, nil
    if isClient() then
        sendClientCommand(getSpecificPlayer(0), "BuildAhead", "unclaim", {
            id = site.id, name = site.name, x = site.x, y = site.y, z = site.z, nSprite = site.nSprite })
    end
end
BuildAhead.unclaim = unclaimSite

-- the planned site of this name on a square (by square: in multiplayer the
-- server's list may have replaced a local id meanwhile)
local function siteOn(name, x, y, z)
    for _, site in ipairs(BuildAhead.getSites()) do
        if site.name == name and site.x == x and site.y == y and site.z == z then return site end
    end
end

-- the player took over: a movement key or the cancel key (vanilla stops the
-- walks on these too). A function so tests can stand in for the keys.
function BuildAhead.tookOver(playerObj)
    return playerObj:pressedMovement(false) or playerObj:pressedCancelAction()
end

local function onReceiveGlobalModData(key, data)
    if key ~= BuildAheadSites.KEY or type(data) ~= "table" then return end
    ModData.add(BuildAheadSites.KEY, data)
    for id in pairs(cache) do cache[id] = nil end
end

-- ---------------------------------------------------------------- material bans

-- Item full types ("Base.Plank") the scheduler must not use, for any recipe.
-- Per player, kept in the player's ModData; there is no list window, only the
-- toggles in the build panel (BuildAhead_BanUI.lua).
BuildAhead.BAN_KEY = "BuildAheadBans"
BuildAhead.onBansChanged = {} -- functions(playerObj, fullType, banned)

function BuildAhead.getBans(playerObj)
    local md = playerObj:getModData()
    if type(md[BuildAhead.BAN_KEY]) ~= "table" then md[BuildAhead.BAN_KEY] = {} end
    return md[BuildAhead.BAN_KEY]
end

function BuildAhead.isBanned(playerObj, fullType)
    return fullType ~= nil and BuildAhead.getBans(playerObj)[fullType] == true
end

function BuildAhead.setBanned(playerObj, fullType, banned)
    if not fullType then return end
    BuildAhead.getBans(playerObj)[fullType] = banned and true or nil
    -- in multiplayer the server applies the bans when it performs the build
    if isClient() then
        sendClientCommand(playerObj, "BuildAhead", "bans", { bans = BuildAhead.getBans(playerObj) })
    end
    for _, c in pairs(cache) do c.checkedAt = nil; c.gatherAt = nil end
    log(banned and "banned" or "unbanned", fullType)
    for _, fn in ipairs(BuildAhead.onBansChanged) do pcall(fn, playerObj, fullType, banned) end
end

function BuildAhead.toggleBan(playerObj, fullType)
    BuildAhead.setBanned(playerObj, fullType, not BuildAhead.isBanned(playerObj, fullType))
end

-- ---------------------------------------------------------------- build entities

local function getTool(inputScript, inventory, bans)
    if not inputScript then return nil end
    local entryItems = inputScript:getPossibleInputItems()
    for m = 0, entryItems:size() - 1 do
        local itemType = entryItems:get(m):getFullName()
        if not bans[itemType] then
            local result = inventory:getAllTypeEvalRecurse(itemType, ISBuildIsoEntity.predicateMaterial)
            if result:size() > 0 then return result:get(0):getFullType() end
        end
    end
end

-- inputs for the scheduler, without banned item types (BuildAhead_Inputs.lua)
local function fillInputs(logic, playerObj, containers)
    BuildAheadInputs.fill(logic, BuildAhead.getBans(playerObj), containers or ISInventoryPaneContextMenu.getContainers(playerObj))
end
BuildAhead.fillInputs = fillInputs

-- the containers at hand, with the loot window brought up to date first
-- (it refreshes on its own only a frame later, e.g. after a drop)
function BuildAhead.freshContainers(playerObj)
    local ok, err = pcall(function() getPlayerLoot(playerObj:getPlayerNum()):refreshBackpacks() end)
    if not ok then log("loot refresh error", err) end
    return ISInventoryPaneContextMenu.getContainers(playerObj)
end

-- the inventory and the bags in it, without the loot window's containers
local function carriedContainers(playerObj)
    local list = ArrayList.new()
    for _, v in ipairs(getPlayerInventory(playerObj:getPlayerNum()).inventoryPane.inventoryPage.backpacks) do
        list:add(v.inventory)
    end
    return list
end

-- "manual Base.Sapling x6 Base.RippedSheets x2": the inputs a build will use (log)
function BuildAhead.describeInputs(logic, data)
    data = data or logic:getRecipeData()
    local parts = { logic:isManualSelectInputs() and "manual" or "auto" }
    local recipe = data:getRecipe()
    local inputs = recipe and recipe:getInputs()
    for i = 0, (inputs and inputs:size() or 0) - 1 do
        local d = data:getDataForInputScript(inputs:get(i))
        local counts = {}
        for n = 0, (d and d:getAppliedItemsCount() or 0) - 1 do
            local t = d:getAppliedItem(n):getFullType()
            counts[t] = (counts[t] or 0) + 1
        end
        for t, c in pairs(counts) do parts[#parts + 1] = t .. " x" .. c end
    end
    return table.concat(parts, " ")
end

-- same as ISEntityBuildMenu.onBuildEntity, without the cursor
local function makeEntity(playerObj, info, nSprite)
    local containers = ISInventoryPaneContextMenu.getContainers(playerObj)
    local e = ISBuildIsoEntity:new(playerObj, info, nSprite, containers)
    e.player = playerObj:getPlayerNum() -- normally set by setDrag; tryBuild needs it
    -- ISBuildIsoEntity:new sets dragNilAfterPlace, and tryBuild would then drop the
    -- player's build cursor (setDrag(nil)) each time the scheduler starts a build
    e.dragNilAfterPlace = false
    e.blockAfterPlace = false
    local recipe = info:getRecipe():getCraftRecipe()
    local inv = playerObj:getInventory()
    local bans = BuildAhead.getBans(playerObj)
    e.equipBothHandItem = getTool(recipe:getToolBoth(), inv, bans)
    e.firstItem = getTool(recipe:getToolRight(), inv, bans)
    e.secondItem = getTool(recipe:getToolLeft(), inv, bans)
    e.buildAheadSite = true
    e:getSprite() -- applies nSprite (north/west)
    -- the build panel does this while dragging; without it no inputs are selected
    fillInputs(e.buildPanelLogic, playerObj)
    return e
end

local function siteEntity(playerObj, site)
    local c = cache[site.id]
    if c and c.entity then return c.entity end
    local info = objectInfoByName(site.name)
    if not info then return nil end
    local e = makeEntity(playerObj, info, site.nSprite)
    cache[site.id] = { entity = e }
    return e
end

local function siteSquare(site)
    return getCell():getGridSquare(site.x, site.y, site.z)
end

local function isSiteValid(playerObj, site)
    local e = siteEntity(playerObj, site)
    local sq = siteSquare(site)
    if not e or not sq then return false end
    local ok, valid = pcall(e.isValid, e, sq)
    return ok and valid
end

-- ---------------------------------------------------------------- materials

-- materials of the recipe that fillInputs could not find, as "Plank x2"
local function missingMaterials(logic)
    local out = {}
    local recipe = logic:getRecipe()
    local inputs = recipe and recipe:getInputs()
    if not inputs then return out end
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        if not input:isAutomationOnly() and input:getResourceType() == ResourceType.Item then
            local need = input:getIntAmount()
            local short = need - logic:getInputCount(input)
            if short > 0 then
                local items = input:getPossibleInputItems()
                local name = items:size() > 0 and items:get(0):getDisplayName() or "?"
                out[#out + 1] = short > 1 and (name .. " x" .. short) or name
            end
        end
    end
    return out
end
BuildAhead.missingMaterials = missingMaterials

-- the materials are in reach of the player right now
local function hasMaterials(playerObj, site, containers)
    if playerObj:isBuildCheat() then return true end
    local e = siteEntity(playerObj, site)
    if not e then return false end
    containers = containers or ISInventoryPaneContextMenu.getContainers(playerObj)
    e.buildPanelLogic:setContainers(containers)
    fillInputs(e.buildPanelLogic, playerObj, containers)
    return e.buildPanelLogic:canPerformCurrentRecipe()
end

-- same, with the loot window refreshed first (after a drop at the site)
function BuildAhead.hasMaterialsNow(playerObj, site)
    return hasMaterials(playerObj, site, BuildAhead.freshContainers(playerObj))
end

-- what the build's own check lacks right now, for the log: "Plank x2", the
-- inputs it filled, and the number of containers at hand
function BuildAhead.lackingNow(playerObj, site)
    local e = siteEntity(playerObj, site)
    if not e then return "no entity" end
    local containers = BuildAhead.freshContainers(playerObj)
    local logic = e.buildPanelLogic
    logic:setContainers(containers)
    fillInputs(logic, playerObj, containers)
    return table.concat(missingMaterials(logic), ", ") .. " | filled " .. BuildAhead.describeInputs(logic)
        .. " | containers " .. containers:size() .. " | can " .. tostring(logic:canPerformCurrentRecipe())
end

-- a BuildLogic of the site's recipe for planning, apart from the ghost's entity
local function planLogic(playerObj, site)
    siteEntity(playerObj, site)
    local c = cache[site.id]
    if c and c.planLogic then return c.planLogic end
    local info = objectInfoByName(site.name)
    if not info then return nil end
    local logic = BuildLogic.new(playerObj, nil, nil)
    logic:setRecipe(info:getRecipe():getCraftRecipe())
    if c then c.planLogic = logic end
    return logic
end

-- What to fetch for a site (BuildAheadFetch.plan): {} when nothing, nil and
-- the missing names when the sources within range are not enough.
-- base: the containers whose materials count as there already (default: what
-- the player carries, since loot-window containers stay behind when the player
-- walks to the site); atHand: the square the site is built from, whose 3x3 is
-- at hand there (counted as there already, not fetched; default: the site's kept
-- stand square); reuse: a scan made a moment ago for a site nearby may answer
-- (BuildAheadFetch.scan).
function BuildAhead.fetchPlan(playerObj, site, base, atHand, reuse)
    local logic = planLogic(playerObj, site)
    if not logic then return nil, {} end
    base = base or carriedContainers(playerObj)
    atHand = atHand or BuildAhead.keptStand(site)
    local bans = BuildAhead.getBans(playerObj)
    logic:setContainers(base)
    BuildAheadInputs.fill(logic, bans, base)
    return BuildAheadFetch.plan(playerObj, logic, bans, site.x, site.y, site.z, atHand, base, reuse)
end

-- While the ghosts are drawn, at most this many sites per frame get a new
-- "can be gathered" answer and a new state; the others keep their last one a
-- little longer. Many sites planned at once would otherwise all recheck in the
-- same frame (a long freeze with dozens of yellow sites).
BuildAhead.GATHER_PER_FRAME = 2
BuildAhead.STATES_PER_FRAME = 8
local frameBudget = nil -- { gather, states } while the ghosts are drawn

-- the missing materials can be gathered within range (answer reused for a while)
local function canGather(playerObj, site)
    if playerObj:isBuildCheat() then return true end
    siteEntity(playerObj, site)
    local c = cache[site.id]
    if not c then return false end
    local t = getTimestampMs()
    if c.gatherAt and t - c.gatherAt < BuildAheadFetch.CHECK_EVERY_MS then return c.gather, c.gatherMissing end
    if frameBudget and c.gatherAt then
        if frameBudget.gather <= 0 then return c.gather, c.gatherMissing end
        frameBudget.gather = frameBudget.gather - 1
    end
    c.gatherAt = t
    -- a scan shared between nearby sites only for the ghosts; the scheduler and the
    -- reasons shown on a click look afresh
    local ok, plan, missing = pcall(BuildAhead.fetchPlan, playerObj, site, nil, nil, frameBudget ~= nil)
    if not ok then log("fetch plan error", plan) end
    c.gather = ok and plan ~= nil
    c.gatherMissing = ok and missing or nil
    return c.gather, c.gatherMissing
end
BuildAhead.canGather = canGather

-- at hand now, or can be fetched
local function materialsAvailable(playerObj, site)
    return hasMaterials(playerObj, site) or canGather(playerObj, site)
end

-- skills the recipe needs that the player lacks, as "Carpentry 2"
local function missingSkills(playerObj, site)
    local out = {}
    if playerObj:isBuildCheat() then return out end
    local info = objectInfoByName(site.name)
    local recipe = info and info:getRecipe() and info:getRecipe():getCraftRecipe()
    if not recipe then return out end
    for i = 0, recipe:getRequiredSkillCount() - 1 do
        local rs = recipe:getRequiredSkill(i)
        if not CraftRecipeManager.hasPlayerRequiredSkill(rs, playerObj) then
            out[#out + 1] = tostring(rs:getPerk():getName()) .. " " .. tostring(rs:getLevel())
        end
    end
    return out
end
BuildAhead.missingSkills = missingSkills

-- the player has the skill levels the recipe needs (nil recipe: nothing to check)
local function hasSkills(playerObj, recipe)
    return not recipe or playerObj:isBuildCheat() or recipe:characterHasRequiredSkills(playerObj)
end
BuildAhead.hasSkills = hasSkills

-- ---------------------------------------------------------------- self-enclosure

-- the self-enclosure check of a site (BuildAheadTrap.evaluate; nil when the object
-- blocks nothing), reused for a while unless fresh
local function trapCheck(playerObj, site, fresh)
    local e = siteEntity(playerObj, site)
    local c = cache[site.id]
    if not e or not c then return nil end
    local t = getTimestampMs()
    if not fresh and c.trapAt and t - c.trapAt < BuildAheadTrap.CHECK_EVERY_MS then return c.trap end
    local ok, r = pcall(BuildAheadTrap.evaluate, e, site.x, site.y, site.z)
    if not ok then log("trap check error", r); r = nil end
    c.trapAt, c.trap = t, r
    return r
end
BuildAhead.trapCheck = trapCheck

-- building the site would wall the player in from every square it can be built from
function BuildAhead.wouldTrap(playerObj, site, fresh)
    if playerObj:isBuildCheat() then return false end
    local r = trapCheck(playerObj, site, fresh)
    return r ~= nil and r.trap and #r.safe == 0
end

-- Sites the player ordered by hand ("Build planned"): built even when every side traps.
-- Cleared when the build is performed or fails; the chain after it avoids traps again.
local directSites = {}

-- walk to the chosen stand square. ISPathFindAction, as vanilla's walk to a build
-- (ISWalkToTimedAction is invalid at game speed above 2); a failed path ends the
-- queue, so the build is not started from the wrong side.
local function walkToStand(playerObj, stand)
    local psq = playerObj:getCurrentSquare()
    if psq and psq:getX() == stand:getX() and psq:getY() == stand:getY() and psq:getZ() == stand:getZ() then
        return true
    end
    ISTimedActionQueue.add(ISPathFindAction:pathToLocationF(playerObj, stand:getX() + 0.5, stand:getY() + 0.5, stand:getZ()))
    return true
end
BuildAhead.walkToStand = walkToStand

-- The square a site is built from, chosen once and kept for the site: every
-- fetch trip walks there and drops its load around it, and the build takes the
-- materials from there. Vanilla's walk to a wall (AdjacentFreeTileFinder.FindWall)
-- picks the side nearest in a straight line, which outdoors can be across a
-- wall from the player and can change from one trip to the next.
local stands = {} -- site key (name and square) -> "x,y" of its stand square
BuildAhead.STAND_RADIUS = 40 -- path search around the player for the stand, in squares
BuildAhead.STAND_OFF_EDGE = 1000 -- extra steps for a stand off either side of the new edge (only when no side is reached)

local function standKey(site)
    return site.name .. "@" .. site.x .. "," .. site.y .. "," .. site.z .. ":" .. tostring(site.nSprite)
end

-- the stand square kept for the site, if any (no search)
function BuildAhead.keptStand(site)
    local s = stands[standKey(site)]
    if not s then return nil end
    local x, y = string.match(s, "^(-?%d+),(-?%d+)$")
    return getCell():getGridSquare(tonumber(x), tonumber(y), site.z)
end

-- The stand square for the site (kept, or chosen now): among the squares that
-- do not wall the player in, the one the player reaches in the fewest steps,
-- preferring the two sides of a new edge. nil: nothing found (vanilla walks).
-- r: the site's trapCheck result.
function BuildAhead.standFor(playerObj, site, r)
    if not r or #r.safe == 0 then return nil end
    local k = standKey(site)
    local kept = stands[k]
    local byKey = {}
    for _, sq in ipairs(r.safe) do byKey[sq:getX() .. "," .. sq:getY()] = sq end
    local psq = playerObj:getCurrentSquare()
    local sameLevel = psq ~= nil and psq:getZ() == site.z
    if kept and byKey[kept] then
        local sq = byKey[kept]
        if not sameLevel or sq == psq then return sq end
        local d = BuildAheadTrap.pathDistances(psq, { sq }, BuildAhead.STAND_RADIUS)
        if d[BuildAheadTrap.key(sq:getX(), sq:getY())] then return sq end
    end
    stands[k] = nil
    if not sameLevel then return nil end
    local dist = BuildAheadTrap.pathDistances(psq, r.safe, BuildAhead.STAND_RADIUS)
    local best, bestScore
    for _, sq in ipairs(r.safe) do
        local sk = BuildAheadTrap.key(sq:getX(), sq:getY())
        local d = dist[sk]
        if d then
            local score = d + (r.preferred[sk] and 0 or BuildAhead.STAND_OFF_EDGE)
            if not bestScore or score < bestScore then best, bestScore = sq, score end
        end
    end
    if best then
        stands[k] = best:getX() .. "," .. best:getY()
        log("site", site.id, "stand", best:getX(), best:getY(), "steps", dist[BuildAheadTrap.key(best:getX(), best:getY())])
    end
    return best
end

-- a wall, door, frame or window: vanilla sets e.isWallLike only while it draws
-- the cursor, so the scheduler's entities work it out the same way here
local function isWallLike(e)
    -- (ISBuildingObject starts it at false, so only true can be trusted)
    if e.isWallLike then return true end
    if e.buildAheadWallLike ~= nil then return e.buildAheadWallLike end
    local ok, yes = pcall(function()
        local face = e:getFace()
        for xx = 0, face:getWidth() - 1 do
            for yy = 0, face:getHeight() - 1 do
                local ti = face:getTileInfo(xx, yy, 0)
                local name = ti and ti:getSpriteName()
                if name then
                    local props = getSprite(name):getProperties()
                    for _, t in ipairs({ "WALL_N", "WALL_W", "WALL_N_TRANS", "WALL_W_TRANS", "WINDOW_N", "WINDOW_W",
                        "DOOR_WALL_N", "DOOR_WALL_W" }) do
                        if IsoPropertyType[t] and props:has(IsoPropertyType[t]) then return true end
                    end
                    -- a door in a frame stands on the frame's edge too
                    for _, f in ipairs({ "doorN", "doorW", "WallN", "WallW", "WallNTrans", "WallWTrans" }) do
                        if IsoFlagType[f] and props:has(IsoFlagType[f]) then return true end
                    end
                    return false
                end
            end
        end
        return false
    end)
    e.buildAheadWallLike = ok and yes or false
    if e.buildAheadWallLike then e.isWallLike = true end
    return e.buildAheadWallLike
end

-- Where the player builds the site from: sets e.buildAheadStand (the walk then
-- goes there, see BuildAhead.standFor). false: every square traps (unless the
-- site was ordered by hand).
local function chooseStand(playerObj, site, e)
    if playerObj:isBuildCheat() then return true end
    local r = trapCheck(playerObj, site, true)
    if r and r.trap and #r.safe == 0 then
        if directSites[site.id] then
            log("site", site.id, "ordered by hand: built although it walls the player in")
            return true
        end
        log("site", site.id, "would wall the player in from every side:", BuildAheadTrap.squares(r.trapped))
        return false
    end
    -- walls, doors and frames: a kept stand on the side the player reaches. Other
    -- objects (stairs, furniture) walk the vanilla way unless a side traps.
    local stand
    if isWallLike(e) or (r and r.trap) then
        -- frames and doors block nothing (they can be passed): stand anywhere around
        local cands = r
        if not cands then
            local ok, res = pcall(BuildAheadTrap.standsAround, e, site.x, site.y, site.z)
            cands = ok and res or nil
        end
        stand = BuildAhead.standFor(playerObj, site, cands)
    end
    if not stand and r and r.trap then
        -- no path found: the safe square nearest in a straight line, as before
        stand = BuildAheadTrap.standSquare(playerObj, r)
    end
    if stand then
        if r and r.trap then
            log("site", site.id, "built from", stand:getX(), stand:getY(), "- would trap at", BuildAheadTrap.squares(r.trapped))
        end
        e.buildAheadStand = stand
    end
    return true
end
BuildAhead.chooseStand = chooseStand

local function cursorRecipe(cursor)
    return cursor.objectInfo and cursor.objectInfo:getRecipe() and cursor.objectInfo:getRecipe():getCraftRecipe()
end

-- why a site cannot be built right now, as text for the player (nil if it can);
-- direct: for an order by hand, which may wall the player in
function BuildAhead.cannotBuildReason(playerObj, site, direct)
    if not isSiteValid(playerObj, site) then return getText("IGUI_BuildAhead_Blocked") end
    local skills = missingSkills(playerObj, site)
    if #skills > 0 then return getText("IGUI_BuildAhead_NeedSkill", table.concat(skills, ", ")) end
    if not direct and BuildAhead.wouldTrap(playerObj, site) then return getText("IGUI_BuildAhead_Trap") end
    if hasMaterials(playerObj, site) then return nil end
    local gather, missing = canGather(playerObj, site)
    if gather then return nil end
    if not missing or #missing == 0 then
        local e = siteEntity(playerObj, site)
        local ok, m = pcall(missingMaterials, e and e.buildPanelLogic)
        missing = ok and m or {}
    end
    if #missing > 0 then
        return getText("IGUI_BuildAhead_Missing", table.concat(missing, ", "), BuildAheadFetch.RANGE)
    end
    return getText("IGUI_BuildAhead_CannotBuild")
end

-- valid, and the materials are at hand or can be fetched within range
function BuildAhead.canBuildSite(playerObj, site)
    -- skills first: a site planned by another player may need more than this player has,
    -- and the chain must not walk off to fetch materials for it
    return isSiteValid(playerObj, site) and #missingSkills(playerObj, site) == 0
        and not BuildAhead.wouldTrap(playerObj, site) and materialsAvailable(playerObj, site)
end

-- "buildable", "missing" (valid, but the skill is too low or the materials are neither at hand
-- nor within range), "trap" (building it would wall the player in) or "blocked"
function BuildAhead.siteState(playerObj, site)
    if not isSiteValid(playerObj, site) then return "blocked" end
    if #missingSkills(playerObj, site) > 0 then return "missing" end
    if BuildAhead.wouldTrap(playerObj, site) then return "trap" end
    return materialsAvailable(playerObj, site) and "buildable" or "missing"
end

-- ---------------------------------------------------------------- player state

local function actionQueue(playerObj)
    local q = ISTimedActionQueue.getTimedActionQueue(playerObj)
    return q and q.queue or {}
end

-- a build action is running or waiting in the queue (walking to it counts)
function BuildAhead.isBuilding(playerObj)
    for _, a in ipairs(actionQueue(playerObj)) do
        if a.Type == "ISBuildAction" then return true, a end
    end
    return false
end

-- building, or fetching materials for a build (or taking tools back)
function BuildAhead.isBusy(playerObj)
    return BuildAhead.isBuilding(playerObj) or BuildAheadFetch.isActive(playerObj)
end

-- a click with this cursor plans a site (every click except a headless site
-- entity's own build). Inputs chosen by hand in the build panel are not used:
-- the scheduler picks them itself, skipping banned item types.
local function plansSites(cursor)
    return cursor.character ~= nil and not cursor.buildAheadSite
end
BuildAhead.plansSites = plansSites

-- refresh the open build panel, so its material counts follow a scheduler build
local function refreshBuildPanel(playerObj)
    local panel = ISBuildWindow and ISBuildWindow.instance
    if not panel or panel.player ~= playerObj or not panel.logic then return end
    local ok, err = pcall(function()
        panel:updateContainers(true)
        panel.logic:refresh()
        panel:createBuildIsoEntity(true) -- recomputes the cursor's blockBuild
    end)
    if not ok then log("build panel refresh error", err) end
end
BuildAhead.refreshBuildPanel = refreshBuildPanel

-- ---------------------------------------------------------------- scheduler

local pending = nil -- { player, x, y, z, since, wait }: start the nearest site from here once the queue is empty
local skipped = {}  -- site key -> true: tried this chain and could not build
-- by square, not id: in multiplayer the server's list replaces a local id meanwhile
local function skipKey(site)
    return site.name .. "@" .. site.x .. "," .. site.y .. "," .. site.z .. ":" .. tostring(site.nSprite)
end
local checks = {}   -- { name, x, y, z, at }: built here, see whether the object is really there
BuildAhead.CHECK_DELAY_MS = 1000 -- in multiplayer the built object arrives a little after the action ends

local function distSq(site, x, y, z)
    return (site.x - x) ^ 2 + (site.y - y) ^ 2 + ((site.z - z) * 3) ^ 2
end

-- nearest site in range that is valid, has materials and nobody else is building
function BuildAhead.pickNext(playerObj, x, y, z)
    local best, bestD
    local range2 = BuildAhead.RANGE * BuildAhead.RANGE
    local me, hours = myName(), getGameTime():getWorldAgeHours()
    for _, site in ipairs(BuildAhead.getSites()) do
        local d = distSq(site, x, y, z)
        if d <= range2 and not skipped[skipKey(site)] and (not bestD or d < bestD)
            and not BuildAheadSites.isClaimedByOther(site, me, hours) then
            if BuildAhead.canBuildSite(playerObj, site) then
                best, bestD = site, d
            end
        end
    end
    return best
end

-- build now: the materials are at hand
function BuildAhead.tryBuildSite(playerObj, site)
    local info = objectInfoByName(site.name)
    if not info then return false end
    -- a fresh entity: tryBuild hands a copy to the action, and the cached one only draws the ghost
    local e = makeEntity(playerObj, info, site.nSprite)
    if not chooseStand(playerObj, site, e) then return false end
    log("building site", site.id, site.name, site.x, site.y, site.z)
    pcall(function() log("inputs", BuildAhead.describeInputs(e.buildPanelLogic)) end)
    local before = {}
    for _, a in ipairs(actionQueue(playerObj)) do before[a] = true end
    -- with the build cheat (on in -debug) vanilla builds from where the player stands
    -- without calling walkTo: walk to the chosen side first
    if e.buildAheadStand and ISBuildMenu.cheat then walkToStand(playerObj, e.buildAheadStand) end
    e:tryBuild(site.x, site.y, site.z)
    if not BuildAhead.isBuilding(playerObj) then return false end
    -- the walks to the build: when the path fails, the chain goes on without this site
    for _, a in ipairs(actionQueue(playerObj)) do
        if not before[a] and (a.Type == "ISPathFindAction" or a.Type == "ISWalkToTimedAction") then
            a.buildAheadSite = { name = site.name, x = site.x, y = site.y, z = site.z }
        end
    end
    claimSite(site)
    return true
end

BuildAhead.claim = claimSite

-- walk to where the site is built from (the build action does the same)
function BuildAhead.walkToSite(playerObj, site)
    local info = objectInfoByName(site.name)
    if not info then return false end
    local e = makeEntity(playerObj, info, site.nSprite)
    if not chooseStand(playerObj, site, e) then return false end
    return e:walkTo(site.x, site.y, site.z)
end

-- build a site: right away when the player carries the materials (or they are
-- at hand and cannot be fetched), else fetch them first
function BuildAhead.buildSite(playerObj, site)
    if playerObj:isBuildCheat() then return BuildAhead.tryBuildSite(playerObj, site) end
    -- before walking off to fetch: the state pickNext saw may be a moment old
    if not directSites[site.id] and BuildAhead.wouldTrap(playerObj, site, true) then return false end
    -- the square it is built from: what lies around it is at hand there, not fetched
    local e = siteEntity(playerObj, site)
    if e then pcall(chooseStand, playerObj, site, e) end
    local ok, plan = pcall(BuildAhead.fetchPlan, playerObj, site)
    if not ok then log("fetch plan error", plan); plan = nil end
    if plan and #plan == 0 then return BuildAhead.tryBuildSite(playerObj, site) end
    if plan then
        claimSite(site)
        if BuildAheadFetch.start(playerObj, site, plan) then return true end
    end
    if hasMaterials(playerObj, site) then return BuildAhead.tryBuildSite(playerObj, site) end
    return false
end

local function startNext()
    local p = pending
    local playerObj = p.player
    -- a fetch job builds its site itself; the chain goes on after that build
    if BuildAheadFetch.isActive(playerObj) then
        pending = nil
        return
    end
    if #actionQueue(playerObj) > 0 then
        if getTimestampMs() - p.since > p.wait then pending = nil end
        return
    end
    pending = nil
    local site = BuildAhead.pickNext(playerObj, p.x, p.y, p.z)
    if not site then
        log("scheduler: nothing buildable in range")
        skipped = {}
        BuildAheadFetch.endChain(playerObj)
        return
    end
    if not BuildAhead.buildSite(playerObj, site) then
        -- cannot walk there: try the next one
        skipped[skipKey(site)] = true
        pending = { player = playerObj, x = p.x, y = p.y, z = p.z, since = getTimestampMs(), wait = p.wait }
        startNext()
    end
end

-- build the nearest buildable site around (x, y, z) as soon as the player is
-- free: right away when idle, else once the current actions are done
function BuildAhead.schedule(playerObj, x, y, z, waitMs)
    BuildAheadFetch.beginChain(playerObj)
    pending = { player = playerObj, x = x, y = y, z = z, since = getTimestampMs(),
        wait = waitMs or BuildAhead.START_WAIT_MS }
    if #actionQueue(playerObj) == 0 then startNext() end
end

-- a fetch job gave up on a site: skip it and go on with the next one
function BuildAhead.onFetchFailed(playerObj, site, why)
    skipped[skipKey(site)] = true
    directSites[site.id] = nil
    unclaimSite(site)
    if cache[site.id] then cache[site.id].gatherAt = nil end
    playerObj:setHaloNote(getText("IGUI_BuildAhead_FetchFailed"), 255, 180, 80, 300)
    pending = { player = playerObj, x = math.floor(playerObj:getX()), y = math.floor(playerObj:getY()),
        z = math.floor(playerObj:getZ()), since = getTimestampMs(), wait = BuildAhead.START_WAIT_MS }
end

-- ---------------------------------------------------------------- cursor hooks

local function sameAsCurrentBuild(playerObj, name, x, y, z)
    local _, current = BuildAhead.isBuilding(playerObj)
    return current and current.x == x and current.y == y and current.z == z
        and current.item and current.item.objectInfo and current.item.objectInfo:getName() == name
end

local function onCursorClick(cursor, x, y, z)
    local playerObj = cursor.character
    local name = cursor.objectInfo:getName()
    if sameAsCurrentBuild(playerObj, name, x, y, z) then return end
    local site = BuildAhead.addSite(name, x, y, z, cursor.nSprite)
        or BuildAheadSites.find(BuildAheadSites.data(), name, x, y, z, cursor.nSprite)
    local reason = site and BuildAhead.cannotBuildReason(playerObj, site)
    -- an upgrade planned on a planned stage waits for that stage: nothing to say
    if reason == getText("IGUI_BuildAhead_Blocked") and BuildAhead.onPlannedStage(cursor, getCell():getGridSquare(x, y, z)) then
        reason = nil
    end
    if reason then playerObj:setHaloNote(reason, 255, 220, 80, 300) end
    -- while building, the chain picks the next site when the build ends
    if not BuildAhead.isBusy(playerObj) then
        BuildAhead.schedule(playerObj, math.floor(playerObj:getX()), math.floor(playerObj:getY()),
            math.floor(playerObj:getZ()), BuildAhead.CLICK_WAIT_MS)
    end
end

-- the type of the sprite of an entity's first tile (IsoObjectType), or nil
local function faceSpriteType(e)
    local ok, t = pcall(function()
        return getSprite(e:getFace():getTileInfo(0, 0, 0):getSpriteName()):getType()
    end)
    return ok and t or nil
end

local function isDoorEntity(e)
    local t = faceSpriteType(e)
    return t ~= nil and (t == IsoObjectType.doorW or t == IsoObjectType.doorN)
end

local function isDoorFrameEntity(e)
    local t = faceSpriteType(e)
    if t ~= nil and (t == IsoObjectType.doorFrW or t == IsoObjectType.doorFrN) then return true end
    local ok, yes = pcall(function()
        local props = getSprite(e:getFace():getTileInfo(0, 0, 0):getSpriteName()):getProperties()
        return props:has(IsoPropertyType.DOOR_WALL_N) or props:has(IsoPropertyType.DOOR_WALL_W)
    end)
    return ok and yes == true
end

-- An upgrade (a wall or window frame on a wall frame, a door in a door frame) may
-- be planned on a planned site of the stage it needs, before that stage is
-- built: the cursor accepts the square, and the new site stays red (blocked)
-- until the stage below exists; then the chain builds it.
local function onPlannedStage(cursor, square)
    if not square or not cursor.objectInfo then return false end
    local stages = cursor.previousStages
    local hasStages = stages ~= nil and stages:size() > 0
    local door = not hasStages and isDoorEntity(cursor)
    if not hasStages and not door then return false end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local name = cursor.objectInfo:getName()
    for _, site in ipairs(BuildAhead.getSites()) do
        if site.x == x and site.y == y and site.z == z and site.name ~= name then
            local e = siteEntity(cursor.character, site)
            if e and e.north == cursor.north then
                if hasStages then
                    for i = 0, stages:size() - 1 do
                        if string.lower(stages:get(i)) == string.lower(site.name) then return true end
                    end
                elseif isDoorFrameEntity(e) then
                    return true
                end
            end
        end
    end
    return false
end
BuildAhead.onPlannedStage = onPlannedStage

local function hookCursor()
    local origIsValid = ISBuildIsoEntity.isValid
    function ISBuildIsoEntity:isValid(square, ...)
        local planning = plansSites(self)
        -- a site the player lacks the skill for would never be built: stay red, as in vanilla
        if planning and not hasSkills(self.character, cursorRecipe(self)) then
            return origIsValid(self, square, ...)
        end
        local valid
        if self.blockBuild and planning then
            -- planning ignores "craft in progress" and missing materials
            self.blockBuild = false
            local ok, v = pcall(origIsValid, self, square, ...)
            self.blockBuild = true
            valid = ok and v
        else
            valid = origIsValid(self, square, ...)
        end
        if not valid and planning then
            local ok, yes = pcall(onPlannedStage, self, square)
            if ok and yes then return true end
        end
        return valid
    end

    local origTryBuild = ISBuildIsoEntity.tryBuild
    function ISBuildIsoEntity:tryBuild(x, y, z, ...)
        if plansSites(self) then
            if not hasSkills(self.character, cursorRecipe(self)) then
                local skills = missingSkills(self.character, { name = self.objectInfo:getName() })
                self.character:setHaloNote(getText("IGUI_BuildAhead_NeedSkill", table.concat(skills, ", ")), 255, 100, 100, 300)
                return
            end
            onCursorClick(self, x, y, z)
            return
        end
        return origTryBuild(self, x, y, z, ...)
    end
end

-- ---------------------------------------------------------------- chain

local function hookBuildAction()
    -- the containers at hand where the player stands now: the entity got them
    -- before walking, and fetched materials lie on the floor here
    local origStart = ISBuildAction.start
    function ISBuildAction:start(...)
        local item, playerObj = self.item, self.character
        if item and item.buildAheadSite and item.buildPanelLogic and playerObj and playerObj:isLocalPlayer()
            and not playerObj:isBuildCheat() then
            local ok, err = pcall(function()
                local containers = BuildAhead.freshContainers(playerObj)
                local logic = item.buildPanelLogic
                item.containers = containers
                logic:setContainers(containers)
                fillInputs(logic, playerObj, containers)
                -- startCraftAction copied the inputs chosen before walking
                logic:stopCraftAction()
                logic:startCraftAction(self)
                log("build start: inputs", BuildAhead.describeInputs(logic), "player at",
                    math.floor(playerObj:getX()), math.floor(playerObj:getY()))
            end)
            if not ok then log("build start refresh error", err) end
        end
        return origStart(self, ...)
    end

    -- a scheduler build that ends without being performed (rejected, interrupted):
    -- the site stays planned and is free for other players' chains again
    for _, name in ipairs({ "stop", "forceStop" }) do
        local orig = ISBuildAction[name]
        ISBuildAction[name] = function(self, ...)
            if self.item and self.item.buildAheadSite then
                log("build action", name, "at", self.x, self.y, self.z)
                local objName = self.item.objectInfo and self.item.objectInfo:getName()
                local site = objName and siteOn(objName, self.x, self.y, self.z)
                if site then
                    directSites[site.id] = nil
                    unclaimSite(site)
                end
            end
            return orig(self, ...)
        end
    end

    local origPerform = ISBuildAction.perform
    function ISBuildAction:perform(...)
        origPerform(self, ...)
        local playerObj = self.character
        if not playerObj or not playerObj:isLocalPlayer() then return end
        local name = self.item and self.item.objectInfo and self.item.objectInfo:getName()
        if name then
            -- a site built here (by the scheduler or by hand): skip it now, and remove it
            -- once the object is there; if it stays buildable the build failed
            for _, site in ipairs(BuildAhead.getSites()) do
                if site.name == name and site.x == self.x and site.y == self.y and site.z == self.z then
                    skipped[skipKey(site)] = true
                    directSites[site.id] = nil
                    break
                end
            end
            table.insert(checks, { name = name, x = self.x, y = self.y, z = self.z,
                at = getTimestampMs() + BuildAhead.CHECK_DELAY_MS, refresh = self.item.buildAheadSite })
        end
        if self.item and self.item.buildAheadSite then refreshBuildPanel(playerObj) end
        -- the new object changes what the other sites would close off
        for _, c in pairs(cache) do c.trapAt = nil end
        if #BuildAhead.getSites() > 0 then
            pending = { player = playerObj, x = self.x, y = self.y, z = self.z, since = getTimestampMs(),
                wait = BuildAhead.START_WAIT_MS }
        end
    end
end

local function runChecks()
    local now = getTimestampMs()
    local playerObj = getSpecificPlayer(0)
    for i = #checks, 1, -1 do
        local c = checks[i]
        if now >= c.at then
            table.remove(checks, i)
            -- by square, not id: in multiplayer the server's list may have replaced a local id meanwhile
            for _, site in ipairs(playerObj and BuildAhead.getSites() or {}) do
                if site.name == c.name and site.x == c.x and site.y == c.y and site.z == c.z then
                    cache[site.id] = nil
                    if not isSiteValid(playerObj, site) then BuildAhead.removeSite(site.id) end
                    break
                end
            end
            -- in multiplayer the used materials leave the inventory a little after the action
            if c.refresh and playerObj then refreshBuildPanel(playerObj) end
        end
    end
end

local function onTick()
    BuildAheadFetch.update()
    if #checks > 0 then runChecks() end
    if pending then startNext() end
end

-- ---------------------------------------------------------------- ghosts

local function renderGhost(playerObj, site, now)
    local e = siteEntity(playerObj, site)
    if not e then return end
    local c = cache[site.id]
    if not c.checkedAt or (now - c.checkedAt > BuildAhead.VALIDITY_EVERY_MS and frameBudget.states > 0) then
        if c.checkedAt then frameBudget.states = frameBudget.states - 1 end
        c.checkedAt = now
        c.state = BuildAhead.siteState(playerObj, site)
    end
    local face = e:getFace()
    if not face then return end
    local color = c.state == "buildable" and BuildAhead.COLOR
        or c.state == "missing" and BuildAhead.COLOR_MISSING
        or c.state == "trap" and BuildAhead.COLOR_TRAP or BuildAhead.COLOR_BLOCKED
    local a = 0.4 + 0.12 * math.sin(now / 350)
    for zz = 0, face:getzLayers() - 1 do
        for xx = 0, face:getWidth() - 1 do
            for yy = 0, face:getHeight() - 1 do
                local tileInfo = face:getTileInfo(xx, yy, zz)
                local name = tileInfo and tileInfo:getSpriteName()
                local sprite = name and getSprite(name)
                if sprite then
                    sprite:RenderGhostTileColor(site.x + xx, site.y + yy, site.z + zz, color[1], color[2], color[3], a)
                end
            end
        end
    end
end

-- the state the ghost was last drawn with (nil before the first draw)
function BuildAhead.ghostState(site)
    return cache[site.id] and cache[site.id].state
end

local function onPostRender()
    local playerObj = getSpecificPlayer(0)
    local sites = playerObj and BuildAhead.getSites()
    if not sites or #sites == 0 then return end
    -- the state needs the inventory windows (gone while quitting)
    if not getPlayerInventory(0) or not getPlayerLoot(0) then return end
    local now = getTimestampMs()
    local px, py = playerObj:getX(), playerObj:getY()
    local far = (BuildAhead.RANGE * 2) ^ 2
    frameBudget = { gather = BuildAhead.GATHER_PER_FRAME, states = BuildAhead.STATES_PER_FRAME }
    -- round robin: the sites the budget did not reach this frame come first next frame
    local n = #sites
    BuildAhead.renderStart = ((BuildAhead.renderStart or 0) % n) + 1
    for i = 0, n - 1 do
        local site = sites[((BuildAhead.renderStart + i - 1) % n) + 1]
        if (site.x - px) ^ 2 + (site.y - py) ^ 2 < far then
            local ok, err = pcall(renderGhost, playerObj, site, now)
            if not ok and not BuildAhead.renderErrorLogged then
                BuildAhead.renderErrorLogged = true
                log("ghost render error", err)
            end
        end
    end
    frameBudget = nil
end

-- ---------------------------------------------------------------- context menu

local function displayName(site)
    local info = objectInfoByName(site.name)
    local recipe = info and info:getRecipe() and info:getRecipe():getCraftRecipe()
    local ok, text = pcall(function() return recipe:getTranslationName() end)
    if ok and text and text ~= "" then return text end
    return site.name
end

-- sites whose footprint covers the square
function BuildAhead.sitesAt(playerObj, x, y, z)
    local out = {}
    for _, site in ipairs(BuildAhead.getSites()) do
        local e = siteEntity(playerObj, site)
        local face = e and e:getFace()
        local w, h = face and face:getWidth() or 1, face and face:getHeight() or 1
        if z == site.z and x >= site.x and x < site.x + w and y >= site.y and y < site.y + h then
            out[#out + 1] = site
        end
    end
    return out
end

local function onCancelSite(site)
    BuildAhead.removeSite(site.id)
end

-- start the chain at a site by hand, e.g. after fetching the materials
-- an order by hand: built even if it walls the player in (a safe side is still preferred)
local function onBuildSite(site, playerObj)
    local reason = BuildAhead.cannotBuildReason(playerObj, site, true)
    if not reason then
        BuildAheadFetch.beginChain(playerObj)
        directSites[site.id] = true
    end
    if reason or not BuildAhead.buildSite(playerObj, site) then
        directSites[site.id] = nil
        playerObj:setHaloNote(reason or getText("IGUI_BuildAhead_CannotBuild"), 255, 100, 100, 300)
    end
end

local function onCancelNear(playerObj)
    local px, py = playerObj:getX(), playerObj:getY()
    local range2 = BuildAhead.RANGE * BuildAhead.RANGE
    local sites = BuildAhead.getSites()
    for i = #sites, 1, -1 do
        if (sites[i].x - px) ^ 2 + (sites[i].y - py) ^ 2 <= range2 then
            BuildAhead.removeSite(sites[i].id)
        end
    end
end

function BuildAhead.fillContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(playerNum)
    local obj = worldobjects and worldobjects[1]
    local sq = obj and obj:getSquare()
    if not playerObj or not sq then return end
    local here = BuildAhead.sitesAt(playerObj, sq:getX(), sq:getY(), sq:getZ())
    for _, site in ipairs(here) do
        -- an order by hand may wall the player in: allowed, with a warning
        local label = getText("IGUI_BuildAhead_BuildSite", displayName(site))
        local reason = BuildAhead.cannotBuildReason(playerObj, site, true)
        if not reason and BuildAhead.wouldTrap(playerObj, site) then
            label = label .. " " .. getText("IGUI_BuildAhead_MayTrap")
        end
        local build = context:addOption(label, site, onBuildSite, playerObj)
        -- greyed out with the reason, like vanilla options that cannot be done
        reason = build and reason
        if reason then
            build.notAvailable = true
            local tooltip = ISToolTip:new()
            tooltip:initialise()
            tooltip:setVisible(false)
            tooltip.description = reason
            build.toolTip = tooltip
        end
        -- cancelling is always possible
        context:addOption(getText("IGUI_BuildAhead_CancelSite", displayName(site)), site, onCancelSite)
    end
    if #here > 0 and #BuildAhead.getSites() > 1 then
        context:addOption(getText("IGUI_BuildAhead_CancelNear"), playerObj, onCancelNear)
    end
end

-- The build panel's Build button is off while a build runs or materials are
-- missing. Every click plans a site, so keep it on, unless the player lacks
-- the skill level: such a site could never be built.
local function hookBuildButton()
    if not ISWidgetBuildControl then return end
    local origPrerender = ISWidgetBuildControl.prerender
    function ISWidgetBuildControl:prerender(...)
        origPrerender(self, ...)
        local button = self.buttonCraft
        if button and not button.enable and self.logic:getSelectedBuildObject() ~= nil
            and hasSkills(self.player, self.logic:getRecipe()) then
            button.enable = true
        end
    end
end

-- a scheduler build whose stand square was chosen against self-enclosure walks
-- there, instead of to any square next to the object
local function hookWalkTo()
    local orig = ISBuildIsoEntity.walkTo
    function ISBuildIsoEntity:walkTo(x, y, z, ...)
        local stand = self.buildAheadSite and self.buildAheadStand
        if stand then return walkToStand(self.character, stand) end
        return orig(self, x, y, z, ...)
    end
end

-- A walk to a scheduler build that stops: when the player took over (a movement
-- or cancel key), the chain stops there; when the path failed (e.g. the only
-- squares to build from cannot be reached), the site is skipped and the chain
-- goes on with the next one. Either way the site stays planned and unclaimed.
local function onBuildWalkStopped(walk)
    local s = walk.buildAheadSite
    walk.buildAheadSite = nil
    local playerObj = walk.character
    local site = siteOn(s.name, s.x, s.y, s.z)
    if site then unclaimSite(site) end
    if walk.buildAheadTookOver or not walk.buildAheadStopInUpdate then
        -- the player took over, or another action cleared the queue
        if site then directSites[site.id] = nil end
        log("walk to site", site and site.id, "stopped by the player")
        return
    end
    log("walk to site", site and site.id, "failed: skipped")
    if site then
        skipped[skipKey(site)] = true
        directSites[site.id] = nil
    end
    pending = { player = playerObj, x = math.floor(playerObj:getX()), y = math.floor(playerObj:getY()),
        z = math.floor(playerObj:getZ()), since = getTimestampMs(), wait = BuildAhead.START_WAIT_MS }
end

local function hookWalks()
    for _, class in ipairs({ ISPathFindAction, ISWalkToTimedAction }) do
        local origUpdate, origForceStop, origStop = class.update, class.forceStop, class.stop
        -- vanilla stops the walk from update() both for a key press and for a failed path
        class.update = function(self, ...)
            if not self.buildAheadSite then return origUpdate(self, ...) end
            self.buildAheadTookOver = BuildAhead.tookOver(self.character)
            self.buildAheadInUpdate = true
            local ok, err = pcall(origUpdate, self, ...)
            self.buildAheadInUpdate = nil
            if not ok then
                -- don't rethrow: under -debug error() opens the debugger and freezes the game.
                -- Stop the walk like a takeover, so the chain stops instead of retrying.
                log("walk update error", err)
                self.buildAheadTookOver = true
                pcall(self.forceStop, self)
            end
        end
        class.forceStop = function(self, ...)
            if self.buildAheadInUpdate then self.buildAheadStopInUpdate = true end
            return origForceStop(self, ...)
        end
        class.stop = function(self, ...)
            if self.buildAheadSite and self.character and self.character:isLocalPlayer() then
                local ok, err = pcall(onBuildWalkStopped, self)
                if not ok then log("walk stop error", err) end
            end
            return origStop(self, ...)
        end
    end
end

local function installHooks()
    if BuildAhead.hooked or not ISBuildIsoEntity or not ISBuildAction then return end
    BuildAhead.hooked = true
    hookCursor()
    hookBuildButton()
    hookBuildAction()
    hookWalkTo()
    if ISPathFindAction and ISWalkToTimedAction then hookWalks() end
end

local function onGameStart()
    installHooks()
    if isClient() then
        ModData.request(BuildAheadSites.KEY)
        -- the server keeps each player's bans with its copy of the player
        local p = getSpecificPlayer(0)
        if p then sendClientCommand(p, "BuildAhead", "getBans", {}) end
    end
end

-- the server's copy of this player's bans, after "getBans": the server's list
-- wins when it has one, else the local list is sent up
local function onServerCommand(module, command, args)
    if module ~= "BuildAhead" or command ~= "bans" or type(args) ~= "table" then return end
    local p = getSpecificPlayer(0)
    if not p then return end
    if BuildAheadInputs.hasAny(args.bans) then
        local bans = {}
        for k, v in pairs(args.bans) do
            if v then bans[k] = true end
        end
        p:getModData()[BuildAhead.BAN_KEY] = bans
        for _, c in pairs(cache) do c.checkedAt = nil end
    elseif BuildAheadInputs.hasAny(BuildAhead.getBans(p)) then
        sendClientCommand(p, "BuildAhead", "bans", { bans = BuildAhead.getBans(p) })
    end
end

Events.OnGameStart.Add(onGameStart)
Events.OnReceiveGlobalModData.Add(onReceiveGlobalModData)
Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
Events.OnPostRender.Add(onPostRender)
Events.OnFillWorldObjectContextMenu.Add(BuildAhead.fillContextMenu)
