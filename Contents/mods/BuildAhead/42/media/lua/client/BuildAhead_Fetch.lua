-- Build Ahead, stage 2: fetching materials for a planned site.
--
-- Materials at hand are vanilla's: the inventory, the loot window's
-- containers and the floor in the 3x3 around the player. When a site is short,
-- the rest is searched within RANGE tiles of the site, on its level: floor
-- items, containers, corpses and vehicle trunks / truck beds (not seats or
-- glove boxes). Locked containers, other players' safehouses, banned item
-- types and sources that failed recently (blacklist) are left out.
--
-- A fetch job, per site: walk to the nearest source and take what is needed
-- (ISInventoryTransferAction, ISGrabItemAction for floor items), source after
-- source while the inventory and the worn bags have room (up to their
-- capacity: the player may be overloaded for the trip); then walk to the
-- site's stand square (BuildAhead.standFor: one square per site, kept for all
-- trips). When the room stopped the trip short, drop the load on the stand
-- square (spread over its 3x3 if a square is full) and go again; the last trip
-- keeps its load. What lies in the stand's 3x3 counts as at hand and is never
-- fetched. Once the materials are at hand (carried plus dropped), build
-- (BuildAhead.tryBuildSite).
-- Tools are kept in the inventory: a tool taken from a container (or the floor)
-- goes back there when the chain ends, and the weapon held before the chain
-- started is equipped again.
--
-- All steps are vanilla timed actions; the job polls the action queue on each
-- tick and checks what each step really did once the queue is empty.

require "BuildAhead_Inputs"

BuildAheadFetch = BuildAheadFetch or {}
local F = BuildAheadFetch

F.RANGE = 20                 -- tiles from the site
F.CHECK_EVERY_MS = 2000      -- how long a "can be gathered" answer is reused (ghosts, site choice)
F.BLACKLIST_MS = 5 * 60000   -- a source that failed is left out this long
F.SETTLE_MS = 400            -- after the queue empties: let multiplayer item moves arrive
F.MAX_TRIPS = 10
F.MAX_FAILURES = 5
F.FLOOR_CAP = 50             -- ISDropWorldItemAction refuses more weight per square

F.job = nil      -- the running fetch (or tool return) job
F.chain = nil    -- { player, primary, secondary, borrowed = { { id, src } } }
F.blacklist = {} -- source key -> time it may be used again
F.stats = { drops = 0, takes = 0, rehandled = 0 } -- drops queued, items taken, takes from where the site is built from (tests)

local function log(...)
    BuildAhead.log("fetch", ...)
end

local function now() return getTimestampMs() end

function F.isBlacklisted(key)
    local t = F.blacklist[key]
    if t and now() < t then return true end
    F.blacklist[key] = nil
    return false
end

function F.blacklistSource(src, why)
    F.blacklist[src.key] = now() + F.BLACKLIST_MS
    log("source failed, left out for now:", src.key, why or "")
end

-- ---------------------------------------------------------------- sources

local function lootAllowed(playerObj, sq)
    if not isClient() then return true end
    local ok, allowed = pcall(function() return SafeHouse.isSafehouseAllowLoot(sq, playerObj) end)
    return not ok or allowed
end

local function isLocked(playerObj, obj, container)
    if obj and instanceof(obj, "IsoThumpable") and obj:isLockedToCharacter(playerObj) then return true end
    local ok, locked = pcall(function() return container:isLockedToCharacter(playerObj) end)
    return ok and locked
end

-- a trunk or truck bed reachable from outside: not a seat or the glove box
local function isOutsidePart(part)
    local id = part:getId() or ""
    return part:getItemContainer() ~= nil and part:getArea() ~= nil
        and id ~= "GloveBox" and string.sub(id, 1, 4) ~= "Seat"
end

local function trunkDoor(vehicle)
    local part = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear")
    return part and part:getDoor() and part or nil
end

