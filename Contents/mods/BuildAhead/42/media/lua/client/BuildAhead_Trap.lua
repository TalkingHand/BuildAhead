-- Build Ahead: never wall the builder in.
--
-- Before the scheduler starts a site it simulates the result: the edges and
-- squares the object will block (from its face tiles' sprite properties:
-- WallN / WallW / collide edges, solid squares) are added to what already
-- blocks movement (sq:isBlockedTo), and the walkable squares on the site's
-- level are flood-filled from the squares the player could build from.
--
-- A stand square traps when its area is closed after the build and was open
-- before it. "Open" means the fill reached the search boundary (RADIUS), an
-- unloaded square, stairs, or an edge with a door, a window, a window frame
-- or a climbable fence. A wall is built from one side of its edge, so the same
-- wall can trap from one side and not from the other: the scheduler then walks
-- to a square that does not trap and builds from there. When every stand square
-- traps, the site is skipped and shows the reason.
--
-- Client-side only; nothing is synced. The check runs when a site is picked or
-- started, and for the ghost state at most every CHECK_EVERY_MS per site.

BuildAheadTrap = BuildAheadTrap or {}
local T = BuildAheadTrap

T.RADIUS = 30
T.CHECK_EVERY_MS = 2000
T.stats = { fills = 0, squares = 0 }

-- test seam: a square the player may stand on while building (see canStand)
T.standFilter = nil

local function key(x, y) return x * 65536 + y end

local function prop(props, enum, name)
    if not enum then return false end
    local ok, yes = pcall(function()
        local f = enum[name]
        return f ~= nil and props:has(f)
    end)
    return ok and yes == true
end

local function flag(props, name) return prop(props, IsoFlagType, name) end
local function ptype(props, name) return prop(props, IsoPropertyType, name) end

-- doors, door frames, windows and low fences or frames that can be climbed: no barrier
-- (TallHoppable walls and fences, e.g. a log wall, count as walls: climbing them is not a way out)
local function passable(props)
    for _, n in ipairs({ "doorN", "doorW", "DoorWallN", "DoorWallW", "WindowN", "WindowW", "windowN", "windowW",
        "HoppableN", "HoppableW" }) do
        if flag(props, n) then return true end
    end
    return false
end

