-- Multiplayer test, client side (tools/mptest.sh creates Zomboid/Lua/buildahead_mptest.txt
-- in the client's folder only; on the server this file does nothing).
-- From the main menu it connects to the local dedicated server as admin, skips
-- character creation, then checks:
--   1. an idle click plans a site and builds it at once, claimed on the server by square;
--      clicks while building send sites to the server and come back with server ids
--   2. the chain builds the planned sites through the server (materials from the server inventory)
--   3. the built sites are removed on the server; the one without materials stays (yellow)
--   4. cancelling from the right-click menu removes the site on the server
--   5. with LongStick banned, a StickFence built through the server uses saplings only
--   6. fetching: planks and nails dropped on the floor are picked up, carried to a site
--      a few tiles away and consumed by the build from the inventory (one trip: no drop)
--   7. interruption: moving while walking to a build stops it; the server releases the claim
--      at once (no stuck claim), the site stays planned; "Build planned" resumes and builds it
--   8. persistence, part 1: two sites are planned and the client asks the server to save and
--      quit (/quit); tools/mptest.sh restarts the server and the client again, and part 2
--      (trigger file "persist") checks that the server's list still has them
-- Results: "[BuildAheadMP]" lines in the client console.txt, "[BuildAhead] server" lines in the server's.

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAheadMP] " .. table.concat(parts, " "))
end

local r = getFileReader("buildahead_mptest.txt", false)
if not r then return end
local MODE = r:readLine() or "on"
r:close()
local PERSIST_FILE = "buildahead_mppersist.txt"

local USER, PASS = "admin", "buildahead"
local T = { fe = 0, tick = 0, phase = "wait", pass = 0, fail = 0, received = 0 }

local function check(label, ok, extra)
    if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
    log(ok and "PASS" or "FAIL", label, extra or "")
end

-- ---------------------------------------------------------------- main menu: connect

local function onFETick()
    T.fe = T.fe + 1
    if T.fe == 200 and not T.connecting and MainScreen and MainScreen.instance then
        T.connecting = true
        log("connecting")
        ConnectToServer.instance:connect(MainScreen.instance, "", USER, PASS, "127.0.0.1", "", "16361", "", false, true, 1)
    end
    if T.connecting and T.fe % 30 == 0 then
        local prof = MainScreen.instance.charCreationProfession
        local main = MainScreen.instance.charCreationMain
        if prof and prof:isVisible() then
            log("character creation: profession -> next")
            prof:onOptionMouseDown({ internal = "NEXT" })
        elseif main and main:isVisible() then
            log("character creation: main -> next")
            main:onOptionMouseDown({ internal = "NEXT" })
        elseif MapSpawnSelect.instance and MapSpawnSelect.instance:isVisible() then
            log("spawn select -> next")
            MapSpawnSelect.instance:onOptionMouseDown({ internal = "NEXT" })
        end
    end
end
Events.OnFETick.Add(onFETick)
Events.OnConnectFailed.Add(function(msg, detail) log("connect failed", msg, detail) end)

-- ---------------------------------------------------------------- in game

Events.OnReceiveGlobalModData.Add(function(key)
    if key == "BuildAhead" then T.received = T.received + 1 end
end)

local function player() return getSpecificPlayer(0) end

local function hasObject(x, y, z, name)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if objs:get(i):getName() == name then return true end
    end
    return false
end

local function info()
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if i:getName() == "WoodenWallFrame" then return i end
    end
end

local function makeCursor()
    local p = player()
    local c = ISBuildIsoEntity:new(p, T.info, 1, ISInventoryPaneContextMenu.getContainers(p))
    c.player = 0
    c.dragNilAfterPlace = false
    c.blockAfterPlace = true
    c.firstItem = "Base.BallPeenHammerForged"
    c:getSprite()
    return c
end

