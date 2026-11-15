































require "LastOnesStanding/LOS_Core"
require "LastOnesStanding/LOS_Records"
require "LastOnesStanding/LOS_Stock"
require "LastOnesStanding/LOS_Scavenge"
require "LastOnesStanding/LOS_Needs"
require "LastOnesStanding/LOS_Loot"
require "LastOnesStanding/LOS_Barricade"

-- A Last Ones Standing update disables the whole patch until it is rebased.
local Guard = LastOnesStandingSloppyPatch
if not (Guard and Guard.active()) then return end

local LOS = LastOnesStanding
local Lv = {}
LOS.Living = Lv

local HOME_NEAR = 30
local HAUL_SHARE = 0.6
local HAUL_HOLD_MS = 240000
local TAKE_HOURS = 3
local LACK_MIN = 0.05
local RETRY_MS = 60000
local WANTS_MS = 30000

local TRIP_FROM, TRIP_UNTIL = 7, 12
Lv.HAUL_SHARE = HAUL_SHARE

local function hours() return getGameTime():getWorldAgeHours() end



local wantsOf = {}




function Lv.haulFor(rec)
    local owner, key, isFaction = LOS.Stock.ownerOf(rec)
    if not owner then return nil end
    local now = getTimestampMs()
    local memo = wantsOf[key]
    if memo and now - memo.at < WANTS_MS then return memo.haul end
    local lack = LOS.Stock.lackOf(owner, isFaction)
    local weight = LOS.Stock.WEIGHT or {}
    local wants, prio = {}, {}
    for kind, l in pairs(lack) do
        if l >= LACK_MIN or kind == "food" then
            wants[kind] = true
            prio[kind] = 1 - l * (weight[kind] or 0.5)
        end
    end
    local haul = {
        ownKey = key,
        wants = wants,
        kind = function(it)
            local k = LOS.Stock.kindOf(it)
            return (k and wants[k]) and k or nil
        end,
        want = function(k) return prio[k] end,
    }
    wantsOf[key] = { at = now, haul = haul }
    return haul
end



local function containerSpot(npc, c)
    local obj = c and c:getParent()
    local sq = obj and obj:getSquare()
    if not sq then return nil end
    local stand = LOS.Scavenge.standingSquare(npc, sq)
    if not stand then return nil end
    return obj, stand
end



