-- Last Ones Standing Sloppy Expansion and Fixes
-- Additive fixes for Last Ones Standing house storage and scavenging.
-- Only exported functions are wrapped/replaced; the shipped files are left
-- alone so the rest of the mod keeps working unchanged.
-- A Last Ones Standing update disables this file until the patch is rebased.

require "LastOnesStanding/LOS_Core"
require "LastOnesStanding/LOS_Stock"
require "LastOnesStanding/LOS_Storage"
require "LastOnesStanding/LOS_Scavenge"
require "LastOnesStanding/LOS_Corpses"
require "LastOnesStanding/LOS_Clean"
require "LastOnesStanding/LOS_Barricade"
require "LastOnesStanding/LOS_Salvage"
require "LastOnesStanding/LOS_WalkTo"
require "LastOnesStanding/LOS_Orders"
require "LastOnesStanding/LOS_Beds"
require "LastOnesStanding/LOS_Leisure"
require "TimedActions/ISPickupBrokenGlass"

local Guard = LastOnesStandingSloppyPatch
if not (Guard and Guard.active()) then return end

local LOS = LastOnesStanding

---------------------------------------------------------------------------
-- Squares a body can really stand on
---------------------------------------------------------------------------
-- isFree(false) is true for some low furniture (solidtrans without solid),
-- so companions were sent to stand on counters, shelves and beds.  With the
-- "Hop It!" mod installed, which treats those squares as obstacles, that made
-- them hop over (or onto) every piece of furniture on the way; they then
-- reached a square they could not work from and jammed.  Hop It! uses the same
-- test for its obstacles: solidtrans is only walkable when the game says the
-- square is standable (a counter under a window, say).
function LOS.canStandSquare(sq)
    if not sq then return false end
    local ok, free = pcall(function() return sq:isFree(false) end)
    if not (ok and free) then return false end
    local okSolid, solid = pcall(function() return sq:isSolid() end)
    if okSolid and solid then return false end
    local okTrans, trans = pcall(function() return sq:isSolidTrans() end)
    if okTrans and trans then
        local okCan, can = pcall(function() return sq:canStand() end)
        if not (okCan and can) then return false end
    end
    return true
end

local function standable(sq)
    return sq ~= nil and LOS.canStandSquare(sq)
end

---------------------------------------------------------------------------
-- Choosing squares: furniture is not free floor
---------------------------------------------------------------------------
-- The shipped walkableSquare()/standingSquare() only asked isFree(false),
-- which is true for counters, shelves and beds (solidtrans objects without
-- solid).  Companions were told to stand on them, could not work from there
-- and jammed, or hopped over a row of furniture trying to reach them.
local SIDES4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local CORNERS4 = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function patchedWalkableSquare(x, y, z, tries, spread)
    local cell = getCell()
    tries = tries or 1
    spread = spread or 0
    for _ = 1, tries do
        local sx = math.floor(x + ZombRandFloat(-spread, spread))
        local sy = math.floor(y + ZombRandFloat(-spread, spread))
        local sq = cell:getGridSquare(sx, sy, z)
        if sq and LOS.canStandSquare(sq) and not sq:hasFarmingPlant() then return sq end
    end
    return nil
end

local function patchedStandingSquare(npc, csq)
    if not csq then return nil end
    if LOS.canStandSquare(csq) then return csq end
    local cell = getCell()
    local best, bestD = nil, nil
    for _, s in ipairs(SIDES4) do
        local sq = cell:getGridSquare(csq:getX() + s[1], csq:getY() + s[2], csq:getZ())
        if sq and LOS.canStandSquare(sq) and not sq:isBlockedTo(csq) then
            local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), sq:getX() + 0.5, sq:getY() + 0.5)
            if not bestD or d < bestD then best, bestD = sq, d end
        end
    end
    if best then
        if LOS.noteStand then LOS.noteStand(best, csq) end
        return best
    end
    for _, s in ipairs(CORNERS4) do
        local sq = cell:getGridSquare(csq:getX() + s[1], csq:getY() + s[2], csq:getZ())
        if sq and LOS.canStandSquare(sq) and sq:canReachTo(csq) then
            local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), sq:getX() + 0.5, sq:getY() + 0.5)
            if not bestD or d < bestD then best, bestD = sq, d end
        end
    end
    if best and LOS.noteStand then LOS.noteStand(best, csq) end
    return best
end

-- Nearest square a person can actually stand on, searched in rings so the
-- result is predictable (walkableSquare() picks at random).
function LOS.standSquareNear(x, y, z, radius)
    local cell = getCell()
    local here = cell:getGridSquare(x, y, z)
    if here and LOS.canStandSquare(here) then return here end
    for r = 1, radius or 8 do
        for dy = -r, r do
            for dx = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(x + dx, y + dy, z)
                    if sq and LOS.canStandSquare(sq) then return sq end
                end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Hold squares: never send a companion back to a chair or counter
---------------------------------------------------------------------------
-- LOS.Orders.give() records the companion's current square as the place to
-- return to.  If it was sitting on the White Lazy Chair (or standing on any
-- other solidtrans furniture), every "wait" return ordered a walk onto a
-- square the pathfinder refuses.  The companion then collected
-- "found no path ... 1 requests" every few seconds and never settled, which
-- made it look like it was doing nothing at all.  Repair the recorded hold
-- square before the shipped code uses it.
local HOLD_KINDS = { chores = true, wait = true, guard = true, clean = true, upkeep = true, grass = true,
                     barricade = true, planks = true, wood = true, cook = true, water = true,
                     farm = true, tailor = true, mechanic = true, trapper = true, animals = true }

local function fixOrderHold(rec, br, npc, fresh)
    local o = rec and rec.order
    if not (o and o.x and o.y) or not HOLD_KINDS[o.kind] then return end
    -- A new work order means the companion is not resting any more.  This must
    -- happen once, when the order arrives: doing it on every brain tick made
    -- a companion who sat down (to eat, to rest, or to sleep on a seat) stand
    -- straight back up, and cleared the "tried a seat tonight" flag so the
    -- sleep behaviour queued the same seat again every two seconds instead of
    -- falling asleep.
    if br then
        if br.holdSeen ~= o then fresh = true end
        br.holdSeen = o
    end
    if fresh then
        if br then br.sitUntil, br.seatTonight = nil, nil end
        if npc and (npc:isSittingOnFurniture() or npc:isSitOnGround() or npc:isOnBed()) then
            npc:setVariable("forceGetUp", true)
        end
    end
    local z = o.z or 0
    local sq = getCell():getGridSquare(o.x, o.y, z)
    if sq and LOS.canStandSquare(sq) then return end
    local s = LOS.standSquareNear(o.x, o.y, z, 8)
    if not s then return end
    LOS.log("ORDER npc=%s hold square %d,%d,%d is not standable; using %d,%d instead",
        tostring(rec.id), o.x, o.y, z, s:getX(), s:getY())
    o.x, o.y, o.z = s:getX(), s:getY(), s:getZ()
    -- A failed walk to the old chair must not keep the new square on hold.
    if br and br.walkFail then br.walkFail = nil end
end
LOS.fixOrderHold = fixOrderHold

