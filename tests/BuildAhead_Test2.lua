-- Single-player in-game test, part 2 (test environment only: pzt installs this file next to
-- BuildAhead_Test.lua, see TEST_FILES in pzt.conf). Runs after part 1 in the same game
-- (BuildAheadTest2.start / poll); each scenario is a coroutine in its own free area, and a
-- scenario that fails or times out ends at once and the next one starts.
-- Vanilla's build walks are on (ISBuildMenu.cheat off, as in a normal game; -debug turns it on).
--   T1 build types: door frame + door, wall frame + window frame, wall frame + wall (upgrades
--      planned through the cursor on a planned frame, red until the frame exists), a two-tile
--      table, stairs (vanilla walks to their bottom end); objects, materials, sites, order;
--      the player's build cursor is kept when the scheduler starts a build
--   T2 upper floors: a floor on level 1 next to a floor strip, then a wall frame on it; a floor
--      whose only square to build from is an unreachable floor island is skipped and the
--      chain goes on; the player never stands on a square without a floor
--   T3 material sources: a closed, unlocked car trunk (opened) and a corpse; a locked trunk
--      is left alone
--   T4 interruption: moving while walking to a source, another action while carrying the
--      materials to the site, moving while walking to a build: the chain stops, the site
--      stays planned and unclaimed, nothing is lost; "Build planned" or a click resumes
--   T5 many sites: 64 planned sites, frame time and the cost of the state checks; the chain
--      still builds the nearest site first
--   T7 furniture stand: materials lying two squares from a crate are used where they lie (the
--      crate is built from the square next to it whose 3x3 holds them), nothing is fetched
--   T8 stacked crates: three clicks on one square plan three levels, the third ghost sits on
--      two, a fourth is refused; the chain builds all three on that square and stops
--   T8b stacked crates built while the level below is still listed (CHECK_DELAY_MS raised):
--      each build counts for its own level, no level is built twice, all sites go
--   T9 materials for the next sites: four crates, materials in one container: a trip brings
--      the next sites' materials while the inventory holds them (fewer trips), never into a bag
--   T6 persistence, part 1: sites and a ban are left for the reload run
--      (BuildAheadTest2.reloadStart / reloadPoll, a second `pzt run KEEP_SAVE=1`)
-- Results: "[BuildAheadTest2]" lines; failures also as "[PZTest] FAIL".

require "BuildAhead"

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAheadTest2] " .. table.concat(parts, " "))
end

local R = { pass = 0, fail = 0, phase = "idle", performed = {} }

local function harness() return PZTest ~= nil and PZTest.active() end

local function check(label, ok, extra)
    if ok then R.pass = R.pass + 1 else R.fail = R.fail + 1 end
    log(ok and "PASS" or "FAIL", label, extra or "")
    if not ok and harness() then PZTest.fail("BuildAheadTest2 " .. label .. " " .. tostring(extra or "")) end
    return ok
end

local function player() return getSpecificPlayer(0) end

local function queue(p) return ISTimedActionQueue.getTimedActionQueue(p or player()).queue end

-- ---------------------------------------------------------------- coroutine helpers

local function wait(n)
    for _ = 1, n do coroutine.yield() end
end

local diag -- defined below

-- End the running scenario here (its failure is already recorded): no error(), which
-- under -debug opens the Lua debugger and pauses the game. The scenario's coroutine
-- just waits; the runner sees R.aborted and starts the next scenario.
local function abort(why)
    R.aborted = why
    while true do coroutine.yield() end
end

-- give up (fail the scenario) when cond stays false for limit frames
local function waitFor(cond, limit, label)
    local t = 0
    while not cond() do
        t = t + 1
        if t > limit then
            check(label .. " in time", false, diag())
            abort("timeout: " .. label)
        end
        coroutine.yield()
    end
    return t
end

local function busy(p)
    return BuildAhead.isBusy(p) or #queue(p) > 0
end

