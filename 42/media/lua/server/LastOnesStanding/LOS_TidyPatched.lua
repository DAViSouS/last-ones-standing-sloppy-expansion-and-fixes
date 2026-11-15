

















































require "LastOnesStanding/LOS_Core"
require "LastOnesStanding/LOS_Storage"
require "LastOnesStanding/LOS_Scavenge"
require "LastOnesStanding/LOS_Loot"
require "LastOnesStanding/LOS_WoodActions"
require "TimedActions/ISPickupBrokenGlass"
require "TimedActions/ISRemoveBrokenGlass"

-- A Last Ones Standing update disables the whole patch until it is rebased.
local Guard = LastOnesStandingSloppyPatch
if not (Guard and Guard.active()) then return end

local LOS = LastOnesStanding
local Td = {}
LOS.Tidy = Td

local SCAN_MS = 20000
local IDLE_MS = 90000
local CLAIM_MS = 120000

local REPEAT_MS, REPEAT_MOST, REPEAT_LEAVE_MS = 3000, 4, 600000
-- PATCH: 1.25 let a companion load itself to 125% of its maximum weight and
-- then sit there ("it can carry no more") because walking failed.  Never pick
-- up more than it can actually carry.
local HAUL_FREE = 1.0
local TOO_HEAVY = 8
local LEAVE_HOURS = 0.5
local FULL_MS = 600000
local FLOORS = { -1, 0, 1, 2 }
local HOME_FLOORS = { 0, 1, 2, 3 }
local HOME_TRIPS = 12
-- PATCH: walkTo() reports "here" once the character is within ARRIVE (1.6) of
-- the stand square, but LOSLoot/LOSPickUp refuse to start beyond 2.0/1.8 of
-- the object itself.  A stand on the far corner can therefore queue an action
-- that the game throws away every tick: the 6,000-line "goes to take out"
-- loop in the logs.  Check the real reach, walk one square closer, and give up
-- on a job that keeps being remade without ever starting.
local REACH_OBJECT = 1.9
local REACH_FLOOR = 1.7
local STUCK_REPEAT = 4
local STUCK_WINDOW_MS = 30000
local STUCK_COOLDOWN_MS = 600000
local SIDES4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local NOT_TIDIED = { ["Base.Log"] = true, ["Base.LongStick"] = true, ["Base.Sapling"] = true }
local NEVER_EMPTIED = { stove = true, microwave = true, barbecue = true, fireplace = true, woodstove = true,
                        campfire = true, clothingdryer = true, clothingwasher = true, composter = true, bin = true,
                        toaster = true, coffeemaker = true }
local COLD = { fridge = true, freezer = true }
local FOOD = { dryfood = true, freshfood = true, usefirst = true }

-- PATCH: broken glass is an IsoBrokenGlass object on the floor, not an
-- inventory item, so the normal floor tidy scan never saw it.  Sweep the base
-- for it when there is nothing else to tidy and use the game's pickup action.
-- UNTESTED: not confirmed working in game yet.
local GLASS_SCAN_MS = 30000
local GLASS_CLAIM_MS = 120000
local GLASS_SKIP_MS = 600000
local glassAt, glassList = 0, nil
local glassClaims = {}

local function standable(sq)
    if LOS.canStandSquare then return LOS.canStandSquare(sq) end
    return sq ~= nil and sq:isFree(false)
end

local KITCHEN = { "kitchen", "pantry", "dining" }
local ROOMS = {
    dryfood = KITCHEN, freshfood = KITCHEN, usefirst = KITCHEN, water = KITCHEN, cooking = KITCHEN,
    medical = { "bathroom", "medical" },
    guns = { "bedroom", "closet", "office" }, ammo = { "bedroom", "closet", "office" }, melee = { "bedroom", "closet", "hall" },
    clothing = { "bedroom", "closet" }, personal = { "bedroom" }, books = { "bedroom", "living", "office", "library" },
    radios = { "living", "office", "garage" },
    tools = { "garage", "shed", "storage", "closet" }, materials = { "garage", "shed", "storage" },
    carparts = { "garage", "shed" }, farming = { "garage", "shed", "storage" }, outdoors = { "garage", "shed", "storage", "closet" },
    explosives = { "garage", "shed", "storage" }, household = { "kitchen", "living", "storage", "hall" },
}

local FLOOR_ONLY = { household = true }

local PREFER = { clothing = { wardrobe = true, dresser = true }, medical = { medicine = true },
                 tools = { toolcabinet = true, metal_shelves = true, garage_storage = true } }

local scans = {}
local claims = {}
local fullUntil = {}
-- PATCH: source/destination pairs that were attempted too often without the
-- game accepting the action; they are left alone for a while.
local tidyStuck = {}

local function faction() return LOS.Orders and LOS.Orders.playerFaction() or nil end

local function keyOfSquare(sq) return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() end







local ON_FURNITURE = 0.05
if ISDropWorldItemAction then
    local placeComplete = ISDropWorldItemAction.complete
    function ISDropWorldItemAction:complete()
        local r = placeComplete(self)
        if self.character == getSpecificPlayer(0) and self.item and self.sq then
            self.item:getModData().LOS_Placed = keyOfSquare(self.sq)
        end
        return r
    end
end


local function markOf(obj)
    return LOS.Storage.markOf(obj, 0)
end

local function holdsKind(mark, kind)
    if not (mark and mark.types and kind) then return false end
    if mark.types[kind] then return true end

    local parent = LOS.Storage.PARENT[kind]
    if parent and mark.types[parent] and not LOS.Storage.markedFor(kind) then return true end
    return FOOD[kind] == true and (mark.types.dryfood or mark.types.freshfood or mark.types.usefirst) == true
end

local function usable(c, now)
    return not (fullUntil[c] and now < fullUntil[c])
end

-- PATCH: containers were chosen by their label only, never by whether they
-- had room, so a full box kept attracting tidy jobs that then gave up.
local function hasRoomFor(c, it, used)
    if not (c and it) then return false end
    local w = it:getUnequippedWeight()
    return c:getCapacity() - c:getContentsWeight() - (used or 0) + 0.001 >= w
end


local function takesAnything(mark)
    if not mark then return true end
    if not mark.types then return true end
    if mark.types.anything then return true end
    for _ in pairs(mark.types) do return false end
    return true
end

-- PATCH: "Anything" is a fallback, not a first choice.  Rank the containers
-- a kind may go in: 1 = marked for that exact kind, 2 = a parent/food mark,
-- 3 = an Anything box.  Only boxes with real room are considered, so a full
-- building-materials crate no longer wins over an Anything shelf and then
-- causes the load to be taken out and put back again forever.
local function destRank(mark, kind)
    local t = mark and mark.types
    if not (t and kind) then return nil end
    if t[kind] then return 1 end
    if FOOD[kind] and (t.dryfood or t.freshfood or t.usefirst) then return 2 end
    local parent = LOS.Storage.PARENT[kind]
    if parent and t[parent] then return 2 end
    if t.anything then return 3 end
    return nil
