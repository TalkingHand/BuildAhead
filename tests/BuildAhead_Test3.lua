-- Single-player in-game test, part 3 (test environment only: pzt installs this file next to
-- BuildAhead_Test.lua, see TEST_FILES in pzt.conf): the chain and broken tools.
-- Seen in a multiplayer game: a fetch gave up ("build lacks <hammer> ... can false"), then the
-- chain built the next site and every later one with the broken hammer in hand.
--   H1 only a broken claw hammer (in hand) and the planks/nails for three wall frames:
--      no site is built, the chain ends, no build action runs with the broken hammer in hand
--   H2 a claw hammer with condition 1: the first frame is built, the hammer is broken right
--      after that build's perform (setCondition(0)); no further site is built, the chain ends
--   H3 a broken claw hammer (in hand) and a good one: all three frames are built, each with
--      the good hammer in hand
-- Results: "[BuildAheadTest3]" lines; failures also as "[PZTest] FAIL".

require "BuildAhead"

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAheadTest3] " .. table.concat(parts, " "))
end

local R = { pass = 0, fail = 0, phase = "idle", performed = {}, brokenFrames = 0, starts = 0 }

local function harness() return PZTest ~= nil and PZTest.active() end

local function check(label, ok, extra)
    if ok then R.pass = R.pass + 1 else R.fail = R.fail + 1 end
    log(ok and "PASS" or "FAIL", label, extra or "")
    if not ok and harness() then PZTest.fail("BuildAheadTest3 " .. label .. " " .. tostring(extra or "")) end
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

local function handText(h)
    if not h then return "-" end
    return h:getFullType() .. " cond " .. h:getCondition() .. (h:isBroken() and " broken" or "")
end

