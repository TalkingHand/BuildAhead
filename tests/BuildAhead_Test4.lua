-- Single-player in-game test, part 4 (test environment only: pzt installs this file next to
-- BuildAhead_Test.lua, see TEST_FILES in pzt.conf): 1.1.0 features.
--   S0 settings: the sandbox options are read (search range 40, packs opened, drag on)
--   P  packed materials (box of nails, vanilla recipe OpenBox100):
--      P1 a box in the inventory, no loose nails: the box is opened, the wall frame built,
--         98 nails stay loose in the inventory
--      P2 the box in a crate 12 tiles away: fetched, opened, built; 98 nails left
--      P3 enough loose nails and a box: the box stays closed
--      P4 OpenPacks off, only a box: nothing built, the site stays planned, the box closed
--      P5 Base.Nails banned, only a box: the box is not used either
--   R  search range:
--      R1 materials 30 tiles from the site: found with the range 40, not with 20
--      R2 cost: a fresh scan at 40 and 60; 32 sites without materials, frame times at 40
--   D  drag to plan a range (the cursor's rotateMouse/isValid/tryBuild, called as
--      DoTileBuilding calls them; the mouse itself is not moved):
--      D1 floor 3x2: six sites, then built with the materials in the bag
--      D2 wall frame line along x: five north walls; along y: five west walls
--      D3 back on the pressed square: one site, as a click
--      D4 a crate (not a floor or wall): vanilla turns it, one site
--      D5 a blocked square inside a floor range is left out
--      D6 floor drags give the dragged rectangle up to 40x40, wall lines up to 40
--      D7 DragBuild off: no range, vanilla turning
--      D8 vanilla's false release over the inventory window (button held) does not plan;
--         the drag goes on from the pressed square, the real release plans the range
--   M  materials shared among the sites (BuildAheadFetch.allocate):
--      M1 materials for two floors, four planned: the two nearest buildable; four planks: all;
--         a box of nails counts as 100
--      M2 400 floor sites planned at once (as a drag adds them): add time, frame times, every ghost
--         checked, allocation and pick time
--      M3 materials for three of eight frames on a grid: built nearest to the last build first
-- Results: "[BuildAheadTest4]" lines; failures also as "[PZTest] FAIL".

require "BuildAhead"

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAheadTest4] " .. table.concat(parts, " "))
end

local R = { pass = 0, fail = 0, phase = "idle", performed = {} }

local function harness() return PZTest ~= nil and PZTest.active() end

local function check(label, ok, extra)
    if ok then R.pass = R.pass + 1 else R.fail = R.fail + 1 end
    log(ok and "PASS" or "FAIL", label, extra or "")
    if not ok and harness() then PZTest.fail("BuildAheadTest4 " .. label .. " " .. tostring(extra or "")) end
    return ok
end

local function player() return getSpecificPlayer(0) end
local function queue(p) return ISTimedActionQueue.getTimedActionQueue(p or player()).queue end
local function sq(x, y, z) return getCell():getGridSquare(x, y, z) end

local function wait(n)
    for _ = 1, n do coroutine.yield() end
end

-- end the scenario (its failure is recorded) without error(): the runner starts the next one
local function abort(why)
    R.aborted = why
    while true do coroutine.yield() end
end