end

local function hasSpecificMark(mark)
    if not (mark and mark.types) then return false end
    for k in pairs(mark.types) do
        if k ~= "anything" then return true end
    end
    return false
end

local function roomIs(room, parts)
    for _, part in ipairs(parts) do
        if string.find(room, part, 1, true) then return true end
    end
    return false
end





local function tidyPlaceAllowed(o, c, sq)
    if not (o and c and sq) then return false end
    local t = c:getType()
    if NEVER_EMPTIED[t] or t == "dumpster" or t == "trashcan" or t == "garbagecan" then return false end
    return LOS.Storage.inBase(sq:getX(), sq:getY())
end

local function basePlaceFor(place, kind, item, x, y)
    local St = LOS.Storage
    if not kind then return nil end
    local now = getTimestampMs()
    local best, bestRank, bestD = nil, nil, nil
    for _, mark in pairs(St.marks()) do
        if type(mark) == "table" and mark.x and not mark.private and mark.types and St.inBase(mark.x, mark.y) then
            local rank = destRank(mark, kind)
            if rank then
                local o, c, sq = St.boxOfMark(mark)
                if tidyPlaceAllowed(o, c, sq) and usable(c, now) and hasRoomFor(c, item) then
                    local d = (mark.x - x) * (mark.x - x) + (mark.y - y) * (mark.y - y)
                    if not bestRank or rank < bestRank or (rank == bestRank and d < bestD) then
                        best, bestRank, bestD = { o, c, sq }, rank, d
                    end
                end
            end
        end
    end
    -- Perishable food may still prefer a powered fridge when no marked box
    -- for it is free.
    if not best and St.perishable(kind) then
        local o, c, sq, what = St.placeFor(kind, x, y, item)
        if what == "cold" and tidyPlaceAllowed(o, c, sq) and usable(c, now) and hasRoomFor(c, item) then
            return o, c, sq, true, 1
        end
    end
    -- A storage the player designated explicitly may be used even if they did
    -- not put a label on it.  A merely unmarked cupboard may not.
    if not best then
        local main = St.get()
        local o, c, sq = St.target()
        local mark = o and St.markOf(o, (main and main.index) or 0)
        if o and c and not mark and St.isStorage(o) and tidyPlaceAllowed(o, c, sq)
                and usable(c, now) and hasRoomFor(c, item) then
            return o, c, sq, false, 3
        end
    end
    if not best then return nil end
    -- Fourth value stays the "specific" boolean used by the callers; fifth is
    -- the rank (1/2 specific, 3 Anything fallback).
    return best[1], best[2], best[3], bestRank <= 2, bestRank
end

local function basePlace()
    local b = LOS.Storage.base()
    if not b then return nil end
    return { key = "base", parts = b.parts, floors = FLOORS, placeFor = basePlaceFor }
end





local function roomFor(c, item)
    return item == nil or c:getContentsWeight() + item:getUnequippedWeight() <= c:getCapacity()
end
local function homePlaceFor(place, kind, item, x, y)
    if not kind then return nil end
    local now = getTimestampMs()
    if LOS.Storage.perishable(kind) then
        local e = LOS.Storage.nearestCold(place.cold, x, y, LOS.Storage.coldFirst(item))
        if e and usable(e.c, now) and roomFor(e.c, item) then return e.obj, e.c, e.sq, true end
    end
    local rooms = ROOMS[kind]
    if not rooms then return nil end
    local prefer = PREFER[kind]
    local best, bestRank, bestD = nil, nil, nil
    for _, e in ipairs(place.list) do
        if not e.cold and roomIs(e.room, rooms) and usable(e.c, now) and roomFor(e.c, item) then
            local rank = (prefer and prefer[e.c:getType()]) and 1 or 2
            local d = (e.x - x) * (e.x - x) + (e.y - y) * (e.y - y)
            if not bestRank or rank < bestRank or (rank == bestRank and d < bestD) then best, bestRank, bestD = e, rank, d end
        end
    end
    if not best then return nil end
    return best.obj, best.c, best.sq, true
end





local function homeRight(place, kind, e, item, x, y)
    if not kind or FLOOR_ONLY[kind] then return true end
    if item and not homePlaceFor(place, kind, item, x or e.x, y or e.y) then return true end
    if LOS.Storage.perishable(kind) and place.anyCold then return e.cold end
    local rooms = ROOMS[kind]
    if not rooms or not place.hasRoom[kind] then return true end
    return roomIs(e.room, rooms) and not e.cold
end