local function diag()
    local p = player()
    local types = {}
    for _, a in ipairs(queue(p)) do types[#types + 1] = tostring(a.Type) end
    return "at " .. math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. " queue " .. table.concat(types, ",")
        .. " fetch " .. tostring(BuildAheadFetch.job ~= nil) .. " hand " .. handText(p:getPrimaryHandItem())
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

local MATS = { "Base.Plank", "Base.Nails" }

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

-- the materials a recipe consumes (not its tools)
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

-- the hammer the build's recipe applied (nil when none)
local function usedHammer(action)
    local logic = action.item and action.item.buildPanelLogic
    if not logic then return nil end
    local found
    pcall(function()
        local data = logic:getRecipeData()
        local inputs = data:getRecipe():getInputs()
        for i = 0, inputs:size() - 1 do
            local d = data:getDataForInputScript(inputs:get(i))
            for n = 0, (d and d:getAppliedItemsCount() or 0) - 1 do
                local it = d:getAppliedItem(n)
                if isHammer(it) then found = it end
            end
        end
    end)
    return found
end

-- test-only wrappers over the mod's own (installed later, so they run outermost)
local function hookActions()
    if R.hooked then return end
    R.hooked = true
    local origPerform = ISBuildAction.perform
    ISBuildAction.perform = function(self, ...)
        local name = self.item and self.item.objectInfo and self.item.objectInfo:getName()
        -- the wall frame takes the hammer as a recipe input (keep, Prop1): vanilla does not
        -- put it in the hand, so the hammer that counts is the one the recipe applied
        local h = usedHammer(self)
        table.insert(R.performed, { name = name, x = self.x, y = self.y, z = self.z,
            hand = handText(h), handBroken = h == nil or h:isBroken(), handHammer = h ~= nil })
        local r = origPerform(self, ...)
        -- H2: the hammer breaks with the first build
        if R.breakAfterFirst and h then
            R.breakAfterFirst = false
            h:setCondition(0)
            if not h:isBroken() then pcall(function() h:setBroken(true) end) end
            log("H2 hammer broken after the first build:", handText(h))
        end
        return r
    end
    local origStart = ISBuildAction.start
    ISBuildAction.start = function(self, ...)
        R.starts = R.starts + 1
        return origStart(self, ...)
    end
    -- frames a build action runs with a broken hammer as its input
    local origUpdate = ISBuildAction.update
    ISBuildAction.update = function(self, ...)
        local h = self.item and self.item.buildAheadSite and usedHammer(self)
        if h and h:isBroken() then
            R.brokenFrames = R.brokenFrames + 1
        end
        return origUpdate(self, ...)
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

local function addHammer(cond)
    local h = player():getInventory():AddItem("Base.Hammer")
    if cond then h:setCondition(cond) end
    if cond == 0 and not h:isBroken() then pcall(function() h:setBroken(true) end) end
    return h
end

-- three wall frames 2 apart in a free area, the player next to them, the materials in the bag;
-- returns the site squares
local function setupSites(label)
    local p = player()
    clearSites()
    clearBag()
    local info = entityInfo("WoodenWallFrame")
    if not check(label .. " recipe WoodenWallFrame", info ~= nil) then abort("no recipe") end
    local A = findArea(9, 6, label)
    teleport(A.x + 4, A.y + 4, 0)
    wait(60)
    local need = {}
    for _ = 1, 3 do cost(info, need) end
    local inv = p:getInventory()
    for t, n in pairs(need) do
        for _ = 1, n do inv:AddItem(t) end
    end
    local list = {}
    for i = 0, 2 do
        local q = { x = A.x + 2 + i * 2, y = A.y + 2, z = 0 }
        BuildAhead.addSite("WoodenWallFrame", q.x, q.y, q.z, 1)
        list[#list + 1] = q
    end
    check(label .. " three sites planned", #BuildAhead.getSites() == 3, "sites " .. #BuildAhead.getSites())
    local parts = {}
    for t, n in pairs(need) do parts[#parts + 1] = t .. " x" .. n end
    log(label, "materials", table.concat(parts, " "))
    R.performed, R.brokenFrames, R.starts = {}, 0, 0
    return list
end

local function startChain()
    local p = player()
    BuildAhead.schedule(p, math.floor(p:getX()), math.floor(p:getY()), 0)
end

local function builtCount(list)
    local n = 0
    for _, q in ipairs(list) do
        if hasObject(q.x, q.y, q.z, "WoodenWallFrame") then n = n + 1 end
    end
    return n
end

local function endState(label)
    local p = player()
    local types = {}
    for _, a in ipairs(queue(p)) do types[#types + 1] = tostring(a.Type) end
    check(label .. " chain ended", not BuildAhead.isBusy(p) and #queue(p) == 0 and BuildAheadFetch.job == nil, diag())
end

-- ---------------------------------------------------------------- H1 only a broken hammer

local function scenarioBrokenOnly()
    local p = player()
    local list = setupSites("H1")
    local broken = addHammer(0)
    p:setPrimaryHandItem(broken)
    log("H1 hand", handText(p:getPrimaryHandItem()))
    startChain()
    local frames = waitIdle(60 * 120, "H1 chain")
    log("H1 chain idle after", frames, "frames; build starts", R.starts, "performs", #R.performed,
        "frames with a broken hammer in a running build", R.brokenFrames)
    check("H1 no site built", builtCount(list) == 0 and #R.performed == 0,
        "built " .. builtCount(list) .. " performs " .. #R.performed)
    check("H1 all three sites still planned", #BuildAhead.getSites() == 3, "sites " .. #BuildAhead.getSites())
    check("H1 no build runs with the broken hammer", R.brokenFrames <= 1, "frames " .. R.brokenFrames)
    endState("H1")
    clearSites()
    clearBag()
end

-- ---------------------------------------------------------------- H2 the hammer breaks on the first build

local function scenarioBreaks()
    local p = player()
    local list = setupSites("H2")
    addHammer(1)
    R.breakAfterFirst = true
    startChain()
    local frames = waitIdle(60 * 180, "H2 chain")
    R.breakAfterFirst = false
    for i, b in ipairs(R.performed) do log("H2 built", i, b.name, b.x, b.y, "hand", b.hand) end
    log("H2 chain idle after", frames, "frames; build starts", R.starts, "performs", #R.performed,
        "frames with a broken hammer in a running build", R.brokenFrames)
    check("H2 first site built with the good hammer", #R.performed >= 1 and not R.performed[1].handBroken,
        R.performed[1] and R.performed[1].hand or "nothing built")
    -- after the break the chain may fetch another hammer from a container in range (the save
    -- has one where earlier tests returned their tools): then it builds on with that one
    local later = true
    for i = 2, #R.performed do
        if R.performed[i].handBroken then later = false end
    end
    check("H2 no build after the break used the broken hammer", later,
        "performs " .. #R.performed .. " built " .. builtCount(list))
    check("H2 every site is either built or still planned", builtCount(list) + #BuildAhead.getSites() == 3,
        "built " .. builtCount(list) .. " sites " .. #BuildAhead.getSites())
    check("H2 no build runs with the broken hammer", R.brokenFrames <= 1, "frames " .. R.brokenFrames)
    endState("H2")
    clearSites()
    clearBag()
end

-- ---------------------------------------------------------------- H3 a broken and a good hammer

local function scenarioBrokenAndGood()
    local p = player()
    local list = setupSites("H3")
    local broken = addHammer(0)
    local good = addHammer(nil)
    p:setPrimaryHandItem(broken)
    log("H3 hand", handText(p:getPrimaryHandItem()), "good one", handText(good))
    startChain()
    local frames = waitIdle(60 * 180, "H3 chain")
    for i, b in ipairs(R.performed) do log("H3 built", i, b.name, b.x, b.y, "hand", b.hand) end
    log("H3 chain idle after", frames, "frames; build starts", R.starts, "performs", #R.performed,
        "frames with a broken hammer in a running build", R.brokenFrames)
    check("H3 all three sites built", builtCount(list) == 3 and #R.performed == 3,
        "built " .. builtCount(list) .. " performs " .. #R.performed)
    local allGood = #R.performed > 0
    for _, b in ipairs(R.performed) do
        if b.handBroken or not b.handHammer then allGood = false end
    end
    check("H3 every build used the good hammer", allGood)
    check("H3 no build runs with the broken hammer", R.brokenFrames == 0, "frames " .. R.brokenFrames)
    check("H3 all sites removed", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    endState("H3")
    clearSites()
    clearBag()
end

-- ---------------------------------------------------------------- runner

local SCENARIOS = {
    { "H1 only a broken hammer", scenarioBrokenOnly },
    { "H2 hammer breaks on the first build", scenarioBreaks },
    { "H3 broken and good hammer", scenarioBrokenAndGood },
}

local function reset()
    local p = player()
    R.breakAfterFirst = false
    pcall(function() BuildAheadFetch.abort("test reset") end)
    pcall(function() ISTimedActionQueue.clear(p) end)
    pcall(clearSites)
    pcall(clearBag)
end

local function finish()
    R.phase = "done"
    ISBuildMenu.cheat = R.cheat
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
        if harness() then PZTest.fail("BuildAheadTest3 ERROR " .. name .. " " .. tostring(msg)) end
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

BuildAheadTest3 = {}

-- only: "H1,H3" runs just the scenarios whose names start with these
function BuildAheadTest3.start(only)
    if R.phase ~= "idle" then
        PZTest.fail("BuildAheadTest3 already ran in this game; pzt stop, then run again")
        return
    end
    R.phase = "run"
    hookActions()
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

function BuildAheadTest3.poll()
    if R.phase == "done" then
        PZTest.log("BuildAheadTest3 pass " .. R.pass .. " fail " .. R.fail)
        return
    end
    PZTest.step("wait 30")
    PZTest.step("lua BuildAheadTest3.poll()")
end