local function validSquares(rmin, rmax)
    local p = player()
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local probe = makeCursor()
    local out = {}
    for rr = rmin or 2, rmax or 6 do
        for dx = -rr, rr do
            for dy = -rr, rr do
                if math.max(math.abs(dx), math.abs(dy)) == rr then
                    local sq = getCell():getGridSquare(px + dx, py + dy, pz)
                    local spaced = true
                    for _, q in ipairs(out) do
                        if math.abs(q.x - px - dx) <= 1 and math.abs(q.y - py - dy) <= 1 then spaced = false end
                    end
                    if sq and spaced and probe:isValid(sq) then
                        out[#out + 1] = { x = px + dx, y = py + dy, z = pz, d = dx * dx + dy * dy }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function serverIds()
    local all = true
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.id <= 0 then all = false end
    end
    return all
end

local function give()
    local u = '"' .. player():getUsername() .. '"'
    SendCommandToServer("/additem " .. u .. ' "Base.BallPeenHammerForged"')
    -- enough for A and one more frame (2 planks + 2 nails each)
    for _ = 1, 4 do
        SendCommandToServer("/additem " .. u .. ' "Base.Plank"')
        SendCommandToServer("/additem " .. u .. ' "Base.Nails"')
    end
    SendCommandToServer("/addxp " .. u .. " Woodwork=3000 -false")
    SendCommandToServer("/godmod " .. u .. " -true")
    SendCommandToServer("/invisible " .. u .. " -true")
end

local steps = {}

steps.start = function(t)
    log("in game as", player():getUsername(), "at", math.floor(player():getX()), math.floor(player():getY()),
        "isClient", tostring(isClient()), "hooked", tostring(BuildAhead.hooked))
    T.info = info()
    give()
    return "items", t + 300
end

steps.items = function(t)
    local inv = player():getInventory()
    log("inventory planks", inv:getCountTypeRecurse("Base.Plank"), "nails", inv:getCountTypeRecurse("Base.Nails"),
        "hammer", inv:getCountTypeRecurse("Base.BallPeenHammerForged"), "woodwork", player():getPerkLevel(Perks.Woodwork))
    local sq = validSquares()
    log("valid squares", #sq)
    if #sq < 4 then
        check("enough squares", false)
        return "quit", t
    end
    T.A, T.B, T.C = sq[1], sq[2], sq[#sq]
    for _, k in ipairs({ "A", "B", "C" }) do log("square", k, T[k].x, T[k].y, T[k].z) end
    T.cursor = makeCursor()
    T.receivedBefore = T.received
    T.cursor:tryBuild(T.A.x, T.A.y, T.A.z)
    check("1 idle click plans a site", #BuildAhead.getSites() == 1, "sites " .. #BuildAhead.getSites())
    check("1 idle click starts a build", BuildAhead.isBuilding(player()) == true)
    return "plan", t + 20
end

steps.plan = function(t)
    local c = T.cursor
    c.blockBuild = true
    c:tryBuild(T.B.x, T.B.y, T.B.z)
    c:tryBuild(T.C.x, T.C.y, T.C.z)
    check("1 three sites planned locally", #BuildAhead.getSites() == 3, "sites " .. #BuildAhead.getSites())
    return "synced", t + 60
end

steps.synced = function(t)
    check("1 server sent the list back", T.received > T.receivedBefore, "received " .. T.received)
    local sites = BuildAhead.getSites()
    check("1 sites have server ids", serverIds() and #sites >= 2, "sites " .. #sites)
    for _, s in ipairs(sites) do
        if s.x == T.A.x and s.y == T.A.y then
            check("1 site being built is claimed on the server", s.claimBy == player():getUsername(),
                tostring(s.claimBy))
        end
    end
    T.chainStart = t
    return "chain", t
end

steps.chain = function(t)
    local p = player()
    local busy = #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
    if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
    if T.idleSince and t - T.idleSince > 240 then
        check("2 A built", hasObject(T.A.x, T.A.y, T.A.z, "WoodenWallFrame"))
        check("2 nearest site B built by the chain", hasObject(T.B.x, T.B.y, T.B.z, "WoodenWallFrame"))
        check("2 C not built (no materials left)", not hasObject(T.C.x, T.C.y, T.C.z, "WoodenWallFrame"))
        local sites = BuildAhead.getSites()
        check("3 only C left (server list)", #sites == 1 and sites[1].x == T.C.x and sites[1].y == T.C.y and sites[1].id > 0,
            "sites " .. #sites)
        local state = sites[1] and BuildAhead.siteState(p, sites[1])
        check("3 C: materials missing", state == "missing", tostring(state))
        return "cancel", t
    end
    if t - T.chainStart > 60 * 240 then
        check("2 chain finished in time", false)
        return "quit", t
    end
    return "chain", t
end

steps.cancel = function(t)
    local fake = { options = {} }
    function fake:addOption(name, target, fn)
        table.insert(self.options, { name = name, target = target, fn = fn })
    end
    local sq = getCell():getGridSquare(T.C.x, T.C.y, T.C.z)
    BuildAhead.fillContextMenu(0, fake, { sq:getFloor() or sq:getObjects():get(0) }, false)
    local prefix = getText("IGUI_BuildAhead_CancelSite", "")
    local opt
    for _, o in ipairs(fake.options) do
        if string.sub(o.name, 1, #prefix) == prefix then opt = o end
    end
    check("4 cancel option shown", opt ~= nil)
    if opt then opt.fn(opt.target) end
    T.receivedBefore = T.received
    return "cancelled", t + 120
end

steps.cancelled = function(t)
    check("4 server confirmed the removal", T.received > T.receivedBefore and #BuildAhead.getSites() == 0,
        "sites " .. #BuildAhead.getSites())
    -- 5. a banned material is not used by a build the server performs
    local u = '"' .. player():getUsername() .. '"'
    for _ = 1, 6 do
        SendCommandToServer("/additem " .. u .. ' "Base.LongStick"')
        SendCommandToServer("/additem " .. u .. ' "Base.Sapling"')
    end
    for _ = 1, 2 do SendCommandToServer("/additem " .. u .. ' "Base.RippedSheets"') end
    return "banBuild", t + 300
end

local function count(fullType) return player():getInventory():getCountTypeRecurse(fullType) end

steps.banBuild = function(t)
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if i:getName() == "StickFence" then T.fence = i end
    end
    BuildAhead.setBanned(player(), "Base.LongStick", true)
    T.sticks, T.saplings = count("Base.LongStick"), count("Base.Sapling")
    log("fence materials: sticks", T.sticks, "saplings", T.saplings, "sheets", count("Base.RippedSheets"))
    local saved = T.info
    T.info = T.fence
    local sq = validSquares()
    local c = makeCursor()
    T.info = saved
    if #sq == 0 then
        check("5 fence square", false)
        return "quit", t
    end
    T.F = sq[1]
    c:tryBuild(T.F.x, T.F.y, T.F.z)
    check("5 fence build started", BuildAhead.isBuilding(player()) == true)
    T.idleSince, T.banStart = nil, t
    return "banWait", t
end

steps.banWait = function(t)
    local busy = #ISTimedActionQueue.getTimedActionQueue(player()).queue > 0
    if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
    if T.idleSince and t - T.idleSince > 240 then
        check("5 fence built", hasObject(T.F.x, T.F.y, T.F.z, "StickFence"))
        check("5 banned LongStick not used", count("Base.LongStick") == T.sticks,
            T.sticks .. " -> " .. count("Base.LongStick"))
        check("5 saplings used instead", count("Base.Sapling") == T.saplings - 6,
            T.saplings .. " -> " .. count("Base.Sapling"))
        BuildAhead.setBanned(player(), "Base.LongStick", false)
        return "fetchGive", t
    end
    if t - T.banStart > 60 * 240 then
        check("5 fence build finished in time", false)
        return "quit", t
    end
    return "banWait", t
end

-- 6. fetching through the server
local function floorCount(x, y, z, fullType)
    local sq = getCell():getGridSquare(x, y, z)
    local wobs = sq and sq:getWorldObjects()
    local n = 0
    for i = 0, (wobs and wobs:size() or 0) - 1 do
        local it = wobs:get(i):getItem()
        if it and it:getFullType() == fullType then n = n + 1 end
    end
    return n
end

steps.fetchGive = function(t)
    local u = '"' .. player():getUsername() .. '"'
    for _ = 1, 2 do
        SendCommandToServer("/additem " .. u .. ' "Base.Plank"')
        SendCommandToServer("/additem " .. u .. ' "Base.Nails"')
    end
    return "fetchDrop", t + 300
end

-- one drop at a time: queued together, only the first one went through
steps.fetchDrop = function(t)
    local p = player()
    if #ISTimedActionQueue.getTimedActionQueue(p).queue > 0 then return "fetchDrop", t + 20 end
    local sq = p:getCurrentSquare()
    T.drop = T.drop or { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
    T.drops = (T.drops or 0) + 1
    local items = p:getInventory():getItems()
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        -- the materials, and the fence leftovers so one trip carries the planks
        local ft = it:getFullType()
        if (ft == "Base.Plank" or ft == "Base.Nails" or ft == "Base.LongStick" or ft == "Base.Sapling"
            or ft == "Base.RippedSheets") and not it:isEquipped() and T.drops <= 30 then
            ISTimedActionQueue.add(ISDropWorldItemAction:new(p, it, sq, 0.5, 0.5, 0, 0, false))
            return "fetchDrop", t + 60
        end
    end
    return "fetchClick", t + 60
end

steps.fetchClick = function(t)
    local p = player()
    if #ISTimedActionQueue.getTimedActionQueue(p).queue > 0 then return "fetchClick", t + 30 end
    local d = T.drop
    log("dropped: planks", floorCount(d.x, d.y, d.z, "Base.Plank"), "nails", floorCount(d.x, d.y, d.z, "Base.Nails"),
        "bag planks", count("Base.Plank"), "free weight", BuildAheadFetch.freeWeight(p))
    local site
    for _, q in ipairs(validSquares()) do
        if math.max(math.abs(q.x - d.x), math.abs(q.y - d.y)) >= 3 then site = q end
    end
    if not site or count("Base.Plank") > 0 then
        check("6 fetch setup", false, site and "planks still in the bag" or "no square")
        return "quit", t
    end
    T.W = site
    log("square W", site.x, site.y, site.z)
    T.cursor.blockBuild = false
    -- room for the planks in one trip (the default limit is about two planks)
    T.maxWeight, T.maxWeightBase = p:getMaxWeight(), p:getMaxWeightBase()
    p:setMaxWeightBase(50)
    p:setMaxWeight(50)
    T.drops = BuildAheadFetch.stats.drops
    T.cursor:tryBuild(site.x, site.y, site.z)
    check("6 click starts fetching", BuildAheadFetch.isActive(p))
    T.idleSince, T.fetchStart = nil, t
    return "fetchWait", t
end

steps.fetchWait = function(t)
    local p = player()
    local busy = BuildAhead.isBusy(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
    if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
    if T.idleSince and t - T.idleSince > 240 then
        local d, w = T.drop, T.W
        check("6 wall frame built from fetched materials", hasObject(w.x, w.y, w.z, "WoodenWallFrame"))
        check("6 floor materials picked up", floorCount(d.x, d.y, d.z, "Base.Plank") == 0
            and floorCount(d.x, d.y, d.z, "Base.Nails") == 0)
        local left = count("Base.Plank") + count("Base.Nails")
        for dx = -2, 2 do
            for dy = -2, 2 do
                left = left + floorCount(w.x + dx, w.y + dy, w.z, "Base.Plank") + floorCount(w.x + dx, w.y + dy, w.z, "Base.Nails")
            end
        end
        check("6 fetched materials consumed", left == 0, "left " .. left)
        check("6 one trip: built from the inventory, nothing dropped", BuildAheadFetch.stats.drops == T.drops,
            "drops " .. (BuildAheadFetch.stats.drops - T.drops))
        check("6 site removed on the server", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
        p:setMaxWeightBase(T.maxWeightBase)
        p:setMaxWeight(T.maxWeight)
        return "stopGive", t
    end
    if t - T.fetchStart > 60 * 300 then
        check("6 fetch chain finished in time", false)
        return "quit", t
    end
    return "fetchWait", t
end

-- 7. interruption: moving while walking to a build
steps.stopGive = function(t)
    local u = '"' .. player():getUsername() .. '"'
    for _ = 1, 2 do
        SendCommandToServer("/additem " .. u .. ' "Base.Plank"')
        SendCommandToServer("/additem " .. u .. ' "Base.Nails"')
    end
    return "stopClick", t + 300
end

local function mySite(q)
    for _, s in ipairs(BuildAhead.getSites()) do
        if s.x == q.x and s.y == q.y and s.z == q.z then return s end
    end
end

steps.stopClick = function(t)
    local p = player()
    local far = validSquares(8, 12)
    if #far == 0 or count("Base.Plank") < 2 then
        check("7 interrupt setup", false, "squares " .. #far .. " planks " .. count("Base.Plank"))
        return "persistPlan", t
    end
    T.S = far[#far]
    log("square S", T.S.x, T.S.y, T.S.z)
    -- vanilla's walk to the build, as in a normal game (-debug turns the build cheat on)
    T.cheat = ISBuildMenu.cheat
    ISBuildMenu.cheat = false
    T.cursor.blockBuild = false
    T.cursor:tryBuild(T.S.x, T.S.y, T.S.z)
    check("7 click starts walking to the build", BuildAhead.isBuilding(p) == true)
    return "stopMove", t + 60
end

steps.stopMove = function(t)
    local p = player()
    local site = mySite(T.S)
    check("7 site claimed while walking", site ~= nil and site.claimBy == p:getUsername(), site and tostring(site.claimBy))
    -- what a movement key does: the walk stops, the queue empties
    T.tookOver = BuildAhead.tookOver
    BuildAhead.tookOver = function() return true end
    local q = ISTimedActionQueue.getTimedActionQueue(p).queue
    if q[1] then q[1]:forceStop() end
    ISTimedActionQueue.clear(p)
    T.receivedBefore = T.received
    return "stopCheck", t + 180
end

steps.stopCheck = function(t)
    local p = player()
    BuildAhead.tookOver = T.tookOver
    check("7 build stopped by moving", not BuildAhead.isBusy(p) and #ISTimedActionQueue.getTimedActionQueue(p).queue == 0)
    local site = mySite(T.S)
    check("7 site still planned on the server", site ~= nil and site.id > 0, site and tostring(site.id))
    check("7 server released the claim", T.received > T.receivedBefore and site ~= nil and site.claimBy == nil,
        "received " .. (T.received - T.receivedBefore) .. " claim " .. tostring(site and site.claimBy))
    local opt
    if site then
        local fake = { options = {} }
        function fake:addOption(name, target, fn, arg1)
            local o = { name = name, target = target, fn = fn, arg1 = arg1 }
            table.insert(self.options, o)
            return o
        end
        local sq = getCell():getGridSquare(site.x, site.y, site.z)
        BuildAhead.fillContextMenu(0, fake, { sq:getFloor() or sq:getObjects():get(0) }, false)
        local prefix = getText("IGUI_BuildAhead_BuildSite", "")
        for _, o in ipairs(fake.options) do
            if string.sub(o.name, 1, #prefix) == prefix then opt = o end
        end
    end
    if opt and not opt.notAvailable then opt.fn(opt.target, opt.arg1) end
    check("7 Build planned resumes", opt ~= nil and not opt.notAvailable and BuildAhead.isBuilding(p) == true)
    T.idleSince, T.stopStart = nil, t
    return "stopWait", t
end

steps.stopWait = function(t)
    local p = player()
    local busy = BuildAhead.isBusy(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
    if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
    if T.idleSince and t - T.idleSince > 240 then
        check("7 frame built after resuming", hasObject(T.S.x, T.S.y, T.S.z, "WoodenWallFrame"))
        check("7 site removed on the server", mySite(T.S) == nil, "sites " .. #BuildAhead.getSites())
        ISBuildMenu.cheat = T.cheat
        return "persistPlan", t
    end
    if t - T.stopStart > 60 * 240 then
        check("7 resumed build finished in time", false)
        ISBuildMenu.cheat = T.cheat
        return "persistPlan", t
    end
    return "stopWait", t
end

-- 8. persistence, part 1: sites without materials, kept by the server over a restart
steps.persistPlan = function(t)
    local sq = validSquares(2, 8)
    if #sq < 2 then
        check("8 persistence squares", false)
        return "quit", t
    end
    T.P1, T.P2 = sq[1], sq[#sq]
    BuildAhead.addSite("WoodenWallFrame", T.P1.x, T.P1.y, T.P1.z, 1)
    BuildAhead.addSite("WoodenWallFrame", T.P2.x, T.P2.y, T.P2.z, 2)
    return "persistSave", t + 180
end

steps.persistSave = function(t)
    local sites = BuildAhead.getSites()
    check("8 two sites on the server for the restart", #sites == 2 and serverIds(), "sites " .. #sites)
    local w = getFileWriter(PERSIST_FILE, true, false)
    for _, s in ipairs(sites) do
        w:write(s.name .. " " .. s.x .. " " .. s.y .. " " .. s.z .. " " .. s.nSprite .. " " .. s.id .. "\n")
    end
    w:close()
    log("RESULT pass", T.pass, "fail", T.fail)
    -- the server saves the world (global ModData included) and stops; mptest.sh restarts it
    log("asking the server to save and quit")
    SendCommandToServer("/quit")
    log("test done")
    return "done", t
end

steps.quit = function(t)
    log("RESULT pass", T.pass, "fail", T.fail)
    log("test done")
    return "done", t
end

-- 8. persistence, part 2 (after the server restart)
steps.reloadCheck = function(t)
    local r2 = getFileReader(PERSIST_FILE, false)
    if not r2 then
        check("8 saved list found", false)
        return "quit", t
    end
    local want = {}
    local line = r2:readLine()
    while line do
        local a, b, c, d, e, id = string.match(line, "^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)")
        if a then
            want[#want + 1] = { name = a, x = tonumber(b), y = tonumber(c), z = tonumber(d), nSprite = tonumber(e), id = tonumber(id) }
        end
        line = r2:readLine()
    end
    r2:close()
    local sites = BuildAhead.getSites()
    check("8 server list received after the restart", T.received > 0, "received " .. T.received)
    check("8 as many sites as before the restart", #sites == #want and #want == 2, #sites .. " of " .. #want)
    for _, w in ipairs(want) do
        local found
        for _, s in ipairs(sites) do
            if s.name == w.name and s.x == w.x and s.y == w.y and s.z == w.z and s.nSprite == w.nSprite then found = s end
        end
        check("8 site " .. w.x .. "," .. w.y .. " nSprite " .. w.nSprite .. " kept with its id", found ~= nil and found.id == w.id,
            found and tostring(found.id) or "missing")
    end
    return "quit", t
end

local function onTick()
    local p = player()
    if not p then return end
    T.tick = T.tick + 1
    local t = T.tick
    if T.phase == "wait" then
        if t > 300 then T.phase, T.at = (MODE == "persist" and "reloadCheck" or "start"), t end
        return
    end
    local step = steps[T.phase]
    if not step or t < (T.at or 0) then return end
    local ok, nextPhase, at = pcall(step, t)
    if not ok then
        log("ERROR in", T.phase, nextPhase)
        T.phase, T.at = "quit", t
    else
        T.phase, T.at = nextPhase, at
    end
end

Events.OnRenderTick.Add(function()
    local ok, err = pcall(onTick)
    if not ok and not T.errored then
        T.errored = true
        log("ERROR tick", err)
    end
end)