-- what the player is doing, for a timeout
diag = function()
    local p = player()
    local types = {}
    for _, a in ipairs(queue(p)) do types[#types + 1] = tostring(a.Type) end
    local job = BuildAheadFetch.job
    local okP, paused = pcall(isGamePaused)
    return "speed " .. tostring(getGameSpeed()) .. " paused " .. tostring(okP and paused) .. " at " .. math.floor(p:getX()) .. "," .. math.floor(p:getY())
        .. "," .. math.floor(p:getZ()) .. " queue " .. table.concat(types, ",") .. " fetch " .. tostring(job ~= nil)
end

-- until the player has been idle for `settle` frames (3 s)
local function waitIdle(limit, label, settle)
    local p, idle, t = player(), 0, 0
    settle = settle or 180
    while idle < settle do
        t = t + 1
        if t > limit then
            check(label .. " finished in time", false, diag())
            abort("timeout: " .. label)
        end
        if busy(p) then idle = 0 else idle = idle + 1 end
        coroutine.yield()
    end
end

-- ---------------------------------------------------------------- world helpers

local function entityInfo(name)
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if i:getName() == name then return i end
    end
end

-- the build panel's cursor, as ISBuildPanel:createBuildIsoEntity makes it
local function makeCursor(info, nSprite)
    local p = player()
    local c = ISBuildIsoEntity:new(p, info, nSprite or 1, ISInventoryPaneContextMenu.getContainers(p))
    c.player = 0
    c.dragNilAfterPlace = false
    c.blockAfterPlace = true
    local recipe = info:getRecipe():getCraftRecipe()
    c.firstItem = recipe:getToolRight() and "Base.BallPeenHammerForged" or nil
    c:getSprite()
    return c
end

local function sq(x, y, z) return getCell():getGridSquare(x, y, z) end

local function objectsAt(x, y, z)
    local s = sq(x, y, z)
    local out = {}
    if s then
        local objs = s:getObjects()
        for i = 0, objs:size() - 1 do
            local n = objs:get(i):getName()
            if n then out[#out + 1] = n end
        end
    end
    return table.concat(out, ",")
end

local function hasObject(x, y, z, name)
    return string.find("," .. objectsAt(x, y, z) .. ",", "," .. name .. ",", 1, true) ~= nil
end

local function siteAt(name, x, y, z)
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.name == name and s.x == x and s.y == y and s.z == z then return s end
    end
end

local function clearSites()
    local sites = BuildAhead.getSites()
    for i = #sites, 1, -1 do BuildAhead.removeSite(sites[i].id) end
end

local function isHammer(item)
    local ok, yes = pcall(function() return item:hasTag(ItemTag.HAMMER) end)
    return ok and yes
end

local function hammerCount(container)
    local n = 0
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        if isHammer(items:get(i)) then n = n + 1 end
    end
    return n
end

local MATS = { "Base.Plank", "Base.Nails", "Base.Hinge", "Base.Doorknob", "Base.LongStick", "Base.Sapling",
    "Base.Log", "Base.RippedSheets", "Base.Pencil", "Base.BaseballBat" }

-- empty hands, no building materials or hammers in the bag
local function clearBag()
    local p = player()
    p:setPrimaryHandItem(nil)
    p:setSecondaryHandItem(nil)
    local inv = p:getInventory()
    local items = inv:getItems()
    local drop = {}
    for _, t in ipairs(MATS) do drop[t] = true end
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        if drop[it:getFullType()] or isHammer(it) then inv:DoRemoveItem(it) end
    end
end

local function count(container, fullType) return container:getCountTypeRecurse(fullType) end
local function invCount(fullType) return count(player():getInventory(), fullType) end

local function addTo(container, fullType, n)
    for _ = 1, n do container:AddItem(fullType) end
end

-- the materials a recipe consumes (not its tools): { [fullType] = n }
local function cost(info, into)
    into = into or {}
    local inputs = info:getRecipe():getCraftRecipe():getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        if input:getResourceType() == ResourceType.Item and not input:isAutomationOnly()
            and not input:isTool() and not input:isKeep() then
            local t = input:getPossibleInputItems():get(0):getFullName()
            into[t] = (into[t] or 0) + input:getIntAmount()
        end
    end
    return into
end

local function costText(c)
    local out = {}
    for t, n in pairs(c) do out[#out + 1] = t .. " x" .. n end
    return table.concat(out, " ")
end

local function teleport(x, y, z)
    local p = player()
    if harness() then
        PZTest.teleport(x + 0.5, y + 0.5, z)
    else
        p:teleportTo(x + 0.5, y + 0.5, z)
    end
end

local function playerSq()
    local s = player():getCurrentSquare()
    return s and (s:getX() .. "," .. s:getY() .. "," .. s:getZ()) or "?"
end

local function freeSquare(s)
    return s and s:isFree(false) and s:TreatAsSolidFloor() and s:getObjects():size() <= 1
        and s:getWorldObjects():size() == 0 and not s:getRoom() and not s:HasStairs()
        and not s:getVehicleContainer() and s:getDeadBodys():size() == 0
end

-- w x h free outdoor squares from (x0, y0), nothing between them
local function openArea(x0, y0, z, w, h)
    for x = x0, x0 + w - 1 do
        for y = y0, y0 + h - 1 do
            local s = sq(x, y, z)
            if not freeSquare(s) then return false end
            local east, south = sq(x + 1, y, z), sq(x, y + 1, z)
            if x < x0 + w - 1 and (not east or s:isBlockedTo(east)) then return false end
            if y < y0 + h - 1 and (not south or s:isBlockedTo(south)) then return false end
        end
    end
    return true
end

-- the nearest free w x h area around the player (its top left corner), searched ring by ring
local function findArea(w, h, label)
    local p = player()
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), 0
    for r = 3, 42 do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r and openArea(px + dx, py + dy, pz, w, h) then
                    log("area", label, px + dx, py + dy, pz, w .. "x" .. h)
                    return { x = px + dx, y = py + dy, z = pz }
                end
            end
        end
        coroutine.yield()
    end
    check(label .. ": free " .. w .. "x" .. h .. " area", false)
    abort("no area for " .. label)
end

local function newCrate(s)
    local obj = IsoThumpable.new(getCell(), s, "carpentry_01_16", false, {})
    obj:setIsContainer(true)
    obj:getContainer():setType("crate")
    obj:setIsThumpable(true)
    s:AddSpecialObject(obj)
    return obj, obj:getContainer()
end

local function fakeMenu(x, y, z)
    local fake = { options = {} }
    function fake:addOption(name, target, fn, arg1)
        local o = { name = name, target = target, fn = fn, arg1 = arg1 }
        table.insert(self.options, o)
        return o
    end
    local s = sq(x, y, z)
    BuildAhead.fillContextMenu(0, fake, { s:getFloor() or s:getObjects():get(0) }, false)
    return fake.options
end

local function findOption(options, key)
    local prefix = getText(key, "")
    for _, o in ipairs(options) do
        if string.sub(o.name, 1, #prefix) == prefix then return o end
    end
end

-- "Build planned" from the site's right-click menu
local function buildPlanned(site)
    local opt = findOption(fakeMenu(site.x, site.y, site.z), "IGUI_BuildAhead_BuildSite")
    if opt and not opt.notAvailable then opt.fn(opt.target, opt.arg1) end
    return opt ~= nil and not opt.notAvailable
end

local function plan(info, nSprite, q, blocked)
    local c = makeCursor(info, nSprite)
    if blocked then c.blockBuild = true end
    c:tryBuild(q.x, q.y, q.z)
    return siteAt(info:getName(), q.x, q.y, q.z), c
end

-- builds performed, in order (test-only wrapper around the mod's own)
local function hookPerform()
    if R.hooked then return end
    R.hooked = true
    local orig = ISBuildAction.perform
    ISBuildAction.perform = function(self, ...)
        local name = self.item and self.item.objectInfo and self.item.objectInfo:getName()
        local p = self.character
        table.insert(R.performed, { name = name, x = self.x, y = self.y, z = self.z,
            px = p and math.floor(p:getX()), py = p and math.floor(p:getY()), pz = p and math.floor(p:getZ()) })
        return orig(self, ...)
    end
end

local function performedIndex(name, x, y, z)
    for i, b in ipairs(R.performed) do
        if b.name == name and b.x == x and b.y == y and b.z == z then return i, b end
    end
end

local function setupPlayer()
    local p = player()
    pcall(function() p:setGodMod(true) end)
    pcall(function() p:setInvisible(true) end)
    for _ = 1, 10 do
        if p:getPerkLevel(Perks.Woodwork) >= 10 then break end
        pcall(function() p:LevelPerk(Perks.Woodwork) end)
    end
    p:setMaxWeightBase(1000)
    p:setMaxWeight(1000)
    BuildAheadTrap.standFilter = nil
    for t in pairs(BuildAhead.getBans(p)) do BuildAhead.setBanned(p, t, false) end
end

-- ---------------------------------------------------------------- T1 build types

local function scenarioTypes()
    local p = player()
    clearSites()
    clearBag()
    local names = { "WoodenWallFrame", "WoodenWallLvl1", "WoodenWindowFrameLvl1", "WoodDoorFrameLvl1",
        "WoodenDoorLvl1", "Wood_TableLvl1", "Wood_Stairs" }
    local info = {}
    for _, n in ipairs(names) do
        info[n] = entityInfo(n)
        if not check("T1 recipe " .. n, info[n] ~= nil) then return end
    end
    local A = findArea(15, 11, "T1")
    teleport(A.x + 7, A.y + 6, 0)
    wait(60)
    local row = A.y + 3
    local P1, P2, P3, P4 = { x = A.x + 2, y = row, z = 0 }, { x = A.x + 5, y = row, z = 0 },
        { x = A.x + 8, y = row, z = 0 }, { x = A.x + 11, y = row, z = 0 }
    local P5 = { x = A.x + 2, y = A.y + 6, z = 0 }
    -- materials for everything, nothing more
    local need = {}
    cost(info.WoodenWallFrame, need)
    cost(info.WoodenWallFrame, need)
    for _, n in ipairs({ "WoodenWallLvl1", "WoodenWindowFrameLvl1", "WoodDoorFrameLvl1", "WoodenDoorLvl1",
        "Wood_TableLvl1", "Wood_Stairs" }) do cost(info[n], need) end
    log("T1 materials", costText(need))
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    for t, n in pairs(need) do addTo(inv, t, n) end
    R.performed = {}

    -- the player's own cursor stays when the scheduler starts building
    local own = makeCursor(info.WoodenWallFrame, 1)
    getCell():setDrag(own, 0)
    own:tryBuild(P1.x, P1.y, P1.z)
    local dragKept = getCell():getDrag(0) == own
    getCell():setDrag(nil, 0)
    check("T1 first click starts the chain", BuildAhead.isBusy(p))
    check("T1 the player's build cursor is kept when a scheduler build starts", dragKept)
    local frame1 = siteAt("WoodenWallFrame", P1.x, P1.y, P1.z)

    -- the wall on the planned frame: the cursor accepts the square, the site waits (red)
    local wallCursor = makeCursor(info.WoodenWallLvl1, 1)
    wallCursor.blockBuild = true
    check("T1 wall cursor valid on a planned frame", wallCursor:isValid(sq(P1.x, P1.y, P1.z)))
    local wallSite = plan(info.WoodenWallLvl1, 1, P1, true)
    check("T1 wall planned on the planned frame", frame1 ~= nil and wallSite ~= nil)
    check("T1 wall red until the frame exists", wallSite and BuildAhead.siteState(p, wallSite) == "blocked",
        wallSite and BuildAhead.siteState(p, wallSite))
    -- not on a bare square without a planned frame
    local bare = { x = A.x + 13, y = A.y + 8, z = 0 }
    check("T1 wall cursor still red on a bare square", not wallCursor:isValid(sq(bare.x, bare.y, bare.z)))

    plan(info.WoodenWallFrame, 1, P2, true)
    local winCursor = makeCursor(info.WoodenWindowFrameLvl1, 1)
    winCursor.blockBuild = true
    check("T1 window frame cursor valid on a planned frame", winCursor:isValid(sq(P2.x, P2.y, P2.z)))
    local winSite = plan(info.WoodenWindowFrameLvl1, 1, P2, true)
    plan(info.WoodDoorFrameLvl1, 1, P3, true)
    local doorCursor = makeCursor(info.WoodenDoorLvl1, 1)
    doorCursor.blockBuild = true
    check("T1 door cursor valid on a planned door frame", doorCursor:isValid(sq(P3.x, P3.y, P3.z)))
    local doorSite = plan(info.WoodenDoorLvl1, 1, P3, true)
    check("T1 door red until its frame exists", doorSite and BuildAhead.siteState(p, doorSite) == "blocked",
        doorSite and BuildAhead.siteState(p, doorSite))
    local tableCursor = makeCursor(info.Wood_TableLvl1, 1)
    local tw, th = tableCursor:getFace():getWidth(), tableCursor:getFace():getHeight()
    check("T1 table is a multi-tile object", tw * th >= 2, tw .. "x" .. th)
    local tableSite = plan(info.Wood_TableLvl1, 1, P4, true)
    local stairsCursor = makeCursor(info.Wood_Stairs, 1)
    local sw, sh = stairsCursor:getFace():getWidth(), stairsCursor:getFace():getHeight()
    check("T1 stairs cursor valid", stairsCursor:isValid(sq(P5.x, P5.y, P5.z)), sw .. "x" .. sh .. " north " .. tostring(stairsCursor.north))
    local stairsSite = plan(info.Wood_Stairs, 1, P5, true)
    check("T1 all sites planned", #BuildAhead.getSites() == 8 and winSite and tableSite and stairsSite,
        "sites " .. #BuildAhead.getSites())

    waitIdle(60 * 300, "T1 chain")
    for i, b in ipairs(R.performed) do
        log("T1 built", i, b.name, b.x, b.y, b.z, "player at", b.px, b.py, b.pz)
    end
    local function built(label, name, q)
        check("T1 " .. label .. " built", hasObject(q.x, q.y, q.z, name), objectsAt(q.x, q.y, q.z))
    end
    built("wall on the frame", "WoodenWallLvl1", P1)
    built("window frame on the frame", "WoodenWindowFrameLvl1", P2)
    built("door frame", "WoodDoorFrameLvl1", P3)
    built("door in the frame", "WoodenDoorLvl1", P3)
    built("table", "Wood_TableLvl1", P4)
    local tableTiles = 0
    for xx = 0, tw - 1 do
        for yy = 0, th - 1 do
            if hasObject(P4.x + xx, P4.y + yy, 0, "Wood_TableLvl1") then tableTiles = tableTiles + 1 end
        end
    end
    check("T1 table on all its tiles", tableTiles == tw * th, tableTiles .. " of " .. tw * th)
    built("stairs", "Wood_Stairs", P5)
    local stairTiles = 0
    for xx = 0, sw - 1 do
        for yy = 0, sh - 1 do
            if hasObject(P5.x + xx, P5.y + yy, 0, "Wood_Stairs") then stairTiles = stairTiles + 1 end
        end
    end
    check("T1 stairs on all three tiles", stairTiles == sw * sh, stairTiles .. " of " .. sw * sh)
    local iF = performedIndex("WoodenWallFrame", P1.x, P1.y, P1.z)
    local iW = performedIndex("WoodenWallLvl1", P1.x, P1.y, P1.z)
    check("T1 frame built before the wall on it", iF and iW and iF < iW, tostring(iF) .. " < " .. tostring(iW))
    local iF2 = performedIndex("WoodenWallFrame", P2.x, P2.y, P2.z)
    local iWin = performedIndex("WoodenWindowFrameLvl1", P2.x, P2.y, P2.z)
    check("T1 frame built before the window frame", iF2 and iWin and iF2 < iWin)
    local iDF = performedIndex("WoodDoorFrameLvl1", P3.x, P3.y, P3.z)
    local iD = performedIndex("WoodenDoorLvl1", P3.x, P3.y, P3.z)
    check("T1 door frame built before the door", iDF and iD and iDF < iD)
    -- vanilla walks to the bottom end of stairs: north stairs from x + 2, else from y + 2
    local _, sb = performedIndex("Wood_Stairs", P5.x, P5.y, P5.z)
    local bx, by = P5.x, P5.y + 2
    if stairsCursor.north then bx, by = P5.x + 2, P5.y end
    check("T1 stairs built from next to their bottom end", sb and math.max(math.abs(sb.px - bx), math.abs(sb.py - by)) <= 1,
        sb and (sb.px .. "," .. sb.py .. " bottom " .. bx .. "," .. by) or "not built")
    check("T1 all sites removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    local left = {}
    for t in pairs(need) do
        if invCount(t) > 0 then left[#left + 1] = t .. " x" .. invCount(t) end
    end
    check("T1 materials consumed", #left == 0, table.concat(left, " "))
    check("T1 eight builds performed", #R.performed == 8, "builds " .. #R.performed)
end

-- ---------------------------------------------------------------- T2 upper floors

local FLOOR = "carpentry_02_58"

local function upperSquare(x, y, floor)
    local s = sq(x, y, 1) or getCell():createNewGridSquare(x, y, 1, true)
    if floor and not s:getFloor() then s:addFloor(FLOOR) end
    return s
end

-- the player stands on a floor on level 1, checked every frame while R.footing is on
local function footingTick()
    local f = R.footing
    if not f then return end
    local p = player()
    local s = p:getCurrentSquare()
    local z = p:getZ()
    f.frames = f.frames + 1
    if z < f.minZ then f.minZ = z end
    if not s or s:getZ() ~= 1 or not s:TreatAsSolidFloor() then
        f.bad = f.bad + 1
        if not f.where then f.where = (s and (s:getX() .. "," .. s:getY() .. "," .. s:getZ()) or "nil") .. " z " .. z end
    end
end

local function scenarioUpper()
    local p = player()
    clearSites()
    clearBag()
    local floorInfo, frameInfo = entityInfo("WoodFloorLvl1"), entityInfo("WoodenWallFrame")
    if not check("T2 floor recipe", floorInfo ~= nil and frameInfo ~= nil) then return end
    local A = findArea(17, 7, "T2")
    local cx, cy = A.x + 7, A.y + 3
    -- level 1: a floor strip cx-3..cx+3 (the existing support), a gap, a floor island at cx+6;
    -- the squares around exist but have no floor
    for x = A.x, A.x + 16 do
        for y = A.y, A.y + 6 do upperSquare(x, y, false) end
    end
    for x = cx - 3, cx + 3 do upperSquare(x, cy, true) end
    upperSquare(cx + 6, cy, true)
    for x = A.x, A.x + 16 do
        for y = A.y, A.y + 6 do
            local s = sq(x, y, 1)
            if s then s:RecalcAllWithNeighbours(true) end
        end
    end
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    local need = cost(floorInfo, cost(floorInfo, cost(frameInfo)))
    for t, n in pairs(need) do addTo(inv, t, n) end
    teleport(cx + 3, cy, 1)
    wait(90)
    check("T2 player on the upper strip", math.floor(p:getZ()) == 1 and p:getCurrentSquare()
        and p:getCurrentSquare():TreatAsSolidFloor(), playerSq())
    R.footing = { frames = 0, bad = 0, minZ = 99 }
    R.performed = {}

    -- J: a floor whose only floor neighbour is the island, which cannot be reached
    local J, K = { x = cx + 6, y = cy + 1, z = 1 }, { x = cx - 4, y = cy, z = 1 }
    local fc = makeCursor(floorInfo, 1)
    check("T2 floor cursor valid next to the island", fc:isValid(sq(J.x, J.y, 1)))
    check("T2 floor cursor valid next to the strip", fc:isValid(sq(K.x, K.y, 1)))
    fc:tryBuild(J.x, J.y, J.z)
    local siteJ = siteAt("WoodFloorLvl1", J.x, J.y, J.z)
    fc.blockBuild = true
    fc:tryBuild(K.x, K.y, K.z)
    local siteK = siteAt("WoodFloorLvl1", K.x, K.y, K.z)
    check("T2 both floors planned", siteJ ~= nil and siteK ~= nil, "sites " .. #BuildAhead.getSites())
    waitIdle(60 * 120, "T2 floors")
    check("T2 floor next to the strip built", hasObject(K.x, K.y, 1, "WoodFloorLvl1") and sq(K.x, K.y, 1):TreatAsSolidFloor(),
        objectsAt(K.x, K.y, 1))
    check("T2 unreachable floor not built", not hasObject(J.x, J.y, 1, "WoodFloorLvl1"))
    check("T2 unreachable floor still planned", siteAt("WoodFloorLvl1", J.x, J.y, J.z) ~= nil)
    check("T2 unreachable floor left unclaimed", siteJ and siteJ.claimBy == nil, siteJ and tostring(siteJ.claimBy))

    -- a wall frame on the west edge of the new floor: one side has no floor
    local wc = makeCursor(frameInfo, 1)
    check("T2 wall frame cursor valid on the new floor", wc:isValid(sq(K.x, K.y, 1)), "north " .. tostring(wc.north))
    wc:tryBuild(K.x, K.y, K.z)
    check("T2 wall frame build started", BuildAhead.isBusy(p))
    waitIdle(60 * 120, "T2 wall")
    check("T2 wall frame built on the upper floor", hasObject(K.x, K.y, 1, "WoodenWallFrame"), objectsAt(K.x, K.y, 1))
    local f = R.footing
    R.footing = nil
    check("T2 player never on a square without a floor", f.bad == 0, "frames " .. f.frames .. " bad " .. f.bad
        .. " first " .. tostring(f.where))
    check("T2 player stayed on level 1 (no fall)", f.minZ >= 1 and math.floor(p:getZ()) == 1, "min z " .. f.minZ)
    for _, b in ipairs(R.performed) do
        local s = sq(b.px, b.py, b.pz)
        check("T2 " .. tostring(b.name) .. " built standing on a floor", s and s:TreatAsSolidFloor() and b.pz == 1,
            b.px .. "," .. b.py .. "," .. b.pz)
    end
    clearSites()
    teleport(A.x + 1, A.y + 1, 0)
    wait(60)
end

-- ---------------------------------------------------------------- T3 vehicles and corpses

local function trunkDoor(v)
    local part = v:getPartById("TrunkDoor") or v:getPartById("DoorRear")
    return part and part:getDoor() and part or nil
end

local function trunk(v)
    for i = 0, v:getPartCount() - 1 do
        local part = v:getPartByIndex(i)
        local id = part:getId() or ""
        if part:getItemContainer() and part:getArea() and id ~= "GloveBox" and string.sub(id, 1, 4) ~= "Seat" then
            return part
        end
    end
end

local function emptyContainer(c)
    local items = c:getItems()
    for i = items:size() - 1, 0, -1 do c:DoRemoveItem(items:get(i)) end
end

local function spawnCar(s, locked)
    local v = addVehicleDebug("Base.CarNormal", IsoDirections.E, nil, s)
    if not v then return nil end
    for i = 0, v:getPartCount() - 1 do
        local c = v:getPartByIndex(i):getItemContainer()
        if c then emptyContainer(c) end
    end
    local door = trunkDoor(v)
    pcall(function() v:setTrunkLocked(locked) end)
    if door then
        pcall(function() door:getDoor():setLocked(locked) end)
        pcall(function() door:getDoor():setOpen(false) end)
    end
    return v, trunk(v), door
end

local function scenarioSources()
    local p = player()
    clearSites()
    clearBag()
    local frameInfo = entityInfo("WoodenWallFrame")
    local A = findArea(22, 14, "T3")
    local site = { x = A.x + 11, y = A.y + 7, z = 0 }
    teleport(site.x, site.y + 2, 0)
    wait(60)
    p:getInventory():AddItem("Base.BallPeenHammerForged")
    -- the nearest source: a locked trunk with everything; then a closed unlocked trunk with
    -- the planks, and a corpse with the nails
    local lockedCar, lockedTrunk = spawnCar(sq(A.x + 17, A.y + 7, 0), true)
    local car, carTrunk, carDoor = spawnCar(sq(A.x + 4, A.y + 3, 0), false)
    if not check("T3 cars spawned", lockedCar ~= nil and car ~= nil and lockedTrunk ~= nil and carTrunk ~= nil,
        tostring(lockedTrunk and lockedTrunk:getId()) .. " " .. tostring(carTrunk and carTrunk:getId())) then
        return
    end
    log("T3 trunk", carTrunk:getId(), "door", carDoor and carDoor:getId(), "locked car trunk locked",
        tostring(lockedCar:isTrunkLocked()))
    addTo(lockedTrunk:getItemContainer(), "Base.Plank", 2)
    addTo(lockedTrunk:getItemContainer(), "Base.Nails", 2)
    addTo(carTrunk:getItemContainer(), "Base.Plank", 2)
    check("T3 trunk lid closed and unlocked", carDoor == nil or (not carDoor:getDoor():isOpen()
        and not carDoor:getDoor():isLocked() and not car:isTrunkLocked()))
    check("T3 locked trunk is locked", lockedCar:isTrunkLocked() or (trunkDoor(lockedCar)
        and trunkDoor(lockedCar):getDoor():isLocked()))
    local bodySq = sq(A.x + 11, A.y + 12, 0)
    pcall(createRandomDeadBody, bodySq, 0)
    wait(5)
    local bodies = bodySq:getDeadBodys()
    local body = bodies:size() > 0 and bodies:get(0) or nil
    if not check("T3 corpse spawned", body ~= nil and body:getContainer() ~= nil) then return end
    emptyContainer(body:getContainer())
    addTo(body:getContainer(), "Base.Nails", 2)
    local siteState
    BuildAhead.addSite("WoodenWallFrame", site.x, site.y, site.z, 1)
    local s = siteAt("WoodenWallFrame", site.x, site.y, site.z)
    siteState = s and BuildAhead.siteState(p, s)
    check("T3 site buildable from the trunk and the corpse", siteState == "buildable", tostring(siteState))
    local plan = BuildAhead.fetchPlan(p, s)
    local kinds = {}
    for _, e in ipairs(plan or {}) do kinds[#kinds + 1] = e.src.kind .. ":" .. e.src.key end
    log("T3 plan", table.concat(kinds, " "))
    check("T3 plan: trunk and corpse, not the locked trunk", plan and #plan == 2, table.concat(kinds, " "))
    check("T3 Build planned starts fetching", buildPlanned(s) and BuildAheadFetch.isActive(p))
    waitIdle(60 * 180, "T3 fetch")
    check("T3 frame built from the trunk and the corpse", hasObject(site.x, site.y, 0, "WoodenWallFrame"))
    check("T3 trunk emptied of planks", count(carTrunk:getItemContainer(), "Base.Plank") == 0,
        "planks " .. count(carTrunk:getItemContainer(), "Base.Plank"))
    check("T3 trunk lid was opened", carDoor == nil or carDoor:getDoor():isOpen())
    check("T3 corpse emptied of nails", count(body:getContainer(), "Base.Nails") == 0,
        "nails " .. count(body:getContainer(), "Base.Nails"))
    check("T3 locked trunk untouched", count(lockedTrunk:getItemContainer(), "Base.Plank") == 2
        and count(lockedTrunk:getItemContainer(), "Base.Nails") == 2)
    check("T3 materials consumed", invCount("Base.Plank") == 0 and invCount("Base.Nails") == 0,
        "planks " .. invCount("Base.Plank") .. " nails " .. invCount("Base.Nails"))
    check("T3 site removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
end

-- ---------------------------------------------------------------- T4 interruption

-- the player presses a movement key for a few frames (the stand-in for BuildAhead.tookOver)
local function pressMovement(frames)
    local orig = BuildAhead.tookOver
    BuildAhead.tookOver = function() return true end
    -- what the game does on a movement key: the current action stops, the queue empties
    local q = queue()
    if q[1] then q[1]:forceStop() end
    ISTimedActionQueue.clear(player())
    wait(frames or 5)
    BuildAhead.tookOver = orig
end

local function stillQuiet(frames, label)
    local p = player()
    local t = 0
    while t < frames do
        if busy(p) then return check(label, false, "busy after " .. t .. " frames") end
        t = t + 1
        coroutine.yield()
    end
    return check(label, true)
end

local function scenarioInterrupt()
    local p = player()
    clearSites()
    clearBag()
    local frameInfo = entityInfo("WoodenWallFrame")
    local A = findArea(25, 7, "T4")
    local W = { x = A.x + 3, y = A.y + 3, z = 0 }
    local W2 = { x = A.x + 5, y = A.y + 3, z = 0 }
    local crateSq = sq(A.x + 22, A.y + 3, 0)
    local _, crate = newCrate(crateSq)
    addTo(crate, "Base.BallPeenHammerForged", 1)
    addTo(crate, "Base.Plank", 4)
    addTo(crate, "Base.Nails", 4)
    teleport(A.x + 12, A.y + 3, 0)
    wait(60)

    -- a. moving while walking to the crate
    local siteW = plan(frameInfo, 1, W)
    check("T4a click starts fetching", siteW ~= nil and BuildAheadFetch.isActive(p))
    wait(40)
    check("T4a site claimed while fetching", siteW and siteW.claimBy == p:getUsername(), siteW and tostring(siteW.claimBy))
    pressMovement()
    check("T4a fetch stopped by moving", not BuildAheadFetch.isActive(p))
    check("T4a site still planned", siteAt("WoodenWallFrame", W.x, W.y, 0) ~= nil)
    check("T4a site unclaimed", siteW.claimBy == nil, tostring(siteW.claimBy))
    stillQuiet(240, "T4a nothing restarts on its own")
    check("T4a nothing taken from the crate", count(crate, "Base.Plank") == 4 and hammerCount(crate) == 1)

    -- b. another action while carrying the materials to the site
    check("T4b Build planned resumes", buildPlanned(siteW) and BuildAheadFetch.isActive(p))
    waitFor(function()
        local job = BuildAheadFetch.job
        local st = job and job.steps and job.steps[job.i]
        return st and st.kind == "site" and job.phase == "walk"
    end, 60 * 60, "T4b fetch carrying to the site")
    wait(30)
    local carried = invCount("Base.Plank")
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    ISTimedActionQueue.clear(p)
    ISTimedActionQueue.add(ISPathFindAction:pathToLocationF(p, px + 0.5, py + 1.5, 0))
    wait(5)
    check("T4b fetch stopped by the other action", not BuildAheadFetch.isActive(p))
    waitFor(function() return #queue(p) == 0 end, 60 * 20, "T4b the player's own walk")
    stillQuiet(240, "T4b nothing restarts on its own")
    check("T4b carried materials still in the bag", carried >= 2 and invCount("Base.Plank") == carried
        and invCount("Base.Nails") >= 2, "planks " .. invCount("Base.Plank") .. " nails " .. invCount("Base.Nails"))
    check("T4b borrowed hammer still in the bag", hammerCount(p:getInventory()) == 1 and hammerCount(crate) == 0)
    check("T4b site still planned and unclaimed", siteAt("WoodenWallFrame", W.x, W.y, 0) ~= nil and siteW.claimBy == nil)
    -- a later click resumes: both frames, from the bag and the crate; the hammer goes back
    plan(frameInfo, 1, W2)
    check("T4b click resumes the chain", BuildAhead.isBusy(p))
    waitIdle(60 * 180, "T4b chain")
    check("T4b both frames built", hasObject(W.x, W.y, 0, "WoodenWallFrame") and hasObject(W2.x, W2.y, 0, "WoodenWallFrame"))
    check("T4b hammer back in the crate", hammerCount(crate) == 1 and hammerCount(p:getInventory()) == 0,
        "crate " .. hammerCount(crate) .. " bag " .. hammerCount(p:getInventory()))
    check("T4b materials consumed", invCount("Base.Plank") + count(crate, "Base.Plank") == 0
        and invCount("Base.Nails") + count(crate, "Base.Nails") == 0)

    -- c. moving while walking to a build (materials in the bag; vanilla's walk)
    local W3 = { x = A.x + 21, y = A.y + 5, z = 0 }
    teleport(A.x + 3, A.y + 5, 0)
    wait(60)
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    addTo(inv, "Base.Plank", 2)
    addTo(inv, "Base.Nails", 2)
    local siteW3 = plan(frameInfo, 1, W3)
    wait(30)
    local walking = false
    for _, a in ipairs(queue(p)) do
        if a.Type == "ISPathFindAction" or a.Type == "ISWalkToTimedAction" then walking = true end
    end
    check("T4c walking to the build", walking and BuildAhead.isBuilding(p))
    check("T4c site claimed", siteW3 and siteW3.claimBy == p:getUsername())
    pressMovement()
    check("T4c build stopped by moving", not BuildAhead.isBuilding(p) and #queue(p) == 0)
    stillQuiet(240, "T4c nothing restarts on its own")
    check("T4c site still planned and unclaimed", siteAt("WoodenWallFrame", W3.x, W3.y, 0) ~= nil and siteW3.claimBy == nil)
    check("T4c materials still in the bag", invCount("Base.Plank") == 2 and invCount("Base.Nails") == 2)
    check("T4c Build planned resumes", buildPlanned(siteW3))
    waitIdle(60 * 120, "T4c build")
    check("T4c frame built", hasObject(W3.x, W3.y, 0, "WoodenWallFrame"))
    check("T4c site removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    clearBag()
end

-- ---------------------------------------------------------------- T5 many sites

local function frameTimes(n)
    local last = getTimestampMs()
    local total, worst = 0, 0
    for _ = 1, n do
        coroutine.yield()
        local t = getTimestampMs()
        local d = t - last
        last = t
        total = total + d
        if d > worst then worst = d end
    end
    return total / n, worst
end

local function scenarioMany()
    local p = player()
    clearSites()
    clearBag()
    local frameInfo = entityInfo("WoodenWallFrame")
    local A = findArea(5, 5, "T5")
    teleport(A.x + 2, A.y + 2, 0)
    wait(90)
    ISBuildMenu.cheat = true -- no walks: the order is what is tested here
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    -- valid squares 2 apart around the player, nearest first
    local probe = makeCursor(frameInfo, 1)
    local squares = {}
    for r = 2, 12, 2 do
        for dx = -r, r, 2 do
            for dy = -r, r, 2 do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local s = sq(px + dx, py + dy, 0)
                    if s and probe:isValid(s) then squares[#squares + 1] = { x = px + dx, y = py + dy, z = 0 } end
                end
            end
        end
    end
    log("T5 valid squares", #squares)
    if not check("T5 at least 64 squares", #squares >= 64, #squares) then return end
    local avg0, worst0 = frameTimes(300)
    log("T5 frame time without sites: avg", avg0, "worst", worst0)
    for i = 1, 64 do
        local q = squares[i]
        BuildAhead.addSite("WoodenWallFrame", q.x, q.y, q.z, 1)
    end
    check("T5 64 sites planned", #BuildAhead.getSites() == 64, "sites " .. #BuildAhead.getSites())
    -- no materials anywhere: every site is yellow and looks for materials within 20 tiles.
    -- The first frames evaluate all 64 new sites once (here planned in one frame; a player
    -- plans one per click); after that the checks are spread over the frames.
    local avgW, worstW = frameTimes(60)
    log("T5 first evaluation of 64 new sites: worst frame", worstW, "ms")
    check("T5 first evaluation of 64 new sites stays short", worstW <= 500, "worst " .. worstW .. " ms")
    local avg1, worst1 = frameTimes(600)
    log("T5 frame time with 64 sites (materials missing): avg", avg1, "worst", worst1)
    local states = {}
    for _, s in ipairs(BuildAhead.getSites()) do
        local st = tostring(BuildAhead.ghostState(s))
        states[st] = (states[st] or 0) + 1
    end
    local text = {}
    for k, n in pairs(states) do text[#text + 1] = k .. " " .. n end
    check("T5 ghosts drawn, materials missing", states.missing == 64, table.concat(text, ", "))
    -- one full check of every site, as if none had a cached answer
    local t0 = getTimestampMs()
    for _, s in ipairs(BuildAhead.getSites()) do
        local okState = pcall(function()
            BuildAhead.trapCheck(p, s, true)
            BuildAhead.siteState(p, s)
        end)
        if not okState then break end
    end
    local full = getTimestampMs() - t0
    log("T5 one state check of all 64 sites (cached answers):", full, "ms")
    check("T5 ghosts and checks cost little per frame", avg1 <= avg0 + 5, "avg " .. avg1 .. " ms vs " .. avg0 .. " ms")
    check("T5 no long frames from the checks", worst1 <= math.max(100, worst0 * 2), "worst " .. worst1 .. " ms vs " .. worst0 .. " ms")

    -- materials for three frames: the chain starts at the player and goes nearest first
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    addTo(inv, "Base.Plank", 6)
    addTo(inv, "Base.Nails", 6)
    local avg2, worst2 = frameTimes(300)
    log("T5 frame time with 64 sites (buildable): avg", avg2, "worst", worst2)
    check("T5 buildable ghosts cost little per frame", avg2 <= avg0 + 5 and worst2 <= math.max(100, worst0 * 2),
        "avg " .. avg2 .. " worst " .. worst2)
    -- the expected order, by the scheduler's rule (nearest to the last build, list order on ties)
    local expected, used = {}, {}
    local ox, oy = px, py
    for _ = 1, 3 do
        local best, bestD
        for _, s in ipairs(BuildAhead.getSites()) do
            local d = (s.x - ox) ^ 2 + (s.y - oy) ^ 2
            if not used[s.id] and d <= 400 and (not bestD or d < bestD) then best, bestD = s, d end
        end
        used[best.id] = true
        expected[#expected + 1] = best
        ox, oy = best.x, best.y
    end
    R.performed = {}
    local t1 = getTimestampMs()
    BuildAhead.schedule(p, px, py, 0)
    log("T5 scheduler pick with 64 sites took", getTimestampMs() - t1, "ms")
    waitIdle(60 * 120, "T5 chain")
    local got = {}
    for _, b in ipairs(R.performed) do got[#got + 1] = b.x .. "," .. b.y end
    local want = {}
    for _, s in ipairs(expected) do want[#want + 1] = s.x .. "," .. s.y end
    check("T5 chain builds nearest first", table.concat(got, " ") == table.concat(want, " "),
        "built " .. table.concat(got, " ") .. " expected " .. table.concat(want, " "))
    check("T5 the other 61 stay planned", #BuildAhead.getSites() == 61, "sites " .. #BuildAhead.getSites())
    ISBuildMenu.cheat = false
    clearSites()
    clearBag()
end

-- ---------------------------------------------------------------- T7 furniture stand

local CRATE = "Wood_Crate_Lvl2"

local function floorCount(x, y, z, fullType)
    local s = sq(x, y, z)
    local wos = s and s:getWorldObjects()
    local n = 0
    for i = 0, (wos and wos:size() or 0) - 1 do
        local it = wos:get(i):getItem()
        if it and it:getFullType() == fullType then n = n + 1 end
    end
    return n
end

local function countAt(name, x, y, z)
    local n = 0
    for part in string.gmatch(objectsAt(x, y, z), "[^,]+") do
        if part == name then n = n + 1 end
    end
    return n
end

-- the materials lie two squares east of the crate, the player comes from the west:
-- the crate is built from a square next to it whose 3x3 holds them, and nothing is fetched
local function scenarioFurnitureStand()
    local p = player()
    clearSites()
    clearBag()
    local info = entityInfo(CRATE)
    if not check("T7 recipe " .. CRATE, info ~= nil) then return end
    local A = findArea(9, 5, "T7")
    local S = { x = A.x + 4, y = A.y + 2, z = 0 }
    local M = { x = S.x + 2, y = S.y + 1, z = 0 }
    teleport(A.x, S.y, 0)
    wait(60)
    p:getInventory():AddItem("Base.BallPeenHammerForged")
    local need = cost(info)
    local msq = sq(M.x, M.y, M.z)
    for t, n in pairs(need) do
        for _ = 1, n do msq:AddWorldInventoryItem(t, 0.5, 0.5, 0) end
    end
    BuildAheadFetch.scanCache = nil
    log("T7 materials at", M.x, M.y, costText(need), "crate at", S.x, S.y, "player at", playerSq())
    local takes, rehandled = BuildAheadFetch.stats.takes, BuildAheadFetch.stats.rehandled
    R.performed = {}
    local site = plan(info, 1, S)
    check("T7 crate planned", site ~= nil)
    waitIdle(60 * 120, "T7 chain")
    local _, b = performedIndex(CRATE, S.x, S.y, S.z)
    check("T7 crate built", hasObject(S.x, S.y, S.z, CRATE), objectsAt(S.x, S.y, S.z))
    check("T7 built next to the crate, with the materials in its 3x3",
        b and math.max(math.abs(b.px - M.x), math.abs(b.py - M.y)) <= 1
            and math.max(math.abs(b.px - S.x), math.abs(b.py - S.y)) == 1,
        b and (b.px .. "," .. b.py) or "not built")
    check("T7 nothing fetched", BuildAheadFetch.stats.takes == takes
        and BuildAheadFetch.stats.rehandled == rehandled, "takes " .. (BuildAheadFetch.stats.takes - takes))
    local left = {}
    for t in pairs(need) do
        local n = floorCount(M.x, M.y, M.z, t) + invCount(t)
        if n > 0 then left[#left + 1] = t .. " x" .. n end
    end
    check("T7 floor materials used where they lie", #left == 0, table.concat(left, " "))
    check("T7 site removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
end

-- ---------------------------------------------------------------- T8 stacked crates

-- three clicks on one square plan three levels of a crate stack; the chain builds them
-- on that square, removes the sites and builds no more
local function scenarioStack()
    local p = player()
    clearSites()
    clearBag()
    local info = entityInfo(CRATE)
    if not check("T8 recipe " .. CRATE, info ~= nil) then return end
    local A = findArea(6, 6, "T8")
    local S = { x = A.x + 3, y = A.y + 3, z = 0 }
    teleport(A.x + 1, S.y, 0)
    wait(60)
    -- no materials yet: level 1 cannot be built, so the levels above show yellow too
    for _ = 1, 3 do makeCursor(info, 1):tryBuild(S.x, S.y, S.z) end
    local planned = {}
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.x == S.x and s.y == S.y and s.z == S.z and s.stack then planned[s.stack] = s end
    end
    if planned[3] then
        local st = {}
        for i = 1, 3 do st[i] = BuildAhead.siteState(p, planned[i]) end
        check("T8 level 1 without materials not buildable", st[1] ~= "buildable", st[1])
        check("T8 levels above it missing (yellow)", st[2] == "missing" and st[3] == "missing", st[2] .. "," .. st[3])
    else
        check("T8 three levels planned without materials", false)
    end
    clearSites()
    wait(60)
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    local need = cost(info)
    for t, n in pairs(need) do addTo(inv, t, n * 3) end
    R.performed = {}
    -- (a build without stacking support still runs the clicks and the chain, as a crate of 32)
    local si = BuildAhead.stackInfo and BuildAhead.stackInfo(makeCursor(info, 1))
    if not check("T8 crate is stackable", si and si.surface > 0, si and tostring(si.surface)) then
        si = { surface = 32 }
    end
    local levels = math.floor((BuildAhead.STACK_MAX or 96) / si.surface)
    check("T8 three levels fit", levels >= 3, "surface " .. si.surface .. " levels " .. levels)
    for _ = 1, 3 do makeCursor(info, 1):tryBuild(S.x, S.y, S.z) end
    local stack = {}
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.x == S.x and s.y == S.y and s.z == S.z then stack[#stack + 1] = s end
    end
    table.sort(stack, function(a, b) return (a.stack or 0) < (b.stack or 0) end)
    local levelsText = {}
    for _, s in ipairs(stack) do levelsText[#levelsText + 1] = tostring(s.stack) end
    check("T8 three levels planned on one square", #stack == 3 and stack[1].stack == 1 and stack[3].stack == 3,
        table.concat(levelsText, ","))
    if stack[3] and BuildAhead.stackBase then
        local base = BuildAhead.stackBase(p, stack[3], si)
        check("T8 third ghost drawn on two levels", base == 2 * si.surface, "base " .. tostring(base))
    end
    if levels == 3 then
        check("T8 a fourth planned level is refused by the cursor", not makeCursor(info, 1):isValid(sq(S.x, S.y, S.z)))
    end
    -- a level waits for the planned one below (materials are there for all three)
    if stack[3] then
        check("T8 upper levels wait for level 1", not BuildAhead.canBuildSite(p, stack[2])
            and not BuildAhead.canBuildSite(p, stack[3]))
    end
    waitIdle(60 * 300, "T8 chain")
    wait(120)
    for i, b in ipairs(R.performed) do log("T8 built", i, b.name, b.x, b.y, b.z, "player at", b.px, b.py) end
    check("T8 three crates on the square", countAt(CRATE, S.x, S.y, S.z) == 3, objectsAt(S.x, S.y, S.z))
    local behind = countAt(CRATE, S.x - 1, S.y - 1, 0) + countAt(CRATE, S.x - 2, S.y - 2, 0)
    check("T8 nothing built on the squares behind", behind == 0, "crates " .. behind)
    local others = 0
    for _, b in ipairs(R.performed) do
        if not (b.x == S.x and b.y == S.y) then others = others + 1 end
    end
    check("T8 three builds, all on the square", #R.performed == 3 and others == 0, "builds " .. #R.performed)
    check("T8 all sites removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    check("T8 a full stack is refused by the cursor", not makeCursor(info, 1):isValid(sq(S.x, S.y, S.z)))
end

-- T8b: the next level is built while the level below is still listed (its site goes
-- CHECK_DELAY_MS after the build; a short build, e.g. Handy or a fast game, ends
-- sooner). Each build must count for its own level: three crates, no rebuilt level,
-- and every site removed once the delay has passed.
local function scenarioStackFast()
    local p = player()
    clearSites()
    clearBag()
    local info = entityInfo(CRATE)
    if not check("T8b recipe " .. CRATE, info ~= nil) then return end
    local A = findArea(6, 6, "T8b")
    local S = { x = A.x + 3, y = A.y + 3, z = 0 }
    teleport(A.x + 1, S.y, 0)
    wait(60)
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    local need = cost(info)
    for t, n in pairs(need) do addTo(inv, t, n * 5) end
    R.performed = {}
    R.checkDelay = BuildAhead.CHECK_DELAY_MS
    BuildAhead.CHECK_DELAY_MS = 20000
    for _ = 1, 3 do makeCursor(info, 1):tryBuild(S.x, S.y, S.z) end
    waitIdle(60 * 300, "T8b chain")
    wait(120)
    local t0 = getTimestampMs()
    for i, b in ipairs(R.performed) do log("T8b built", i, b.name, b.x, b.y, b.z) end
    check("T8b three crates on the square", countAt(CRATE, S.x, S.y, S.z) == 3, objectsAt(S.x, S.y, S.z))
    check("T8b three builds", #R.performed == 3, "builds " .. #R.performed)
    -- the sites go when the delay has passed
    local frames = 0
    while #BuildAhead.getSites() > 0 and frames < 60 * 60 do
        wait(1)
        frames = frames + 1
    end
    BuildAhead.CHECK_DELAY_MS = R.checkDelay
    R.checkDelay = nil
    local left = {}
    for _, s in ipairs(BuildAhead.getSites()) do left[#left + 1] = tostring(s.stack) end
    check("T8b all levels removed", #left == 0, "left " .. table.concat(left, ",") .. " after "
        .. (getTimestampMs() - t0) .. " ms")
end

-- ---------------------------------------------------------------- T9 materials for the next sites

-- four crates in a row, their materials in one container further off: a trip brings
-- the materials of as many of the next sites as the inventory holds, so the chain
-- needs ceil(4 / sites per trip) fetch trips, not four; nothing goes into the worn bag
local function scenarioBatch()
    local p = player()
    clearSites()
    clearBag()
    local info = entityInfo(CRATE)
    if not check("T9 recipe " .. CRATE, info ~= nil) then return end
    local A = findArea(14, 6, "T9")
    teleport(A.x + 1, A.y + 3, 0)
    wait(60)
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    local bag = inv:AddItem("Base.Bag_Schoolbag")
    pcall(function() p:setWornItem(bag:canBeEquipped(), bag) end)
    check("T9 bag worn", p:isEquipped(bag))
    local need = cost(info)
    local siteW = 0
    for t, n in pairs(need) do siteW = siteW + n * instanceItem(t):getUnequippedWeight() end
    local room = BuildAheadFetch.freeWeight(p)
    local perTrip = math.floor(room / siteW)
    local N = 4
    local _, store = newCrate(sq(A.x + 12, A.y + 5, 0))
    for t, n in pairs(need) do addTo(store, t, n * N) end
    log("T9 site weight", string.format("%.1f", siteW), "room", string.format("%.1f", room), "sites per trip", perTrip)
    check("T9 at least one site per trip", perTrip >= 1)
    -- count the fetch jobs and where the transfers go
    local origStart, origTransfer = BuildAheadFetch.start, ISInventoryTransferUtil.newInventoryTransferAction
    local jobs, toBag = 0, 0
    BuildAheadFetch.start = function(...)
        local ok = origStart(...)
        if ok then jobs = jobs + 1 end
        return ok
    end
    ISInventoryTransferUtil.newInventoryTransferAction = function(chr, item, src, dest, ...)
        if chr == p and dest ~= inv then toBag = toBag + 1 end
        return origTransfer(chr, item, src, dest, ...)
    end
    R.restore = function()
        BuildAheadFetch.start = origStart
        ISInventoryTransferUtil.newInventoryTransferAction = origTransfer
    end
    R.performed = {}
    for i = 1, N do makeCursor(info, 1):tryBuild(A.x + 1 + 2 * i, A.y + 1, 0) end
    waitIdle(60 * 600, "T9 chain")
    wait(120)
    R.restore()
    R.restore = nil
    local built = 0
    for i = 1, N do
        if hasObject(A.x + 1 + 2 * i, A.y + 1, 0, CRATE) then built = built + 1 end
    end
    check("T9 all crates built", built == N, "built " .. built)
    local expected = perTrip >= 1 and math.ceil(N / perTrip) or N
    check("T9 fetch trips for the next sites", jobs == expected, "jobs " .. jobs .. " expected " .. expected)
    check("T9 nothing put into the worn bag", toBag == 0, "transfers into a bag " .. toBag)
    local left = 0
    for t in pairs(need) do left = left + count(store, t) end
    check("T9 store emptied", left == 0, "left " .. left)
    check("T9 all sites removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    pcall(function() p:removeWornItem(bag) end)
    inv:DoRemoveItem(bag)
end

-- ---------------------------------------------------------------- T6 persistence, part 1

local PERSIST_FILE = "buildahead_persist.txt"

local function scenarioPersistSave()
    local p = player()
    clearSites()
    clearBag()
    local frameInfo = entityInfo("WoodenWallFrame")
    local A = findArea(9, 5, "T6")
    teleport(A.x + 1, A.y + 2, 0)
    wait(60)
    -- no materials: the sites stay planned
    local list = {
        { name = "WoodenWallFrame", x = A.x + 4, y = A.y + 1, z = 0, nSprite = 1 },
        { name = "WoodenWallFrame", x = A.x + 6, y = A.y + 3, z = 0, nSprite = 2 },
        { name = "WoodenWallLvl1", x = A.x + 4, y = A.y + 1, z = 0, nSprite = 1 },
    }
    for _, s in ipairs(list) do BuildAhead.addSite(s.name, s.x, s.y, s.z, s.nSprite) end
    BuildAhead.setBanned(p, "Base.LongStick", true)
    check("T6 sites planned for the reload", #BuildAhead.getSites() == 3 and frameInfo ~= nil)
    local w = getFileWriter(PERSIST_FILE, true, false)
    for _, s in ipairs(BuildAhead.getSites()) do
        w:write(s.name .. " " .. s.x .. " " .. s.y .. " " .. s.z .. " " .. s.nSprite .. " " .. s.id .. "\n")
    end
    w:write("ban Base.LongStick\n")
    w:close()
    log("T6 saved for the reload:", #BuildAhead.getSites(), "sites, ban Base.LongStick")
end

-- ---------------------------------------------------------------- runner

local SCENARIOS = {
    { "T1 build types", scenarioTypes },
    { "T2 upper floors", scenarioUpper },
    { "T3 vehicles and corpses", scenarioSources },
    { "T4 interruption", scenarioInterrupt },
    { "T5 many sites", scenarioMany },
    { "T7 furniture stand", scenarioFurnitureStand },
    { "T8 stacked crates", scenarioStack },
    { "T8b stacked crates, built fast", scenarioStackFast },
    { "T9 materials for the next sites", scenarioBatch },
    { "T6 persistence (save)", scenarioPersistSave },
}

-- after a failed scenario: stop whatever runs, so the next one starts clean
local function reset()
    local p = player()
    R.footing = nil
    pcall(function() BuildAheadFetch.abort("test reset") end)
    pcall(function() ISTimedActionQueue.clear(p) end)
    BuildAheadTrap.standFilter = nil
    ISBuildMenu.cheat = false
    if R.checkDelay then
        BuildAhead.CHECK_DELAY_MS = R.checkDelay
        R.checkDelay = nil
    end
    if R.restore then
        pcall(R.restore)
        R.restore = nil
    end
    pcall(clearSites)
    if p:getZ() >= 1 then pcall(teleport, math.floor(p:getX()) + 3, math.floor(p:getY()) + 3, 0) end
end

local function finish()
    R.phase = "done"
    ISBuildMenu.cheat = R.cheat
    log("RESULT pass", R.pass, "fail", R.fail)
    log("test done")
end

-- Each scenario is a coroutine resumed once per frame. A timeout ends it through
-- abort(). Kahlua does not hand an error inside a coroutine back to
-- coroutine.resume, so the resume also runs in a pcall: an unexpected error ends
-- that scenario too (under -debug the debugger may stop on it first).
local function startScenario(i)
    local s = R.list[i]
    R.index = i
    if not s then
        R.co = nil
        finish()
        return
    end
    log("scenario", s[1])
    R.co = coroutine.create(s[2])
end

Events.OnRenderTick.Add(function()
    if R.phase ~= "run" and R.phase ~= "reload" then return end
    -- the game pauses itself now and then (e.g. focus); the walks and builds need it running
    if getGameSpeed() == 0 then pcall(setGameSpeed, 1) end
    pcall(footingTick)
    if not R.co then return end
    local okCall, okCo, err = pcall(coroutine.resume, R.co)
    if not (okCall and okCo) then
        local msg = okCall and err or okCo
        local name = R.list[R.index] and R.list[R.index][1] or "?"
        R.fail = R.fail + 1
        log("ERROR in", name, msg)
        if harness() then PZTest.fail("BuildAheadTest2 ERROR " .. name .. " " .. tostring(msg)) end
        pcall(reset)
        pcall(setupPlayer)
        startScenario(R.index + 1)
    elseif R.aborted then
        log("scenario ended early:", R.aborted)
        R.aborted = nil
        pcall(reset)
        pcall(setupPlayer)
        startScenario(R.index + 1)
    elseif coroutine.status(R.co) == "dead" then
        pcall(setupPlayer)
        startScenario(R.index + 1)
    end
end)

-- ---------------------------------------------------------------- T6 persistence, part 2 (reload run)

local function reloadCheck()
    wait(120)
    local p = player()
    local r = getFileReader(PERSIST_FILE, false)
    if not check("T6 reload: saved list found", r ~= nil) then return end
    local want, bans = {}, {}
    local line = r:readLine()
    while line do
        local a, b, c, d, e = string.match(line, "^(%S+) (%S+) (%S+) (%S+) (%S+)")
        if a == "ban" then
            bans[#bans + 1] = b
        elseif a then
            want[#want + 1] = { name = a, x = tonumber(b), y = tonumber(c), z = tonumber(d), nSprite = tonumber(e) }
        end
        line = r:readLine()
    end
    r:close()
    local sites = BuildAhead.getSites()
    check("T6 reload: as many sites as saved", #sites == #want and #want == 3, #sites .. " of " .. #want)
    for _, s in ipairs(want) do
        local found = BuildAheadSites.find(BuildAheadSites.data(), s.name, s.x, s.y, s.z, s.nSprite)
        check("T6 reload: site " .. s.name .. " " .. s.x .. "," .. s.y .. " nSprite " .. s.nSprite, found ~= nil)
    end
    for _, b in ipairs(bans) do
        check("T6 reload: ban " .. b .. " kept", BuildAhead.isBanned(p, b))
    end
    wait(60)
    local drawn = 0
    for _, s in ipairs(sites) do
        if BuildAhead.ghostState(s) ~= nil then drawn = drawn + 1 end
    end
    check("T6 reload: ghosts drawn", drawn == #sites, drawn .. " of " .. #sites)
    check("T6 reload: nothing starts on load", not BuildAhead.isBusy(p))
end

BuildAheadTest2 = {}

-- only: "T7,T8" runs just the scenarios whose names start with these
function BuildAheadTest2.start(only)
    if R.phase ~= "idle" then
        PZTest.fail("BuildAheadTest2 already ran in this game; pzt stop, then run again")
        return
    end
    R.phase = "run"
    hookPerform()
    setupPlayer()
    R.cheat = ISBuildMenu.cheat
    ISBuildMenu.cheat = false
    R.list = SCENARIOS
    if only then
        R.list = {}
        for _, sc in ipairs(SCENARIOS) do
            for pre in string.gmatch(only, "[^,]+") do
                if string.sub(sc[1], 1, #pre) == pre then R.list[#R.list + 1] = sc end
            end
        end
    end
    log("start")
    startScenario(1)
end

function BuildAheadTest2.poll()
    if R.phase == "done" then
        PZTest.log("BuildAheadTest2 pass " .. R.pass .. " fail " .. R.fail)
        return
    end
    PZTest.step("wait 30")
    PZTest.step("lua BuildAheadTest2.poll()")
end

-- the reload run (second `pzt run KEEP_SAVE=1`): what part 1 left must be there
function BuildAheadTest2.reloadStart()
    R.phase = "reload"
    R.cheat = ISBuildMenu.cheat
    R.list = { { "T6 persistence (reload)", reloadCheck } }
    log("reload start")
    startScenario(1)
end
