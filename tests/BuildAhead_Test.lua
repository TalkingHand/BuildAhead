-- Single-player in-game test, test environment only: pzt (PZTestHarness) installs this file
-- into the test copy of the mod (TEST_FILES in pzt.conf) and its script calls
-- BuildAheadTest.start() and BuildAheadTest.poll(). Uses the real hooks in BuildAhead.lua:
--   1. idle: a cursor click plans a site and the scheduler starts building it right away
--   2. building: the blocked cursor is valid and clicks become sites (not the current square)
--   3. chain: when a build finishes, the nearest valid site with materials is built next;
--      a site without materials is left as a ghost; the build panel is refreshed
--   4. ghosts: blue buildable, yellow materials missing, red blocked (screenshot);
--      materials appearing while idle do not start a build
--   5. right-click menu: cancel option removes the site
--   6. idle without materials: a click plans a site, names what is missing, builds nothing;
--      the Build button stays on; manual input selection builds the vanilla way
--   7. "Build planned" from the menu builds the site
--   8. material bans
--   9. fetching: with nothing in the bag, a wall frame and a stick fence are built from a
--      crate and the floor 5-10 tiles away; a locked crate, a walled-in square, a source that
--      vanishes and banned items are left alone; the hammer goes back to its crate and the
--      weapon held before is equipped again; everything fits in one trip each, so nothing is
--      dropped at the sites: the builds take the materials from the inventory
--  10. multi-trip: with little room in the bag, the first trip drops its load at the site,
--      the last one builds from the inventory
--  11. skill too low
--  12. self-enclosure: a 3x3 room of walls with a gap in its north side, the player inside;
--      the wall frame planned in the gap is built from outside and the player ends up outside;
--      with no square outside to build from (stand filter, test seam) the chain leaves it planned
--      with the reason (ghost "trap"); "Build planned" stays on with a warning and builds it,
--      walling the player in; a short open wall line is still built
-- Results: "[BuildAheadTest]" lines in console.txt (failures also as "[PZTest] FAIL", so
-- `pzt run` exits 1), Screenshots/pzt_<run>_buildahead_stage1.png and _stage2.png

require "BuildAhead"

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print("[BuildAheadTest] " .. table.concat(parts, " "))
end

local T = { tick = 0, phase = "wait", pass = 0, fail = 0 }

local function harness() return PZTest ~= nil and PZTest.active() end

local function check(label, ok, extra)
    if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
    log(ok and "PASS" or "FAIL", label, extra or "")
    if not ok and harness() then PZTest.fail("BuildAheadTest " .. label .. " " .. tostring(extra or "")) end
end

-- an error in a phase counts as a failure (the phase machine then goes on or quits)
local function phaseError(where, e)
    T.fail = T.fail + 1
    log("ERROR " .. where, e)
    if harness() then PZTest.fail("BuildAheadTest ERROR " .. where .. " " .. tostring(e)) end
end

local function shot(name)
    pcall(function()
        if harness() then PZTest.shot(name) else getCore():TakeFullScreenshot(name .. ".png") end
    end)
end

local function player() return getSpecificPlayer(0) end