-- every source in the box x0..x1, y0..y1 on level cz (blacklist and exclusion not applied)
local function scanBox(playerObj, x0, y0, x1, y1, cz)
    local out = {}
    local cell = getCell()
    local vehicles = {}
    for x = x0, x1 do
        for y = y0, y1 do
            local sq = cell:getGridSquare(x, y, cz)
            if sq then
                local found = {}
                if sq:getWorldObjects():size() > 0 then
                    found[#found + 1] = { key = "f:" .. x .. "," .. y .. "," .. cz, kind = "floor" }
                end
                local objs = sq:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    for n = 0, o:getContainerCount() - 1 do
                        local c = o:getContainerByIndex(n)
                        if c and not c:isEmpty() and not isLocked(playerObj, o, c) then
                            found[#found + 1] = { key = "c:" .. x .. "," .. y .. "," .. cz .. ":" .. i .. ":" .. n,
                                kind = "container", container = c, obj = o }
                        end
                    end
                end
                local bodies = sq:getDeadBodys()
                for i = 0, (bodies and bodies:size() or 0) - 1 do
                    local b = bodies:get(i)
                    local c = b:getContainer()
                    if c and not c:isEmpty() and not b:isAnimal() then
                        found[#found + 1] = { key = "b:" .. x .. "," .. y .. "," .. cz .. ":" .. i,
                            kind = "corpse", container = c, obj = b }
                    end
                end
                local v = sq:getVehicleContainer()
                if v and not vehicles[v:getId()] and not v:getDriver() then
                    vehicles[v:getId()] = true
                    local door = trunkDoor(v)
                    local trunkLocked = v:isTrunkLocked() or (door and door:getDoor():isLocked())
                    for i = 0, v:getPartCount() - 1 do
                        local part = v:getPartByIndex(i)
                        if isOutsidePart(part) and not (trunkLocked and part:getId() ~= "TruckBedOpen")
                            and not part:getItemContainer():isEmpty() then
                            found[#found + 1] = { key = "v:" .. v:getId() .. ":" .. part:getId(),
                                kind = "vehicle", container = part:getItemContainer(), vehicle = v, part = part }
                        end
                    end
                end
                if #found > 0 and lootAllowed(playerObj, sq) then
                    for _, src in ipairs(found) do
                        src.sq, src.x, src.y, src.z = sq, x, y, cz
                        out[#out + 1] = src
                    end
                end
            end
        end
    end
    return out
end

F.SCAN_REUSE_MS = 2000 -- how long a shared scan is reused for "can be gathered" answers
F.SCAN_MARGIN = 10     -- a shared scan covers this much more around the site, for the sites nearby
F.stats.scans = 0
F.scanCache = nil      -- { x0, y0, x1, y1, z, at, list }

-- Every source within RANGE of (cx, cy) on level cz; `exclude` is a square
-- whose 3x3 is at hand already and not searched. reuse: the answer may come
-- from a scan made for a site nearby a moment ago (ghost colours and the choice
-- of the next site, which ask for many sites at once); a fetch that starts
-- always scans afresh.
function F.scan(playerObj, cx, cy, cz, exclude, reuse)
    local r = F.RANGE
    local list
    local c = F.scanCache
    if reuse and c and c.z == cz and now() - c.at < F.SCAN_REUSE_MS and c.player == playerObj
        and cx - r >= c.x0 and cx + r <= c.x1 and cy - r >= c.y0 and cy + r <= c.y1 then
        list = c.list
    else
        local m = reuse and F.SCAN_MARGIN or 0
        local x0, y0, x1, y1 = cx - r - m, cy - r - m, cx + r + m, cy + r + m
        list = scanBox(playerObj, x0, y0, x1, y1, cz)
        F.stats.scans = F.stats.scans + 1
        if reuse then
            F.scanCache = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, z = cz, at = now(), list = list, player = playerObj }
        end
    end
    local out = {}
    for _, src in ipairs(list) do
        -- a vehicle is found on its first square in the box: allow for its length
        local rr = src.kind == "vehicle" and r + 3 or r
        if math.abs(src.x - cx) <= rr and math.abs(src.y - cy) <= rr
            and not (exclude and cz == exclude.z and math.abs(src.x - exclude.x) <= 1 and math.abs(src.y - exclude.y) <= 1)
            and not F.isBlacklisted(src.key) then
            -- a copy: planning marks its sources (distance, reachable)
            local copy = {}
            for k, v in pairs(src) do copy[k] = v end
            out[#out + 1] = copy
        end
    end
    return out
end

-- { item = InventoryItem, wo = IsoWorldInventoryObject or nil }, top level only
function F.sourceItems(src)
    local out = {}
    if src.kind == "floor" then
        local wobs = src.sq:getWorldObjects()
        for i = 0, wobs:size() - 1 do
            local wo = wobs:get(i)
            if wo:getItem() then out[#out + 1] = { item = wo:getItem(), wo = wo } end
        end
    else
        local items = src.container:getItems()
        for i = 0, items:size() - 1 do out[#out + 1] = { item = items:get(i) } end
    end
    return out
end

local function playerNear(playerObj, sq)
    local psq = playerObj:getCurrentSquare()
    return psq ~= nil and psq:getZ() == sq:getZ() and math.abs(psq:getX() - sq:getX()) <= 1
        and math.abs(psq:getY() - sq:getY()) <= 1 and (psq == sq or psq:canReachTo(sq))
end

-- cheap check before planning; a path that fails later blacklists the source
function F.reachable(playerObj, src)
    if src.kind == "vehicle" then return src.part:getArea() ~= nil end
    if playerNear(playerObj, src.sq) then return true end
    return AdjacentFreeTileFinder.Find(src.sq, playerObj) ~= nil
end

-- ---------------------------------------------------------------- plan

-- inputs of the logic's recipe that its current fill leaves short
local function usable(s, item, playerObj, bans)
    local t = item:getFullType()
    if not s.types[t] or bans[t] or not ISBuildIsoEntity.predicateMaterial(item) then return false end
    local ok, can = pcall(function() return s.input:canUseItem(item, playerObj) end)
    return not ok or can
end

local function amountOf(s, item)
    if s.uses and instanceof(item, "DrainableComboItem") then return item:getCurrentUses() end
    return 1
end

-- Inputs of the logic's recipe that its fill leaves unsatisfied, with how much
-- is still short. The fill assigns nothing to an input it cannot satisfy in
-- full, so what is there already is counted here from `base` (the containers
-- the logic was filled from); `taken` gets the ids counted.
function F.shortInputs(logic, base, bans, playerObj, taken)
    local out = {}
    local recipe = logic:getRecipe()
    local inputs = recipe and recipe:getInputs()
    if not inputs then return out end
    local data = logic:getRecipeData()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        if not input:isAutomationOnly() and input:getResourceType() == ResourceType.Item then
            local d = data:getDataForInputScript(input)
            if not (d and d:isInputItemsSatisfied()) then
                local uses = not input:isItemCount()
                local types = {}
                local possible = input:getPossibleInputItems()
                for k = 0, possible:size() - 1 do types[possible:get(k):getFullName()] = true end
                local s = { input = input, uses = uses, types = types,
                    short = uses and input:getAmount() or input:getIntAmount(),
                    tool = input:isTool() or input:isKeep(),
                    name = possible:size() > 0 and possible:get(0):getDisplayName() or "?" }
                for c = 0, (base and base:size() or 0) - 1 do
                    for t in pairs(types) do
                        if s.short <= 0 then break end
                        local items = base:get(c):getAllTypeEvalRecurse(t, ISBuildIsoEntity.predicateMaterial)
                        for n = 0, items:size() - 1 do
                            local item = items:get(n)
                            if s.short <= 0 then break end
                            if not taken[item:getID()] and usable(s, item, playerObj, bans) then
                                taken[item:getID()] = true
                                s.short = s.short - amountOf(s, item)
                            end
                        end
                    end
                end
                if s.short > 0 then out[#out + 1] = s end
            end
        end
    end
    return out
end

local function distSq(playerObj, src)
    return (src.x + 0.5 - playerObj:getX()) ^ 2 + (src.y + 0.5 - playerObj:getY()) ^ 2
end

-- the source lies in the 3x3 of the square the site is built from, reachable
-- from there: the build takes from it without a trip
local function atHandOf(src, stand)
    if not stand or src.kind == "vehicle" or src.z ~= stand.z
        or math.abs(src.x - stand.x) > 1 or math.abs(src.y - stand.y) > 1 then
        return false
    end
    local sq = stand.sq
    return sq ~= nil and (sq == src.sq or sq:canReachTo(src.sq))
end

-- { x, y, z, sq } from an IsoGridSquare or a { x, y, z } table
local function standOf(s)
    if not s then return nil end
    if type(s) == "table" then
        return { x = s.x, y = s.y, z = s.z, sq = s.sq or getCell():getGridSquare(s.x, s.y, s.z) }
    end
    return { x = s:getX(), y = s:getY(), z = s:getZ(), sq = s }
end
F.standOf = standOf

-- What to fetch so that `logic` (filled from the materials at hand) can do its
-- recipe: { { src, items = { { item, wo, tool } } } }, nearest source first;
-- {} when nothing is short. nil and the names still missing ("Plank x2") when
-- the sources within range are not enough. atHand: the square the site is built
-- from; what lies in its 3x3 counts as there already and is not fetched.
-- reuse: see F.scan.
function F.plan(playerObj, logic, bans, cx, cy, cz, atHand, base, reuse)
    local taken = {}
    local shorts = F.shortInputs(logic, base, bans, playerObj, taken)
    if #shorts == 0 then return {} end
    local stand = standOf(atHand)
    local sources = F.scan(playerObj, cx, cy, cz, nil, reuse)
    -- materials lying where the site is built from: count them first
    local others = {}
    for _, src in ipairs(sources) do
        if atHandOf(src, stand) then
            for _, s in ipairs(shorts) do
                for _, e in ipairs(F.sourceItems(src)) do
                    if s.short <= 0 then break end
                    local id = e.item:getID()
                    if not taken[id] and usable(s, e.item, playerObj, bans) then
                        taken[id] = true
                        s.short = s.short - amountOf(s, e.item)
                    end
                end
            end
        else
            others[#others + 1] = src
        end
    end
    sources = others
    for _, src in ipairs(sources) do src.d = distSq(playerObj, src) end
    table.sort(sources, function(a, b) return a.d < b.d end)
    local picks = {}
    for _, s in ipairs(shorts) do
        for _, src in ipairs(sources) do
            if s.short <= 0 then break end
            if src.reachable ~= false then
                for _, e in ipairs(F.sourceItems(src)) do
                    if s.short <= 0 then break end
                    local id = e.item:getID()
                    if not taken[id] and usable(s, e.item, playerObj, bans) then
                        if src.reachable == nil then src.reachable = F.reachable(playerObj, src) end
                        if not src.reachable then break end
                        taken[id] = true
                        s.short = s.short - amountOf(s, e.item)
                        picks[src] = picks[src] or {}
                        table.insert(picks[src], { item = e.item, wo = e.wo, tool = s.tool })
                    end
                end
            end
        end
    end
    local missing = {}
    for _, s in ipairs(shorts) do
        if s.short > 0 then
            local n = math.ceil(s.short)
            missing[#missing + 1] = n > 1 and (s.name .. " x" .. n) or s.name
        end
    end
    if #missing > 0 then return nil, missing end
    local plan = {}
    for _, src in ipairs(sources) do
        if picks[src] then plan[#plan + 1] = { src = src, items = picks[src] } end
    end
    return plan
end

-- ---------------------------------------------------------------- job

local function actionQueue(playerObj)
    local q = ISTimedActionQueue.getTimedActionQueue(playerObj)
    return q and q.queue or {}
end

-- run fn, which queues timed actions, and remember them as the job's own
local function queueOwn(job, fn)
    local before = {}
    for _, a in ipairs(actionQueue(job.player)) do before[a] = true end
    local ok, res = pcall(fn)
    if not ok then log("error queueing actions", res) end
    for _, a in ipairs(actionQueue(job.player)) do
        if not before[a] then job.own[a] = true end
    end
    return ok and res ~= false
end

function F.isActive(playerObj)
    return F.job ~= nil and (playerObj == nil or F.job.player == playerObj)
end

-- the chain starts: remember the weapon in hand
function F.beginChain(playerObj)
    if F.chain and F.chain.player == playerObj then return end
    F.chain = { player = playerObj, primary = playerObj:getPrimaryHandItem(),
        secondary = playerObj:getSecondaryHandItem(), borrowed = {} }
end

-- Where fetched items go: the inventory, then the bags the player wears or
-- holds. Each is filled up to its capacity, as vanilla lets a transfer do:
-- the player may end up overloaded (slower) for the trip.
function F.carryContainers(playerObj)
    local inv = playerObj:getInventory()
    local out = { inv }
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if instanceof(it, "InventoryContainer") and it:getInventory() and playerObj:isEquipped(it) then
            out[#out + 1] = it:getInventory()
        end
    end
    return out
end

-- the item with this id in the inventory or a bag it carries
local function inInventory(playerObj, id)
    for _, c in ipairs(F.carryContainers(playerObj)) do
        local item = c:getItemById(id)
        if item then return item end
    end
end

-- weight a container can still take (getCapacityWeight lags behind items just
-- added; getContentsWeight counts them)
local function roomIn(playerObj, c)
    return c:getEffectiveCapacity(playerObj) - c:getContentsWeight()
end

-- weight the player can still take in the inventory and the bags it wears or holds
function F.freeWeight(playerObj)
    local free = 0
    for _, c in ipairs(F.carryContainers(playerObj)) do free = free + math.max(0, roomIn(playerObj, c)) end
    return free
end

-- Trip steps from a plan, as much as the inventory and the worn bags hold
-- (at least one item). Each item gets the container it goes into (e.dest).
local function tripSteps(job, plan)
    local p = job.player
    local inv = p:getInventory()
    local bins = {}
    for _, c in ipairs(F.carryContainers(p)) do
        -- what goes into a worn bag also weighs on the inventory, less the bag's reduction
        local bag = c ~= inv and c:getContainingItem()
        local keep = bag and instanceof(bag, "InventoryContainer") and (1 - bag:getWeightReduction() / 100) or 1
        bins[#bins + 1] = { c = c, free = roomIn(p, c), keep = keep, main = c == inv }
    end
    local main = bins[1]
    -- tools stay in the inventory itself (the build equips them from there), and
    -- floor items too: in multiplayer the server grabs into the inventory only
    local function place(w, mainOnly)
        for _, b in ipairs(bins) do
            if (b.main or not mainOnly) and w <= b.free and (b.main or w * b.keep <= main.free) then
                b.free = b.free - w
                if not b.main then main.free = main.free - w * b.keep end
                return b.c
            end
        end
    end
    local steps, full, count = {}, false, 0
    for _, entry in ipairs(plan) do
        local take = {}
        for _, e in ipairs(entry.items) do
            local dest = place(e.item:getUnequippedWeight(), e.tool or entry.src.kind == "floor")
            if not dest and count == 0 then dest = inv end
            if dest then
                count = count + 1
                e.dest = dest
                take[#take + 1] = e
            else
                -- left for the next trip; a lighter item further on may still fit
                full = true
            end
        end
        if #take > 0 then steps[#steps + 1] = { kind = "take", src = entry.src, items = take } end
    end
    if #steps == 0 then return nil end
    steps[#steps + 1] = { kind = "site" }
    -- another trip follows: leave the load at the site; on the last trip the
    -- build takes it from the inventory
    if full then steps[#steps + 1] = { kind = "drop" } end
    steps[#steps + 1] = { kind = "replan" }
    return steps, full
end

local function finish(job, why)
    if F.job == job then F.job = nil end
    log("job ended:", why)
end

-- the site cannot be done this way: the scheduler goes on with the next one
local function failSite(job, why)
    finish(job, "site " .. tostring(job.site and job.site.id) .. " given up: " .. why)
    if job.site then BuildAhead.onFetchFailed(job.player, job.site, why) end
end

-- start fetching for a site with a plan from BuildAhead.fetchPlan
function F.start(playerObj, site, plan)
    F.beginChain(playerObj)
    local job = { player = playerObj, site = site, own = {}, trips = 1, failures = 0, carried = {} }
    job.steps = tripSteps(job, plan)
    if not job.steps then
        log("site", site.id, "materials too heavy to carry")
        return false
    end
    F.job = job
    job.i = 1
    local n = 0
    local sources = 0
    for _, st in ipairs(job.steps) do
        if st.kind == "take" then n, sources = n + #st.items, sources + 1 end
    end
    log("site", site.id, "fetching", n, "items from", sources, "sources, room", string.format("%.1f", F.freeWeight(playerObj)))
    F.advance(job)
    return true
end

local function walkToSource(job, src)
    local p = job.player
    return queueOwn(job, function()
        if src.kind == "vehicle" then
            if src.vehicle:canAccessContainer(src.part:getIndex(), p) then return true end
            local action = ISPathFindAction:pathToVehicleArea(p, src.vehicle, src.part:getArea())
            ISTimedActionQueue.add(action)
            return true
        end
        return luautils.walkAdj(p, src.sq, true)
    end)
end

local function atSource(job, src)
    local p = job.player
    if src.kind == "vehicle" then return src.vehicle:canAccessContainer(src.part:getIndex(), p) end
    return playerNear(p, src.sq)
end

local function itemStillThere(src, e)
    if src.kind == "floor" then
        return e.wo:getSquare() == src.sq and src.sq:getWorldObjects():contains(e.wo)
    end
    return e.item:getContainer() == src.container
end

-- In multiplayer, item moves queued together fail after the first one (each
-- waits for its server transaction): there they are queued one at a time.
local function oneAtATime() return isClient() end

-- queue the next takes from st.pos on; 0 when none are left
local function queueTake(job, st)
    local p = job.player
    local inv = p:getInventory()
    local n = 0
    queueOwn(job, function()
        while (st.pos or 0) < #st.items do
            st.pos = (st.pos or 0) + 1
            local e = st.items[st.pos]
            if itemStillThere(st.src, e) then
                n = n + 1
                if st.src.kind == "floor" then
                    ISTimedActionQueue.add(ISGrabItemAction:new(p, e.wo, ISWorldObjectContextMenu.grabItemTime(p, e.wo)))
                else
                    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(p, e.item, st.src.container, e.dest or inv))
                end
                if oneAtATime() then break end
            end
        end
    end)
    return n
end

local function checkTake(job, st)
    local got, lost = 0, 0
    -- a source where the site is built from should have counted as at hand (tests)
    local stand = job.site and standOf(BuildAhead.keptStand(job.site))
    if atHandOf(st.src, stand) then F.stats.rehandled = F.stats.rehandled + 1 end
    for _, e in ipairs(st.items) do
        local id = e.item:getID()
        if inInventory(job.player, id) then
            got = got + 1
            F.stats.takes = F.stats.takes + 1
            job.carried[#job.carried + 1] = { id = id, tool = e.tool }
            if e.tool and F.chain then
                table.insert(F.chain.borrowed, { id = id, src = st.src })
            end
        else
            lost = lost + 1
        end
    end
    return got, lost
end

-- squares to drop on: the player's, then the rest of its 3x3 (not the site's own squares)
local function dropSquares(job)
    local p = job.player
    local psq = p:getCurrentSquare()
    local out = { psq }
    local site = job.site
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq = getCell():getGridSquare(psq:getX() + dx, psq:getY() + dy, psq:getZ())
            local onSite = sq and sq:getX() == site.x and sq:getY() == site.y and sq:getZ() == site.z
            if sq and sq ~= psq and not onSite and sq:TreatAsSolidFloor() and not psq:isBlockedTo(sq) then
                out[#out + 1] = sq
            end
        end
    end
    return out
end

-- queue the next drops of the carried materials; 0 when none are left
local function queueDrop(job)
    local p = job.player
    if not job.dropIds then
        -- tools stay in the inventory: the build equips them from there
        job.dropIds, job.dropLoad = {}, {}
        for _, c in ipairs(job.carried) do
            if not c.tool then job.dropIds[#job.dropIds + 1] = c.id end
        end
        job.carried = {}
        job.dropSquares = dropSquares(job)
    end
    local n = 0
    queueOwn(job, function()
        while #job.dropIds > 0 do
            local id = table.remove(job.dropIds, 1)
            local item = inInventory(p, id)
            if item and item:getContainer() ~= p:getInventory() then
                -- a bag item is dropped from the inventory: take it out first, drop it next time
                ISTimedActionQueue.add(ISInventoryTransferAction:new(p, item, item:getContainer(), p:getInventory()))
                table.insert(job.dropIds, 1, id)
                n = n + 1
                break
            elseif item then
                local w = item:getUnequippedWeight()
                for _, sq in ipairs(job.dropSquares) do
                    local cur = job.dropLoad[sq] or sq:getTotalWeightOfItemsOnFloor()
                    if cur + w <= F.FLOOR_CAP then
                        job.dropLoad[sq] = cur + w
                        ISTimedActionQueue.add(ISDropWorldItemAction:new(p, item, sq,
                            ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0, ZombRand(360), false))
                        F.stats.drops = F.stats.drops + 1
                        n = n + 1
                        break
                    end
                end
                if n > 0 and oneAtATime() then break end
            end
        end
    end)
    return n
end

local function nextStep(job)
    job.i = job.i + 1
    job.phase = nil
    F.advance(job)
end

local function sourceFailed(job, st, why)
    F.blacklistSource(st.src, why)
    job.failures = job.failures + 1
    if job.failures >= F.MAX_FAILURES then
        failSite(job, "too many failed sources")
        return
    end
    nextStep(job)
end

local function replan(job)
    local p = job.player
    local site = job.site
    if BuildAhead.hasMaterialsNow(p, site) then
        finish(job, "materials at site " .. site.id)
        if not BuildAhead.tryBuildSite(p, site) then BuildAhead.onFetchFailed(p, site, "build did not start") end
        return
    end
    if job.trips >= F.MAX_TRIPS then return failSite(job, "too many trips") end
    -- at hand: around the square the site is built from (where the player stands now)
    local plan, missing = BuildAhead.fetchPlan(p, site, BuildAhead.freshContainers(p),
        BuildAhead.keptStand(site) or p:getCurrentSquare())
    if not plan or #plan == 0 then
        if plan then
            -- the plan sees everything at hand but the build does not: say what it lacks
            pcall(function() log("site", site.id, "build lacks", BuildAhead.lackingNow(p, site)) end)
        end
        return failSite(job, plan and "materials not usable" or ("missing " .. table.concat(missing or {}, ", ")))
    end
    local steps = tripSteps(job, plan)
    if not steps then return failSite(job, "materials too heavy to carry") end
    job.trips = job.trips + 1
    job.steps, job.i, job.phase = steps, 1, nil
    log("site", site.id, "trip", job.trips)
    F.advance(job)
end

-- tool return and weapon steps at the end of the chain
local function returnStep(job, st)
    local p = job.player
    local item = inInventory(p, st.id)
    if not item then return nextStep(job) end
    local src = st.src
    if not job.phase then
        job.phase = "walk"
        local ok
        if src.kind == "container" then
            ok = queueOwn(job, function() return luautils.walkToContainer(src.container, p:getPlayerNum()) end)
        else
            ok = walkToSource(job, src)
        end
        if not ok then
            log("cannot walk back to", src.key, "with", item:getFullType())
            return nextStep(job)
        end
        return
    end
    if job.phase == "walk" then
        job.phase = "put"
        if not atSource(job, src) then
            log("could not get back to", src.key, "with", item:getFullType())
            return nextStep(job)
        end
        queueOwn(job, function()
            if item:isEquipped() then ISTimedActionQueue.add(ISUnequipAction:new(p, item, 50)) end
            if src.kind == "floor" then
                ISTimedActionQueue.add(ISDropWorldItemAction:new(p, item, src.sq,
                    ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0, ZombRand(360), false))
            else
                ISTimedActionQueue.add(ISInventoryTransferAction:new(p, item, p:getInventory(), src.container))
            end
        end)
        return
    end
    log("returned", item:getFullType(), "to", src.key)
    nextStep(job)
end

function F.advance(job)
    if F.job ~= job then return end
    local st = job.steps[job.i]
    if not st then return finish(job, "done") end
    local p = job.player
    if st.kind == "take" then
        if not job.phase then
            job.phase = "walk"
            if job.site then BuildAhead.claim(job.site) end
            if not walkToSource(job, st.src) then return sourceFailed(job, st, "no path") end
            return
        end
        if job.phase == "walk" then
            if not atSource(job, st.src) then
                -- vehicle trunk shut: open it once
                local door = st.src.kind == "vehicle" and trunkDoor(st.src.vehicle)
                if door and not job.opened and not door:getDoor():isOpen() and not door:getDoor():isLocked() then
                    job.opened = true
                    queueOwn(job, function() ISTimedActionQueue.add(ISOpenVehicleDoor:new(p, st.src.vehicle, door)) end)
                    return
                end
                return sourceFailed(job, st, "could not reach it")
            end
            job.opened = nil
            job.phase = "take"
            if queueTake(job, st) == 0 then return sourceFailed(job, st, "items gone") end
            return
        end
        if queueTake(job, st) > 0 then return end
        local got, lost = checkTake(job, st)
        log("took", got, "items from", st.src.key, lost > 0 and ("(" .. lost .. " failed)") or "")
        if lost > 0 then return sourceFailed(job, st, "transfer failed") end
        return nextStep(job)
    elseif st.kind == "site" then
        if not job.phase then
            job.phase = "walk"
            BuildAhead.claim(job.site)
            if not queueOwn(job, function() return BuildAhead.walkToSite(p, job.site) end) then
                return failSite(job, "no path to the site")
            end
            return
        end
        local psq = p:getCurrentSquare()
        if not psq or psq:getZ() ~= job.site.z or math.abs(psq:getX() - job.site.x) > 2
            or math.abs(psq:getY() - job.site.y) > 2 then
            -- the walk can be cut short (a zombie, a door): try once more
            job.siteWalks = (job.siteWalks or 0) + 1
            if job.siteWalks <= 1 and queueOwn(job, function() return BuildAhead.walkToSite(p, job.site) end) then
                return
            end
            return failSite(job, "could not reach the site")
        end
        job.siteWalks = nil
        return nextStep(job)
    elseif st.kind == "drop" then
        job.phase = "drop"
        if queueDrop(job) > 0 then return end
        job.dropIds, job.dropLoad, job.dropSquares = nil, nil, nil
        return nextStep(job)
    elseif st.kind == "replan" then
        return replan(job)
    elseif st.kind == "return" then
        return returnStep(job, st)
    elseif st.kind == "equip" then
        if not job.phase then
            job.phase = "equip"
            local item = st.item
            if item:getContainer() == p:getInventory() and p:getPrimaryHandItem() ~= item then
                queueOwn(job, function()
                    ISInventoryPaneContextMenu.equipWeapon(item, true, st.twoHands, p:getPlayerNum())
                end)
                return
            end
        end
        return nextStep(job)
    end
end

-- the chain is over: take borrowed tools back, then the weapon from before
function F.endChain(playerObj)
    local chain = F.chain
    if not chain or chain.player ~= playerObj or F.job then return end
    F.chain = nil
    local steps = {}
    for _, b in ipairs(chain.borrowed) do
        if inInventory(playerObj, b.id) then steps[#steps + 1] = { kind = "return", id = b.id, src = b.src } end
    end
    local weapon = chain.primary
    if weapon and playerObj:getPrimaryHandItem() ~= weapon and weapon:getContainer() == playerObj:getInventory() then
        steps[#steps + 1] = { kind = "equip", item = weapon, twoHands = chain.secondary == weapon }
    end
    if #steps == 0 then return end
    log("chain ended: returning", #chain.borrowed, "tools")
    F.job = { player = playerObj, own = {}, steps = steps, i = 1, ending = true }
    F.advance(F.job)
end

-- stop without queueing anything more (the player took over). The site stays
-- planned and unclaimed; what was carried stays in the inventory, and borrowed
-- tools go back when a later chain ends.
function F.abort(why)
    local job = F.job
    if not job then return end
    finish(job, "stopped: " .. why)
    if job.site then BuildAhead.unclaim(job.site) end
end

function F.update()
    local job = F.job
    if not job then return end
    local p = job.player
    if not p or p:isDead() then return F.abort("player gone") end
    if BuildAhead.tookOver(p) then return F.abort("player moved") end
    local q = actionQueue(p)
    for _, a in ipairs(q) do
        if not job.own[a] then return F.abort("another action") end
    end
    if #q > 0 then
        job.emptySince = nil
        return
    end
    local t = now()
    if not job.emptySince then
        job.emptySince = t
        return
    end
    if t - job.emptySince < F.SETTLE_MS then return end
    job.emptySince = nil
    local ok, err = pcall(F.advance, job)
    if not ok then
        log("error", err)
        if F.job == job then failSite(job, "error") end
    end
end