-- what the object at (x, y) blocks on its own level:
-- { n = {key}, w = {key}, solid = {key}, tiles = {{x, y}}, any }
-- n[k]: the north edge of square k, w[k]: its west edge
function T.blockage(e, x, y)
    local b = { n = {}, w = {}, solid = {}, tiles = {}, any = false }
    local face = e and e:getFace()
    if not face then return b end
    for xx = 0, face:getWidth() - 1 do
        for yy = 0, face:getHeight() - 1 do
            local ti = face:getTileInfo(xx, yy, 0)
            local name = ti and ti:getSpriteName()
            local blocking = ti and ti:isBlocking()
            if ti and (name or blocking) then
                local tx, ty = x + xx, y + yy
                local k = key(tx, ty)
                b.tiles[#b.tiles + 1] = { x = tx, y = ty }
                local sprite = name and getSprite(name)
                local props = sprite and sprite:getProperties()
                if props then
                    if not passable(props) then
                        local nw = flag(props, "WallNW")
                        if nw or flag(props, "WallN") or flag(props, "WallNTrans") or flag(props, "collideN")
                            or ptype(props, "WALL_N") or ptype(props, "WALL_N_TRANS") then
                            b.n[k] = true
                            b.any = true
                        end
                        if nw or flag(props, "WallW") or flag(props, "WallWTrans") or flag(props, "collideW")
                            or ptype(props, "WALL_W") or ptype(props, "WALL_W_TRANS") then
                            b.w[k] = true
                            b.any = true
                        end
                        if flag(props, "solid") or flag(props, "solidtrans") then
                            b.solid[k] = true
                            b.any = true
                        end
                    end
                elseif blocking then
                    b.solid[k] = true
                    b.any = true
                end
            end
        end
    end
    return b
end

-- the sprite flags of the object's first tile, for the log
function T.flagsText(e)
    local ok, text = pcall(function()
        local ti = e:getFace():getTileInfo(0, 0, 0)
        local props = getSprite(ti:getSpriteName()):getProperties()
        local out = {}
        local flags = props:getFlagsList()
        for i = 0, flags:size() - 1 do out[#out + 1] = tostring(flags:get(i)) end
        return ti:getSpriteName() .. " " .. table.concat(out, ",")
    end)
    return ok and text or ("? " .. tostring(text))
end

-- "n:1,2 w: solid:" for the log
function T.describe(b)
    local function list(t)
        local out = {}
        for k in pairs(t) do out[#out + 1] = math.floor(k / 65536) .. "," .. (k % 65536) end
        return table.concat(out, ";")
    end
    return "n:" .. list(b.n) .. " w:" .. list(b.w) .. " solid:" .. list(b.solid)
end

-- the new object blocks the step from (ax, ay) to the neighbour (bx, by)
local function newBlocked(b, ax, ay, bx, by)
    if b.solid[key(bx, by)] then return true end
    if by == ay - 1 then return b.n[key(ax, ay)] == true end
    if by == ay + 1 then return b.n[key(bx, by)] == true end
    if bx == ax - 1 then return b.w[key(ax, ay)] == true end
    if bx == ax + 1 then return b.w[key(bx, by)] == true end
    return false
end

local function call(obj, method, arg)
    local ok, r = pcall(function() return obj[method](obj, arg) end)
    return ok and r
end

-- an edge that blocks walking but can be gone through: door, window, frame, low fence
local function exitEdge(a, b)
    if call(a, "isDoorTo", b) or call(a, "isWindowTo", b) or call(a, "isHoppableTo", b) then return true end
    local frame = call(a, "getWindowFrameTo", b)
    return frame ~= nil and frame ~= false
end

local function walkable(sq)
    return sq ~= nil and sq:TreatAsSolidFloor() and sq:isFree(false)
end

local DIRS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

-- Flood fill from a square on its level, with the new blockage b (nil: as now).
-- Returns open (true/false) and the squares seen ({key = true}); when targets
-- ({key = true}) are given and all of them are reached, returns "joined".
-- An open fill stops early, so its squares are only part of the area.
local function fill(start, b, targets)
    local z = start:getZ()
    local sx, sy = start:getX(), start:getY()
    local R = T.RADIUS
    local cell = getCell()
    local seen = { [key(sx, sy)] = true }
    local left = 0
    if targets then
        for k in pairs(targets) do if not seen[k] then left = left + 1 end end
        if left == 0 then return "joined", seen end
    end
    local queue, head = { start }, 1
    T.stats.fills = T.stats.fills + 1
    while head <= #queue do
        local a = queue[head]
        head = head + 1
        T.stats.squares = T.stats.squares + 1
        if a:HasStairs() then return true, seen end
        local ax, ay = a:getX(), a:getY()
        for _, d in ipairs(DIRS) do
            local bx, by = ax + d[1], ay + d[2]
            local k = key(bx, by)
            if not seen[k] and not (b and newBlocked(b, ax, ay, bx, by)) then
                if math.abs(bx - sx) > R or math.abs(by - sy) > R then return true, seen end
                local sq = cell:getGridSquare(bx, by, z)
                if not sq then return true, seen end
                if a:isBlockedTo(sq) then
                    if exitEdge(a, sq) then return true, seen end
                elseif walkable(sq) then
                    seen[k] = true
                    queue[#queue + 1] = sq
                    if targets and targets[k] then
                        left = left - 1
                        if left <= 0 then return "joined", seen end
                    end
                end
            end
        end
    end
    return false, seen
end
T.fill = fill

-- a square the player may build from
local function canStand(sq, b)
    if not walkable(sq) or b.solid[key(sq:getX(), sq:getY())] or sq:HasStairs() then return false end
    if T.standFilter and not T.standFilter(sq) then return false end
    return true
end

-- Which squares around the object trap the player.
-- Returns { trap = bool (some stand square traps), safe = {sq}, trapped = {sq},
--           preferred = {key = true} (the squares on either side of a new wall edge) }
-- or nil when the object blocks nothing.
function T.evaluate(e, x, y, z)
    local b = T.blockage(e, x, y)
    if not b.any then return nil end
    local cell = getCell()
    -- squares right across the new barrier: if one fill links them all, nothing is cut off
    local sides, preferred = {}, {}
    local function side(sx, sy)
        local sq = cell:getGridSquare(sx, sy, z)
        if sq and walkable(sq) and not b.solid[key(sx, sy)] then sides[key(sx, sy)] = sq end
    end
    for k in pairs(b.n) do
        local tx, ty = math.floor(k / 65536), k % 65536
        side(tx, ty); side(tx, ty - 1)
        preferred[key(tx, ty)], preferred[key(tx, ty - 1)] = true, true
    end
    for k in pairs(b.w) do
        local tx, ty = math.floor(k / 65536), k % 65536
        side(tx, ty); side(tx - 1, ty)
        preferred[key(tx, ty)], preferred[key(tx - 1, ty)] = true, true
    end
    for k in pairs(b.solid) do
        local tx, ty = math.floor(k / 65536), k % 65536
        for _, d in ipairs(DIRS) do side(tx + d[1], ty + d[2]) end
    end
    local result = { trap = false, safe = {}, trapped = {}, preferred = preferred }
    local first
    local targets = {}
    for k, sq in pairs(sides) do
        targets[k] = true
        first = first or sq
    end
    -- stand squares: around every tile, and the tiles themselves (a wall's own square)
    local stands, standKeys = {}, {}
    for _, t in ipairs(b.tiles) do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local k = key(t.x + dx, t.y + dy)
                if not standKeys[k] then
                    standKeys[k] = true
                    local sq = cell:getGridSquare(t.x + dx, t.y + dy, z)
                    if sq and canStand(sq, b) then stands[#stands + 1] = sq end
                end
            end
        end
    end
    if not first then
        for _, sq in ipairs(stands) do result.safe[#result.safe + 1] = sq end
        return result
    end
    local open, seen = fill(first, b, targets)
    if open == "joined" then
        -- every side reaches every other one: the build closes nothing off
        for _, sq in ipairs(stands) do result.safe[#result.safe + 1] = sq end
        return result
    end
    -- areas after the build: key -> trapped (true/false)
    local verdict = {}
    local function record(isOpen, s, startSq)
        local trapped = false
        if not isOpen then
            -- closed now: a trap only if the build closed it
            local wasOpen = fill(startSq, nil, nil)
            trapped = wasOpen == true
        end
        for k in pairs(s) do verdict[k] = trapped end
    end
    record(open, seen, first)
    for _, sq in ipairs(stands) do
        local k = key(sq:getX(), sq:getY())
        if verdict[k] == nil then
            local o, s = fill(sq, b, nil)
            record(o, s, sq)
        end
        if verdict[k] then
            result.trap = true
            result.trapped[#result.trapped + 1] = sq
        else
            result.safe[#result.safe + 1] = sq
        end
    end
    return result
end

-- The square to build from: nil when no stand square traps (walk the vanilla
-- way), else the safe square nearest to the player, on the far side of the new
-- edge when there is one. Second result true: every stand square traps.
function T.standSquare(playerObj, r)
    if not r or not r.trap then return nil, false end
    if #r.safe == 0 then return nil, true end
    local psq = playerObj:getCurrentSquare()
    local px, py = playerObj:getX(), playerObj:getY()
    local best, bestScore
    for _, sq in ipairs(r.safe) do
        local score = (sq:getX() + 0.5 - px) ^ 2 + (sq:getY() + 0.5 - py) ^ 2
        if not r.preferred[key(sq:getX(), sq:getY())] then score = score + 10000 end
        if sq == psq then score = -1 end
        if not bestScore or score < bestScore then best, bestScore = sq, score end
    end
    return best, false
end

T.key = key

-- Squares to build an object from when it blocks nothing (a frame, a door: they
-- can be passed): around its tiles, the tiles themselves included. Same shape
-- as T.evaluate's result; preferred: the two sides of a wall-like object's edge.
function T.standsAround(e, x, y, z)
    local b = T.blockage(e, x, y)
    local cell = getCell()
    local result = { trap = false, safe = {}, trapped = {}, preferred = {} }
    local seen = {}
    local tiles = #b.tiles > 0 and b.tiles or { { x = x, y = y } }
    for _, t in ipairs(tiles) do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local k = key(t.x + dx, t.y + dy)
                if not seen[k] then
                    seen[k] = true
                    local sq = cell:getGridSquare(t.x + dx, t.y + dy, z)
                    if sq and canStand(sq, b) then result.safe[#result.safe + 1] = sq end
                end
            end
        end
    end
    if e and e.isWallLike then
        result.preferred[key(x, y)] = true
        if e.north then result.preferred[key(x, y - 1)] = true else result.preferred[key(x - 1, y)] = true end
    end
    return result
end

-- Steps from `start` to each of `squares` on its level, walking around walls
-- (a door counts as open: the player opens it on the way). Returns
-- {key = steps} for the squares reached within `radius` of start.
function T.pathDistances(start, squares, radius)
    local z = start:getZ()
    local sx, sy = start:getX(), start:getY()
    local want, left = {}, 0
    for _, sq in ipairs(squares) do
        local k = key(sq:getX(), sq:getY())
        if sq:getZ() == z and not want[k] then
            want[k] = true
            left = left + 1
        end
    end
    local out = {}
    local function reach(k, d)
        if want[k] then
            out[k], want[k] = d, nil
            left = left - 1
        end
    end
    reach(key(sx, sy), 0)
    local cell = getCell()
    local seen = { [key(sx, sy)] = true }
    local queue, dists, head = { start }, { 0 }, 1
    while head <= #queue and left > 0 do
        local a, d = queue[head], dists[head]
        head = head + 1
        local ax, ay = a:getX(), a:getY()
        for _, dd in ipairs(DIRS) do
            local bx, by = ax + dd[1], ay + dd[2]
            local k = key(bx, by)
            if not seen[k] and math.abs(bx - sx) <= radius and math.abs(by - sy) <= radius then
                local sq = cell:getGridSquare(bx, by, z)
                -- seen only once entered: a square behind a wall may be reached another way
                if sq and walkable(sq) and (not a:isBlockedTo(sq) or call(a, "isDoorTo", sq)) then
                    seen[k] = true
                    queue[#queue + 1] = sq
                    dists[#dists + 1] = d + 1
                    reach(k, d + 1)
                end
            end
        end
    end
    return out
end

-- trapped squares listed for the log
function T.squares(list)
    local out = {}
    for _, sq in ipairs(list or {}) do out[#out + 1] = sq:getX() .. "," .. sq:getY() end
    return table.concat(out, " ")
end