---------------------------------------------------------------------------
-- Waiting somewhere it cannot reach: wait where it stands
---------------------------------------------------------------------------
-- A wait or guard order stores the square the companion stood on when it was
-- told, and LOS.Orders.backTo() sends it back there every few seconds.  If
-- that square becomes unreachable while the companion is still close to it --
-- *Hop It!* hopped it out of the room, a door shut behind it, furniture was
-- pushed across -- every one of those orders is a path request the game
-- refuses.  The companion paces in circles, hopping furniture, and never
-- settles.  Once a wait walk has failed for good, move the recorded spot to
-- the square it is standing on instead.
-- UNTESTED: waiting for an in-game confirmation.
local WAIT_TAGS = { wait = true, guard = true }
local WAIT_NEAR = 8

local function waitWhereItStands(npc, tag, gx, gy)
    if not WAIT_TAGS[tag] or not npc or npc:getVehicle() then return end
    local id = LOS.idOf(npc)
    if not id then return end
    local rec = LOS.Records and LOS.Records.get and LOS.Records.get(id)
    local o = rec and rec.order
    if not (o and o.x and o.y) then return end
    -- Only when the walk was going to the recorded post itself.  "wait" is
    -- the tag LOS.Orders.backTo() puts on that walk, whichever work order the
    -- companion holds (tidy, clean, water...), so do not test o.kind here.
    if gx and (math.abs(gx - (o.x + 0.5)) > 1.5 or math.abs(gy - (o.y + 0.5)) > 1.5) then return end
    -- Wait posts on a wall line are where walls get built; moving one would
    -- take the companion off the line.
    if o.kind == "wait" and LOS.Walls and LOS.Walls.nearLine then
        local ok, near = pcall(LOS.Walls.nearLine, o.x, o.y)
        if ok and near then return end
    end
    local z = o.z or 0
    if math.floor(npc:getZ()) ~= z then return end
    local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), o.x + 0.5, o.y + 0.5)
    if d > WAIT_NEAR then return end
    local sq = LOS.standSquareNear(math.floor(npc:getX()), math.floor(npc:getY()), z, 2)
    if not sq or (sq:getX() == o.x and sq:getY() == o.y) then return end
    LOS.log("ORDER npc=%d cannot reach its %s spot at %d,%d (%.1f tiles); it waits where it stands at %d,%d",
        id, o.kind, o.x, o.y, d, sq:getX(), sq:getY())
    o.x, o.y, o.z = sq:getX(), sq:getY(), sq:getZ()
end