-- PATCH: the original only accepted items stamped LOS_StockOf == key, so a
-- group could starve in a house full of player-dropped or pre-existing food.
-- The shipped code now accepts ordinary food, so keep that, but never take
-- things out of a container the player marked private, and let ordinary water
-- (not only the group's own stamped bottles) be fetched too.
local function isPrivateContainer(c)
    local St = LOS.Storage
    if not (St and St.markOf) then return false end
    local obj = c:getParent()
    if not obj then return false end
    for i = 0, obj:getContainerCount() - 1 do
        if obj:getContainerByIndex(i) == c then
            local mark = St.markOf(obj, i)
            return mark ~= nil and mark.private == true
        end
    end
    return false
end


local function findStore(list, key, what, npc)
    local on = what == "food" and npc and LOS.Needs.allOn(npc) or nil
    local best, bestC, bestDays = nil, nil, nil
    for _, e in ipairs(list) do
        if not isPrivateContainer(e.c) then
            local items = e.c:getItems()
            for i = 0, items:size() - 1 do
                local it = items:get(i)
                local md = it:hasModData() and it:getModData() or nil
                local theirs = md ~= nil and md.LOS_StockOf == key and md.LOS_Stock == what


                local houses = not (md and md.LOS_StockOf)
                if theirs or houses then
                    if what == "food" then
                        if instanceof(it, "Food") and LOS.Needs.isMeal(it, on or {}) then
                            local days = LOS.Needs.daysLeft(it)
                            if not bestDays or days < bestDays then best, bestC, bestDays = it, e.c, days end
                        end
                    elseif not LOS.Needs.waterProblem(it) then
                        return e.c, it
                    end
                end
            end
        end
    end
    if best then return bestC, best end
    return nil
end




-- PATCH: hasRoomFor() only sees what is already inside a container, not the
-- items we are planning to put there.  Track the weight reserved for each
-- container so a batch cannot be over-assigned and then fail at arrival.
local function addIfFits(npc, c, it, by, used)
    local w = it:getUnequippedWeight()
    local free = c:getCapacity() - c:getContentsWeight()
    if free - (used[c] or 0) + 0.001 >= w and c:hasRoomFor(npc, it) then
        by[c] = by[c] or {}
        table.insert(by[c], it)
        used[c] = (used[c] or 0) + w
        return true
    end
    return false
end


local function putAway(npc, list, items)
    local by, kinds, used = {}, {}, {}
    for _, it in ipairs(items) do
        local kind = (it:hasModData() and it:getModData().LOS_Stock) or LOS.Stock.kindOf(it)
        kinds[it] = kind
        local placed = false
        for _, c in ipairs(LOS.Stock.coldIn(list, it)) do
            if addIfFits(npc, c, it, by, used) then
                placed = true
                break
            end
        end
        if not placed then
            for _, c in ipairs(LOS.Stock.keptIn(list, kind or "")) do
                if addIfFits(npc, c, it, by, used) then break end
            end
        end
    end
    local best, bestN = nil, 0
    for c, its in pairs(by) do
        if #its > bestN then best, bestN = c, #its end
    end
    return best, best and by[best] or nil, kinds
end

local function counts(items, kinds)
    local n, parts = {}, {}
    for _, it in ipairs(items) do
        local k = kinds[it] or "other"
        n[k] = (n[k] or 0) + 1
    end
    for k, c in pairs(n) do parts[#parts + 1] = string.format("%s %d", k, c) end
    table.sort(parts)
    return table.concat(parts, ", ")
end



local function nameOf(owner)
    local name = owner and LOS.Standing and LOS.Standing.nameOf(owner)
    return name and tostring(name) or tostring(owner and owner.id)
end


local function arrive(id, npc, br, role, now, ctx, job, key, owner)
    if not job.object:getSquare() then return false end
    if job.kind == "eat" then
        if not job.container:contains(job.item) then return false end
        LOS.Stock.mark(job.item, nil)
        br.livingTookAt = hours()
        ctx.setState(br, role, now, "living", string.format("(taking %s from the house)", tostring(job.item:getType())))
        ISTimedActionQueue.add(LOSLoot:new(npc, job.object, job.container, { job.item }))
        LOS.log("LIVING npc=%d (%s) takes %s from its group's house (%s)", id, nameOf(owner), tostring(job.item:getType()),
            job.what == "food" and "hungry" or "thirsty")
        return true
    end

    local items = {}
    for _, it in ipairs(job.items) do
        if npc:getInventory():containsRecursive(it) and job.container:hasRoomFor(npc, it) then
            items[#items + 1] = it
            if job.kinds[it] then LOS.Stock.mark(it, job.kinds[it], key) end
        end
    end
    if #items == 0 then return false end
    ctx.setState(br, role, now, "living", string.format("(putting %d things away in the house)", #items))
    ISTimedActionQueue.add(LOSLoot:new(npc, job.object, job.container, items, { store = true }))
    LOS.log("LIVING npc=%d (%s) puts away in its group's house, %s at %d,%d: %s", id, nameOf(owner),
        tostring(job.container:getType()), job.stand:getX(), job.stand:getY(), counts(items, job.kinds))
    return true
end


function Lv.step(id, npc, br, rec, role, cur, now, ctx)
    local obj = rec.objective
    if not obj or obj.kind ~= "scavenge" then
        br.living = nil
        return false
    end
    if cur then return cur.tag == "living" end
    local owner, key = LOS.Stock.ownerOf(rec)
    if not owner then
        br.living = nil
        return false
    end
    local home = owner.home
    if IsoUtils.DistanceTo(npc:getX(), npc:getY(), home.x + 0.5, home.y + 0.5) > HOME_NEAR then
        br.living = nil
        return false
    end

    local job = br.living
    if job then
        local r = LOS.Objectives.walkTo(npc, br, role, now, ctx, job, "living", job.what == "away" and "home with finds"
            or "to the house for " .. job.what)
        if r == "busy" then return true end
        br.living = nil
        if r == "failed" then
            LOS.log("LIVING npc=%d couldn't get to its group's house (%s)", id, job.what)
            br.livingRetry = now + RETRY_MS
            return false
        end
        return arrive(id, npc, br, role, now, ctx, job, key, owner)
    end
    if now < (br.livingRetry or 0) then return false end
    if not (LOS.Brain and LOS.Brain.calm and LOS.Brain.calm(br, now)) then return false end


    local what = nil
    if LOS.Needs.isThirsty(npc) and not LOS.Needs.carries(npc, "water") then what = "water"
    elseif LOS.Needs.isHungry(npc) and not LOS.Needs.carries(npc, "food") then what = "food" end
    if what and hours() - (br.livingTookAt or -1000) >= TAKE_HOURS then
        local list = LOS.Stock.homeContainers(owner, key)
        local c, item = nil, nil
        if list then c, item = findStore(list, key, what, npc) end
        if c then
            local object, stand = containerSpot(npc, c)
            if object then
                br.living = { kind = "eat", what = what, object = object, container = c, item = item, stand = stand,
                              at = now, tries = 0 }
                return Lv.step(id, npc, br, rec, role, cur, now, ctx)
            end
        end
    end


    local items = LOS.Scavenge.haulItems(npc)
    if #items == 0 then
        br.haulSince = nil

        if LOS.Barricade.homeStep(id, npc, br, rec, role, cur, now, ctx, owner, key) then return true end


        return LOS.Tidy.homeStep(id, npc, br, rec, role, cur, now, ctx, owner, key)
    end
    br.haulSince = br.haulSince or now
    if LOS.Scavenge.haulWeight(npc) < LOS.Scavenge.haulLoad(npc) * HAUL_SHARE and now - br.haulSince < HAUL_HOLD_MS then
        return false
    end
    if br.lootJob then return false end
    local list = LOS.Stock.homeContainers(owner, key)
    if not list or #list == 0 then return false end
    local c, batch, kinds = putAway(npc, list, items)
    if not c then
        if not br.livingFullSaid then
            br.livingFullSaid = true
            LOS.log("LIVING npc=%d (%s): no room in the house for what it carries (%d things)", id, nameOf(owner), #items)
        end
        br.livingRetry = now + RETRY_MS
        return false
    end
    local object, stand = containerSpot(npc, c)
    if not object then
        br.livingRetry = now + RETRY_MS
        return false
    end
    br.living = { kind = "store", what = "away", object = object, container = c, items = batch, kinds = kinds,
                  stand = stand, at = now, tries = 0 }
    return Lv.step(id, npc, br, rec, role, cur, now, ctx)
end



local lastHour = nil



local PARTY_MOST = 3



function Lv.update(now)
    local h = math.floor(hours())
    if h == lastHour then return end
    lastHour = h
    local hour = getGameTime():getHour()
    if hour < TRIP_FROM or hour > TRIP_UNTIL then return end
    local today = math.floor(hours() / 24)
    local by = {}
    for id, npc in pairs(LOS.Bodies.byId) do
        local rec = LOS.Records.get(id)
        if rec and not npc:isDead() then
            local owner, key, isFaction = LOS.Stock.ownerOf(rec)
            if owner and owner.stock then
                local g = by[key]
                if not g then
                    g = { owner = owner, isFaction = isFaction, free = {} }
                    by[key] = g
                end
                if rec.objective and rec.objective.kind == "scavenge" then g.free[#g.free + 1] = rec end
            end
        end
    end
    for key, g in pairs(by) do
        local owner, s = g.owner, g.owner.stock
        if owner.fleshDay ~= today then
            owner.fleshDay = today
            local n = LOS.Stock.headcount(owner, g.isFaction)
            local settled = g.isFaction and owner.settle ~= nil
            local lacks = LOS.Stock.lacks(s, n, settled)
            local hungry = LOS.Stock.hungry(s, n, settled)
            local trips = LOS.Stock.trips(lacks, #g.free, hungry, function() return ZombRandFloat(0, 1) end)

            if LOS.Ways then trips = math.max(0, math.min(#g.free, trips + LOS.Ways.extraTrips(owner, hungry))) end
            LOS.log("LIVING %s decides its day in the flesh: lacks %s most%s; %d of %d free here go out", nameOf(owner),
                lacks[1].lack > 0 and lacks[1].kind or "nothing", hungry and " (hungry)" or "", trips, #g.free)

            local left = trips
            if g.isFaction and trips >= 1 and #g.free >= 2 then left = math.max(left, 2) end
            for _ = 1, trips do
                if #g.free == 0 or left <= 0 then break end
                local e = LOS.Stock.fleshPick(owner, g.isFaction, s, hungry)
                if not e then
                    LOS.log("LIVING %s has no building in reach left to go to today", nameOf(owner))
                    break
                end
                local size = g.isFaction and math.min(#g.free, PARTY_MOST, left) or 1
                left = left - size
                local who = {}
                for _ = 1, size do
                    local rec = table.remove(g.free, ZombRand(#g.free) + 1)
                    rec.objective = { kind = "trip", key = e.key, x = e.bx, y = e.by, z = 0,
                                      b = { x = e.x, y = e.y, w = e.w, h = e.h }, owner = key, since = hours(),
                                      lack = lacks[1].kind, party = size > 1 and e.key or nil }
                    table.insert(who, tostring(rec.id))
                end
                LOS.log("LIVING %s (%s) set%s off for the building at %s, %.0f tiles from home, for %s",
                    size > 1 and ("a party of " .. size .. ", npc " .. table.concat(who, ", ")) or ("npc=" .. who[1]),
                    nameOf(owner), size > 1 and "" or "s", e.key, e.d, lacks[1].kind)
            end
        end
    end
end


function Lv.tripDone(rec, trip, why, carried, empty)
    local owner, key = LOS.Stock.ownerOf(rec)
    if owner and owner.stock and key == trip.owner then LOS.Stock.fleshTripDone(owner, owner.stock, trip.key, carried, empty) end
    LOS.log("LIVING npc=%d (%s) heads home from the building at %s (%s) with %d things for the group", rec.id,
        nameOf(owner), tostring(trip.key), why, carried)
end