local function diag()
    local p = player()
    local types = {}
    for _, a in ipairs(queue(p)) do types[#types + 1] = tostring(a.Type) end
    return "at " .. math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. " queue " .. table.concat(types, ",")
        .. " fetch " .. tostring(BuildAheadFetch.job ~= nil)
end

local function busy(p) return BuildAhead.isBusy(p) or #queue(p) > 0 end

-- until the player has been idle for 3 s
local function waitIdle(limit, label)
    local p, idle, t = player(), 0, 0
    while idle < 180 do
        t = t + 1
        if t > limit then
            check(label .. " finished in time", false, diag())
            abort("timeout: " .. label)
        end
        if busy(p) then idle = 0 else idle = idle + 1 end
        coroutine.yield()
    end
    return t
end

local function entityInfo(name)
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if i:getName() == name then return i end
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

local MATS = { "Base.Plank", "Base.Nails", "Base.NailsBox", "Base.Screws", "Base.ScrewsBox" }

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

local function invCount(fullType) return player():getInventory():getCountTypeRecurse(fullType) end

local function addTo(container, fullType, n)
    for _ = 1, n do container:AddItem(fullType) end
end

local function teleport(x, y, z)
    if harness() then PZTest.teleport(x + 0.5, y + 0.5, z) else player():teleportTo(x + 0.5, y + 0.5, z) end
end

local function freeSquare(s)
    return s and s:isFree(false) and s:TreatAsSolidFloor() and s:getObjects():size() <= 1
        and s:getWorldObjects():size() == 0 and not s:getRoom() and not s:HasStairs()
        and not s:getVehicleContainer() and s:getDeadBodys():size() == 0
end

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

-- a free area not used by an earlier scenario
local function findArea(w, h, label)
    local p = player()
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    for r = 3, 42 do
        for dx = -r, r do
            for dy = -r, r do
                local x, y = px + dx, py + dy
                local used = false
                for _, u in ipairs(R.used or {}) do
                    if x < u.x + u.w + 2 and x + w + 2 > u.x and y < u.y + u.h + 2 and y + h + 2 > u.y then used = true end
                end
                if not used and math.max(math.abs(dx), math.abs(dy)) == r and openArea(x, y, 0, w, h) then
                    log("area", label, x, y, w .. "x" .. h)
                    R.used = R.used or {}
                    table.insert(R.used, { x = x, y = y, w = w, h = h })
                    return { x = x, y = y, z = 0 }
                end
            end
        end
        coroutine.yield()
    end
    check(label .. ": free " .. w .. "x" .. h .. " area", false)
    abort("no area for " .. label)
end

local function hasObject(x, y, z, name)
    local s = sq(x, y, z)
    if not s then return false end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        if objs:get(i):getName() == name then return true end
    end
    return false
end

local function siteAt(name, x, y, z)
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.name == name and s.x == x and s.y == y and s.z == z then return s end
    end
end

local function newCrate(s)
    local obj = IsoThumpable.new(getCell(), s, "carpentry_01_16", false, {})
    obj:setIsContainer(true)
    obj:getContainer():setType("crate")
    obj:setIsThumpable(true)
    s:AddSpecialObject(obj)
    return obj, obj:getContainer()
end

-- the build panel's cursor, as ISBuildPanel:createBuildIsoEntity makes it
local function makeCursor(info, nSprite)
    local p = player()
    local c = ISBuildIsoEntity:new(p, info, nSprite or 1, ISInventoryPaneContextMenu.getContainers(p))
    c.player = 0
    c.dragNilAfterPlace = false
    c.blockAfterPlace = true
    c:getSprite()
    return c
end

-- press on (sx, sy), drag to (mx, my), release: what DoTileBuilding does with the cursor
-- (rotateMouse with the square under the mouse while the button is down, isValid and
-- tryBuild on the pressed square on release). Returns the cursor and isValid on release.
local function drag(info, nSprite, sx, sy, mx, my)
    local c = makeCursor(info, nSprite)
    c.square = sq(sx, sy, 0)
    c.isLeftDown = true
    c:rotateMouse(sx, sy) -- the press
    c:rotateMouse(mx, my) -- the drag
    c:getSprite()
    c.isLeftDown = false
    c.build = true
    local valid = c:isValid(c.square)
    if valid then
        c.build = false
        c:tryBuild(sx, sy, 0)
    end
    return c, valid
end

local function siteCount(name)
    local n = 0
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.name == name then n = n + 1 end
    end
    return n
end

local function setupPlayer()
    local p = player()
    pcall(function() p:setGodMod(true) end)
    pcall(function() p:setInvisible(true) end)
    pcall(function() p:setZombiesDontAttack(true) end)
    for _ = 1, 10 do
        if p:getPerkLevel(Perks.Woodwork) >= 10 then break end
        pcall(function() p:LevelPerk(Perks.Woodwork) end)
    end
    p:setMaxWeightBase(1000)
    p:setMaxWeight(1000)
    BuildAheadTrap.standFilter = nil
    for t in pairs(BuildAhead.getBans(p)) do BuildAhead.setBanned(p, t, false) end
    BuildAheadFetch.RANGE, BuildAheadFetch.OPEN_PACKS, BuildAhead.DRAG_ENABLED = 40, true, true
    BuildAheadFetch.packFailed = {}
    BuildAheadFetch.scanCache = nil
    BuildAheadFetch.sourceFilter = nil
end

-- only these squares' sources count (what earlier tests left in the world stays out)
local function onlySources(squares)
    BuildAheadFetch.sourceFilter = function(src)
        for _, s in ipairs(squares) do
            if src.x == s:getX() and src.y == s:getY() and src.z == s:getZ() then return true end
        end
        return false
    end
end

local function hookPerform()
    if R.hooked then return end
    R.hooked = true
    local orig = ISBuildAction.perform
    ISBuildAction.perform = function(self, ...)
        local name = self.item and self.item.objectInfo and self.item.objectInfo:getName()
        table.insert(R.performed, { name = name, x = self.x, y = self.y, z = self.z })
        return orig(self, ...)
    end
end

-- a drag's release starts the chain when the player is idle; the D scenarios only look at
-- the sites, so the chain (it may go off to fetch materials found in range) is stopped
local function stopChain()
    pcall(function() BuildAheadFetch.abort("test") end)
    pcall(function() ISTimedActionQueue.clear(player()) end)
end

local function startChain()
    local p = player()
    BuildAhead.schedule(p, math.floor(p:getX()), math.floor(p:getY()), 0)
end

-- ---------------------------------------------------------------- S0 settings

local function scenarioSettings()
    local sv = SandboxVars and SandboxVars.BuildAhead
    log("S0 SandboxVars.BuildAhead", sv and ("FetchRange " .. tostring(sv.FetchRange) .. " OpenPacks "
        .. tostring(sv.OpenPacks) .. " DragBuild " .. tostring(sv.DragBuild)) or "nil")
    BuildAhead.applySandbox()
    -- the test save has no value of its own: the defaults
    check("S0 search range from the sandbox (default 40)", BuildAheadFetch.RANGE == ((sv and tonumber(sv.FetchRange)) or 40),
        "range " .. tostring(BuildAheadFetch.RANGE))
    check("S0 packs opened by default", BuildAheadFetch.OPEN_PACKS == true)
    check("S0 drag on by default", BuildAhead.DRAG_ENABLED == true)
    local packs = BuildAheadFetch.packs()
    check("S0 nail and screw boxes known (recipe OpenBox100 found)", packs["Base.NailsBox"] ~= nil and packs["Base.ScrewsBox"] ~= nil)
    check("S0 missing text names the range", string.find(getText("IGUI_BuildAhead_Missing", "x", BuildAheadFetch.RANGE), "40", 1, true) ~= nil,
        getText("IGUI_BuildAhead_Missing", "x", BuildAheadFetch.RANGE))
    setupPlayer()
end

-- ---------------------------------------------------------------- P packs

local FRAME = "WoodenWallFrame" -- hammer (keep), 2 planks, 2 nails

-- a wall frame site in a free area, the player next to it with a hammer and the planks
local function packSite(label)
    local p = player()
    clearSites()
    clearBag()
    local A = findArea(6, 5, label)
    teleport(A.x + 1, A.y + 3, 0)
    wait(60)
    p:getInventory():AddItem("Base.Hammer")
    addTo(p:getInventory(), "Base.Plank", 2)
    local site = BuildAhead.addSite(FRAME, A.x + 3, A.y + 2, 0, 1)
    check(label .. " site planned", site ~= nil)
    onlySources({}) -- nothing from the world unless the scenario says so
    R.performed = {}
    return site, A
end

local function scenarioPackCarried()
    local site = packSite("P1")
    local inv = player():getInventory()
    inv:AddItem("Base.NailsBox")
    local opens = BuildAheadFetch.stats.opens
    check("P1 no loose nails, one box", invCount("Base.Nails") == 0 and invCount("Base.NailsBox") == 1)
    check("P1 ghost buildable with only a box", BuildAhead.canBuildSite(player(), site))
    startChain()
    waitIdle(60 * 120, "P1 chain")
    check("P1 frame built", hasObject(site.x, site.y, 0, FRAME), "performs " .. #R.performed)
    check("P1 box opened", invCount("Base.NailsBox") == 0 and BuildAheadFetch.stats.opens == opens + 1,
        "boxes " .. invCount("Base.NailsBox") .. " opens " .. (BuildAheadFetch.stats.opens - opens))
    check("P1 only what the build needs used: 98 nails left", invCount("Base.Nails") == 98, "nails " .. invCount("Base.Nails"))
    check("P1 site removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    clearSites()
    clearBag()
end

local function scenarioPackFetched()
    local site, A = packSite("P2")
    -- a crate 12 tiles away holds a box of nails
    local C
    for d = 12, 16 do
        local s = sq(A.x + 3 + d, A.y + 2, 0)
        if freeSquare(s) then C = s break end
        s = sq(A.x + 3 - d, A.y + 2, 0)
        if freeSquare(s) then C = s break end
    end
    if not check("P2 a square for the crate", C ~= nil) then return end
    local _, crate = newCrate(C)
    crate:AddItem("Base.NailsBox")
    onlySources({ C })
    BuildAheadFetch.scanCache = nil
    local opens, takes = BuildAheadFetch.stats.opens, BuildAheadFetch.stats.takes
    local plan = BuildAhead.fetchPlan(player(), site)
    local planned = false
    for _, entry in ipairs(plan or {}) do
        for _, e in ipairs(entry.items) do
            if e.open and e.item:getFullType() == "Base.NailsBox" then planned = true end
        end
    end
    check("P2 the plan takes the box to open it", planned)
    startChain()
    waitIdle(60 * 180, "P2 chain")
    check("P2 frame built", hasObject(site.x, site.y, 0, FRAME), "performs " .. #R.performed)
    check("P2 box taken from the crate and opened", crate:getCountTypeRecurse("Base.NailsBox") == 0
        and invCount("Base.NailsBox") == 0 and BuildAheadFetch.stats.opens == opens + 1,
        "crate " .. crate:getCountTypeRecurse("Base.NailsBox") .. " bag " .. invCount("Base.NailsBox")
        .. " opens " .. (BuildAheadFetch.stats.opens - opens) .. " takes " .. (BuildAheadFetch.stats.takes - takes))
    check("P2 98 nails left loose", invCount("Base.Nails") == 98, "nails " .. invCount("Base.Nails"))
    clearSites()
    clearBag()
end

local function scenarioPackNotNeeded()
    local site = packSite("P3")
    local inv = player():getInventory()
    addTo(inv, "Base.Nails", 2)
    inv:AddItem("Base.NailsBox")
    local opens = BuildAheadFetch.stats.opens
    startChain()
    waitIdle(60 * 120, "P3 chain")
    check("P3 frame built", hasObject(site.x, site.y, 0, FRAME))
    check("P3 the box stays closed", invCount("Base.NailsBox") == 1 and BuildAheadFetch.stats.opens == opens,
        "boxes " .. invCount("Base.NailsBox") .. " nails " .. invCount("Base.Nails"))
    check("P3 the loose nails used", invCount("Base.Nails") == 0, "nails " .. invCount("Base.Nails"))
    clearSites()
    clearBag()
end

local function scenarioPackOff()
    local site = packSite("P4")
    player():getInventory():AddItem("Base.NailsBox")
    BuildAheadFetch.OPEN_PACKS = false
    local plan, missing = BuildAhead.fetchPlan(player(), site)
    log("P4 plan", plan and #plan or "nil", "missing", table.concat(missing or {}, ", "))
    startChain()
    waitIdle(60 * 60, "P4 chain")
    check("P4 nothing built", not hasObject(site.x, site.y, 0, FRAME) and #R.performed == 0, "performs " .. #R.performed)
    check("P4 site stays planned, box closed", #BuildAhead.getSites() == 1 and invCount("Base.NailsBox") == 1,
        "sites " .. #BuildAhead.getSites() .. " boxes " .. invCount("Base.NailsBox"))
    BuildAheadFetch.OPEN_PACKS = true
    clearSites()
    clearBag()
end

local function scenarioPackBanned()
    local p = player()
    local site = packSite("P5")
    p:getInventory():AddItem("Base.NailsBox")
    BuildAhead.setBanned(p, "Base.Nails", true)
    startChain()
    waitIdle(60 * 60, "P5 chain")
    check("P5 nothing built with nails banned", not hasObject(site.x, site.y, 0, FRAME) and #R.performed == 0)
    check("P5 box closed", invCount("Base.NailsBox") == 1)
    BuildAhead.setBanned(p, "Base.Nails", false)
    clearSites()
    clearBag()
end

-- ---------------------------------------------------------------- R range

local function scenarioRange()
    local p = player()
    clearSites()
    clearBag()
    local A = findArea(4, 4, "R1")
    teleport(A.x + 1, A.y + 1, 0)
    wait(60)
    p:getInventory():AddItem("Base.Hammer")
    local site = BuildAhead.addSite(FRAME, A.x + 2, A.y + 2, 0, 1)
    -- materials 30 tiles away (east or west, whichever square is free and loaded)
    local C
    for d = 30, 34 do
        for _, dx in ipairs({ d, -d }) do
            local s = sq(site.x + dx, site.y, 0)
            if not C and freeSquare(s) then C = s end
        end
    end
    if not check("R1 a loaded free square 30-34 tiles away", C ~= nil) then return end
    local _, crate = newCrate(C)
    onlySources({ C })
    addTo(crate, "Base.Plank", 2)
    addTo(crate, "Base.Nails", 2)
    log("R1 crate at", C:getX(), C:getY(), "site", site.x, site.y)
    BuildAheadFetch.RANGE = 40
    BuildAheadFetch.scanCache = nil
    local plan40 = BuildAhead.fetchPlan(p, site)
    BuildAheadFetch.RANGE = 20
    BuildAheadFetch.scanCache = nil
    local plan20, missing20 = BuildAhead.fetchPlan(p, site)
    BuildAheadFetch.RANGE = 40
    BuildAheadFetch.scanCache = nil
    check("R1 found within 40", plan40 ~= nil and #plan40 > 0)
    check("R1 not found within 20", plan20 == nil, "missing " .. table.concat(missing20 or {}, ", "))
    -- and the chain fetches it from there
    R.performed = {}
    startChain()
    waitIdle(60 * 240, "R1 chain")
    check("R1 frame built with the far materials", hasObject(site.x, site.y, 0, FRAME), "performs " .. #R.performed)
    clearSites()
    clearBag()
    -- leave the crate empty for the rest
    pcall(function() crate:removeAllItems() end)
end

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

local function scenarioRangeCost()
    local p = player()
    clearSites()
    clearBag()
    local A = findArea(5, 5, "R2")
    onlySources({}) -- all sites stay yellow; the scan itself still runs over the whole range
    teleport(A.x + 2, A.y + 2, 0)
    wait(90)
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    for _, r in ipairs({ 20, 40, 60 }) do
        BuildAheadFetch.RANGE = r
        BuildAheadFetch.scanCache = nil
        local scans = BuildAheadFetch.stats.scans
        local t0 = getTimestampMs()
        local list = BuildAheadFetch.scan(p, px, py, 0)
        local ms = getTimestampMs() - t0
        log("R2 fresh scan, range", r, ":", ms, "ms,", BuildAheadFetch.stats.scans - scans, "blocks,", #list, "sources")
        if r == 40 then check("R2 a fresh scan at 40 stays short", ms <= 250, ms .. " ms") end
    end
    BuildAheadFetch.RANGE = 40
    BuildAheadFetch.scanCache = nil
    local avg0, worst0 = frameTimes(300)
    log("R2 frame time without sites: avg", avg0, "worst", worst0)
    -- 32 frames without materials: yellow, every one looks for materials within 40
    local probe = makeCursor(entityInfo(FRAME), 1)
    local n = 0
    for r = 2, 12, 2 do
        for dx = -r, r, 2 do
            for dy = -r, r, 2 do
                if n < 32 and math.max(math.abs(dx), math.abs(dy)) == r then
                    local s = sq(px + dx, py + dy, 0)
                    if s and probe:isValid(s) then
                        BuildAhead.addSite(FRAME, px + dx, py + dy, 0, 1)
                        n = n + 1
                    end
                end
            end
        end
    end
    check("R2 32 sites planned", n == 32, "sites " .. n)
    local _, worstW = frameTimes(60)
    log("R2 first evaluation of the new sites: worst frame", worstW, "ms")
    local avg1, worst1 = frameTimes(600)
    log("R2 frame time with", n, "sites at range 40: avg", avg1, "worst", worst1, "blocks scanned", BuildAheadFetch.stats.scans)
    check("R2 ghosts at range 40 cost little per frame", avg1 <= avg0 + 5, "avg " .. avg1 .. " ms vs " .. avg0 .. " ms")
    check("R2 no long frames at range 40", worst1 <= math.max(100, worst0 * 2), "worst " .. worst1 .. " ms vs " .. worst0 .. " ms")
    local t1 = getTimestampMs()
    BuildAhead.pickNext(p, px, py, 0)
    log("R2 scheduler pick among", n, "sites took", getTimestampMs() - t1, "ms")
    clearSites()
end

-- ---------------------------------------------------------------- D drag

local FLOOR = "WoodFloorLvl1"

local function scenarioDragFloor()
    local p = player()
    clearSites()
    clearBag()
    local info = entityInfo(FLOOR)
    if not check("D1 recipe " .. FLOOR, info ~= nil) then return end
    local A = findArea(7, 6, "D1")
    onlySources({})
    teleport(A.x, A.y + 5, 0)
    wait(60)
    local c0 = makeCursor(info, 1)
    check("D1 the floor drags as a range", BuildAhead.dragKind(c0) == "floor", tostring(BuildAhead.dragKind(c0)))
    local sx, sy = A.x + 2, A.y + 1
    local c, valid = drag(info, 1, sx, sy, sx + 2, sy + 1)
    check("D1 release on the range is valid", valid)
    local all = true
    for x = sx, sx + 2 do
        for y = sy, sy + 1 do
            if not siteAt(FLOOR, x, y, 0) then all = false end
        end
    end
    check("D1 six floor sites, one per square", siteCount(FLOOR) == 6 and all, "sites " .. siteCount(FLOOR))
    check("D1 the drag is cleared after the release", c.buildAheadDrag == nil)
    -- build them: hammer, 6 planks, 6 nails
    local inv = p:getInventory()
    inv:AddItem("Base.Hammer")
    addTo(inv, "Base.Plank", 6)
    addTo(inv, "Base.Nails", 6)
    R.performed = {}
    startChain()
    waitIdle(60 * 300, "D1 chain")
    local built = 0
    for x = sx, sx + 2 do
        for y = sy, sy + 1 do
            if hasObject(x, y, 0, FLOOR) then built = built + 1 end
        end
    end
    check("D1 all six floors built", built == 6, "built " .. built .. " performs " .. #R.performed)
    check("D1 sites removed", siteCount(FLOOR) == 0, "sites " .. siteCount(FLOOR))
    clearSites()
    clearBag()
end

local function scenarioDragWall()
    clearSites()
    local info = entityInfo(FRAME)
    local A = findArea(8, 8, "D2")
    teleport(A.x, A.y + 7, 0)
    wait(30)
    local c0 = makeCursor(info, 1)
    check("D2 the wall frame drags as a line", BuildAhead.dragKind(c0) == "wall", tostring(BuildAhead.dragKind(c0)))
    -- along x (a little off the axis): north walls on y = sy
    local sx, sy = A.x + 1, A.y + 1
    local c = drag(info, 1, sx, sy, sx + 4, sy + 1)
    stopChain()
    local northOk = true
    for x = sx, sx + 4 do
        local s = siteAt(FRAME, x, sy, 0)
        if not s or s.nSprite ~= 2 then northOk = false end
    end
    check("D2 line along x: five north wall frames", siteCount(FRAME) == 5 and northOk and c.north == true,
        "sites " .. siteCount(FRAME) .. " cursor north " .. tostring(c.north))
    clearSites()
    -- along y: west walls on x = sx
    c = drag(info, 2, sx + 6, sy, sx + 6, sy + 4)
    stopChain()
    local westOk = true
    for y = sy, sy + 4 do
        local s = siteAt(FRAME, sx + 6, y, 0)
        if not s or s.nSprite ~= 1 then westOk = false end
    end
    check("D2 line along y: five west wall frames", siteCount(FRAME) == 5 and westOk and not c.north,
        "sites " .. siteCount(FRAME) .. " cursor north " .. tostring(c.north))
    -- the chain may have started on these (no materials: nothing to do); stop it before clearing
    stopChain()
    clearSites()
end

local function scenarioDragBack()
    clearSites()
    local info = entityInfo(FRAME)
    local A = findArea(4, 4, "D3")
    local sx, sy = A.x + 1, A.y + 1
    local c = makeCursor(info, 1)
    c.square = sq(sx, sy, 0)
    c.isLeftDown = true
    c:rotateMouse(sx + 3, sy)
    check("D3 a range while dragged", c.buildAheadDrag ~= nil)
    c:rotateMouse(sx, sy)
    check("D3 back on the pressed square: no range", c.buildAheadDrag == nil)
    c.isLeftDown = false
    c:tryBuild(sx, sy, 0)
    stopChain()
    check("D3 one site, as a click", siteCount(FRAME) == 1 and siteAt(FRAME, sx, sy, 0) ~= nil, "sites " .. siteCount(FRAME))
    clearSites()
end

local function scenarioDragOther()
    clearSites()
    local info = entityInfo("Wood_Crate_Lvl2")
    if not check("D4 crate recipe", info ~= nil) then return end
    local A = findArea(5, 5, "D4")
    local sx, sy = A.x + 2, A.y + 2
    local c = makeCursor(info, 1)
    check("D4 a crate does not drag as a range", BuildAhead.dragKind(c) == false, tostring(BuildAhead.dragKind(c)))
    c.square = sq(sx, sy, 0)
    c.isLeftDown = true
    c:rotateMouse(sx, sy - 2) -- vanilla: drag north turns it to nSprite 2
    check("D4 vanilla turns it toward the mouse", c.nSprite == 2 and c.buildAheadDrag == nil, "nSprite " .. tostring(c.nSprite))
    c.isLeftDown = false
    c:getSprite()
    c:tryBuild(sx, sy, 0)
    check("D4 one site", #BuildAhead.getSites() == 1, "sites " .. #BuildAhead.getSites())
    stopChain()
    clearSites()
end

local function scenarioDragBlocked()
    clearSites()
    local info = entityInfo(FLOOR)
    local A = findArea(5, 4, "D5")
    local sx, sy = A.x + 1, A.y + 1
    -- one square of the 3x2 range has this floor already (BuildRecipeCode.floor.OnIsValid
    -- refuses a square holding the same sprite)
    local blocked = sq(sx + 1, sy + 1, 0)
    local c = makeCursor(info, 1)
    pcall(function()
        local name = c:getFace():getTileInfo(0, 0, 0):getSpriteName()
        blocked:AddTileObject(IsoObject.new(blocked, name))
    end)
    local blockedValid = c:isValid(blocked)
    log("D5 floor valid on the crate's square:", tostring(blockedValid))
    drag(info, 1, sx, sy, sx + 2, sy + 1)
    if blockedValid then
        check("D5 (the square was not blocked after all: all six planned)", siteCount(FLOOR) == 6, "sites " .. siteCount(FLOOR))
    else
        check("D5 the blocked square left out: five sites", siteCount(FLOOR) == 5 and siteAt(FLOOR, sx + 1, sy + 1, 0) == nil,
            "sites " .. siteCount(FLOOR))
    end
    stopChain()
    clearSites()
end

local function scenarioDragCap()
    clearSites()
    local info = entityInfo(FLOOR)
    local p = player()
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    -- the range's width and height as squares, from dragSquares
    local function shape(list)
        local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
        for _, q in ipairs(list) do
            x0, x1 = math.min(x0, q.x), math.max(x1, q.x)
            y0, y1 = math.min(y0, q.y), math.max(y1, q.y)
        end
        if #list == 0 then return 0, 0 end
        return x1 - x0 + 1, y1 - y0 + 1
    end
    local function floorDrag(dx, dy)
        local c = makeCursor(info, 1)
        c.square = sq(px, py, 0)
        c.isLeftDown = true
        c:rotateMouse(px + dx, py + dy)
        local list = BuildAhead.dragSquares(c) or {}
        c.isLeftDown = false
        c.buildAheadDrag = nil
        return list
    end
    -- each case: the drag (dx, dy) and the floor it must give (w x h, every square)
    for _, k in ipairs({ { 29, 29, 30, 30 }, { 29, 4, 30, 5 }, { 4, 29, 5, 30 }, { -19, -9, 20, 10 },
        { 39, 39, 40, 40 }, { 59, 59, 40, 40 }, { 59, 2, 40, 3 } }) do
        local list = floorDrag(k[1], k[2])
        local w, h = shape(list)
        check("D6 floor drag " .. (math.abs(k[1]) + 1) .. "x" .. (math.abs(k[2]) + 1) .. " gives " .. k[3] .. "x" .. k[4],
            w == k[3] and h == k[4] and #list == k[3] * k[4], "got " .. w .. "x" .. h .. " squares " .. #list)
        if k[1] == 29 and k[2] == 29 then
            check("D6 nearest the pressed square first", list[1] and list[1].x == px and list[1].y == py)
        end
    end
    -- walls: a line of 40 at most, either axis
    local frame = entityInfo(FRAME)
    for _, k in ipairs({ { 29, 0, 30 }, { 59, 0, 40 }, { 0, 59, 40 } }) do
        local c = makeCursor(frame, 1)
        c.square = sq(px, py, 0)
        c.isLeftDown = true
        c:rotateMouse(px + k[1], py + k[2])
        local n = #(BuildAhead.dragSquares(c) or {})
        c.isLeftDown = false
        c.buildAheadDrag = nil
        check("D6 wall drag " .. math.max(k[1], k[2]) + 1 .. " long gives " .. k[3], n == k[3], "got " .. n)
    end
end

-- vanilla counts the button as up over the inventory window and "releases" there
-- (DoTileBuilding then calls tryBuild, and moves cursor.square to the mouse after);
-- with the mouse button really held the drag goes on from the pressed square
local function scenarioDragOverInventory()
    clearSites()
    local info = entityInfo(FLOOR)
    local A = findArea(6, 5, "D8")
    local sx, sy = A.x + 1, A.y + 1
    local held = true
    local orig = BuildAhead.heldOverInventory
    BuildAhead.heldOverInventory = function() return held end
    local ok, err = pcall(function()
        local c = makeCursor(info, 1)
        c.square = sq(sx, sy, 0)
        c.isLeftDown = true
        c:rotateMouse(sx, sy)
        c:rotateMouse(sx + 2, sy + 1)
        -- the false release over the inventory, as DoTileBuilding does it
        c.isLeftDown = false
        c.build = true
        if c:isValid(c.square) then
            c.build = false
            c:tryBuild(sx, sy, 0)
        end
        c.build = false
        check("D8 no sites while the button is held over the inventory", siteCount(FLOOR) == 0, "sites " .. siteCount(FLOOR))
        check("D8 the range is kept", c.buildAheadDrag ~= nil)
        -- next frames over the inventory: the cursor follows the mouse, render puts it back
        c.square = sq(sx + 4, sy + 3, 0)
        pcall(c.render, c, sx + 4, sy + 3, 0, c.square)
        check("D8 the range is still kept after a frame", c.buildAheadDrag ~= nil)
        -- back in the world, still held: the drag goes on from the pressed square
        c.square = sq(sx + 4, sy + 3, 0)
        c.isLeftDown = true
        c:rotateMouse(sx + 3, sy + 2)
        local d = c.buildAheadDrag
        check("D8 the drag keeps its pressed square", d and d.sx == sx and d.sy == sy and c.square:getX() == sx,
            d and (d.sx .. "," .. d.sy) or "no drag")
        -- the real release
        held = false
        c.isLeftDown = false
        c.build = true
        if c:isValid(c.square) then
            c.build = false
            c:tryBuild(sx, sy, 0)
        end
        stopChain()
        check("D8 the real release plans the whole 4x3 range", siteCount(FLOOR) == 12, "sites " .. siteCount(FLOOR))
        -- released over the inventory: no release comes, the drag ends without sites
        clearSites()
        held = true
        c = makeCursor(info, 1)
        c.square = sq(sx, sy, 0)
        c.isLeftDown = true
        c:rotateMouse(sx + 2, sy)
        c.isLeftDown = false
        c:tryBuild(sx, sy, 0)
        held = false
        pcall(c.render, c, sx, sy, 0, c.square)
        check("D8 let go over the inventory: drag ends, no sites", c.buildAheadDrag == nil and siteCount(FLOOR) == 0,
            "sites " .. siteCount(FLOOR))
    end)
    BuildAhead.heldOverInventory = orig
    if not ok then check("D8 ran", false, tostring(err)) end
    stopChain()
    clearSites()
end

local function scenarioDragOff()
    clearSites()
    local info = entityInfo(FRAME)
    local A = findArea(5, 5, "D7")
    local sx, sy = A.x + 1, A.y + 1
    BuildAhead.DRAG_ENABLED = false
    local c = makeCursor(info, 1)
    c.square = sq(sx, sy, 0)
    c.isLeftDown = true
    c:rotateMouse(sx + 3, sy)
    check("D7 DragBuild off: no range, vanilla turns it east", c.buildAheadDrag == nil and c.nSprite == 3,
        "nSprite " .. tostring(c.nSprite))
    c.isLeftDown = false
    BuildAhead.DRAG_ENABLED = true
    clearSites()
end

-- ---------------------------------------------------------------- runner

-- ---------------------------------------------------------------- M shared materials

-- M1: materials for two floors, four floors planned: the two nearest the player
-- are buildable, the other two miss a plank and a nail (each site no longer counts
-- the same planks for itself)
local function scenarioShared()
    local p = player()
    clearSites()
    clearBag()
    local A = findArea(6, 3, "M1")
    teleport(A.x, A.y + 1, 0)
    wait(30)
    onlySources({}) -- only what the player carries
    local inv = p:getInventory()
    inv:AddItem("Base.Hammer")
    addTo(inv, "Base.Plank", 2)
    addTo(inv, "Base.Nails", 2)
    local sx, sy = A.x + 1, A.y + 1
    for i = 0, 3 do BuildAhead.addSite(FLOOR, sx + i, sy, 0, 1) end
    check("M1 four floor sites", siteCount(FLOOR) == 4, "sites " .. siteCount(FLOOR))
    BuildAhead.dropAllocation()
    local okAt, missAt = {}, {}
    for _, site in ipairs(BuildAhead.getSites()) do
        local ok, missing = BuildAhead.materialsAvailable(p, site)
        if ok then okAt[#okAt + 1] = site.x - sx else missAt[#missAt + 1] = site.x - sx .. ":" .. table.concat(missing or {}, "/") end
    end
    table.sort(okAt)
    log("M1 buildable", table.concat(okAt, ","), "missing", table.concat(missAt, " "))
    check("M1 two buildable, the two nearest", #okAt == 2 and okAt[1] == 0 and okAt[2] == 1,
        "buildable " .. table.concat(okAt, ","))
    check("M1 the other two miss materials", #missAt == 2, table.concat(missAt, " "))
    -- two more planks and nails: all four
    addTo(inv, "Base.Plank", 2)
    addTo(inv, "Base.Nails", 2)
    BuildAhead.dropAllocation()
    local all = 0
    for _, site in ipairs(BuildAhead.getSites()) do
        if BuildAhead.materialsAvailable(p, site) then all = all + 1 end
    end
    check("M1 with four planks all four buildable", all == 4, "buildable " .. all)
    -- a box of nails (100) instead of loose nails covers all four
    clearBag()
    inv:AddItem("Base.Hammer")
    addTo(inv, "Base.Plank", 4)
    inv:AddItem("Base.NailsBox")
    BuildAhead.dropAllocation()
    all = 0
    for _, site in ipairs(BuildAhead.getSites()) do
        if BuildAhead.materialsAvailable(p, site) then all = all + 1 end
    end
    check("M1 a box of nails counts as 100 nails", all == 4, "buildable " .. all)
    BuildAheadFetch.sourceFilter = nil
    clearSites()
    clearBag()
end

-- M2: 400 floor sites planned at once (no materials): frame times while their
-- ghosts are drawn and checked, the shared allocation and the scheduler's pick
local function scenarioManySites()
    local p = player()
    clearSites()
    clearBag()
    BuildAheadFetch.sourceFilter = nil
    local avg0, worst0 = frameTimes(300)
    log("M2 frame time without sites: avg", avg0, "worst", worst0)
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    -- as a drag's release adds them: all at once
    local entries = {}
    for dx = -10, 9 do
        for dy = -10, 9 do
            if dx ~= 0 or dy ~= 0 then
                entries[#entries + 1] = { name = FLOOR, x = px + dx, y = py + dy, z = 0, nSprite = 1 }
            end
        end
    end
    local t0 = getTimestampMs()
    local n = #BuildAhead.addSites(entries)
    local addMs = getTimestampMs() - t0
    log("M2 planned", n, "sites in", addMs, "ms")
    check("M2 adding them is quick", addMs <= 50, addMs .. " ms")
    check("M2 about 400 sites planned", n >= 390, "sites " .. n)
    local _, worstFirst = frameTimes(60)
    log("M2 first frames after planning: worst", worstFirst, "ms")
    check("M2 no freeze when they are planned", worstFirst <= math.max(150, worst0 * 3),
        "worst " .. worstFirst .. " ms vs " .. worst0 .. " ms")
    local avg1, worst1 = frameTimes(600)
    log("M2 frame time with", n, "sites: avg", avg1, "worst", worst1)
    check("M2 ghosts cost little per frame", avg1 <= avg0 + 8, "avg " .. avg1 .. " ms vs " .. avg0 .. " ms")
    check("M2 no long frames", worst1 <= math.max(150, worst0 * 3), "worst " .. worst1 .. " ms vs " .. worst0 .. " ms")
    local checked = 0
    for _, site in ipairs(BuildAhead.getSites()) do
        if BuildAhead.ghostState(site) then checked = checked + 1 end
    end
    check("M2 every ghost checked within 10 s", checked == n, "checked " .. checked .. " of " .. n)
    BuildAhead.dropAllocation()
    local t1 = getTimestampMs()
    BuildAhead.allocation(p)
    log("M2 shared allocation of", n, "sites took", getTimestampMs() - t1, "ms")
    local t2 = getTimestampMs()
    BuildAhead.pickNext(p, px, py, 0)
    local pickMs = getTimestampMs() - t2
    log("M2 scheduler pick among", n, "sites took", pickMs, "ms")
    check("M2 the pick stays short", pickMs <= 100, pickMs .. " ms")
    clearSites()
end

-- M3: materials for three wall frames, nine sites on a grid with equal distances: the
-- chain builds nearest to the last build (list order on ties), and the shared materials
-- follow that order (they went to the sites nearest the player before)
local function scenarioChainOrder()
    local p = player()
    clearSites()
    clearBag()
    local A = findArea(9, 9, "M3")
    teleport(A.x + 4, A.y + 4, 0)
    wait(30)
    onlySources({})
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    for dy = -2, 2, 2 do
        for dx = -2, 2, 2 do
            if dx ~= 0 or dy ~= 0 then BuildAhead.addSite(FRAME, px + dx, py + dy, 0, 1) end
        end
    end
    local inv = p:getInventory()
    inv:AddItem("Base.Hammer")
    addTo(inv, "Base.Plank", 6)
    addTo(inv, "Base.Nails", 6)
    local expected, used = {}, {}
    local ox, oy = px, py
    for _ = 1, 3 do
        local best, bestD
        for _, s in ipairs(BuildAhead.getSites()) do
            local d = (s.x - ox) ^ 2 + (s.y - oy) ^ 2
            if not used[s.id] and d <= 400 and (not bestD or d < bestD) then best, bestD = s, d end
        end
        used[best.id] = true
        expected[#expected + 1] = best.x .. "," .. best.y
        ox, oy = best.x, best.y
    end
    R.performed = {}
    BuildAhead.schedule(p, px, py, 0)
    waitIdle(60 * 120, "M3 chain")
    local got = {}
    for _, b in ipairs(R.performed) do got[#got + 1] = b.x .. "," .. b.y end
    check("M3 chain builds nearest to the last build", table.concat(got, " ") == table.concat(expected, " "),
        "built " .. table.concat(got, " ") .. " expected " .. table.concat(expected, " "))
    check("M3 the other five stay planned", #BuildAhead.getSites() == 5, "sites " .. #BuildAhead.getSites())
    BuildAheadFetch.sourceFilter = nil
    stopChain()
    clearSites()
    clearBag()
end

local SCENARIOS = {
    { "S0 settings", scenarioSettings },
    { "P1 box in the inventory", scenarioPackCarried },
    { "P2 box fetched", scenarioPackFetched },
    { "P3 box not needed", scenarioPackNotNeeded },
    { "P4 packs off", scenarioPackOff },
    { "P5 nails banned", scenarioPackBanned },
    { "R1 materials 30 tiles away", scenarioRange },
    { "R2 range cost", scenarioRangeCost },
    { "D1 floor range", scenarioDragFloor },
    { "D2 wall lines", scenarioDragWall },
    { "D3 back on the pressed square", scenarioDragBack },
    { "D4 crate", scenarioDragOther },
    { "D5 blocked square", scenarioDragBlocked },
    { "D6 cap", scenarioDragCap },
    { "D8 over inventory", scenarioDragOverInventory },
    { "D7 drag off", scenarioDragOff },
    { "M1 shared", scenarioShared },
    { "M2 many sites", scenarioManySites },
    { "M3 chain order", scenarioChainOrder },
}

local function reset()
    local p = player()
    pcall(function() BuildAheadFetch.abort("test reset") end)
    pcall(function() ISTimedActionQueue.clear(p) end)
    pcall(clearSites)
    pcall(clearBag)
end

local function finish()
    R.phase = "done"
    ISBuildMenu.cheat = R.cheat
    -- leave the settings as the sandbox has them
    pcall(BuildAhead.applySandbox)
    pcall(function()
        local p = player()
        p:setGodMod(false)
        p:setInvisible(false)
        p:setZombiesDontAttack(false)
    end)
    log("RESULT pass", R.pass, "fail", R.fail)
    log("test done")
end

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
    if R.phase ~= "run" then return end
    if getGameSpeed() == 0 then pcall(setGameSpeed, 1) end
    if not R.co then return end
    local okCall, okCo, err = pcall(coroutine.resume, R.co)
    if not (okCall and okCo) then
        local msg = okCall and err or okCo
        local name = R.list[R.index] and R.list[R.index][1] or "?"
        R.fail = R.fail + 1
        log("ERROR in", name, msg)
        if harness() then PZTest.fail("BuildAheadTest4 ERROR " .. name .. " " .. tostring(msg)) end
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

BuildAheadTest4 = {}

-- only: "P,D2" runs just the scenarios whose names start with these
function BuildAheadTest4.start(only)
    if R.phase ~= "idle" then
        PZTest.fail("BuildAheadTest4 already ran in this game; pzt stop, then run again")
        return
    end
    R.phase = "run"
    hookPerform()
    setupPlayer()
    -- vanilla's build walks and checks as in a normal game (-debug turns the cheat on)
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
    log("start; player build cheat", tostring(player():isBuildCheat()))
    startScenario(1)
end

function BuildAheadTest4.poll()
    if R.phase == "done" then
        PZTest.log("BuildAheadTest4 pass " .. R.pass .. " fail " .. R.fail)
        return
    end
    PZTest.step("wait 30")
    PZTest.step("lua BuildAheadTest4.poll()")
end