local homes = {}
local function homePlace(owner, key)
    local now = getTimestampMs()
    local memo = homes[key]
    if memo and now < memo.at and memo.place.owner == owner then return memo.place end
    local list0 = LOS.Stock.homeContainers(owner, key)
    if not list0 then return nil end
    local sq0 = getCell():getGridSquare(owner.home.x, owner.home.y, owner.home.z or 0)
    local b = sq0 and sq0:getBuilding()
    local def = b and b:getDef()
    if not def then return nil end
    local list, cold, hasRoom, anyCold = {}, {}, {}, false
    for _, e in ipairs(list0) do
        local obj = e.c:getParent()
        local sq = obj and obj:getSquare()
        if sq and not NEVER_EMPTIED[e.c:getType()] then
            local ent = { c = e.c, room = e.room, obj = obj, sq = sq, x = sq:getX(), y = sq:getY(), cold = COLD[e.c:getType()] == true }
            list[#list + 1] = ent
            if ent.cold then
                cold[#cold + 1] = ent
                if ent.c:isPowered() then anyCold = true end
            else
                for kind, rooms in pairs(ROOMS) do
                    if roomIs(ent.room, rooms) then hasRoom[kind] = true end
                end
            end
        end
    end
    local place = { key = key, owner = owner, building = b,
             parts = { { x1 = def:getX(), y1 = def:getY(), x2 = def:getX() + def:getW() - 1, y2 = def:getY() + def:getH() - 1 } },
             floors = HOME_FLOORS, placeFor = homePlaceFor, list = list, cold = cold, anyCold = anyCold, hasRoom = hasRoom }
    homes[key] = { place = place, at = now + SCAN_MS }
    return place
end





local function lookOver(now, place)
    local memo = scans[place.key]
    if memo and now < memo.at then return memo.list end
    local St, cell = LOS.Storage, getCell()
    local out = {}
    local homeless = {}
    local age = getGameTime():getWorldAgeHours()

    for _, z in ipairs(place.floors) do
        for _, p in ipairs(place.parts) do
            for y = p.y1, p.y2 do
                for x = p.x1, p.x2 do
                    local sq = cell:getGridSquare(x, y, z)
                    local wos = sq and (not place.building or sq:getBuilding() == place.building) and sq:getWorldObjects()
                    for i = 0, (wos and wos:size() or 0) - 1 do
                        local wo = wos:get(i)
                        local it = wo:getItem()
                        local md = it and it:getModData()
                        if it and not wo:isExtendedPlacement() and not NOT_TIDIED[it:getFullType()] and not md.LOS_WallSite
                                and md.LOS_Placed ~= keyOfSquare(sq) and wo:getOffZ() <= ON_FURNITURE
                                and not (md.LOS_TidyLeft and age < md.LOS_TidyLeft)
                                and it:getUnequippedWeight() <= TOO_HEAVY then
                            local kind = St.typeOf(it)
                            local dobj, dc, dsq = place.placeFor(place, kind, it, x, y)
                            local e = { key = "floor:" .. keyOfSquare(sq) .. ":" .. i, kind = "floor", sq = sq, wo = wo,
                                        items = { it } }
                            if dobj and usable(dc, now) and hasRoomFor(dc, it) then
                                e.dest = { obj = dobj, c = dc, sq = dsq }
                                table.insert(out, e)
                            elseif kind and place.list then
                                -- Only a group's own house may use its spare
                                -- containers.  An unmarked container in the
                                -- player's base is a source to empty, not a home.
                                table.insert(homeless, e)
                            end
                        end
                    end
                end
            end
        end
    end

    local sources = {}
    if place.list then

        for _, e in ipairs(place.list) do
            table.insert(sources, { obj = e.obj, c = e.c, sq = e.sq, entry = e, house = true, cold = e.cold })
        end
    else

        local sobj, sc, ssq = St.target()
        if sobj then table.insert(sources, { obj = sobj, c = sc, sq = ssq, mark = markOf(sobj), main = true }) end
        for _, mark in pairs(St.marks()) do
            if type(mark) == "table" and mark.x and not mark.private and mark.types and St.inBase(mark.x, mark.y) then
                local o, c, sq = St.boxOfMark(mark)
                if c and c ~= sc then table.insert(sources, { obj = o, c = c, sq = sq, mark = mark }) end
            end
        end

        local seenC = {}
        for _, src in ipairs(sources) do seenC[src.c] = true end
        for _, z in ipairs(FLOORS) do
            for _, p in ipairs(place.parts) do
                for y = p.y1, p.y2 do
                    for x = p.x1, p.x2 do
                        local sq = cell:getGridSquare(x, y, z)
                        local objs = sq and sq:getObjects()
                        for i = 0, (objs and objs:size() or 0) - 1 do
                            local o = objs:get(i)
                            for ci = 0, o:getContainerCount() - 1 do
                                local c = o:getContainerByIndex(ci)
                                if c and not seenC[c] and not NEVER_EMPTIED[c:getType()] and St.markOf(o, ci) == nil then
                                    seenC[c] = true
                                    table.insert(sources, { obj = o, c = c, sq = sq, mark = nil, house = true,
                                                            cold = COLD[c:getType()] == true })
                                end
                            end
                        end
                    end
                end
            end
        end
    end






    local spares = {}
    if place.list then
        -- A group's own house may spill into its other cupboards.  The player's
        -- base may not: its unmarked containers are meant to be emptied.
        for _, src in ipairs(sources) do
            if src.house and not src.cold then table.insert(spares, src) end
        end
    end
    if not place.list then





        local cars = LOS.vehicles and LOS.vehicles()
        for vi = 0, (cars and cars:size() or 0) - 1 do
            local v = cars:get(vi)
            if v and not v:getDriver() and math.abs(v:getCurrentSpeedKmHour()) < 1 and St.inBase(v:getX(), v:getY()) then
                for pi = 0, v:getPartCount() - 1 do
                    local part = v:getPartByIndex(pi)
                    local c = part and part:getItemContainer()
                    local pid = part and tostring(part:getId()) or ""
                    if c and not c:isEmpty() and (string.find(pid, "TruckBed", 1, true) or string.find(pid, "TrailerTrunk", 1, true)) then
                        local at = part:getArea() and v:getAreaCenter(part:getArea())
                        local asq = at and cell:getGridSquare(math.floor(at:getX()), math.floor(at:getY()), math.floor(v:getZ()))
                        local door = v:getPartById("TrunkDoor") or v:getPartById("DoorRear") or v:getPartById("TrunkDoorOpened")
                        if door and not (door:getInventoryItem() and door:getDoor()) then door = nil end
                        if asq and asq:isFree(false) and not (door and door:getDoor():isLocked()) then
                            table.insert(sources, { obj = v, c = c, sq = asq, trunk = true, door = door })
                        end
                    end
                end
            end
        end
    end
    local function spareFor(it, fromSq, notC)
        local best, bestD = nil, nil
        local w = it:getUnequippedWeight()
        for _, sp in ipairs(spares) do
            if sp.c ~= notC and usable(sp.c, now) and sp.c:getContentsWeight() + w <= sp.c:getCapacity() then
                local d = IsoUtils.DistanceToSquared(fromSq:getX(), fromSq:getY(), sp.sq:getX(), sp.sq:getY())
                    + (sp.sq:getZ() ~= fromSq:getZ() and 400 or 0)
                if not bestD or d < bestD then best, bestD = sp, d end
            end
        end
        return best
    end
    for _, e in ipairs(homeless) do
        local sp = spareFor(e.items[1], e.sq, nil)
        if sp then
            e.dest = { obj = sp.obj, c = sp.c, sq = sp.sq }
            table.insert(out, e)
        end
    end
    for _, src in ipairs(sources) do
        local byDest = {}
        local items = src.c:getItems()
        local isAnything = false
        if not src.entry and not src.trunk then
            if src.mark == nil then
                -- The designated main storage is the fallback place even when
                -- it has no label; an ordinary unmarked box is not.
                isAnything = src.main == true
            else
                isAnything = takesAnything(src.mark) and not hasSpecificMark(src.mark)
            end
        end
        local unmarked = not src.entry and not src.trunk and src.mark == nil and not src.main
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local kind = St.typeOf(it)
            local dobj, dc, dsq, specific, rank
            local move = false

            if src.entry then
                move = kind ~= nil and not homeRight(place, kind, src.entry, it, src.entry.x, src.entry.y)
            elseif src.trunk then
                move = true
            else
                local right = holdsKind(src.mark, kind)

                if right and St.perishable(kind) and not src.cold and not (src.mark and src.mark.types and src.mark.types[kind]) then
                    local _, _, _, what = St.placeFor(kind, src.sq:getX(), src.sq:getY(), it)
                    if what == "cold" then right = false end
                end

                if unmarked then
                    -- PATCH: containers with no mark at all in the base are
                    -- emptied and their contents resorted.
                    move = true
                elseif isAnything then
                    -- PATCH: Anything is only a fallback.  Leave its contents
                    -- alone unless a container marked for their kind has room;
                    -- moving Anything -> Anything caused an endless take-out /
                    -- put-back loop with planks.  Food stays in a cold box.
                    if src.cold and St.perishable(kind) then
                        move = false
                    else
                        dobj, dc, dsq, specific, rank = place.placeFor(place, kind or "misc", it,
                            src.sq:getX(), src.sq:getY())
                        move = rank ~= nil and rank <= 2 and dc ~= src.c
                    end
                else
                    -- A container marked for other kinds: take out what does
                    -- not belong, including things with no useful kind.
                    move = (kind == nil) or not right
                end
            end

            if move and not NOT_TIDIED[it:getFullType()] and not (src.cold and instanceof(it, "Food")) then
                if not dobj then
                    local destKind = kind
                    if not destKind and not src.entry then destKind = "misc" end
                    dobj, dc, dsq, specific, rank = place.placeFor(place, destKind, it,
                        src.sq:getX(), src.sq:getY())
                end

                -- A group's own house may use spare cupboards; the player's
                -- base may not use unmarked containers as destinations.
                if not (dobj and dc ~= src.c) and place.list and src.house then
                    local sp = spareFor(it, src.sq, src.c)
                    if sp then dobj, dc, dsq = sp.obj, sp.c, sp.sq end
                end
                if dobj and dc ~= src.c and usable(dc, now) then
                    local e = byDest[dc]
                    local used = e and e.used or 0
                    -- PATCH: don't queue more than the destination can take.
                    if hasRoomFor(dc, it, used) then
                        if not e then
                            e = { key = "cont:" .. keyOfSquare(src.sq) .. ">" .. keyOfSquare(dsq), kind = "container", sq = src.sq,
                                  obj = src.obj, c = src.c, items = {}, used = 0, dest = { obj = dobj, c = dc, sq = dsq },
                                  trunk = src.trunk, door = src.door }
                            byDest[dc] = e
                            table.insert(out, e)
                        end
                        table.insert(e.items, it)
                        e.used = used + it:getUnequippedWeight()
                    end
                end
            end
        end
    end
    scans[place.key] = { list = out, at = now + SCAN_MS, seen = now }
    return out
end



function Td.left(key)
    local memo = scans[key]
    if not memo or getTimestampMs() - memo.seen > 120000 then return nil end
    return #memo.list
end


local function carriedTidy(npc)
    local out = {}
    -- PATCH: broken glass is rubbish.  Sweep any leftover pieces out of the
    -- inventory here so they can never end up dropped on the floor or filed
    -- away in a cupboard.
    local inv0 = npc:getInventory()
    local items0 = inv0:getItems()
    for i = items0:size() - 1, 0, -1 do
        local it = items0:get(i)
        if string.find(it:getFullType(), "BrokenGlass", 1, true) then inv0:DoRemoveItem(it) end
    end
    -- PATCH: a companion that looted a heavy load (planks, bleach, tins) and
    -- was then given chores had no way to put that load down: only things it
    -- picked up for tidying were ever considered.  It stayed at 20+ of 12
    -- weight, so tidy could never pick anything up and chores stalled with
    -- "it can carry no more".  When it is over its maximum, include the loot
    -- it is carrying too, so tidy can store it (or set it down if no marked
    -- place has room).  Equipped items stay in hand.
    local over = npc:getInventoryWeight() > npc:getMaxWeight() * 0.90
    local held, off = npc:getPrimaryHandItem(), npc:getSecondaryHandItem()
    -- Never put away clothes the companion is wearing.
    local worn = {}
    local wc = npc:getWornItems()
    for i = 0, (wc and wc:size() or 0) - 1 do
        local wi = wc:get(i)
        local w = wi and (wi.getItem and wi:getItem() or wi)
        if w then worn[w] = true end
    end
    local St = LOS.Storage
    -- Kinds safe to shed when over the weight limit.  Weapons, guns and ammo
    -- are deliberately left alone: an over-encumbered companion must not
    -- store its only weapon.  Bags stay too; the things inside them are walked.
    local SAFE_STORE = { household = true, materials = true, cooking = true, books = true, clothing = true,
                         medical = true, dryfood = true, freshfood = true,
                         usefirst = true, water = true, farming = true, outdoors = true, carparts = true,
                         reloading = true }
    local function walk(container, depth)
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local md = it:getModData()
            local kind = St and St.typeOf and St.typeOf(it)
            -- PATCH: tools (hammers, saws, screwdrivers) were never put away:
            -- they were only un-equipped into the inventory, so the player had
            -- to keep taking them back.  Store them even from the hand: a
            -- hammer kept in hand after boarding was why no later board job
            -- could find one in the base.
            local tool = kind == "tools" and it ~= off
            -- PATCH: over the weight limit, shed ordinary carried things too,
            -- not only loot marked LOS_Haul.  Starting kits (canned food, for
            -- one) have no such mark, so a companion could stay over 100% of
            -- its carry weight forever and hardly move.
            local shed = over and kind and SAFE_STORE[kind] and not worn[it]
                and not instanceof(it, "InventoryContainer")
            if md.LOS_Tidy or md.LOS_Haul or tool or (shed and it ~= held and it ~= off) then
                table.insert(out, it)
            end
            if depth < 3 and instanceof(it, "InventoryContainer") then
                walk(it:getItemContainer(), depth + 1)
            end
        end
    end
    walk(npc:getInventory(), 0)
    return out
end

local function idle(id, br, now, why)
    br.tidyIdleUntil = now + IDLE_MS
    if why and br.tidyWhy ~= why then
        br.tidyWhy = why
        LOS.log("TIDY npc=%d waits: %s", id, why)
    end
    return false
end

local function claimFree(key, id, now)
    local c = claims[key]
    return not c or c.id == id or now >= c.untilMs or not LOS.Bodies.byId[c.id]
end


-- PATCH: only bulky, easily replaced things may be set on the floor.  A radio,
-- a tool, a weapon or someone's personal things must never be dropped just to
-- make room; the companion keeps them until there is a proper place.
local DROP_KINDS = { household = true, materials = true, cooking = true, books = true, clothing = true,
                     medical = true, dryfood = true, freshfood = true, usefirst = true, water = true,
                     farming = true, outdoors = true, carparts = true, reloading = true, toys = true,
                     pets = true, animalparts = true }
local function mayLeave(it)
    local kind = LOS.Storage.typeOf(it)
    return kind ~= nil and DROP_KINDS[kind] == true
end

-- Broken glass swept up by a companion should not end up back on the floor if
-- every cupboard is full; it is rubbish, so it is thrown away instead.
local function isGlassJunk(it)
    local ft = it:getFullType()
    return string.find(ft, "BrokenGlass", 1, true) ~= nil or string.find(ft, "GlassShard", 1, true) ~= nil
end

local function leaveHere(id, npc, items, br)
    local sq = npc:getCurrentSquare()
    if not sq then return end
    local age = getGameTime():getWorldAgeHours()
    local left, kept, swept = 0, 0, 0
    for _, it in ipairs(items) do
        if isGlassJunk(it) then
            local from = it:getContainer()
            if from then
                from:DoRemoveItem(it)
                ISTransferAction:removeItemOnCharacter(npc, it)
                it:getModData().LOS_Tidy = nil
                swept = swept + 1
            end
        elseif mayLeave(it) then
            local from = it:getContainer()
            if from then
                from:DoRemoveItem(it)
                ISTransferAction:removeItemOnCharacter(npc, it)
                it:getModData().LOS_Tidy = nil
                -- Short enough that the next time there is room tidy can pick
                -- it up again, but long enough not to pick it up and drop it
                -- straight back down in a loop.
                it:getModData().LOS_TidyLeft = age + LEAVE_HOURS
                sq:AddWorldInventoryItem(it, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0.0)
                left = left + 1
            end
        else
            kept = kept + 1
        end
    end
    if swept > 0 then
        LOS.log("TIDY npc=%d: threw away %d piece(s) of broken glass", id, swept)
    end
    if left > 0 then
        LOS.log("TIDY npc=%d: no room anywhere for %d thing(s); left on the floor at %d,%d for %d minutes", id, left,
            sq:getX(), sq:getY(), math.floor(LEAVE_HOURS * 60 + 0.5))
    end
    if kept > 0 then
        if not br or br.tidyKeepSaid ~= kept then
            if br then br.tidyKeepSaid = kept end
            LOS.log("TIDY npc=%d: keeps %d personal or essential thing(s) it could not store", id, kept)
        end
    end
    if br and kept > 0 then br.tidyIdleUntil = getTimestampMs() + IDLE_MS end
end



local TIDY_FULL = 12
function Td.need(now)
    local place = basePlace()
    if not place then return 0, 0 end
    local n = #lookOver(now, place)
    return math.min(1, n / TIDY_FULL), n
end

-- PATCH: the real distance to the thing the action works on (the game's own
-- LOSLoot/LOSPickUp checks), not just the distance to the stand square.
local function nearObject(npc, obj, reach)
    local sq = obj and obj:getSquare()
    if not sq then return false end
    return IsoUtils.DistanceTo(npc:getX(), npc:getY(), sq:getX() + 0.5, sq:getY() + 0.5) <= (reach or REACH_OBJECT)
end


-- PATCH: the nearest square beside the object where the character can stand.
local function closerStand(npc, obj)
    local csq = obj and obj:getSquare()
    if not csq then return nil end
    if standable(csq) then return csq end
    local cell, best, bestD = getCell(), nil, nil
    for _, d in ipairs(SIDES4) do
        local sq = cell:getGridSquare(csq:getX() + d[1], csq:getY() + d[2], csq:getZ())
        if sq and standable(sq) and not csq:isWallTo(sq) then
            local dd = IsoUtils.DistanceToSquared(npc:getX(), npc:getY(), sq:getX() + 0.5, sq:getY() + 0.5)
            if not bestD or dd < bestD then best, bestD = sq, dd end
        end
    end
    return best
end


-- PATCH: if walkTo() said "here" but the action cannot reach its object, take
-- one step to the square beside it.  Only once per job; the watchdog below
-- catches it if even that does not work.
local function stepCloser(npc, ctx, job, now)
    local obj = job.object or job.worldItem
    if not obj then return false end
    local reach = job.kind == "pickup" and REACH_FLOOR or REACH_OBJECT
    if nearObject(npc, obj, reach) then return false end
    if job.closerTried then return false end
    job.closerTried = true
    local closer = closerStand(npc, obj)
    if closer and closer ~= npc:getCurrentSquare() then
        job.stand, job.at = closer, now
        ctx.orderMove(npc, closer, false, "tidy")
        return true
    end
    return false
end


local function sameObjectKey(o)
    local sq = o and o:getSquare()
    if not sq then return tostring(o) end
    return string.format("%s@%d,%d,%d", tostring(o:getType()), sq:getX(), sq:getY(), sq:getZ())
end


local function jobKeyOf(place, job)
    local what = job.kind == "put" and sameObjectKey(job.object)
        or tostring(job.task or sameObjectKey(job.object))
    return tostring(place and place.key or "?") .. "|" .. tostring(job.kind) .. "|" .. what
end


local function stuckFree(key, now)
    local untilMs = tidyStuck[key]
    if untilMs and now < untilMs then return false end
    if untilMs then tidyStuck[key] = nil end
    return true
end


-- PATCH: count how often the same job is made without ever reaching the queue.
-- Four attempts in half a minute means the game is refusing it: blacklist the
-- pair for ten minutes so chores can fall through to the next kind of work.
local function rememberJob(id, npc, br, place, job, now)
    local key = jobKeyOf(place, job)
    local watch = br.tidyWatch
    if watch and watch.key == key and now - watch.at < STUCK_WINDOW_MS then
        watch.n, watch.at = watch.n + 1, now
    else
        watch = { key = key, n = 1, at = now }
        br.tidyWatch = watch
    end
    if watch.n < STUCK_REPEAT then return false end

    br.tidyWatch, br.tidyJob = nil, nil
    br.tidyTook, br.tidyPut, br.tidyStockKey = nil, nil, nil
    br.tidyDests = {}
    if job.task then tidyStuck[job.task] = now + STUCK_COOLDOWN_MS end
    if job.container and job.kind == "put" then fullUntil[job.container] = now + STUCK_COOLDOWN_MS end
    if scans[place.key] then scans[place.key].at = 0 end
    LOS.log("TIDY npc=%d tried the same %s job %d times and the game would not start it; leaving %s alone for %d minutes",
        id, tostring(job.kind), watch.n, job.kind == "put" and "that place" or "that container", STUCK_COOLDOWN_MS / 60000)
    return true
end


-- PATCH: broken glass is a world object (IsoBrokenGlass), not an inventory
-- item, so lookOver() cannot see it.  The game's pickup action,
-- ISPickupBrokenGlass, turns it into Base.BrokenGlass in the inventory; mark
-- that for the normal tidy put-away on the next tick.  A smashed window that
-- still holds its shards is cleared with ISRemoveBrokenGlass instead.
-- UNTESTED: not confirmed working in game yet.
local GLASS_MARGIN = 4
local function glassInBase()
    local now = getTimestampMs()
    if glassList and now < glassAt then return glassList end
    glassAt = now + GLASS_SCAN_MS
    local out = {}
    local b = LOS.Storage.base()
    if not b then glassList = out return out end
    local cell, seen = getCell(), {}
    for _, z in ipairs({ -1, 0, 1, 2 }) do
        for _, p in ipairs(b.parts or {}) do
            -- A little margin catches shards that fell just outside the marked
            -- base line when a window was smashed.
            for y = p.y1 - GLASS_MARGIN, p.y2 + GLASS_MARGIN do
                for x = p.x1 - GLASS_MARGIN, p.x2 + GLASS_MARGIN do
                    local at = x .. "," .. y .. "," .. z
                    if not seen[at] then
                        seen[at] = true
                        local sq = cell:getGridSquare(x, y, z)
                        local objs = sq and sq:getObjects()
                        for i = 0, (objs and objs:size() or 0) - 1 do
                            local o = objs:get(i)
                            if o then
                                if instanceof(o, "IsoBrokenGlass") then
                                    out[#out + 1] = { glass = o, sq = sq, key = "floor:" .. at .. ":" .. i }
                                elseif instanceof(o, "IsoWindow") and o:isSmashed() and not o:isGlassRemoved() then
                                    out[#out + 1] = { window = o, sq = sq, key = "window:" .. at .. ":" .. i }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if #out > 0 then LOS.log("TIDY found %d broken-glass job(s) in and around the base", #out) end
    glassList = out
    return out
end

local function glassClaimFree(g, id, now)
    local c = glassClaims[g.key]
    return not c or c.id == id or now >= c.untilMs or not LOS.Bodies.byId[c.id]
end

local function runGlassJob(id, npc, br, role, now, ctx, job)
    local what = job.window and "the broken glass in the window" or "the broken glass"
    local r = LOS.Objectives.walkTo(npc, br, role, now, ctx, job, "glass", "to " .. what)
    if r == "busy" then return true end
    br.glassJob = nil
    if r == "failed" then
        glassClaims[job.key] = { id = id, untilMs = now + GLASS_SKIP_MS }
        return false
    end
    if not job.sq then return false end
    if job.window then
        if not (job.window:getSquare() and job.window:isSmashed() and not job.window:isGlassRemoved()) then return false end
        local a = ISRemoveBrokenGlass:new(npc, job.window)
        a.tag = "glass"
        ISTimedActionQueue.add(a)
        glassClaims[job.key] = { id = id, untilMs = now + GLASS_CLAIM_MS }
        ctx.setState(br, role, now, "tidy", "(clearing broken glass from a window)")
        LOS.log("TIDY npc=%d clears the broken glass from the window at %d,%d", id, job.sq:getX(), job.sq:getY())
        return true
    end
    if not job.glass:getSquare() then return false end
    local a = ISPickupBrokenGlass:new(npc, job.glass)
    a.tag = "glass"
    ISTimedActionQueue.add(a)
    br.glassPicked = true
    glassClaims[job.key] = { id = id, untilMs = now + GLASS_CLAIM_MS }
    ctx.setState(br, role, now, "tidy", "(picking up broken glass)")
    LOS.log("TIDY npc=%d picks up the broken glass at %d,%d", id, job.sq:getX(), job.sq:getY())
    return true
end

local function glassPickedUp(id, npc, br, cur)
    if not br.glassPicked then return false end
    local items = npc:getInventory():getItems()
    local n = 0
    -- Broken glass is rubbish, not stock.  Sweep it up and throw it away
    -- instead of leaving it in the inventory for tidy to drop on the floor
    -- again when every cupboard is full.
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        local ft = it:getFullType()
        if string.find(ft, "BrokenGlass", 1, true) then
            local from = it:getContainer()
            if from then from:DoRemoveItem(it) else npc:getInventory():DoRemoveItem(it) end
            n = n + 1
        end
    end
    if n > 0 then
        br.glassPicked = nil
        LOS.log("TIDY npc=%d swept up and threw away %d piece(s) of broken glass", id, n)
        return true
    end
    -- The pickup action may still be running; wait for it to finish instead of
    -- dropping the flag on the very next tick.
    if not (cur and cur.Type == "ISPickupBrokenGlass") then
        br.glassPicked = nil
    end
    return false
end





local PACK_MS = 60000
function Td.emptyPack(id, npc, br, role, cur, now, ctx)
    if cur and (cur.Type == "LOSLoot" or cur.tag == "store") then return true end
    if cur then return false end
    if br.storeJob then return LOS.Objectives.storeStep(id, npc, br, role, now, ctx) end
    if now < (br.packAt or 0) then return false end
    if not (LOS.Trade and LOS.Trade.kept and LOS.Storage and LOS.Storage.get() and LOS.Objectives.startStore) then return false end

    if LOS.Scavenge.haulWeight(npc) > 0 and now >= (br.storeRetryAt or 0) then
        if LOS.Objectives.startStore(id, npc, br, role, now, ctx, "emptying its pack") then
            return LOS.Objectives.storeStep(id, npc, br, role, now, ctx)
        end
        br.packAt = now + PACK_MS
        return false
    end
    br.packAt = now + PACK_MS
    local kept = LOS.Trade.kept(npc)
    local n, w = 0, 0
    local opener, knife = false, false
    local function walk(container, depth)
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local md = it:getModData()

            local firstOpener = it:hasTag(ItemTag.CAN_OPENER) and not opener
            local firstKnife = it:hasTag(ItemTag.SHARP_KNIFE) and not knife
            if instanceof(it, "InventoryContainer") then
                if depth < 2 then walk(it:getItemContainer(), depth + 1) end




            elseif not (kept[it] or instanceof(it, "Radio") or instanceof(it, "Key") or md.LOS_Tidy or npc:isEquipped(it)
                    or md.LOS_Given or md.LOS_WarmOff or md.LOS_Warm or instanceof(it, "Food") or it:isCanBandage()
                    or (it:getFluidContainer() and not it:getFluidContainer():isEmpty())
                    or (it:hasTag(ItemTag.CAN_OPENER) and not opener) or (it:hasTag(ItemTag.SHARP_KNIFE) and not knife)) then
                if not md.LOS_Haul then
                    md.LOS_Haul = true
                    n = n + 1
                    w = w + it:getUnequippedWeight()
                end
            end
            if firstOpener then opener = true end
            if firstKnife then knife = true end
        end
    end
    walk(npc:getInventory(), 0)
    if n > 0 then LOS.log("TIDY npc=%d empties its pack: %d thing(s), %.1f weight, that aren't its kit go to the storage", id, n, w) end
    if LOS.Scavenge.haulWeight(npc) <= 0 then return false end
    if LOS.Objectives.startStore(id, npc, br, role, now, ctx, "emptying its pack") then
        return LOS.Objectives.storeStep(id, npc, br, role, now, ctx)
    end
    return false
end

local function glassStart(id, npc, br, role, now, ctx)
    if now < (br.glassSearchAt or 0) then return false end
    br.glassSearchAt = now + 5000
    local best, bestD = nil, nil
    for _, g in ipairs(glassInBase()) do
        local here = (g.glass and g.glass:getSquare()) or (g.window and g.window:getSquare())
        if here and glassClaimFree(g, id, now) then
            local d = IsoUtils.DistanceToSquared(npc:getX(), npc:getY(), g.sq:getX() + 0.5, g.sq:getY() + 0.5)
            if not bestD or d < bestD then best, bestD = g, d end
        end
    end
    if not best then return false end
    local stand = LOS.Scavenge.standingSquare(npc, best.sq)
    if not stand then
        glassClaims[best.key] = { id = id, untilMs = now + GLASS_SKIP_MS }
        return false
    end
    local job = { glass = best.glass, window = best.window, sq = best.sq, key = best.key, stand = stand, at = now, tries = 0 }
    br.glassJob = job
    glassClaims[best.key] = { id = id, untilMs = now + GLASS_CLAIM_MS }
    if best.window then
        LOS.log("TIDY npc=%d goes to clear the broken glass from the window at %d,%d", id, best.sq:getX(), best.sq:getY())
    else
        LOS.log("TIDY npc=%d goes to pick up the broken glass at %d,%d", id, best.sq:getX(), best.sq:getY())
    end
    return runGlassJob(id, npc, br, role, now, ctx, job)
end


function Td.step(id, npc, br, rec, role, cur, now, ctx, place)
    -- Broken glass work is ours, so handle it before the ordinary cur guard.
    -- It is only done for the player's base, never for a group's own house.
    if not (place and place.owner) then
        glassPickedUp(id, npc, br, cur)
        if br.glassJob then
            local aiming = cur and (cur.Type == "LOSWalkTo" and cur.tag == "glass")
            local using = cur and (cur.Type == "ISPickupBrokenGlass" or cur.Type == "ISRemoveBrokenGlass")
            if using then
                return true
            elseif cur and not aiming then
                -- something else is running; leave the glass job for later
            else
                local g = br.glassJob.glass or br.glassJob.window
                if g and g:getSquare() and runGlassJob(id, npc, br, role, now, ctx, br.glassJob) then
                    return true
                end
                br.glassJob = nil
            end
        end
    end
    if cur and (cur.tag == "tidy" or cur == br.tidyAction) then return true end
    if cur then return false end
    br.tidyAction = nil
    place = place or basePlace()
    if not place then return idle(id, br, now, "there is no base") end


    local function unmark(c, stockKey)
        local items = c:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local md = it:getModData()
            if stockKey and md.LOS_Tidy then
                local kind = LOS.Stock.kindOf(it)
                if kind then LOS.Stock.mark(it, kind, stockKey) end
            end
            md.LOS_Tidy = nil
        end
    end
    br.tidyDests = br.tidyDests or {}


    local function destOf(it)
        local m = br.tidyDests[it]
        if m and m.obj:getSquare() and usable(m.c, now) and hasRoomFor(m.c, it) then return m.obj, m.c, m.sq end
        return place.placeFor(place, LOS.Storage.typeOf(it), it, npc:getX(), npc:getY())
    end
    if br.tidyPut then
        local put = br.tidyPut
        br.tidyPut = nil
        unmark(put, br.tidyStockKey)
        br.tidyStockKey = nil
        local left = 0
        for _, it in ipairs(carriedTidy(npc)) do
            local _, dc = destOf(it)
            if dc == put then left = left + 1 end
        end
        if left > 0 then
            fullUntil[put] = now + FULL_MS
            LOS.log("TIDY npc=%d: the place it was putting things in is full; %d thing(s) left on it", id, left)
        end
    end

    if br.tidyTook then
        unmark(br.tidyTook)
        br.tidyTook = nil
    end

    if not br.tidyJob and #carriedTidy(npc) == 0 then br.tidyDests = {} end
    local here = place.owner and "the house" or "the base"
    local job = br.tidyJob
    if not job then
        if now < (br.tidyIdleUntil or 0) then return false end
        local carrying = carriedTidy(npc)
        if #carrying > 0 then





            local dobj, dc, dsq = destOf(carrying[1])
            -- destOf already prefers a container marked for the kind and only
            -- falls back to an Anything box with room.  There is nothing better
            -- to try here; leaveHere() will keep anything personal or essential.
            if not dobj then
                leaveHere(id, npc, carrying, br)
                return false
            end
            local stand = LOS.Scavenge.standingSquare(npc, dsq)
            if not stand then




                fullUntil[dc] = now + FULL_MS
                LOS.log("TIDY npc=%d can't reach the %s at %d,%d: passed over for now, its things go elsewhere", id,
                    tostring(dc:getType()), dsq:getX(), dsq:getY())
                return false
            end
            job = { kind = "put", object = dobj, container = dc, stand = stand }
        else



            local max = npc:getMaxWeight()
            local w = npc:getInventoryWeight()
            local best, bestD, heavy = nil, nil, 0
            for _, t in ipairs(lookOver(now, place)) do
                if claimFree(t.key, id, now) and stuckFree(t.key, now) then
                    local fits = false
                    for _, it in ipairs(t.items) do
                        if w + it:getUnequippedWeight() < max * HAUL_FREE then
                            fits = true
                            break
                        end
                    end
                    if fits then
                        local d = IsoUtils.DistanceToSquared(npc:getX(), npc:getY(), t.sq:getX() + 0.5, t.sq:getY() + 0.5)
                        if not bestD or d < bestD then best, bestD = t, d end
                    else
                        heavy = heavy + 1
                    end
                end
            end
            if not best then
                if heavy > 0 then
                    return idle(id, br, now, string.format("it can carry no more (%d place(s) left with only things too heavy for what it has on it)", heavy))
                end
                if not place.owner and glassStart(id, npc, br, role, now, ctx) then return true end
                return idle(id, br, now, here .. " is tidy")
            end
            claims[best.key] = { id = id, untilMs = now + CLAIM_MS }

            local picks = {}
            for _, it in ipairs(best.items) do
                local iw = it:getUnequippedWeight()
                if w + iw < max * HAUL_FREE then
                    table.insert(picks, it)
                    w = w + iw
                end
            end
            if #picks == 0 then return idle(id, br, now, "it can carry no more") end
            local stand
            if best.kind == "floor" and standable(best.sq) then
                stand = best.sq
            else
                stand = LOS.Scavenge.standingSquare(npc, best.sq)
            end
            if not stand then
                claims[best.key] = { id = id, untilMs = now + CLAIM_MS * 5 }
                return false
            end
            for _, it in ipairs(picks) do br.tidyDests[it] = best.dest end




            local wos = {}
            if best.kind == "floor" then
                wos[1] = best.wo
                for _, t in ipairs(lookOver(now, place)) do
                    if t ~= best and t.kind == "floor" and t.sq:getZ() == stand:getZ() and claimFree(t.key, id, now)
                            and stuckFree(t.key, now)
                            and IsoUtils.DistanceTo(t.sq:getX() + 0.5, t.sq:getY() + 0.5, stand:getX() + 0.5, stand:getY() + 0.5) <= 1.4 then
                        local it = t.items[1]
                        local iw = it:getUnequippedWeight()
                        if w + iw < max * HAUL_FREE then
                            table.insert(picks, it)
                            table.insert(wos, t.wo)
                            br.tidyDests[it] = t.dest
                            claims[t.key] = { id = id, untilMs = now + CLAIM_MS }
                            w = w + iw
                        end
                    end
                end
            end
            job = { kind = best.kind == "floor" and "pickup" or "take", object = best.obj, container = best.c,
                    worldItem = best.wo, worldItems = wos, picks = picks, stand = stand, task = best.key,
                    into = tostring(best.dest.c:getType()), door = best.door, trunk = best.trunk }
            if place.owner then br.tidyTrips = (br.tidyTrips or 0) + 1 end
        end
        job.at, job.tries = now, 0
        -- PATCH: a job remade over and over without ever starting is refused by
        -- the game; stop remaking it and let the next kind of work have a turn.
        if rememberJob(id, npc, br, place, job, now) then return false end
        local rp = br.tidyRepeat
        if rp and rp.task == job.task and job.task ~= nil and now - rp.at < REPEAT_MS then
            rp.n, rp.at = rp.n + 1, now
            if rp.n >= REPEAT_MOST then
                claims[job.task] = { id = -1, untilMs = now + REPEAT_LEAVE_MS }
                br.tidyRepeat = nil
                LOS.log("TIDY npc=%d planned the same %s at %s %d times with nothing done: that one is left for %d minutes (%s, %d thing(s), standing at %d,%d,%d)",
                    id, job.kind, tostring(job.task), REPEAT_MOST, math.floor(REPEAT_LEAVE_MS / 60000), tostring(job.into), #(job.picks or {}),
                    job.stand and job.stand:getX() or 0, job.stand and job.stand:getY() or 0, job.stand and job.stand:getZ() or 0)
                return false
            end
        else
            br.tidyRepeat = { task = job.task, n = 1, at = now }
        end
        br.tidyJob, br.tidyWhy = job, nil
        LOS.log("TIDY npc=%d%s %s", id, place.owner and (" (its group's house " .. tostring(place.key) .. ")") or "",
            job.kind == "put" and string.format("puts away what it carries (into the %s)", tostring(job.container:getType()))
            or string.format("goes to %s %d thing(s), for the %s%s", job.kind == "pickup" and "pick up" or "take out", #job.picks,
                job.into, job.trunk and " (out of a car's trunk)" or ""))
    end

    local r = LOS.Objectives.walkTo(npc, br, role, now, ctx, job, "tidy", job.kind == "put" and "to put things away" or "to the mess")
    if r == "busy" then return true end
    br.tidyJob = nil
    if r == "failed" then
        if job.task then claims[job.task] = { id = id, untilMs = now + CLAIM_MS * 5 } end




        if job.kind == "put" and job.container then
            fullUntil[job.container] = now + FULL_MS
            LOS.log("TIDY npc=%d couldn't get to where things go (the %s at %d,%d): passed over for now, its things go elsewhere", id,
                tostring(job.container:getType()), job.object and job.object:getX() or 0, job.object and job.object:getY() or 0)
        else
            LOS.log("TIDY npc=%d couldn't get to the mess", id)
        end
        return false
    end
    if scans[place.key] then scans[place.key].at = 0 end
    if job.kind == "put" then

        local items, used = {}, 0
        for _, it in ipairs(carriedTidy(npc)) do
            local _, dc = destOf(it)
            -- PATCH: only hand over what the destination can hold.
            if dc == job.container and hasRoomFor(job.container, it, used) then
                table.insert(items, it)
                used = used + it:getUnequippedWeight()
            end
        end
        if #items == 0 then
            fullUntil[job.container] = now + FULL_MS
            br.tidyWatch = nil
            if scans[place.key] then scans[place.key].at = 0 end
            LOS.log("TIDY npc=%d: the %s has no room left; looking for another place", id,
                tostring(job.container:getType()))
            return false
        end
        -- PATCH: make sure the action can really reach the container.
        if stepCloser(npc, ctx, job, now) then return true end
        -- PATCH: a refused queue is retried every tick; count those too.
        if rememberJob(id, npc, br, place, job, now) then return false end

        br.tidyPut = job.container
        br.tidyStockKey = place.owner and place.key or nil
        ctx.setState(br, role, now, "tidy", string.format("(putting %d thing(s) away)", #items))
        br.tidyAction = LOSLoot:new(npc, job.object, job.container, items, { store = true })
        br.tidyAction.tag = "tidy"
        ISTimedActionQueue.add(br.tidyAction)
        br.tidyWatch = nil
        return true
    elseif job.kind == "pickup" then
        -- PATCH: LOSPickUp only works within 1.8 of the thing on the floor.
        if stepCloser(npc, ctx, job, now) then return true end
        if rememberJob(id, npc, br, place, job, now) then return false end
        local n = 0
        for i, wo in ipairs(job.worldItems or { job.worldItem }) do
            if wo:getSquare() then
                job.picks[i]:getModData().LOS_Tidy = true
                local a = LOSPickUp:new(npc, wo, false)
                a.tag = "tidy"
                ISTimedActionQueue.add(a)
                br.tidyAction = a
                n = n + 1
            end
        end
        if n == 0 then
            br.tidyWatch = nil
            if scans[place.key] then scans[place.key].at = 0 end
            return false
        end
        ctx.setState(br, role, now, "tidy", string.format("(picking %d thing(s) up off the floor)", n))
        br.tidyWatch = nil
        return true
    end
    local still = {}
    for _, it in ipairs(job.picks) do
        if job.container:contains(it) then
            it:getModData().LOS_Tidy = true
            table.insert(still, it)
        end
    end
    if #still == 0 then
        -- PATCH: the scan was stale; look again rather than remake the same job.
        br.tidyWatch = nil
        if scans[place.key] then scans[place.key].at = 0 end
        return false
    end
    -- PATCH: do not queue a take the game will refuse for distance.
    if stepCloser(npc, ctx, job, now) then return true end
    if rememberJob(id, npc, br, place, job, now) then return false end
    ctx.setState(br, role, now, "tidy", string.format("(taking %d thing(s) out to put them where they go)", #still))
    br.tidyTook = job.container

    if job.trunk and job.door and job.door:getDoor() and not job.door:getDoor():isOpen() and ISOpenVehicleDoor then
        local open = ISOpenVehicleDoor:new(npc, job.object, job.door)
        open.tag = "tidy"
        ISTimedActionQueue.add(open)
    end
    br.tidyAction = LOSLoot:new(npc, job.object, job.container, still)
    br.tidyAction.tag = "tidy"

    if job.trunk then br.tidyAction.atSquare = job.stand end
    ISTimedActionQueue.add(br.tidyAction)
    br.tidyWatch = nil
    return true
end



function Td.homeStep(id, npc, br, rec, role, cur, now, ctx, owner, key)
    if cur and (cur.tag == "tidy" or cur == br.tidyAction) then return true end
    local day = math.floor(getGameTime():getWorldAgeHours() / 24)
    if br.tidyDay ~= day then br.tidyDay, br.tidyTrips = day, 0 end
    local busy = br.tidyJob or br.tidyPut or br.tidyTook or #carriedTidy(npc) > 0
    if not busy and ((br.tidyTrips or 0) >= HOME_TRIPS or now < (br.tidyIdleUntil or 0)) then return false end
    local place = homePlace(owner, key)
    if not place then return false end
    return Td.step(id, npc, br, rec, role, cur, now, ctx, place)
end

LOS.log("PATCH tidy capacity/destination fixes loaded: specific-mark-first sorting, Anything fallback, unmarked base containers emptied, personal items kept, broken glass and windows")

return Td