---------------------------------------------------------------------------
-- Couches as beds: the game lies the character on another tile of the couch
---------------------------------------------------------------------------
-- Some couches (the Orange and Yellow ones, for instance) have no sprite
-- grid, so LOS.Beds only recorded the object's own tile as the bed.  The
-- game's get-in animation then lies the character down on a neighbouring
-- tile of the same couch, the shipped check called that "off its bed", and
-- the companion got up again ('it got in at 2007,6529, off its bed; sleeps
-- on the floor').  A character that is in bed, next to the bed it chose and
-- on the same floor has made it into that bed, whichever tile it lies on.
local upstreamBedStep, upstreamBedStart

local function bedTile(tb, sq)
    return sq ~= nil and tb ~= nil and tb.onIt ~= nil and tb.onIt[sq:getX() .. "," .. sq:getY()] == true
end

-- A bed whose pieces are all known (a sprite grid) has several tiles here.
-- A couch without one has a single recorded tile even though its sprite is
-- two or three tiles long.
local function bedTileCount(tb)
    local n = 0
    for _ in pairs(tb and tb.onIt or {}) do n = n + 1 end
    return n
end

local function nearItsBed(tb, npc)
    local head = tb and tb.head
    local sq = head and head:getSquare()
    if not sq then return false end
    if math.floor(npc:getZ()) ~= (tb.z or sq:getZ()) then return false end
    return IsoUtils.DistanceTo(npc:getX(), npc:getY(), sq:getX() + 0.5, sq:getY() + 0.5) <= 2.5
end

local function patchedBedStep(id, npc, br, now, cur)
    local tb = br and br.toBed
    if tb and tb.stage == "in" and bedTileCount(tb) <= 1 and not bedTile(tb, npc:getCurrentSquare())
            and npc:isOnBed() and npc:getVariableBoolean("OnBedStarted") and nearItsBed(tb, npc) then
        local sq = npc:getCurrentSquare()
        LOS.log("BEDS npc=%d is in its bed at %s, lying on the game's own tile at %d,%d (a couch with no sprite grid)",
            id, tb.key, sq:getX(), sq:getY())
        npc:setVariable("OnBedAnim", "Asleep")
        return "in"
    end
    return upstreamBedStep(id, npc, br, now, cur)
end

-- The shipped start() also offers the two corners beside the bed.  A
-- companion that takes a corner as its nearest free square never gets the
-- game's get-in animation to line it up, and ends up "off its bed" at that
-- corner (7378,8253 for the bed at 7379,8254).  From the side it works.
local SIDE_N = { { -1, 0 }, { 1, 0 } }
local SIDE_EW = { { 0, -1 }, { 0, 1 } }

local function nearSideSquare(headSq, z, npc, facing)
    local dirs = (facing == "N" or facing == "S") and SIDE_N or SIDE_EW
    local cell = getCell()
    local best, bestD = nil, nil
    for _, d in ipairs(dirs) do
        local sq = cell:getGridSquare(headSq:getX() + d[1], headSq:getY() + d[2], z)
        if sq and sq:isFree(false) then
            local dist = (sq:getX() + 0.5 - npc:getX()) ^ 2 + (sq:getY() + 0.5 - npc:getY()) ^ 2
            if not bestD or dist < bestD then best, bestD = sq, dist end
        end
    end
    return best
end

local function patchedBedStart(id, npc, br, now)
    local r = upstreamBedStart(id, npc, br, now)
    local tb = br and br.toBed
    if r and tb and not tb.floor and tb.head then
        local hsq = tb.head:getSquare()
        local dx = hsq and (tb.x - hsq:getX()) or 0
        local dy = hsq and (tb.y - hsq:getY()) or 0
        if hsq and dx ~= 0 and dy ~= 0 and bedTileCount(tb) > 1 then
            local facing = SeatingManager.getInstance():getFacingDirection(tb.head)
            local sq = nearSideSquare(hsq, tb.z or hsq:getZ(), npc, facing)
            if sq then
                local ox, oy = tb.x, tb.y
                tb.x, tb.y, tb.z = sq:getX(), sq:getY(), sq:getZ()
                ISTimedActionQueue.clear(npc)
                ISTimedActionQueue.add(LOSWalkTo:new(npc, tb.x, tb.y, tb.z, false, "bed"))
                LOS.log("BEDS npc=%d gets into its bed at %s from the side at %d,%d, not the corner at %d,%d",
                    id, tb.key, tb.x, tb.y, ox, oy)
            end
        end
    end
    return r
end

---------------------------------------------------------------------------
-- A break taken when dead on its feet becomes sleep
---------------------------------------------------------------------------
-- A break scores above everything else while it is on: the shipped code
-- gives the current activity 0.1 on top, so a companion at a full 0.8
-- fatigue watched television for the whole break and never went to bed.
-- A companion that has reached the shipped "exhausted" mark, or one that
-- should be abed for the night, is better off asleep.  Do not end the break
-- for that: without it the job want climbs back above sleep, so the break
-- stays on (keeping work at bay) and the sleep behaviour is nudged above it
-- instead.  A reading companion also has to stop reading: the shipped step
-- will not hand over while a timed action is running.
local NAP_FATIGUE, NAP_WANT = 0.8, 0.95
local upstreamLeisureStep, upstreamGiveBreak

local function napOwed(npc, rec)
    local Sl = LOS.Sleep
    if not (Sl and Sl.wants and npc and rec and Sl.wants(npc, rec, "companion")) then return false end
    if npc:getStats():get(CharacterStat.FATIGUE) >= NAP_FATIGUE then return true end
    return Sl.isNight ~= nil and Sl.isNight()
end

local function boostSleep()
    local list = LOS.Behaviours and LOS.Behaviours.of and LOS.Behaviours.of("life")
    if not list then return end
    for _, b in ipairs(list) do
        if b.name == "sleep" and not b.napBoost then
            local wants = b.wants
            b.napBoost = true
            b.wants = function(c)
                local s = wants and wants(c) or nil
                if c.br and c.br.breakUntilH and napOwed(c.npc, c.rec) then
                    return math.max(s or 0, NAP_WANT)
                end
                return s
            end
        end
    end
end

local function patchedLeisureStep(id, npc, br, rec, cur, now, ctx, player)
    if br and br.breakUntilH and br.leisure and napOwed(npc, rec) then
        -- Wind the activity up now (the shipped step then puts the book or
        -- fetched item away and gets up) and drop a running action such as
        -- ISReadABook, which would otherwise block the sleep behaviour.
        br.leisure.untilMs = now - 1
        if cur and cur.Type ~= "LOSWalkTo" and ISTimedActionQueue.queues[npc] then
            ISTimedActionQueue.clear(npc)
        end
        if not br.napTold then
            br.napTold = true
            LOS.log("LEISURE npc=%d is dead on its feet: it stops its break and lies down", id)
        end
    elseif br then
        br.napTold = nil
    end
    return upstreamLeisureStep(id, npc, br, rec, cur, now, ctx, player)
end

local function patchedGiveBreak(id, now)
    local br = LOS.Brain and LOS.Brain.get(id)
    local rec = LOS.Records and LOS.Records.get(id)
    local npc = LOS.Bodies and LOS.Bodies.byId and LOS.Bodies.byId[id]
    local nap = br and npc and rec and napOwed(npc, rec)
    local r = upstreamGiveBreak(id, now)
    if nap then
        LOS.log("LEISURE npc=%d is dead on its feet: the break becomes a sleep", id)
    end
    return r
end

---------------------------------------------------------------------------
-- Storage marks: never use a bin outside the base as a cupboard
---------------------------------------------------------------------------
-- The player's faction keeps every container mark ever made.  Marks made on
-- the composter and crate outside the base were therefore valid storage
-- destinations, so companions carried planks and nails ten tiles out of the
-- base and put them in the composter.  A place for things is inside the base
-- and is not a bin, composter or dumpster.
local FOOD_TYPES = { dryfood = true, freshfood = true, usefirst = true }
local NOT_A_PLACE = { composter = true, bin = true, dumpster = true, trashcan = true, garbagecan = true,
                      wheeliebin = true, garbage = true }

local function placeAllowed(c, sq)
    if not (c and sq) then return false end
    if NOT_A_PLACE[tostring(c:getType())] then return false end
    local St = LOS.Storage
    local b = St.base()
    if b and not St.inBase(sq:getX(), sq:getY()) then return false end
    return true
end

local upstreamPlaceFor

local function patchedPlaceFor(typeKey, x, y, item)
    if not (upstreamPlaceFor and typeKey) then return nil end
    local o, c, sq, what = upstreamPlaceFor(typeKey, x, y, item)
    if o and c and sq and placeAllowed(c, sq) then return o, c, sq, what end
    -- The shipped pick was a bin or a mark outside the base.  Look for the
    -- best marked container that is a real place inside the base instead.
    local St = LOS.Storage
    local best, bestRank, bestD = nil, nil, nil
    for _, mark in pairs(St.marks()) do
        if not mark.private and mark.types then
            local rank = nil
            if mark.types[typeKey] then rank = 1
            elseif FOOD_TYPES[typeKey] and (mark.types.dryfood or mark.types.freshfood or mark.types.usefirst) then rank = 2
            elseif St.PARENT[typeKey] and mark.types[St.PARENT[typeKey]] then rank = 2
            elseif mark.types.anything then rank = 3 end
            if rank and mark.x then
                local bo, bc, bsq = St.boxOfMark(mark)
                if bo and bc and bsq and placeAllowed(bc, bsq) then
                    local d = (mark.x - x) * (mark.x - x) + (mark.y - y) * (mark.y - y)
                    if not bestRank or rank < bestRank or (rank == bestRank and d < bestD) then
                        best, bestRank, bestD = { bo, bc, bsq }, rank, d
                    end
                end
            end
        end
    end
    if not best then return nil end
    return best[1], best[2], best[3], ({ "marked", "food", "anything" })[bestRank]
end

-- Nails have no useful display category, so typeOf() gave up on them and
-- tidy could neither store them nor take them out of a clothing wardrobe.
local upstreamTypeOf

local function patchedTypeOf(item)
    if not upstreamTypeOf then return nil end
    local kind = upstreamTypeOf(item)
    if kind then return kind end
    local ft = item and item:getFullType() or ""
    if ft == "Base.BrokenGlass" then return "household" end
    if ft == "Base.Nails" or ft == "Base.NailsBox" or ft == "Base.NailsCarton"
            or string.find(ft, "Nails", 1, true) then
        return "materials"
    end
    return nil
end

---------------------------------------------------------------------------
-- Scavenging: unopened tins count as food
---------------------------------------------------------------------------
-- An unopened can has no hunger value until its opening recipe is used, so
-- foodProblem() reports "doesn't fill" and the original haulKind() rejects
-- it.  Cans were therefore the one thing a group never brought home.  They
-- are still food for storage and later opening, so classify them as food.
local function isUnopenedFood(item)
    if not instanceof(item, "Food") then return false end
    local recipe = item.getOpeningRecipe and item:getOpeningRecipe()
    if recipe and recipe ~= "" then return true end
    return LOS.Needs and LOS.Needs.foodProblem and LOS.Needs.foodProblem(item) == "needs a tool to open"
end

---------------------------------------------------------------------------
-- House containers: keep using the home even when it is inside the base
---------------------------------------------------------------------------
-- The shipped homeContainers() returns nil when the group's home lies inside
-- the player's designated base (LOS.Storage.inBase).  That disabled eating,
-- hauling and tidying for every group living in the base.  Scan the home
-- building in that case as well, but skip containers the player marked as
-- private so their own storage is not touched.
local NOT_IN = { stove = true, microwave = true, woodstove = true, fireplace = true, barbecue = true, campfire = true,
                 bin = true, clothingwasher = true, clothingdryer = true, toaster = true, vendingsnack = true,
                 vendingpop = true, postbox = true, mailbox = true, dumpster = true, composter = true }
local HOME_SCAN_MS = 60000
local homeSeen = {}

local function isPrivate(obj, index)
    local St = LOS.Storage
    local mark = St and St.markOf and St.markOf(obj, index) or nil
    return mark ~= nil and mark.private == true
end

local function scanHome(owner, key)
    local home = owner.home
    local now = getTimestampMs()
    local memo = homeSeen[key]
    local cell = getCell()
    local sq0 = cell:getGridSquare(home.x, home.y, home.z or 0)
    local b = sq0 and sq0:getBuilding()
    if not b then
        homeSeen[key] = nil
        return nil
    end
    if memo and memo.b == b and now < memo.at then return memo.list end
    local def = b:getDef()
    if not def then return nil end
    local x1, y1 = def:getX(), def:getY()
    local x2, y2 = x1 + def:getW(), y1 + def:getH()
    if not (cell:getGridSquare(x1, y1, 0) and cell:getGridSquare(x2, y1, 0)
            and cell:getGridSquare(x1, y2, 0) and cell:getGridSquare(x2, y2, 0)) then
        return nil
    end
    local list = {}
    for z = 0, 3 do
        for x = x1, x2 do
            for y = y1, y2 do
                local sq = cell:getGridSquare(x, y, z)
                if sq and sq:getBuilding() == b then
                    local room = sq:getRoom()
                    local name = room and string.lower(tostring(room:getName())) or ""
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        for ci = 0, o:getContainerCount() - 1 do
                            local c = o:getContainerByIndex(ci)
                            if c and not NOT_IN[tostring(c:getType())] and not isPrivate(o, ci) then
                                list[#list + 1] = { c = c, room = name }
                            end
                        end
                    end
                end
            end
        end
    end
    homeSeen[key] = { list = list, b = b, at = now + HOME_SCAN_MS }
    return list
end

-- PATCH: for the base ("base:x,y,z") scan every part of the player's base,
-- not just the building the main storage happens to sit in.  This is what
-- lets boarding materials in another building of the base be found.
local baseSeen = {}

local function scanBase(key)
    local now = getTimestampMs()
    local memo = baseSeen[key]
    if memo and now < memo.at then return memo.list end
    local b = LOS.Storage.base()
    if not b then return nil end
    local cell, list = getCell(), {}
    for _, z in ipairs({ -1, 0, 1, 2 }) do
        for _, p in ipairs(b.parts or {}) do
            for y = p.y1, p.y2 do
                for x = p.x1, p.x2 do
                    local sq = cell:getGridSquare(x, y, z)
                    local objs = sq and sq:getObjects()
                    for i = 0, (objs and objs:size() or 0) - 1 do
                        local o = objs:get(i)
                        for ci = 0, o:getContainerCount() - 1 do
                            local c = o:getContainerByIndex(ci)
                            if c and not NOT_IN[tostring(c:getType())] and not isPrivate(o, ci) then
                                list[#list + 1] = { c = c, room = "" }
                            end
                        end
                    end
                end
            end
        end
    end
    baseSeen[key] = { list = list, at = now + HOME_SCAN_MS }
    return list
end

local function patchedHomeContainers(owner, key)
    key = key or ("o" .. tostring(owner and owner.id or 0))
    if string.sub(key, 1, 5) == "base:" then return scanBase(key) end
    if not (owner and owner.home) then return nil end
    return scanHome(owner, key)
end

----------------------------------------------------------------------------
-- Corpses: put bodies down close by, on a square that is actually loaded
----------------------------------------------------------------------------
-- The shipped picker starts 20 tiles outside the *whole base bounds* and then
-- caches that square.  In a base made of several buildings that is often 40+
-- tiles from the body and outside the player's loading radius, so work() gave
-- up with "the place for them isn't loaded" and the body stayed put.  Pick the
-- nearest loaded outdoor square just outside the base instead.
local DUMP_SEARCH = 40
local DUMP_CLEARANCE = 2

local function nearPart(b, x, y, pad)
    for _, p in ipairs(b and b.parts or {}) do
        if x >= p.x1 - pad and x <= p.x2 + pad and y >= p.y1 - pad and y <= p.y2 + pad then return true end
    end
    return false
end

local function inBaseSquare(b, x, y)
    if nearPart(b, x, y, 0) then return true end
    local St = LOS.Storage
    return St and St.inBase and St.inBase(x, y) or false
end

local function pickLoadedDump(b, body)
    local cell = getCell()
    local bx, by = math.floor(body:getX()), math.floor(body:getY())
    local bz = math.floor(body:getZ())
    if bz > 0 then bz = 0 end -- upstairs bodies are thrown down, as before
    for r = DUMP_CLEARANCE + 1, DUMP_SEARCH do
        local best, bestD = nil, nil
        for dy = -r, r do
            for dx = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(bx + dx, by + dy, bz)
                    if sq and sq:isOutside() and sq:getBuilding() == nil and sq:isFree(false)
                            and not inBaseSquare(b, sq:getX(), sq:getY())
                            and not nearPart(b, sq:getX(), sq:getY(), DUMP_CLEARANCE) then
                        local d = IsoUtils.DistanceTo(bx, by, sq:getX(), sq:getY())
                        if not bestD or d < bestD then best, bestD = sq, d end
                    end
                end
            end
        end
        if best then return best end
    end
    return nil
end

local upstreamCorpseSpot

local function corpseData()
    local R = LOS.Records
    local d = R and R.data and R.data()
    if not d then return nil end
    d.ownDead = d.ownDead or {}
    return d
end

local function spotLoaded(s)
    local sq = s and s.x and getCell():getGridSquare(s.x, s.y, s.z or 0)
    return sq ~= nil and sq:isOutside()
end

local function patchedCorpseSpot(b, body)
    local C = LOS.Corpses
    if not (b and body) then return upstreamCorpseSpot and upstreamCorpseSpot(b, body) or nil end
    -- A place the player named is theirs; keep the shipped answer for it.
    if C.spotSet and C.spotSet() then
        return upstreamCorpseSpot and upstreamCorpseSpot(b, body) or nil
    end
    local d = corpseData()
    local base = string.format("%d,%d,%d,%d", b.x1, b.y1, b.x2, b.y2)
    -- Reuse the square already chosen while it is loaded: next body selection
    -- uses it to avoid picking up corpses that are already at the dump.
    if d and d.bodySpot and d.bodySpot.base == base and spotLoaded(d.bodySpot) then return d.bodySpot end
    local sq = pickLoadedDump(b, body)
    if not sq then return upstreamCorpseSpot and upstreamCorpseSpot(b, body) or nil end
    local spot = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), base = base }
    if d then d.bodySpot = spot end
    local now = getTimestampMs()
    if not C._patchSpotSaid or now - C._patchSpotSaid > 60000 then
        C._patchSpotSaid = now
        LOS.log("CORPSES a place for bodies is picked beside the body: %d,%d,%d (loaded, %.0f tiles away)", spot.x, spot.y,
            spot.z, IsoUtils.DistanceTo(body:getX(), body:getY(), spot.x + 0.5, spot.y + 0.5))
    end
    return spot
end

----------------------------------------------------------------------------
-- Cleaning: look through every container in the base, not just the main one
----------------------------------------------------------------------------
-- sources() only looked in the designated storage and the marked boxes, so a
-- mop or bleach bottle in any other cupboard was invisible and the companions
-- refused to clean ("nothing to clean it with in the base").  When the shipped
-- step gives up for that reason, find the missing thing anywhere in the base
-- and start its normal fetch job.
local CLEAN_SCAN_MS = 5000
local cleanScanAt, cleanScan = 0, nil
local cleanBad = {}
local CLEAN_BAD_MS = 600000

local function patchIsLiquid(it)
    local fc = it and it:getFluidContainer()
    return fc ~= nil and (fc:contains(Fluid.Bleach) or fc:contains(Fluid.CleaningLiquid))
        and fc:getAmount() >= ZomboidGlobals.CleanBloodBleachAmount
end

local function patchIsScrubber(it)
    return it ~= nil and it:hasTag(ItemTag.CLEAN_STAINS) and not it:isBroken()
end

-- PATCH: after a cleaning job, put the mop/sponge and the bleach bottle away
-- instead of walking around with them in hand forever.  Test the fluid even
-- when the bottle is empty by now: an empty bleach bottle was still "in hand"
-- and no longer counted as a liquid.
local function isCleanGear(it)
    if it == nil then return false end
    local ok, fc = pcall(function() return it:getFluidContainer() end)
    if ok and fc and (fc:contains(Fluid.Bleach) or fc:contains(Fluid.CleaningLiquid)) then return true end
    local ok2, scrub = pcall(function() return it:hasTag(ItemTag.CLEAN_STAINS) and not it:isBroken() end)
    return ok2 and scrub or false
end

local function parkCleanGear(npc)
    local p, s = npc:getPrimaryHandItem(), npc:getSecondaryHandItem()
    local changed = false
    if isCleanGear(p) then npc:setPrimaryHandItem(nil) changed = true end
    if isCleanGear(s) then npc:setSecondaryHandItem(nil) changed = true end
    if changed then
        pcall(function() npc:resetEquippedHandsModels() end)
        LOS.log("CLEAN npc=%d puts the cleaning things away", LOS.idOf(npc) or -1)
    end
end

local function scanCleanBase(npc)
    local now = getTimestampMs()
    if cleanScan and now < cleanScanAt then return cleanScan end
    cleanScanAt = now + CLEAN_SCAN_MS
    local b = LOS.Storage.base()
    local cell = getCell()
    local liquids, scrubs = {}, {}
    local stain, stainD = nil, nil
    for _, z in ipairs({ -1, 0, 1, 2 }) do
        for _, p in ipairs(b and b.parts or {}) do
            for y = p.y1, p.y2 do
                for x = p.x1, p.x2 do
                    local sq = cell:getGridSquare(x, y, z)
                    if sq then
                        if sq:haveStains() then
                            local d = IsoUtils.DistanceToSquared(npc:getX(), npc:getY(), x + 0.5, y + 0.5)
                            if not stainD or d < stainD then stain, stainD = sq, d end
                        end
                        local objs = sq:getObjects()
                        for i = 0, objs:size() - 1 do
                            local o = objs:get(i)
                            for ci = 0, o:getContainerCount() - 1 do
                                local c = o:getContainerByIndex(ci)
                                local mark = c and LOS.Storage.markOf(o, ci) or nil
                                if c and not (mark and mark.private) then
                                    local liq = c:getFirstEvalRecurse(patchIsLiquid)
                                    if liq then liquids[#liquids + 1] = { obj = o, c = c, sq = sq, item = liq } end
                                    local scr = c:getFirstEvalRecurse(patchIsScrubber)
                                    if scr then scrubs[#scrubs + 1] = { obj = o, c = c, sq = sq, item = scr } end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    cleanScan = { liquids = liquids, scrubs = scrubs, stain = stain }
    return cleanScan
end

-- Container wrapper objects are not guaranteed to keep their Lua identity, so
-- remember a bad source by its object, square and container index instead.
local function cleanKeyOf(e)
    local sq = e.obj and e.obj:getSquare()
    local idx = 0
    for i = 0, e.obj:getContainerCount() - 1 do
        if e.obj:getContainerByIndex(i) == e.c then idx = i break end
    end
    return string.format("%s@%d,%d,%d#%d", tostring(e.obj:getType()), sq and sq:getX() or -1,
        sq and sq:getY() or -1, sq and sq:getZ() or 0, idx)
end

local function freshClean(list, now)
    for _, e in ipairs(list or {}) do
        local key = cleanKeyOf(e)
        local untilMs = cleanBad[key]
        if not untilMs or now >= untilMs then
            if untilMs then cleanBad[key] = nil end
            return e, key
        end
    end
    return nil
end

local upstreamCleanStep

local function patchedCleanStep(id, npc, br, rec, role, cur, now, ctx)
    if not upstreamCleanStep then return false end
    -- Nothing to clean right now: don't keep a sponge or bleach bottle in hand.
    if not cur and not br.clean then parkCleanGear(npc) end
    if not br.clean and br.cleanTried then
        local tried = br.cleanTried
        br.cleanTried = nil
        local inv = npc:getInventory()
        local got = tried.kind == "liquid" and inv:getFirstEvalRecurse(patchIsLiquid)
            or tried.kind == "scrub" and inv:getFirstEvalRecurse(patchIsScrubber)
        if not got and now - tried.at > 1000 then cleanBad[tried.key] = now + CLEAN_BAD_MS end
    end
    local hadClean = br.clean ~= nil and br.clean.kind == "clean"
    if upstreamCleanStep(id, npc, br, rec, role, cur, now, ctx) then return true end
    if hadClean and not br.clean then parkCleanGear(npc) end
    if cur or br.clean then return false end
    local why = tostring(br.cleanWhy or "")
    if not string.find(why, "nothing to clean it with", 1, true) then return false end
    -- Upstream throttles this message through cleanIdleUntil; only do the wide
    -- scan now and then so a base with no cleaning supplies is not rescanned
    -- every tick.
    if now < (br.cleanPatchAt or 0) then return false end
    br.cleanPatchAt = now + 30000

    local scan = scanCleanBase(npc)
    if not scan.stain then return false end
    local inv = npc:getInventory()
    local hasLiquid = inv:getFirstEvalRecurse(patchIsLiquid) ~= nil
    local hasScrub = inv:getFirstEvalRecurse(patchIsScrubber) ~= nil
    local src, kind, srcKey = nil, nil, nil
    if not hasLiquid then
        src, srcKey = freshClean(scan.liquids, now)
        kind = "liquid"
    end
    if not src and not hasScrub then
        src, srcKey = freshClean(scan.scrubs, now)
        kind = "scrub"
    end
    if not src then return false end
    local stand = LOS.Scavenge.standingSquare(npc, src.sq)
    if not stand then return false end

    br.cleanIdleUntil = 0
    br.cleanWhy = nil
    br.clean = { kind = "fetch", object = src.obj, container = src.c, items = { src.item }, stand = stand,
                 sq = scan.stain, at = now, tries = 0 }
    src.item:getModData().LOS_Haul = true
    br.cleanTried = { key = srcKey, at = now, kind = kind }
    LOS.log("CLEAN npc=%d: the group's storage has no %s; it goes to fetch some from a container in the base at %d,%d",
        id, kind == "liquid" and "bleach or cleaning liquid" or "mop, broom, sponge or cloth", src.sq:getX(), src.sq:getY())
    return upstreamCleanStep(id, npc, br, rec, role, cur, now, ctx)
end

----------------------------------------------------------------------------
-- Boarding: materials may live in any container in the base's building
----------------------------------------------------------------------------
-- Bc.step only searched the one main storage container; with the hammer in a
-- cupboard two rooms away it idled "I need a hammer" and chores never got the
-- window boarded.  When that happens, run the house path (which our patched
-- homeContainers makes scan the whole building) against the storage building.
local upstreamBarricadeStep

-- PATCH: when the square inside the storage building is furniture (or is
-- otherwise not standable), board the window from the other side instead of
-- declaring it unreachable.  e.indoor doubles as the stand square and as the
-- side of the barricade that needsBoards() inspects, so replacing it with the
-- opposite square keeps both consistent.
local function oppositeStand(e)
    local wnd = e.window
    local csq = wnd and wnd:getSquare()
    if not (csq and e.indoor) then return nil end
    if LOS.canStandSquare(e.indoor) then return nil end
    local cell = getCell()
    local ox, oy = (wnd:getNorth() and 0 or -1), (wnd:getNorth() and -1 or 0)
    local alt
    if e.indoor:getX() == csq:getX() and e.indoor:getY() == csq:getY() and e.indoor:getZ() == csq:getZ() then
        alt = cell:getGridSquare(csq:getX() + ox, csq:getY() + oy, csq:getZ())
    else
        alt = csq
    end
    if alt and LOS.canStandSquare(alt) then return alt end
    return nil
end

local function smarterWindows(br)
    for _, e in ipairs(br.boardWindows or {}) do
        local alt = oppositeStand(e)
        if alt then e.indoor = alt end
    end
end

-- Bc.step() rebuilds br.boardWindows and picks a window in the same call, so
-- fixing the list after the fact would still let it choose a furniture square.
-- Build the list ourselves (with the smart side) first; the shipped code then
-- sees a fresh list and uses it.
local BOARD_WINDOWS_MS = 300000

local function prepareBaseWindows(br, now, id)
    local _, _, ssq = LOS.Storage.target()
    local building = ssq and ssq:getBuilding()
    local Bc = LOS.Barricade
    if not (building and Bc and Bc.windowsOf) then return end
    local key = string.format("base:%d,%d,%d", ssq:getX(), ssq:getY(), ssq:getZ())
    if br.boardWindows and br.boardHome == key and now < (br.boardWindowsAt or 0) then return end
    local list, stats = Bc.windowsOf(building, ssq:getZ())
    if not list then return end
    br.boardWindows, br.boardHome, br.boardWindowsAt, br.boardSkip = list, key, now + BOARD_WINDOWS_MS, {}
    smarterWindows(br)
    LOS.log("BOARD npc=%d: %d windows on this floor of the storage's building (%d rooms, %d squares looked at, %d windows seen, %d of them not this building's)",
        id, #list, stats and stats.rooms or 0, stats and stats.squares or 0, stats and stats.windows or 0,
        stats and stats.outside or 0)
end

local function patchedBarricadeStep(id, npc, br, rec, role, cur, now, ctx)
    if not upstreamBarricadeStep then return false end
    smarterWindows(br)
    prepareBaseWindows(br, now, id)
    if upstreamBarricadeStep(id, npc, br, rec, role, cur, now, ctx) then return true end
    if cur or br.boardJob then return false end
    -- Only try the wide search once a minute; otherwise the upstream idle (and
    -- its own message) would send us back into the scan every tick.
    if now < (br.patchBoardAt or 0) then return false end
    local said = tostring(br.boardSaid or "")
    local want = string.find(said, "hammer", 1, true) and "hammer"
        or string.find(said, "planks", 1, true) and "planks"
        or string.find(said, "nails", 1, true) and "nails"
    if not want then return false end
    br.patchBoardAt = now + 60000
    local sobj, sc, ssq = LOS.Storage.target()
    if not ssq then return false end
    local b = LOS.Storage.base()
    if not b then return false end
    local owner = { id = -1, home = { x = ssq:getX(), y = ssq:getY(), z = ssq:getZ() } }
    local key = string.format("base:%d,%d,%d", ssq:getX(), ssq:getY(), ssq:getZ())
    br.boardIdleUntil, br.boardSaid = 0, nil
    -- keep the window list we already prepared (and smartened) instead of
    -- letting homeStep rebuild it from scratch
    br.boardHome = key
    local ok = LOS.Barricade.homeStep(id, npc, br, rec, role, cur, now, ctx, owner, key)
    if ok then
        LOS.log("BOARD npc=%d: the main storage had no %s; it looks through the base's containers", id, want)
        return true
    end
    return false
end

----------------------------------------------------------------------------
-- Salvaging: don't wander 40 tiles out while looking after the base
----------------------------------------------------------------------------
-- Sv.find() searches 40 tiles around the companion, outside the base, for
-- wooden furniture to take apart.  During the "look after the base" order that
-- turned into long unexplained trips away from home.  Keep the shipped search
-- for anything close to the base, and leave anything further alone.
local SALVAGE_NEAR = 16
local upstreamSalvageFind
local upstreamStandingSquare

local function distanceToBase(b, x, y)
    local best = nil
    for _, p in ipairs(b and b.parts or {}) do
        local dx = math.max(p.x1 - x, 0, x - p.x2)
        local dy = math.max(p.y1 - y, 0, y - p.y2)
        local d = math.sqrt(dx * dx + dy * dy)
        if not best or d < best then best = d end
    end
    return best
end

-- Sv.find() is exported, so reject its far-away pick right where it is made
-- instead of touching the shipped step.  Sv.step already throttles this call
-- through br.salvageLookAt, so the message cannot repeat every tick.
local function patchedSalvageFind(npc, b)
    if not upstreamSalvageFind then return nil end
    local found, why = upstreamSalvageFind(npc, b)
    if not (found and found.sq) then return found, why end
    local d = distanceToBase(b, found.sq:getX(), found.sq:getY())
    if d and d > SALVAGE_NEAR then
        LOS.log("SALVAGE npc=%d leaves the furniture at %d,%d alone: it is more than %d tiles from the base while the base is being looked after",
            LOS.idOf(npc) or -1, found.sq:getX(), found.sq:getY(), SALVAGE_NEAR)
        return nil, "the wooden furniture in reach is too far from the base"
    end
    return found, why
end

----------------------------------------------------------------------------
-- Pathing: open ordinary closed doors instead of standing at them
----------------------------------------------------------------------------
-- goRound() only handled locked doors (by detouring through an open one).
-- Plain closed doors made the path fail and the walker stopped, which looked
-- like a companion stuck at the base door.  After the shipped attempts fail,
-- open a closed, unlocked door right beside the character and path on.
local upstreamGoRound
local upstreamClimbOver
local DOOR_SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local STEP_OFF = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
local DOOR_AGAIN_MS = 3000
local DOOR_MAX_REQUESTS = 20
local DOOR_REACH = 4

local function isDoorObject(o)
    return instanceof(o, "IsoDoor") or (instanceof(o, "IsoThumpable") and o:isDoor())
end

-- IsoThumpable gates do not all expose couldBeOpen(); let ToggleDoor decide for
-- those, and honour the check on ordinary doors.
local function doorOpenable(o, chr)
    if not instanceof(o, "IsoDoor") then return true end
    return o:couldBeOpen(chr)
end

-- A companion of the player may work the player's base doors; other people's
-- doors are left alone.
local function isBaseDoer(chr)
    local R = LOS.Records
    local rec = R and R.get and R.get(LOS.idOf(chr) or -1)
    return rec ~= nil and (rec.role == "companion" or rec.faction == "player")
end

-- PATCH: a walker whose current square is blocked (a door square, a bed, a
-- pushed-about square) fails every path request instantly until the shipped
-- failed() finally steps it off.  Do that first, then path again.
local function stepOffBlocked(self)
    local chr = self.character
    local sq = chr:getCurrentSquare()
    if not sq or sq:isFree(false) or chr:isOnBed() or chr:getVehicle() then return false end
    local cell = getCell()
    for _, d in ipairs(STEP_OFF) do
        local n = cell:getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
        -- PATCH: isFree(false) accepts chairs, beds and counters; use the same
        -- standable test as the rest of the patch so it never steps from one
        -- piece of furniture onto another.
        if n and LOS.canStandSquare(n) then
            chr:setX(n:getX() + 0.5)
            chr:setY(n:getY() + 0.5)
            chr:setLastX(n:getX() + 0.5)
            chr:setLastY(n:getY() + 0.5)
            LOS.log("WALK %s stood where nobody can stand (%d,%d); stepped off onto %d,%d", tostring(self.tag),
                sq:getX(), sq:getY(), n:getX(), n:getY())
            return true
        end
    end
    return false
end

-- PATCH: a closed door within a few tiles, roughly toward where it is going
-- and inside the player's base.  Base doors are relocked behind companions by
-- the shipped code, so the next trip across a multi-building base cannot find
-- a path at all: the walker only unlocked doors it was already standing next
-- to.  Open (and, when locked, temporarily unlock) the one in the way.
local function openBaseDoorToward(self, sq, gx, gy)
    local chr = self.character
    local St = LOS.Storage
    if not (St and St.inBase and isBaseDoer(chr)) then return false end
    local dx, dy = gx - (sq:getX() + 0.5), gy - (sq:getY() + 0.5)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then return false end
    dx, dy = dx / len, dy / len
    local cell, best, bestD = getCell(), nil, nil
    for oy = -DOOR_REACH, DOOR_REACH do
        for ox = -DOOR_REACH, DOOR_REACH do
            local d2 = ox * ox + oy * oy
            if d2 > 0 and d2 <= DOOR_REACH * DOOR_REACH then
                local x, y = sq:getX() + ox, sq:getY() + oy
                if (ox * dx + oy * dy) / math.sqrt(d2) > 0.35 and St.inBase(x, y) then
                    local other = cell:getGridSquare(x, y, sq:getZ())
                    if other then
                        local objs = other:getObjects()
                        for i = 0, objs:size() - 1 do
                            local o = objs:get(i)
                            if isDoorObject(o) and o:getSquare() == other and not o:IsOpen()
                                    and not o:isBarricaded() then
                                local locked = o:isLocked() or o:isLockedByKey()
                                if locked or doorOpenable(o, chr) then
                                    if not bestD or d2 < bestD then best, bestD = o, d2 end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not best then return false end
    local locked = best:isLocked() or best:isLockedByKey()
    if locked then
        -- the shipped update() relocks a door recorded this way once the
        -- character is away from it again
        if not self.relock then
            self.relock = { door = best, keyed = best:isLockedByKey(), latched = best:isLocked() }
        end
        best:setLockedByKey(false)
        best:setIsLocked(false)
    end
    best:ToggleDoor(chr)
    if best:IsOpen() then
        self.step, self.shrinks = nil, 0
        self:pathNow()
        LOS.log("WALK %s opened the %s base door at %d,%d", tostring(self.tag), locked and "locked" or "closed",
            best:getSquare():getX(), best:getSquare():getY())
        return true
    end
    return false
end

local function openDoorBeside(self)
    local chr = self and self.character
    local sq = chr and chr:getCurrentSquare()
    if not sq or chr:getVehicle() then return false end
    if stepOffBlocked(self) then
        self.step, self.shrinks = nil, 0
        self:pathNow()
        return true
    end
    if (self.requests or 0) >= DOOR_MAX_REQUESTS then return false end
    local now = getTimestampMs()
    if self.losDoorAt and now - self.losDoorAt < DOOR_AGAIN_MS then return false end
    local gx, gy = self:goal()
    local hereD = gx and IsoUtils.DistanceTo(sq:getX() + 0.5, sq:getY() + 0.5, gx, gy) or nil
    local cell = getCell()
    for _, d in ipairs(DOOR_SIDES) do
        local other = cell:getGridSquare(sq:getX() + d[1], sq:getY() + d[2], sq:getZ())
        local door = other and sq:getDoorTo(other)
        -- only a door that actually takes it nearer where it is going
        local helps = not hereD or IsoUtils.DistanceTo(other:getX() + 0.5, other:getY() + 0.5, gx, gy) < hereD - 0.4
        if helps and door and isDoorObject(door) and not door:IsOpen() and not door:isBarricaded()
                and not door:isLocked() and not door:isLockedByKey() and doorOpenable(door, chr) then
            self.losDoorAt = now
            door:ToggleDoor(chr)
            if door:IsOpen() then
                self.step, self.shrinks = nil, 0
                self:pathNow()
                LOS.log("WALK %s opened the closed door at %d,%d", tostring(self.tag), other:getX(), other:getY())
                return true
            end
        end
    end
    if gx and openBaseDoorToward(self, sq, gx, gy) then return true end
    return false
end

local function patchedGoRound(self)
    if upstreamGoRound and upstreamGoRound(self) then return true end
    return openDoorBeside(self)
end

-- The shipped update() calls climbOver() after a quick path failure (a door
-- one or two squares away fails in well under a second), so ordinary doors
-- have to be handled here as well as in goRound().
local function patchedClimbOver(self, now)
    if upstreamClimbOver and upstreamClimbOver(self, now) then return true end
    return openDoorBeside(self)
end

local upstreamOrderStep, upstreamOrderGive, upstreamOnWalkFailed

local function onWalkFailedWrapper(npc, tag, now, gx, gy, gz, remembered)
    if upstreamOnWalkFailed then upstreamOnWalkFailed(npc, tag, now, gx, gy, gz, remembered) end
    waitWhereItStands(npc, tag, gx, gy)
end

local function patchedOrderStep(id, npc, br, rec, role, cur, now, ctx, player)
    fixOrderHold(rec, br, npc)
    return upstreamOrderStep(id, npc, br, rec, role, cur, now, ctx, player)
end

local function patchedOrderGive(id, kind, backBy)
    local r = upstreamOrderGive(id, kind, backBy)
    local br = LOS.Brain and LOS.Brain.state and LOS.Brain.state[id]
    local npc = LOS.Bodies and LOS.Bodies.byId and LOS.Bodies.byId[id]
    fixOrderHold(LOS.Records and LOS.Records.get(id), br, npc, true)
    return r
end

local function cleanWrapper(id, npc, br, rec, role, cur, now, ctx)
    return patchedCleanStep(id, npc, br, rec, role, cur, now, ctx)
end

local function bedStepWrapper(id, npc, br, now, cur)
    return patchedBedStep(id, npc, br, now, cur)
end

local function bedStartWrapper(id, npc, br, now)
    return patchedBedStart(id, npc, br, now)
end

local function leisureStepWrapper(id, npc, br, rec, cur, now, ctx, player)
    return patchedLeisureStep(id, npc, br, rec, cur, now, ctx, player)
end

local function giveBreakWrapper(id, now)
    return patchedGiveBreak(id, now)
end

local function barricadeWrapper(id, npc, br, rec, role, cur, now, ctx)
    return patchedBarricadeStep(id, npc, br, rec, role, cur, now, ctx)
end

local function salvageFindWrapper(npc, b)
    return patchedSalvageFind(npc, b)
end

local function standingWrapper(npc, csq)
    return patchedStandingSquare(npc, csq)
end

local function placeForWrapper(typeKey, x, y, item)
    return patchedPlaceFor(typeKey, x, y, item)
end

local function typeOfWrapper(item)
    return patchedTypeOf(item)
end

local function goRoundWrapper(self)
    return patchedGoRound(self)
end

local function climbOverWrapper(self, now)
    return patchedClimbOver(self, now)
end

---------------------------------------------------------------------------
-- Install / re-install (mod load order safety)
---------------------------------------------------------------------------
local haulWrapper = nil
local saidBaseChores = false

local function install()
    local Sk, S = LOS.Stock, LOS.Scavenge
    if not (Sk and S) then return end

    boostSleep()

    if Sk.homeContainers ~= patchedHomeContainers then
        Sk.homeContainers = patchedHomeContainers
    end

    if LOS.walkableSquare ~= patchedWalkableSquare then
        LOS.walkableSquare = patchedWalkableSquare
    end

    if S.standingSquare and S.standingSquare ~= standingWrapper then
        if not upstreamStandingSquare then upstreamStandingSquare = S.standingSquare end
        S.standingSquare = standingWrapper
    end

    local St = LOS.Storage
    if St and St.placeFor and St.placeFor ~= placeForWrapper then
        if not upstreamPlaceFor then upstreamPlaceFor = St.placeFor end
        St.placeFor = placeForWrapper
    end
    if St and St.typeOf and St.typeOf ~= typeOfWrapper then
        if not upstreamTypeOf then upstreamTypeOf = St.typeOf end
        St.typeOf = typeOfWrapper
    end

    if S.haulKind ~= haulWrapper then
        local original = S.haulKind
        haulWrapper = function(item)
            local kind = original(item)
            if kind then return kind end
            if isUnopenedFood(item) then return "food" end
            return nil
        end
        S.haulKind = haulWrapper
    end

    local C = LOS.Corpses
    if C and C.spot and C.spot ~= patchedCorpseSpot then
        if not upstreamCorpseSpot then upstreamCorpseSpot = C.spot end
        C.spot = patchedCorpseSpot
    end

    local Cl = LOS.Clean
    if Cl and Cl.step and Cl.step ~= cleanWrapper then
        if not upstreamCleanStep then upstreamCleanStep = Cl.step end
        Cl.step = cleanWrapper
    end

    local Bc = LOS.Barricade
    if Bc and Bc.step and Bc.step ~= barricadeWrapper then
        if not upstreamBarricadeStep then upstreamBarricadeStep = Bc.step end
        Bc.step = barricadeWrapper
    end

    local Sv = LOS.Salvage
    if Sv and Sv.find and Sv.find ~= salvageFindWrapper then
        if not upstreamSalvageFind then upstreamSalvageFind = Sv.find end
        Sv.find = salvageFindWrapper
    end

    local Bd = LOS.Beds
    if Bd and Bd.step and Bd.step ~= bedStepWrapper then
        if not upstreamBedStep then upstreamBedStep = Bd.step end
        Bd.step = bedStepWrapper
    end
    if Bd and Bd.start and Bd.start ~= bedStartWrapper then
        if not upstreamBedStart then upstreamBedStart = Bd.start end
        Bd.start = bedStartWrapper
    end

    local Le = LOS.Leisure
    if Le and Le.step and Le.step ~= leisureStepWrapper then
        if not upstreamLeisureStep then upstreamLeisureStep = Le.step end
        Le.step = leisureStepWrapper
    end
    if Le and Le.giveBreak and Le.giveBreak ~= giveBreakWrapper then
        if not upstreamGiveBreak then upstreamGiveBreak = Le.giveBreak end
        Le.giveBreak = giveBreakWrapper
    end

    local Walk = LOSWalkTo
    if Walk and Walk.goRound and Walk.goRound ~= goRoundWrapper then
        if not upstreamGoRound then upstreamGoRound = Walk.goRound end
        Walk.goRound = goRoundWrapper
    end
    if Walk and Walk.climbOver and Walk.climbOver ~= climbOverWrapper then
        if not upstreamClimbOver then upstreamClimbOver = Walk.climbOver end
        Walk.climbOver = climbOverWrapper
    end

    local Ord = LOS.Orders
    if Ord and Ord.step and Ord.step ~= patchedOrderStep then
        if not upstreamOrderStep then upstreamOrderStep = Ord.step end
        Ord.step = patchedOrderStep
    end
    if Ord and Ord.give and Ord.give ~= patchedOrderGive then
        if not upstreamOrderGive then upstreamOrderGive = Ord.give end
        Ord.give = patchedOrderGive
    end

    if LOS.onWalkFailed and LOS.onWalkFailed ~= onWalkFailedWrapper then
        if not upstreamOnWalkFailed then upstreamOnWalkFailed = LOS.onWalkFailed end
        LOS.onWalkFailed = onWalkFailedWrapper
    end

    if not saidBaseChores then
        saidBaseChores = true
        LOS.log("PATCH base chores loaded: body spots, cleaning sources and gear, boarding materials from any marked box and sides, salvage range, stand squares, storage marks and sorting, base doors, tool storage, personal-item keeping, over-weight unloading, hold squares, broken glass, window sides, couch beds and bed sides, breaks that become sleep, wait spots it cannot reach")
    end
end

install()
Events.OnGameBoot.Add(install)
Events.OnGameStart.Add(install)

LOS.log("PATCH living storage/scavenging fixes loaded")