local function objectsAt(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    local out = {}
    if sq then
        local objs = sq:getObjects()
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

local function validSquares(info)
    local p = player()
    local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    local probe = makeCursor(info)
    local out = {}
    for rr = 2, 9 do
        for dx = -rr, rr do
            for dy = -rr, rr do
                if math.max(math.abs(dx), math.abs(dy)) == rr then
                    local sq = getCell():getGridSquare(px + dx, py + dy, pz)
                    local spaced = true
                    for _, q in ipairs(out) do
                        if math.abs(q.x - px - dx) <= 1 and math.abs(q.y - py - dy) <= 1 then spaced = false end
                    end
                    if sq and spaced and probe:isValid(sq) then
                        out[#out + 1] = { x = px + dx, y = py + dy, z = pz, d = dx * dx + dy * dy, up = dx + dy < 0 }
                    end
                end
            end
        end
    end
    return out
end

local function pick(list, pred)
    for i, q in ipairs(list) do
        if pred(q) then return table.remove(list, i) end
    end
end

local function setup()
    local p = player()
    pcall(function() p:setGodMod(true) end)
    pcall(function() p:setInvisible(true) end)
    for _ = 1, 10 do pcall(function() p:LevelPerk(Perks.Woodwork) end) end
    local info
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if i:getName() == "WoodenWallFrame" then info = i end
    end
    T.info = info
    local inv = p:getInventory()
    inv:AddItem("Base.BallPeenHammerForged")
    -- enough for A and two more frames (2 planks + 2 nails each); the fourth site stays planned
    for _ = 1, 6 do inv:AddItem("Base.Plank"); inv:AddItem("Base.Nails") end

    local squares = validSquares(info)
    table.sort(squares, function(a, b) return a.d < b.d end)
    log("valid squares", #squares)
    -- A, B, C close below the player; D far above (built last, so it is the one left over); G above
    T.A = pick(squares, function(q) return not q.up end)
    T.B = pick(squares, function(q) return not q.up end)
    T.C = pick(squares, function(q) return not q.up end)
    for i = #squares, 1, -1 do
        if squares[i].up and squares[i].d >= 16 then T.D = table.remove(squares, i) break end
    end
    T.G = pick(squares, function(q) return q.up end)
    T.E = pick(squares, function(q) return q.up end)
    for _, k in ipairs({ "A", "B", "C", "D", "G", "E" }) do
        local q = T[k]
        log("square", k, q and q.x, q and q.y, q and q.z)
        if not q then
            check("enough squares", false)
            T.phase = "quit"
            return
        end
    end

    T.cursor = makeCursor(info)
    -- 1. idle: the click plans a site and the scheduler builds it at once
    check("1 not building before click", not BuildAhead.isBuilding(p))
    T.cursor:tryBuild(T.A.x, T.A.y, T.A.z)
    check("1 click plans a site", #BuildAhead.getSites() == 1, "sites " .. #BuildAhead.getSites())
    local _, action = BuildAhead.isBuilding(p)
    check("1 click starts building it", action ~= nil and action.x == T.A.x and action.y == T.A.y
        and action.item ~= nil and action.item.buildAheadSite == true)
    T.phase = "plan"
end

local function plan()
    local p = player()
    local c = T.cursor
    c.blockBuild = true -- what the build panel sets while the craft action runs
    local sqB = getCell():getGridSquare(T.B.x, T.B.y, T.B.z)
    check("2 blocked cursor is valid while building", c:isValid(sqB))
    c:tryBuild(T.B.x, T.B.y, T.B.z)
    c:tryBuild(T.C.x, T.C.y, T.C.z)
    c:tryBuild(T.D.x, T.D.y, T.D.z)
    -- the square being built right now (skipped when A's build is already over: then the click
    -- would plan a site on a built square, which stays as a red ghost)
    local _, cur = BuildAhead.isBuilding(p)
    if cur and cur.x == T.A.x and cur.y == T.A.y then
        c:tryBuild(T.A.x, T.A.y, T.A.z)
    else
        log("A already built: no click on it")
    end
    c:tryBuild(T.B.x, T.B.y, T.B.z) -- duplicate
    -- B, C, D, and A while it is still being built
    local expected = BuildAheadSites.find(BuildAheadSites.data(), "WoodenWallFrame", T.A.x, T.A.y, T.A.z, 1) and 4 or 3
    check("2 three more sites planned", #BuildAhead.getSites() == expected, "sites " .. #BuildAhead.getSites())
    local builds = 0
    for _, a in ipairs(ISTimedActionQueue.getTimedActionQueue(p).queue) do
        if a.Type == "ISBuildAction" then builds = builds + 1 end
    end
    check("2 still only one build queued", builds == 1, "builds " .. builds)
    -- a stand-in build panel, to see that scheduler builds refresh it
    T.realPanel = ISBuildWindow.instance
    T.panelRefreshes = 0
    ISBuildWindow.instance = {
        player = p,
        logic = { refresh = function() T.panelRefreshes = T.panelRefreshes + 1 end },
        updateContainers = function() end,
        createBuildIsoEntity = function() end,
    }
    T.phase = "chain"
    T.chainStart = T.tick
end

local function chainDone()
    local p = player()
    local builtB = hasObject(T.B.x, T.B.y, T.B.z, "WoodenWallFrame")
    local builtC = hasObject(T.C.x, T.C.y, T.C.z, "WoodenWallFrame")
    local builtD = hasObject(T.D.x, T.D.y, T.D.z, "WoodenWallFrame")
    check("3 A built", hasObject(T.A.x, T.A.y, T.A.z, "WoodenWallFrame"))
    check("3 nearest sites B and C built by the chain", builtB and builtC)
    check("3 D not built (no materials left)", not builtD)
    local sites = BuildAhead.getSites()
    check("3 only D left planned", #sites == 1 and sites[1].x == T.D.x and sites[1].y == T.D.y,
        "sites " .. #sites)
    check("3 materials used", p:getInventory():getCountTypeRecurse("Base.Plank") == 0,
        "planks " .. p:getInventory():getCountTypeRecurse("Base.Plank"))
    check("3 build panel refreshed after scheduler builds", T.panelRefreshes >= 3, "refreshes " .. T.panelRefreshes)
    ISBuildWindow.instance = T.realPanel
    T.phase = "noMaterials"
end

local function fakeMenu(x, y, z)
    local fake = { options = {} }
    function fake:addOption(name, target, fn, arg1)
        local o = { name = name, target = target, fn = fn, arg1 = arg1 }
        table.insert(self.options, o)
        return o
    end
    local sq = getCell():getGridSquare(x, y, z)
    BuildAhead.fillContextMenu(0, fake, { sq:getFloor() or sq:getObjects():get(0) }, false)
    local names = {}
    for _, o in ipairs(fake.options) do names[#names + 1] = o.name end
    log("menu options:", table.concat(names, " | "))
    return fake.options
end

local function findOption(options, key)
    local prefix = getText(key, "")
    for _, o in ipairs(options) do
        if string.sub(o.name, 1, #prefix) == prefix then return o end
    end
end

-- 6. idle, no materials: the Build button stays on and a click plans a site
local function noMaterials()
    local p = player()
    local c = makeCursor(T.info)
    c.buildPanelLogic:autoPopulateInputs()
    local canPerform = c.buildPanelLogic:canPerformCurrentRecipe()
    c.blockBuild = not canPerform -- what the build panel sets
    check("6 no materials: recipe cannot be done", not canPerform)
    local missing = BuildAhead.missingMaterials(c.buildPanelLogic)
    local plank = getScriptManager():getItem("Base.Plank"):getDisplayName()
    local named = false
    for _, m in ipairs(missing) do
        if string.find(m, plank, 1, true) then named = true end
    end
    check("6 missing materials named", named, table.concat(missing, ", "))
    check("6 idle", not BuildAhead.isBuilding(p))
    local sqE = getCell():getGridSquare(T.E.x, T.E.y, T.E.z)
    check("6 cursor still valid without materials", c:isValid(sqE))
    local before = #BuildAhead.getSites()
    c:tryBuild(T.E.x, T.E.y, T.E.z)
    check("6 click plans a site", #BuildAhead.getSites() == before + 1, before .. " -> " .. #BuildAhead.getSites())
    check("6 nothing starts building", not BuildAhead.isBuilding(p))
    local siteE = BuildAheadSites.find(BuildAheadSites.data(), "WoodenWallFrame", T.E.x, T.E.y, T.E.z, 1)
    local stateE = siteE and BuildAhead.siteState(p, siteE)
    check("6 site state: materials missing", stateE == "missing", tostring(stateE))

    -- the build button, with the panel parts it reads faked
    local button = { enable = false, title = "Build" }
    function button:setTitle(t) self.title = t end
    function button:setVisible() end
    local manual = false
    local control = {
        buttonCraft = button, player = p,
        logic = {
            cachedCanPerformCurrentRecipe = function() return false end,
            isCraftActionInProgress = function() return false end,
            getSelectedBuildObject = function() return T.info end,
            isManualSelectInputs = function() return manual end,
            getRecipe = function() return T.info:getRecipe():getCraftRecipe() end,
        },
    }
    ISWidgetBuildControl.prerender(control)
    check("6 build button enabled without materials", button.enable and button.title == "Build",
        tostring(button.enable) .. " " .. button.title)
    manual = true
    button.enable = false
    ISWidgetBuildControl.prerender(control)
    check("6 build button on with manual inputs too", button.enable)
    -- skill level too low: the button stays off, as in vanilla
    local realRecipe = control.logic.getRecipe
    control.logic.getRecipe = function() return { characterHasRequiredSkills = function() return false end } end
    button.enable = false
    ISWidgetBuildControl.prerender(control)
    check("6 build button off without the skill", not button.enable)
    control.logic.getRecipe = realRecipe

    -- manual input selection (the build panel's default): clicks still plan sites
    local m = makeCursor(T.info)
    m.buildPanelLogic:setManualSelectInputs(true)
    m.blockBuild = true
    check("6 manual: blocked cursor is valid", m:isValid(sqE))
    before = #BuildAhead.getSites()
    m:tryBuild(T.G.x, T.G.y, T.G.z)
    check("6 manual: click plans a site", #BuildAhead.getSites() == before + 1, before .. " -> " .. #BuildAhead.getSites())
    check("6 manual: nothing starts building", not BuildAhead.isBuilding(p))
    local siteG = BuildAheadSites.find(BuildAheadSites.data(), "WoodenWallFrame", T.G.x, T.G.y, T.G.z, 1)
    if siteG then BuildAhead.removeSite(siteG.id) end

    -- no materials yet: "build planned" is greyed out with the reason, cancel stays available
    local optsNo = fakeMenu(T.D.x, T.D.y, T.D.z)
    local buildNo = findOption(optsNo, "IGUI_BuildAhead_BuildSite")
    local cancelNo = findOption(optsNo, "IGUI_BuildAhead_CancelSite")
    check("7 build option greyed out without materials", buildNo and buildNo.notAvailable == true
        and buildNo.toolTip ~= nil, buildNo and buildNo.toolTip and buildNo.toolTip.description or "")
    check("7 cancel option still available", cancelNo and not cancelNo.notAvailable)

    -- 7. materials for one more frame, then "build planned" from the menu at D
    local inv = p:getInventory()
    for _ = 1, 2 do inv:AddItem("Base.Plank"); inv:AddItem("Base.Nails") end
    local opt = findOption(fakeMenu(T.D.x, T.D.y, T.D.z), "IGUI_BuildAhead_BuildSite")
    check("7 build option on the site", opt ~= nil and not opt.notAvailable)
    if opt then opt.fn(opt.target, opt.arg1) end
    check("7 build started from the menu", BuildAhead.isBuilding(p))
    T.phase = "buildFromMenu"
    T.idleSince = nil
    T.menuStart = T.tick
end

local function buildFromMenuDone()
    check("7 D built", hasObject(T.D.x, T.D.y, T.D.z, "WoodenWallFrame"))
    check("7 E still planned (no materials)", not hasObject(T.E.x, T.E.y, T.E.z, "WoodenWallFrame")
        and #BuildAhead.getSites() == 1, "sites " .. #BuildAhead.getSites())
    -- a blocked site for the red ghost: the square of A, already built
    BuildAhead.addSite("WoodenWallFrame", T.A.x, T.A.y, T.A.z, 1)
    -- G for the context menu test
    BuildAhead.addSite("WoodenWallFrame", T.G.x, T.G.y, T.G.z, 1)
    -- materials for one frame: E and G turn blue, but nothing starts while idle
    local inv = player():getInventory()
    for _ = 1, 2 do inv:AddItem("Base.Plank"); inv:AddItem("Base.Nails") end
    T.phase = "ghost"
    T.ghostAt = T.tick
end

local function contextMenu()
    local opt = findOption(fakeMenu(T.G.x, T.G.y, T.G.z), "IGUI_BuildAhead_CancelSite")
    check("5 cancel option on the site square", opt ~= nil)
    local before = #BuildAhead.getSites()
    if opt then opt.fn(opt.target, opt.arg1) end
    check("5 cancel removes the site", #BuildAhead.getSites() == before - 1,
        before .. " -> " .. #BuildAhead.getSites())
end

-- 8. material bans: StickFence takes 6 of [LongStick; Sapling]
local function entityInfo(name)
    for _, i in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if i:getName() == name then return i end
    end
end

local function fenceLogic(p, recipe)
    local logic = BuildLogic.new(p, nil, nil)
    logic:setContainers(ISInventoryPaneContextMenu.getContainers(p))
    logic:setRecipe(recipe)
    return logic
end

local function count(p, fullType) return p:getInventory():getCountTypeRecurse(fullType) end

local function banStart()
    local p = player()
    -- leftovers from the earlier phases would be picked first
    local sites = BuildAhead.getSites()
    for i = #sites, 1, -1 do BuildAhead.removeSite(sites[i].id) end
    local fence = entityInfo("StickFence")
    check("8 StickFence recipe found", fence ~= nil)
    if not fence then return end
    T.fence = fence
    local recipe = fence:getRecipe():getCraftRecipe()
    local inv = p:getInventory()
    for _ = 1, 6 do inv:AddItem("Base.LongStick"); inv:AddItem("Base.Sapling") end
    for _ = 1, 4 do inv:AddItem("Base.RippedSheets") end
    local stickInput
    for i = 0, recipe:getInputs():size() - 1 do
        local input = recipe:getInputs():get(i)
        local items = input:getPossibleInputItems()
        for k = 0, items:size() - 1 do
            if items:get(k):getFullName() == "Base.LongStick" then stickInput = input end
        end
    end
    check("8 stick input found", stickInput ~= nil)
    if not stickInput then return end
    local skin = XuiManager.GetDefaultSkin()

    -- the toggle on the recipe input box: bans the type it shows, a second click unbans it
    local logic = fenceLogic(p, recipe)
    logic:autoPopulateInputs()
    local w = ISXuiSkin.build(skin, "S_NeedsAStyle", ISWidgetInput, 0, 0, 10, 10, p, logic, stickInput)
    w:initialise()
    w:instantiate()
    w:calculateLayout(0, 0)
    w:updateValues()
    local shown = BuildAheadBanUI.widgetFullType(w)
    check("8 input box has a ban button", w.buildAheadBanButton ~= nil, tostring(shown))
    if w.buildAheadBanButton then
        local b = w.buildAheadBanButton
        b.onclick(b.target, b)
        check("8 input toggle bans the shown type", BuildAhead.isBanned(p, shown) and w.buildAheadBanned == true,
            tostring(shown))
        check("8 banned input box drawn red", w.borderColor and w.borderColor.r > 0.8 and w.borderColor.g < 0.3)
        b.onclick(b.target, b)
        check("8 second click unbans it", not BuildAhead.isBanned(p, shown))
    end

    -- the toggle in the manual selection list: ban LongStick there
    local panel = ISXuiSkin.build(skin, "S_NeedsAStyle", ISCraftInventoryPanel, 0, 0, 300, 400, p, logic)
    panel:initialise()
    panel:instantiate()
    panel:calculateLayout(300, 400)
    logic:setManualSelectInputScriptFilter(stickInput)
    panel:populate()
    local box = panel.itemListBox
    local row, names = nil, {}
    for i, entry in ipairs(box.items) do
        local ft = BuildAheadBanUI.rowFullType(entry.item)
        names[#names + 1] = tostring(ft)
        if ft == "Base.LongStick" and not row then row = i end
    end
    check("8 LongStick row in the selection list", row ~= nil, table.concat(names, ","))
    if row then
        box:onMouseDown(box.width - 8 - (box:isVScrollBarVisible() and box.vscroll:getWidth() or 0), box:topOfItem(row) + 2)
    end
    check("8 list toggle bans LongStick", BuildAhead.isBanned(p, "Base.LongStick"))
    check("8 ban stored in player ModData", p:getModData().BuildAheadBans
        and p:getModData().BuildAheadBans["Base.LongStick"] == true)
    pcall(function() box:render() end)

    -- build with LongStick banned: only saplings are used
    local squares = validSquares(fence)
    table.sort(squares, function(a, b) return a.d < b.d end)
    T.S, T.S2 = squares[1], squares[#squares]
    check("8 fence squares", T.S ~= nil and T.S2 ~= nil and T.S ~= T.S2, "squares " .. #squares)
    if not T.S or T.S == T.S2 then return end
    T.sticks, T.saplings = count(p, "Base.LongStick"), count(p, "Base.Sapling")
    local c = makeCursor(fence)
    c:tryBuild(T.S.x, T.S.y, T.S.z)
    check("8 fence build started", BuildAhead.isBuilding(p))
    T.phase = "banBuild"
    T.idleSince = nil
    T.banStart = T.tick
end

local function banDone()
    local p = player()
    log("objects at S", objectsAt(T.S.x, T.S.y, T.S.z))
    check("8 fence built", hasObject(T.S.x, T.S.y, T.S.z, "StickFence"))
    check("8 banned LongStick not used", count(p, "Base.LongStick") == T.sticks,
        T.sticks .. " -> " .. count(p, "Base.LongStick"))
    check("8 saplings used instead", count(p, "Base.Sapling") == T.saplings - 6,
        T.saplings .. " -> " .. count(p, "Base.Sapling"))
    -- every alternative banned: the site is "materials missing" though sticks are in the bag
    BuildAhead.setBanned(p, "Base.Sapling", true)
    for _ = 1, 6 do p:getInventory():AddItem("Base.Sapling") end
    local c = makeCursor(T.fence)
    c:tryBuild(T.S2.x, T.S2.y, T.S2.z)
    local site = BuildAheadSites.find(BuildAheadSites.data(), "StickFence", T.S2.x, T.S2.y, T.S2.z, 1)
    local state = site and BuildAhead.siteState(p, site)
    check("8 all alternatives banned: materials missing", state == "missing", tostring(state))
    check("8 all alternatives banned: nothing starts", not BuildAhead.isBuilding(p))
    BuildAhead.setBanned(p, "Base.Sapling", false)
    state = site and BuildAhead.siteState(p, site)
    check("8 unbanned again: buildable", state == "buildable", tostring(state))
    BuildAhead.setBanned(p, "Base.LongStick", false)
    if site then BuildAhead.removeSite(site.id) end
end


-- 9. fetching: nothing in the bag, materials 5 to 10 tiles away
local function cheb(a, b) return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)) end

-- a free floor square dmin..dmax tiles from the player, in the player's room (or outside),
-- at least `gap` tiles from every square in `avoid`
local function freeSquare(dmin, dmax, avoid, gap)
    local p = player()
    local psq = p:getCurrentSquare()
    local px, py, pz = psq:getX(), psq:getY(), psq:getZ()
    for r = dmin, dmax do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local q = { x = px + dx, y = py + dy, z = pz }
                    local sq = getCell():getGridSquare(q.x, q.y, q.z)
                    local ok = sq and sq:isFree(false) and sq:TreatAsSolidFloor() and sq:getObjects():size() <= 1
                        and sq:getWorldObjects():size() == 0 and sq:getRoom() == psq:getRoom()
                        and not sq:getVehicleContainer() and AdjacentFreeTileFinder.Find(sq, p) ~= nil
                    for _, a in ipairs(avoid) do
                        if ok and a.z == q.z and cheb(a, q) < gap then ok = false end
                    end
                    if ok then
                        q.sq = sq
                        return q
                    end
                end
            end
        end
    end
end

local function newCrate(q)
    local obj = IsoThumpable.new(getCell(), q.sq, "carpentry_01_16", false, {})
    obj:setIsContainer(true)
    obj:getContainer():setType("crate")
    obj:setIsThumpable(true)
    q.sq:AddSpecialObject(obj)
    return obj, obj:getContainer()
end

local function addTo(container, fullType, n)
    for _ = 1, n do container:AddItem(fullType) end
end

local function addFloor(q, fullType, n)
    for _ = 1, n do q.sq:AddWorldInventoryItem(fullType, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0) end
end

local function floorCount(q, fullType, radius)
    local n = 0
    radius = radius or 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = getCell():getGridSquare(q.x + dx, q.y + dy, q.z)
            local wobs = sq and sq:getWorldObjects()
            for i = 0, (wobs and wobs:size() or 0) - 1 do
                local it = wobs:get(i):getItem()
                if it and it:getFullType() == fullType then n = n + 1 end
            end
        end
    end
    return n
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

-- walls around a square: N and W walls on it, W wall east of it, N wall south of it
local function enclose(q)
    local function wall(x, y, north)
        local sq = getCell():getGridSquare(x, y, q.z)
        local sprite = north and "walls_exterior_house_01_1" or "walls_exterior_house_01_0"
        local obj = IsoThumpable.new(getCell(), sq, sprite, north, {})
        obj:setIsThumpable(true)
        sq:AddSpecialObject(obj)
        sq:RecalcAllWithNeighbours(true)
    end
    wall(q.x, q.y, true)
    wall(q.x, q.y, false)
    wall(q.x + 1, q.y, false)
    wall(q.x, q.y + 1, true)
end

local function fetchStart()
    local p = player()
    local sites = BuildAhead.getSites()
    for i = #sites, 1, -1 do BuildAhead.removeSite(sites[i].id) end
    -- empty hands and bag of the materials and tools
    p:setPrimaryHandItem(nil)
    p:setSecondaryHandItem(nil)
    local inv = p:getInventory()
    local items = inv:getItems()
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        local t = it:getFullType()
        if t == "Base.Plank" or t == "Base.Nails" or t == "Base.LongStick" or t == "Base.Sapling" or isHammer(it) then
            inv:DoRemoveItem(it)
        end
    end
    local bat = inv:AddItem("Base.BaseballBat")
    p:setPrimaryHandItem(bat)
    -- room for each site's materials in one trip (phase 10 restores the limit)
    T.maxWeight, T.maxWeightBase = p:getMaxWeight(), p:getMaxWeightBase()
    p:setMaxWeightBase(50)
    p:setMaxWeight(50)
    T.bat = bat
    for _ = 1, 2 do inv:AddItem("Base.RippedSheets") end
    BuildAhead.setBanned(p, "Base.LongStick", true)

    local avoid = {}
    for _, k in ipairs({ "A", "B", "C", "D", "E", "G", "S", "S2" }) do
        if T[k] then avoid[#avoid + 1] = T[k] end
    end
    local walls = validSquares(T.info)
    table.sort(walls, function(a, b) return a.d < b.d end)
    T.W = walls[1]
    if T.W then avoid[#avoid + 1] = T.W end
    local fences = validSquares(T.fence)
    table.sort(fences, function(a, b) return a.d < b.d end)
    for _, q in ipairs(fences) do
        if T.W and cheb(q, T.W) >= 2 and q.d > T.W.d then T.F = q break end
    end
    if T.F then avoid[#avoid + 1] = T.F end
    -- sources, nearest first: locked crate, vanishing nails, walled-in planks, open crate, floor
    T.L = freeSquare(5, 10, avoid, 3); if T.L then avoid[#avoid + 1] = T.L end
    T.V = freeSquare(5, 10, avoid, 3); if T.V then avoid[#avoid + 1] = T.V end
    T.U = freeSquare(5, 10, avoid, 3); if T.U then avoid[#avoid + 1] = T.U end
    T.Cr = freeSquare(5, 10, avoid, 3); if T.Cr then avoid[#avoid + 1] = T.Cr end
    T.Fl = freeSquare(5, 10, avoid, 3)
    for _, k in ipairs({ "W", "F", "L", "V", "U", "Cr", "Fl" }) do
        local q = T[k]
        log("fetch square", k, q and q.x, q and q.y, q and q.z)
        if not q then
            check("9 fetch squares", false, k)
            return false
        end
    end

    local lockObj, locked = newCrate(T.L)
    addTo(locked, "Base.Plank", 4)
    addTo(locked, "Base.Nails", 2)
    addTo(locked, "Base.BallPeenHammerForged", 1)
    log("fetch setup: locked crate filled")
    lockObj:setLockedByPadlock(true)
    lockObj:setKeyId(987654)
    T.locked = locked
    check("9 locked crate is locked", lockObj:isLockedToCharacter(p))
    log("fetch setup: locked")
    addFloor(T.V, "Base.Nails", 2)
    local wallsOk, werr = pcall(enclose, T.U)
    if not wallsOk then log("walls failed", werr) end
    log("fetch setup: walls", tostring(wallsOk))
    addFloor(T.U, "Base.Plank", 2)
    T.walled = wallsOk
    log("walled square adjacent free tile", tostring(AdjacentFreeTileFinder.Find(T.U.sq, p)))
    local _, crate = newCrate(T.Cr)
    addTo(crate, "Base.BallPeenHammerForged", 1)
    addTo(crate, "Base.Plank", 1)
    addTo(crate, "Base.Nails", 2)
    addTo(crate, "Base.Sapling", 6)
    T.crate = crate
    log("fetch setup: crate filled")
    addFloor(T.Fl, "Base.Plank", 1)
    addFloor(T.Fl, "Base.LongStick", 6)

    -- the fence: planned without a click, so the click below starts at the wall
    BuildAhead.addSite("StickFence", T.F.x, T.F.y, T.F.z, 1)
    local siteF = BuildAheadSites.find(BuildAheadSites.data(), "StickFence", T.F.x, T.F.y, T.F.z, 1)
    local stateF = siteF and BuildAhead.siteState(p, siteF)
    check("9 fence ghost blue: materials can be fetched", stateF == "buildable", tostring(stateF))
    check("9 no reason shown for a site that can be fetched", siteF and BuildAhead.cannotBuildReason(p, siteF) == nil)

    log("fetch setup: clicking")
    T.drops = BuildAheadFetch.stats.drops
    local c = makeCursor(T.info)
    c:tryBuild(T.W.x, T.W.y, T.W.z)
    check("9 click starts fetching", BuildAheadFetch.isActive(p))
    -- the nearest open source disappears before the player gets there
    local wobs = T.V.sq:getWorldObjects()
    for i = wobs:size() - 1, 0, -1 do
        local wo = wobs:get(i)
        T.V.sq:transmitRemoveItemFromSquare(wo)
    end
    T.vanished = floorCount(T.V, "Base.Nails") == 0
    T.phase = "fetchRun"
    T.idleSince = nil
    T.fetchStart = T.tick
    return true
end

local function fetchDone()
    local p = player()
    local inv = p:getInventory()
    shot("buildahead_stage2")
    log("objects at W", objectsAt(T.W.x, T.W.y, T.W.z), "at F", objectsAt(T.F.x, T.F.y, T.F.z))
    check("9 wall frame built from fetched materials", hasObject(T.W.x, T.W.y, T.W.z, "WoodenWallFrame"))
    check("9 fence built from fetched materials", hasObject(T.F.x, T.F.y, T.F.z, "StickFence"))
    check("9 sites done", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    check("9 crate emptied of planks, nails, saplings", T.crate:getCountTypeRecurse("Base.Plank") == 0
        and T.crate:getCountTypeRecurse("Base.Nails") == 0 and T.crate:getCountTypeRecurse("Base.Sapling") == 0,
        "planks " .. T.crate:getCountTypeRecurse("Base.Plank") .. " nails " .. T.crate:getCountTypeRecurse("Base.Nails")
        .. " saplings " .. T.crate:getCountTypeRecurse("Base.Sapling"))
    check("9 floor plank fetched", floorCount(T.Fl, "Base.Plank") == 0)
    check("9 banned LongSticks not fetched", floorCount(T.Fl, "Base.LongStick") == 6,
        "sticks " .. floorCount(T.Fl, "Base.LongStick"))
    check("9 locked crate untouched", T.locked:getCountTypeRecurse("Base.Plank") == 4
        and T.locked:getCountTypeRecurse("Base.Nails") == 2 and hammerCount(T.locked) == 1)
    check("9 walled-in planks not taken", floorCount(T.U, "Base.Plank") == 2, "walls " .. tostring(T.walled))
    check("9 vanished source left out", T.vanished and BuildAheadFetch.isBlacklisted("f:" .. T.V.x .. "," .. T.V.y .. "," .. T.V.z))
    local left = 0
    for _, t in ipairs({ "Base.Plank", "Base.Nails", "Base.Sapling" }) do
        left = left + inv:getCountTypeRecurse(t) + floorCount(T.W, t, 2) + floorCount(T.F, t, 2)
    end
    check("9 fetched materials consumed (none in the bag or on the floor at the sites)", left == 0, "left " .. left)
    check("9 hammer back in the crate", hammerCount(T.crate) == 1 and hammerCount(inv) == 0,
        "crate " .. hammerCount(T.crate) .. " bag " .. hammerCount(inv))
    check("9 weapon equipped again", p:getPrimaryHandItem() == T.bat, tostring(p:getPrimaryHandItem()))
    check("9 last trips build from the inventory: nothing dropped", BuildAheadFetch.stats.drops == T.drops,
        "drops " .. (BuildAheadFetch.stats.drops - T.drops))
    BuildAhead.setBanned(p, "Base.LongStick", false)
end

-- 10. multi-trip: fill the bag so that one plank fits with the hammer, not two
local function multiStart()
    local p = player()
    local inv = p:getInventory()
    local plankW = instanceItem("Base.Plank"):getUnequippedWeight()
    local hammerW = instanceItem("Base.BallPeenHammerForged"):getUnequippedWeight()
    local nailsW = instanceItem("Base.Nails"):getUnequippedWeight()
    local target = 2 * plankW + hammerW -- no room for this
    p:setMaxWeightBase(T.maxWeightBase)
    p:setMaxWeight(T.maxWeight)
    T.filler = {}
    -- leave less free weight than `target`, but no less than `target` minus a pencil
    local function fill(fullType, keep)
        local w = instanceItem(fullType):getUnequippedWeight()
        while BuildAheadFetch.freeWeight(p) >= target + (keep and w or 0) and #T.filler < 500 do
            T.filler[#T.filler + 1] = inv:AddItem(fullType)
        end
    end
    fill("Base.BaseballBat", true)
    fill("Base.Pencil", false)
    local free = BuildAheadFetch.freeWeight(p)
    check("10 bag holds one plank with the hammer, not two", free >= plankW + hammerW + 2 * nailsW and free < target,
        "free " .. free .. " plank " .. plankW .. " hammer " .. hammerW .. " filler " .. #T.filler)
    local walls = validSquares(T.info)
    table.sort(walls, function(a, b) return a.d < b.d end)
    local avoid = {}
    for _, k in ipairs({ "W", "F", "L", "V", "U", "Cr", "Fl" }) do avoid[#avoid + 1] = T[k] end
    for _, q in ipairs(walls) do
        local ok = true
        for _, a in ipairs(avoid) do if cheb(a, q) < 2 then ok = false end end
        if ok then T.M = q break end
    end
    if T.M then avoid[#avoid + 1] = T.M end
    T.Mc = freeSquare(5, 10, avoid, 3)
    log("multi squares", T.M and T.M.x, T.M and T.M.y, T.Mc and T.Mc.x, T.Mc and T.Mc.y)
    if not T.M or not T.Mc then
        check("10 multi-trip squares", false)
        return false
    end
    local _, crate = newCrate(T.Mc)
    addTo(crate, "Base.BallPeenHammerForged", 1)
    addTo(crate, "Base.Plank", 2)
    addTo(crate, "Base.Nails", 2)
    T.mcrate = crate
    T.drops = BuildAheadFetch.stats.drops
    local c = makeCursor(T.info)
    c:tryBuild(T.M.x, T.M.y, T.M.z)
    check("10 click starts fetching", BuildAheadFetch.isActive(p))
    T.phase = "multiRun"
    T.idleSince = nil
    T.fetchStart = T.tick
    return true
end

-- 11. skill too low: a site someone else planned is not picked, the cursor does not plan,
-- and the menu says why
local function skillChecks()
    local p = player()
    local free = validSquares(T.info)
    local q = free[1]
    if not q then check("11 free square for the skill test", false) return end
    local inv = p:getInventory()
    for _ = 1, 2 do inv:AddItem("Base.Plank"); inv:AddItem("Base.Nails") end
    pcall(function() p:getXp():setXPToLevel(Perks.Woodwork, 0) end)
    for _ = 1, 12 do
        if p:getPerkLevel(Perks.Woodwork) <= 0 then break end
        pcall(function() p:LoseLevel(Perks.Woodwork) end)
    end
    check("11 woodwork lowered below the frame's level 2", p:getPerkLevel(Perks.Woodwork) < 2,
        "level " .. p:getPerkLevel(Perks.Woodwork))
    -- as if another player planned it
    local site = BuildAhead.addSite("WoodenWallFrame", q.x, q.y, q.z, 1)
    check("11 site planned for the test", site ~= nil)
    if not site then return end
    check("11 unskilled: site not buildable", not BuildAhead.canBuildSite(p, site))
    check("11 unskilled: ghost state missing", BuildAhead.siteState(p, site) == "missing",
        tostring(BuildAhead.siteState(p, site)))
    check("11 unskilled: chain does not pick it", BuildAhead.pickNext(p, q.x, q.y, q.z) == nil)
    local reason = BuildAhead.cannotBuildReason(p, site) or ""
    local prefix = getText("IGUI_BuildAhead_NeedSkill", "")
    check("11 unskilled: reason names the skill", string.sub(reason, 1, #prefix) == prefix, reason)
    local opt = findOption(fakeMenu(q.x, q.y, q.z), "IGUI_BuildAhead_BuildSite")
    check("11 unskilled: build option greyed out", opt and opt.notAvailable == true)
    -- the build cursor does not plan without the skill
    local c = makeCursor(T.info)
    c.blockBuild = true
    local other = free[2]
    if other then
        local sq = getCell():getGridSquare(other.x, other.y, other.z)
        check("11 unskilled: cursor stays red", not c:isValid(sq))
        local before = #BuildAhead.getSites()
        c:tryBuild(other.x, other.y, other.z)
        check("11 unskilled: click plans nothing", #BuildAhead.getSites() == before,
            before .. " -> " .. #BuildAhead.getSites())
    end
    check("11 unskilled: nothing starts", not BuildAhead.isBusy(p))
    BuildAhead.removeSite(site.id)
end

local function multiDone()
    local p = player()
    local inv = p:getInventory()
    local drops = BuildAheadFetch.stats.drops - T.drops
    check("10 wall frame built over several trips", hasObject(T.M.x, T.M.y, T.M.z, "WoodenWallFrame"))
    check("10 only the first trip dropped its load (one plank)", drops == 1, "drops " .. drops)
    local left = floorCount(T.M, "Base.Plank", 2) + floorCount(T.M, "Base.Nails", 2)
        + inv:getCountTypeRecurse("Base.Plank") + inv:getCountTypeRecurse("Base.Nails")
        + T.mcrate:getCountTypeRecurse("Base.Plank") + T.mcrate:getCountTypeRecurse("Base.Nails")
    -- the walled-in planks of phase 9 may lie within that area
    if cheb(T.U, T.M) <= 2 then left = left - floorCount(T.U, "Base.Plank") end
    check("10 materials consumed", left == 0, "left " .. left)
    check("10 hammer back in the crate", hammerCount(T.mcrate) == 1 and hammerCount(inv) == 0)
    for _, it in ipairs(T.filler or {}) do
        if it:getContainer() then it:getContainer():DoRemoveItem(it) end
    end
end

-- 12. self-enclosure
local function wallAt(x, y, z, north)
    local sq = getCell():getGridSquare(x, y, z)
    local sprite = north and "walls_exterior_house_01_1" or "walls_exterior_house_01_0"
    local obj = IsoThumpable.new(getCell(), sq, sprite, north, {})
    obj:setIsThumpable(true)
    sq:AddSpecialObject(obj)
    sq:RecalcAllWithNeighbours(true)
end

-- w x h free outdoor squares from (x0, y0), nothing between them
local function openArea(x0, y0, z, w, h)
    local cell = getCell()
    for x = x0, x0 + w - 1 do
        for y = y0, y0 + h - 1 do
            local sq = cell:getGridSquare(x, y, z)
            if not (sq and sq:isFree(false) and sq:TreatAsSolidFloor() and sq:getObjects():size() <= 1
                and sq:getWorldObjects():size() == 0 and not sq:getRoom() and not sq:HasStairs()
                and not sq:getVehicleContainer()) then
                return false
            end
            local east, south = cell:getGridSquare(x + 1, y, z), cell:getGridSquare(x, y + 1, z)
            if x < x0 + w - 1 and (not east or sq:isBlockedTo(east)) then return false end
            if y < y0 + h - 1 and (not south or sq:isBlockedTo(south)) then return false end
        end
    end
    return true
end

local function inRoom(x, y)
    local R = T.R
    return x >= R.x and x <= R.x + 2 and y >= R.y and y <= R.y + 2
end

local function listHas(list, x, y)
    for _, sq in ipairs(list or {}) do
        if sq:getX() == x and sq:getY() == y then return true end
    end
    return false
end

local function playerSquareText()
    local sq = player():getCurrentSquare()
    return sq and (sq:getX() .. "," .. sq:getY()) or "?"
end

-- the player's area is open (not walled in)
local function playerFree()
    local sq = player():getCurrentSquare()
    return sq ~= nil and BuildAheadTrap.fill(sq, nil, nil) == true
end

local function trapStart()
    local p = player()
    local sites = BuildAhead.getSites()
    for i = #sites, 1, -1 do BuildAhead.removeSite(sites[i].id) end
    for _ = 1, 10 do pcall(function() p:LevelPerk(Perks.Woodwork) end) end
    local inv = p:getInventory()
    if hammerCount(inv) == 0 then inv:AddItem("Base.BallPeenHammerForged") end
    -- the frames of the open line, and a log wall for the gap (a wall frame can be climbed through)
    for _ = 1, 4 do inv:AddItem("Base.Plank"); inv:AddItem("Base.Nails") end
    T.logWall = entityInfo("LogWall")
    if not T.logWall then
        check("12 LogWall recipe found", false)
        return false
    end
    pcall(function() p:setMaxWeightBase(200); p:setMaxWeight(200) end)
    -- two log walls: from outside by the chain, then by hand from inside
    for _ = 1, 8 do inv:AddItem("Base.Log"); inv:AddItem("Base.RippedSheets") end
    local psq = p:getCurrentSquare()
    local px, py, pz = psq:getX(), psq:getY(), psq:getZ()
    -- room interior rx..rx+2, ry..ry+2, with two free squares around it
    for r = 3, 25 do
        for dx = -r, r do
            for dy = -r, r do
                if not T.R and math.max(math.abs(dx), math.abs(dy)) == r and openArea(px + dx - 2, py + dy - 2, pz, 7, 7) then
                    T.R = { x = px + dx, y = py + dy, z = pz }
                end
            end
        end
    end
    if not T.R then
        check("12 room area", false)
        return false
    end
    local R = T.R
    -- the open line: west walls at (x, y) and (x, y + 1), away from the room
    local probe = makeCursor(T.info, 1)
    for r = 2, 25 do
        for dx = -r, r do
            for dy = -r, r do
                local x, y = px + dx, py + dy
                if not T.Ln and math.max(math.abs(dx), math.abs(dy)) == r
                    and (x < R.x - 5 or x > R.x + 7 or y < R.y - 5 or y > R.y + 7)
                    and openArea(x - 2, y - 2, pz, 5, 6)
                    and probe:isValid(getCell():getGridSquare(x, y, pz))
                    and probe:isValid(getCell():getGridSquare(x, y + 1, pz)) then
                    T.Ln = { x = x, y = y, z = pz }
                end
            end
        end
    end
    log("trap room", R.x, R.y, R.z, "line", T.Ln and T.Ln.x, T.Ln and T.Ln.y)
    if not T.Ln then
        check("12 open line area", false)
        return false
    end
    -- the walls, with the gap at the north edge of (rx + 1, ry)
    wallAt(R.x, R.y, R.z, true)
    wallAt(R.x + 2, R.y, R.z, true)
    for i = 0, 2 do
        wallAt(R.x + i, R.y + 3, R.z, true)
        wallAt(R.x, R.y + i, R.z, false)
        wallAt(R.x + 3, R.y + i, R.z, false)
    end
    p:teleportTo(R.x + 1.5, R.y + 1.5, R.z)
    return true
end

local function trapClick()
    local p = player()
    local R = T.R
    local gx, gy, z = R.x + 1, R.y, R.z
    local psq = p:getCurrentSquare()
    check("12 player inside the room", psq and inRoom(psq:getX(), psq:getY()), playerSquareText())
    check("12 room open before the build", playerFree())
    local frame = makeCursor(T.info, 2)
    log("frame flags", BuildAheadTrap.flagsText(frame), "blocks", BuildAheadTrap.describe(BuildAheadTrap.blockage(frame, gx, gy)))
    local rf = BuildAheadTrap.evaluate(frame, gx, gy, z)
    check("12 a wall frame (climbable) does not trap", not (rf and rf.trap))
    local c = makeCursor(T.logWall, 2)
    log("log wall flags", BuildAheadTrap.flagsText(c), "blocks", BuildAheadTrap.describe(BuildAheadTrap.blockage(c, gx, gy)))
    local r = BuildAheadTrap.evaluate(c, gx, gy, z)
    check("12 gap wall traps from inside", r and r.trap and listHas(r.trapped, gx, gy),
        r and BuildAheadTrap.squares(r.trapped))
    check("12 gap wall does not trap from outside", r and listHas(r.safe, gx, gy - 1),
        r and BuildAheadTrap.squares(r.safe))
    local stand = r and BuildAheadTrap.standSquare(p, r)
    check("12 built from outside the gap", stand and stand:getX() == gx and stand:getY() == gy - 1,
        stand and (stand:getX() .. "," .. stand:getY()) or "none")
    c:tryBuild(gx, gy, z)
    check("12 click starts building", BuildAhead.isBuilding(p))
end

local function removeObject(x, y, z, name)
    local sq = getCell():getGridSquare(x, y, z)
    local objs = sq:getObjects()
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        if o:getName() == name then sq:transmitRemoveItemFromSquare(o) end
    end
    sq:RecalcAllWithNeighbours(true)
end

local function trapDone()
    local R = T.R
    local gx, gy, z = R.x + 1, R.y, R.z
    check("12 gap wall built", hasObject(gx, gy, z, "LogWall"), objectsAt(gx, gy, z))
    local psq = player():getCurrentSquare()
    check("12 player ended up outside the room", psq and not inRoom(psq:getX(), psq:getY()), playerSquareText())
    check("12 player not walled in", playerFree())
    check("12 room closed now", BuildAheadTrap.fill(getCell():getGridSquare(gx, gy + 1, z), nil, nil) == false)
    -- again, with no square outside to build from: open the gap and go back in
    removeObject(gx, gy, z, "LogWall")
    player():teleportTo(R.x + 1.5, R.y + 1.5, R.z)
end

local function trapSkip()
    local p = player()
    local R = T.R
    local gx, gy, z = R.x + 1, R.y, R.z
    check("12 gap open again", not hasObject(gx, gy, z, "LogWall") and playerFree(), playerSquareText())
    -- test seam: only the squares inside the room can be built from
    BuildAheadTrap.standFilter = function(sq) return inRoom(sq:getX(), sq:getY()) end
    local c = makeCursor(T.logWall, 2)
    c:tryBuild(gx, gy, z)
    local site = BuildAheadSites.find(BuildAheadSites.data(), "LogWall", gx, gy, z, 2)
    T.trapSite = site
    check("12 trap: click plans the site", site ~= nil)
    if not site then return end
    check("12 trap: nothing starts", not BuildAhead.isBusy(p))
    check("12 trap: site state trap", BuildAhead.siteState(p, site) == "trap", tostring(BuildAhead.siteState(p, site)))
    check("12 trap: chain does not pick it", BuildAhead.pickNext(p, gx, gy, z) == nil)
    local trapText = getText("IGUI_BuildAhead_Trap")
    local reason = BuildAhead.cannotBuildReason(p, site)
    check("12 trap: reason says it would wall you in", reason == trapText, tostring(reason))
    -- an order by hand may trap: the option stays on, with a warning
    local opt = findOption(fakeMenu(gx, gy, z), "IGUI_BuildAhead_BuildSite")
    local warn = getText("IGUI_BuildAhead_MayTrap")
    check("12 trap: build option enabled with the warning", opt and not opt.notAvailable
        and string.sub(opt.name, -#warn) == warn, opt and opt.name or "none")
end

local function trapGhost()
    local p = player()
    local site = T.trapSite
    if not site then return end
    check("12 trap: ghost drawn as trap", BuildAhead.ghostState(site) == "trap", tostring(BuildAhead.ghostState(site)))
    check("12 trap: still planned, not built", not BuildAhead.isBusy(p) and not hasObject(site.x, site.y, site.z, "LogWall")
        and #BuildAhead.getSites() == 1, "sites " .. #BuildAhead.getSites())
    -- 12b. the order by hand builds it, walling the player in
    local opt = findOption(fakeMenu(site.x, site.y, site.z), "IGUI_BuildAhead_BuildSite")
    if opt then opt.fn(opt.target, opt.arg1) end
    check("12 direct: build started", BuildAhead.isBusy(p))
end

local function directDone()
    local R = T.R
    local gx, gy, z = R.x + 1, R.y, R.z
    check("12 direct: wall built", hasObject(gx, gy, z, "LogWall"), objectsAt(gx, gy, z))
    local psq = player():getCurrentSquare()
    check("12 direct: player walled in, as ordered", psq and inRoom(psq:getX(), psq:getY()) and not playerFree(),
        playerSquareText())
    check("12 direct: no sites left", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    BuildAheadTrap.standFilter = nil
    -- let the player out for the line test
    removeObject(gx, gy, z, "LogWall")
    player():teleportTo(gx + 0.5, gy - 1.5, z)
end

-- 12c. an open wall line is built as before
local function lineStart()
    local p = player()
    local L = T.Ln
    local c = makeCursor(T.info, 1)
    c:tryBuild(L.x, L.y, L.z)
    check("12 line: click starts building", BuildAhead.isBuilding(p))
    c.blockBuild = true
    c:tryBuild(L.x, L.y + 1, L.z)
    check("12 line: second wall planned", #BuildAhead.getSites() == 2, "sites " .. #BuildAhead.getSites())
end

local function lineDone()
    local L = T.Ln
    check("12 line: both walls built", hasObject(L.x, L.y, L.z, "WoodenWallFrame")
        and hasObject(L.x, L.y + 1, L.z, "WoodenWallFrame"), objectsAt(L.x, L.y, L.z) .. " / " .. objectsAt(L.x, L.y + 1, L.z))
    check("12 line: no sites left", #BuildAhead.getSites() == 0, "sites " .. #BuildAhead.getSites())
    check("12 line: player not walled in", playerFree(), playerSquareText())
    log("trap fills", BuildAheadTrap.stats.fills, "squares", BuildAheadTrap.stats.squares)
end

-- wait until the player has been idle for 3 s, then run done(); give up after limit ticks
local function waitIdle(t, label, limit, done, nextPhase)
    local p = player()
    local busy = BuildAhead.isBusy(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
    if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
    if T.idleSince and t - T.idleSince > 180 then
        local ok, err = pcall(done)
        if not ok then phaseError(label, err) end
        T.phase = nextPhase
        T.phaseAt = t
    elseif t - T.phaseAt > limit then
        check(label .. " finished in time", false)
        T.phase = "quit"
    end
end

local function onTick()
    local p = player()
    if not p then return end
    T.tick = T.tick + 1
    local t = T.tick
    if getGameSpeed() == 0 then pcall(setGameSpeed, 1) end

    if T.phase == "wait" and t > 30 then
        T.phase = "setup"
        local ok, err = pcall(setup)
        if not ok then phaseError("setup", err); T.phase = "quit" end
    elseif T.phase == "plan" and t > 330 then
        local ok, err = pcall(plan)
        if not ok then phaseError("plan", err); T.phase = "quit" end
    elseif T.phase == "chain" then
        local busy = BuildAhead.isBuilding(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
        if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
        -- idle for 3 s means the chain has stopped
        if T.idleSince and t - T.idleSince > 180 then
            local ok, err = pcall(chainDone)
            if not ok then phaseError("chainDone", err); T.phase = "quit" end
        elseif t - T.chainStart > 60 * 300 then
            check("3 chain finished in time", false)
            T.phase = "quit"
        end
    elseif T.phase == "noMaterials" then
        local ok, err = pcall(noMaterials)
        if not ok then phaseError("noMaterials", err); T.phase = "quit" end
    elseif T.phase == "buildFromMenu" then
        local busy = BuildAhead.isBuilding(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
        if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
        if T.idleSince and t - T.idleSince > 180 then
            local ok, err = pcall(buildFromMenuDone)
            if not ok then phaseError("buildFromMenuDone", err); T.phase = "quit" end
        elseif t - T.menuStart > 60 * 300 then
            check("7 menu build finished in time", false)
            T.phase = "quit"
        end
    elseif T.phase == "ghost" then
        if t == T.ghostAt + 120 then
            shot("buildahead_stage1")
            log("screenshot")
            local states = {}
            for _, site in ipairs(BuildAhead.getSites()) do
                local k = (site.x == T.A.x and site.y == T.A.y) and "A"
                    or (site.x == T.E.x and site.y == T.E.y) and "E" or "G"
                states[k] = BuildAhead.ghostState(site)
            end
            check("4 ghost A blocked (red)", states.A == "blocked", tostring(states.A))
            check("4 ghosts E and G buildable (blue)", states.E == "buildable" and states.G == "buildable",
                tostring(states.E) .. " " .. tostring(states.G))
            check("4 materials appearing while idle start nothing", not BuildAhead.isBuilding(p)
                and #ISTimedActionQueue.getTimedActionQueue(p).queue == 0)
        elseif t == T.ghostAt + 160 then
            local ok, err = pcall(contextMenu)
            if not ok then phaseError("contextMenu", err) end
            T.phase = "ban"
        end
    elseif T.phase == "ban" then
        local ok, err = pcall(banStart)
        if not ok then phaseError("banStart", err); T.phase = "quit" end
    elseif T.phase == "banBuild" then
        local busy = BuildAhead.isBuilding(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
        if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
        if T.idleSince and t - T.idleSince > 180 then
            local ok, err = pcall(banDone)
            if not ok then phaseError("banDone", err) end
            T.phase = "fetch"
        elseif t - T.banStart > 60 * 300 then
            check("8 fence build finished in time", false)
            T.phase = "quit"
        end
    elseif T.phase == "fetch" then
        local ok, res = pcall(fetchStart)
        if not ok then phaseError("fetchStart", res) end
        if not (ok and res) then T.phase = "quit" end
    elseif T.phase == "fetchRun" then
        local busy = BuildAhead.isBusy(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
        if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
        if T.idleSince and t - T.idleSince > 180 then
            local ok, err = pcall(fetchDone)
            if not ok then phaseError("fetchDone", err) end
            T.phase = "multi"
        elseif t - T.fetchStart > 60 * 600 then
            check("9 fetch chain finished in time", false)
            T.phase = "quit"
        end
    elseif T.phase == "multi" then
        local ok, res = pcall(multiStart)
        if not ok then phaseError("multiStart", res) end
        if not (ok and res) then T.phase = "quit" end
    elseif T.phase == "multiRun" then
        local busy = BuildAhead.isBusy(p) or #ISTimedActionQueue.getTimedActionQueue(p).queue > 0
        if busy then T.idleSince = nil elseif not T.idleSince then T.idleSince = t end
        if T.idleSince and t - T.idleSince > 180 then
            local ok, err = pcall(multiDone)
            if not ok then phaseError("multiDone", err) end
            local ok2, err2 = pcall(skillChecks)
            if not ok2 then phaseError("skillChecks", err2) end
            T.phase = "trap"
        elseif t - T.fetchStart > 60 * 600 then
            check("10 multi-trip chain finished in time", false)
            T.phase = "quit"
        end
    elseif T.phase == "trap" then
        local ok, res = pcall(trapStart)
        if not ok then phaseError("trapStart", res) end
        if ok and res then T.phase = "trapWait" else T.phase = "quit" end
        T.phaseAt = t
    elseif T.phase == "trapWait" and t - T.phaseAt > 60 then
        local ok, err = pcall(trapClick)
        if not ok then phaseError("trapClick", err) end
        T.phase = "trapRun"
        T.phaseAt = t
        T.idleSince = nil
    elseif T.phase == "trapRun" then
        waitIdle(t, "12 trap build", 60 * 300, trapDone, "trapSkipWait")
    elseif T.phase == "trapSkipWait" and t - T.phaseAt > 60 then
        local ok, err = pcall(trapSkip)
        if not ok then phaseError("trapSkip", err) end
        T.phase = "trapGhost"
        T.phaseAt = t
    elseif T.phase == "trapGhost" and t - T.phaseAt > 90 then
        local ok, err = pcall(trapGhost)
        if not ok then phaseError("trapGhost", err) end
        T.phase = "directRun"
        T.phaseAt = t
        T.idleSince = nil
    elseif T.phase == "directRun" then
        waitIdle(t, "12 direct build", 60 * 300, directDone, "lineWait")
        if T.phase ~= "directRun" then BuildAheadTrap.standFilter = nil end
    elseif T.phase == "lineWait" and t - T.phaseAt > 60 then
        local ok, err = pcall(lineStart)
        if not ok then phaseError("lineStart", err) end
        T.phase = "lineRun"
        T.phaseAt = t
        T.idleSince = nil
    elseif T.phase == "lineRun" then
        waitIdle(t, "12 line", 60 * 300, lineDone, "quit")
    elseif T.phase == "quit" then
        T.phase = "done"
        log("RESULT pass", T.pass, "fail", T.fail)
        log("test done")
        -- under pzt the script ends (poll) and the harness quits
        if not harness() then pcall(function() getCore():quitToDesktop() end) end
    end
end

Events.OnRenderTick.Add(function()
    if not T.started or T.phase == "done" then return end
    local ok, err = pcall(onTick)
    if not ok then
        -- an error outside the phases' own pcalls: stop now instead of hanging until the timeout
        phaseError("tick", err)
        T.phase = "done"
        log("RESULT pass", T.pass, "fail", T.fail)
        log("test done")
    end
end)

-- entry points for the pzt script (STEPS in pzt.conf)
BuildAheadTest = {}

function BuildAheadTest.start()
    if T.started then
        -- the world is no longer the fresh save (pzt live without a restart)
        PZTest.fail("BuildAheadTest already ran in this game; pzt stop, then run again")
        return
    end
    T.started = true
    log("start")
end

-- keeps the harness script running (wait, poll again) until the test is done
function BuildAheadTest.poll()
    if T.phase == "done" then
        PZTest.log("BuildAheadTest pass " .. T.pass .. " fail " .. T.fail)
        return
    end
    PZTest.step("wait 30")
    PZTest.step("lua BuildAheadTest.poll()")
end
