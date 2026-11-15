










require "LastOnesStanding/LOS_Core"
require "LastOnesStanding/LOS_Records"
require "LastOnesStanding/LOS_Scavenge"
require "LastOnesStanding/LOS_Loot"
require "LastOnesStanding/LOS_Storage"
require "LastOnesStanding/LOS_Water"

-- A Last Ones Standing update disables the whole patch until it is rebased.
local Guard = LastOnesStandingSloppyPatch
if not (Guard and Guard.active()) then return end

local LOS = LastOnesStanding
local O = {}
LOS.Objectives = O

local SCAN_MS = 20000
local REST_MS = 120000
local NEXT_MS = 3000
local ARRIVE = 1.6
local WALK_TRIES = 2
-- PATCH: two re-orders used to happen within a second because every brain
-- tick restarted the walker, so companions silently gave up on a container a
-- few tiles away.  Keep trying for a while before calling the walk failed.
local WALK_GIVEUP_MS = 90000
local SPRING_RANGE = 7
local SPRING_ZOMBIE = 3
local GIVE_UP_HOURS = 6
local CALM_MS = 60000
local HIDE_MIN, HIDE_MAX = 12, 22
O.sprungGroups = O.sprungGroups or {}

function O.of(rec)
    if not rec then return nil end
    if rec.objective == nil and rec.role ~= "companion" then rec.objective = { kind = "scavenge" } end
    return rec.objective
end

function O.set(rec, objective)
    rec.objective = objective
end

local function describe(obj)
    if not obj then return "none" end
    if obj.kind == "ambush" then return obj.sprung and "ambush (sprung)" or "ambush (waiting)" end
    if obj.kind == "post" then return "holding a post" end
    if obj.kind == "raid" then return "raiding the player's base" end
    if obj.kind == "scout" then return "scouting for the player's base" end
    if obj.kind == "return" then return "heading home" end
    if obj.kind == "move" then return "moving on" end
    if obj.kind == "visit" then return "visiting the player (" .. tostring(obj.purpose) .. ")" end
    if obj.kind == "trip" then return "out to the building at " .. tostring(obj.key) .. " for its group" end
    return obj.kind
end
O.describe = describe



local function dropJob(br, why, id)
    if br.lootJob and why then
        LOS.log("LOOT npc=%d gave up on %s: %s", id, br.lootJob.key, why)
        br.lootSkip = br.lootSkip or {}
        br.lootSkip[br.lootJob.key] = true
    end
    br.lootJob = nil
end

function LOS.onLooted(npc, count)
    local br = LOS.Brain and LOS.Brain.state[LOS.idOf(npc) or -1]
    if not br then return end
    br.lootJob = nil
    br.nextLootScan = getTimestampMs() + NEXT_MS
end

function LOS.onStored(npc, count, left)
    local br = LOS.Brain and LOS.Brain.state[LOS.idOf(npc) or -1]
    if not br then return end


    local hauling = br.storeJob ~= nil
    br.storeJob = nil
    br.nextLootScan = getTimestampMs() + NEXT_MS
    -- PATCH: a tidy put-away that leaves a thing or two behind means that one
    -- container is full, not the whole base.  Tidy already marks the container
    -- itself, so don't pause all hauling for an hour.  Only a real haul trip
    -- that could not finish marks the group's storage full.
    if left > 0 and hauling and not br.tidyPut and LOS.Storage then LOS.Storage.markFull(npc) end
    if LOS.Base then LOS.Base.onStored(npc, count) end
end




local HAUL_TRIP = 0.75

-- PATCH: a full box for one kind used to abort the whole trip and mark the
-- group's storage "full" for an hour.  Work out which containers can really
-- take part of the load, and send only the things that fit.
local FOOD_TYPES = { dryfood = true, freshfood = true, usefirst = true }
local STORE_NOT = { composter = true, bin = true, dumpster = true, trashcan = true, garbagecan = true,
                    wheeliebin = true, garbage = true }

local function candidateRank(mark, typeKey, everything)
    local t = mark and mark.types
    if not t then return everything and 3 or nil end
    if typeKey then
        if t[typeKey] then return 1 end
        if FOOD_TYPES[typeKey] and (t.dryfood or t.freshfood or t.usefirst) then return 2 end
        local parent = LOS.Storage.PARENT[typeKey]
        if parent and t[parent] then return 2 end
    end
    if t.anything then return 3 end
    if everything then return 2 end
    return nil
end

local function fitsIn(npc, c, it, used)
    local w = it:getUnequippedWeight()
    return c:getCapacity() - c:getContentsWeight() - (used or 0) + 0.001 >= w and c:hasRoomFor(npc, it)
end

-- PATCH: try the container marked for the load's kind first, then a parent
-- mark, and only then an Anything box.  The old order added the main storage
-- before most marks, so a full building-materials crate sent planks into an
-- Anything shelf that tidy then emptied straight back out.
local function storeCandidates(only, x, y)
    local list, seen = {}, {}
    local hasBase = LOS.Storage.base() ~= nil
    local function add(o, c, sq, rank)
        if o and c and not seen[c] then
            seen[c] = true
            list[#list + 1] = { object = o, container = c, sq = sq, rank = rank or 3 }
        end
    end
    for _, mark in pairs(LOS.Storage.marks()) do
        if type(mark) == "table" and mark.x and not mark.private
                and (not hasBase or LOS.Storage.inBase(mark.x, mark.y)) then
            local rank = candidateRank(mark, only, only == nil)
            if rank then
                local mo, mc, msq = LOS.Storage.boxOfMark(mark)
                -- PATCH: a composter or bin mark is not a place for carrying things.
                if mc and not STORE_NOT[tostring(mc:getType())] then add(mo, mc, msq, rank) end
            end
        end
    end
    local o, c, sq = LOS.Storage.target()
    if o and c and not seen[c] then
        local main = LOS.Storage.get()
        local mark = LOS.Storage.markOf(o, (main and main.index) or 0)
        local rank = candidateRank(mark, only, only == nil)
        if not rank and not mark and LOS.Storage.isStorage(o) then rank = 3 end
        if rank then add(o, c, sq, rank) end
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        local da = (a.sq:getX() - x) * (a.sq:getX() - x) + (a.sq:getY() - y) * (a.sq:getY() - y)
        local db = (b.sq:getX() - x) * (b.sq:getX() - x) + (b.sq:getY() - y) * (b.sq:getY() - y)
        return da < db
    end)
    return list
end

local function batchFor(npc, container, items, only)
    local batch, used = {}, 0
    for _, it in ipairs(items) do
        if (only == nil or LOS.Storage.typeOf(it) == only) and fitsIn(npc, container, it, used) then
            batch[#batch + 1] = it
            used = used + it:getUnequippedWeight()
        end
    end
    return batch
end

local function startStore(id, npc, br, role, now, ctx, why)
    local items = LOS.Scavenge.haulItems(npc)
    local counts, only, most = {}, nil, 0
    for _, it in ipairs(items) do
        local t = LOS.Storage.typeOf(it)
        if t then
            counts[t] = (counts[t] or 0) + 1
            if counts[t] > most then only, most = t, counts[t] end
        end
    end

    local obj, c, sq = nil, nil, nil
    for _, e in ipairs(storeCandidates(only, npc:getX(), npc:getY())) do
        local batch = batchFor(npc, e.container, items, only)
        if #batch > 0 then
            obj, c, sq = e.object, e.container, e.sq
            break
        end
    end
    -- PATCH: no blanket fall back to the main storage here.  storeCandidates
    -- already includes it (and every Anything box) as the lowest rank, so a
    -- label-less or Anything box with room was picked there.  Falling back to
    -- target() regardless of its mark is what sent planks to the Anything
    -- shelf that tidy then emptied again.
    if not obj then
        if not br.storeUnloadedLogged then
            br.storeUnloadedLogged = true
            LOS.log("STORE npc=%d can't take its load: %s", id, LOS.Storage.get()
                and "there is no room for it in the group's storage"
                or "the group's storage isn't loaded (too far from the player)")
        end
        -- only call the base full when the main storage itself is full; a
        -- full box for one kind must not stop every other haul.
        local mo, mc = LOS.Storage.target()
        if mo and mc and #items > 0 and #batchFor(npc, mc, items, nil) == 0 then
            LOS.Storage.markFull(nil)
        end
        br.storeRetryAt = now + REST_MS
        return false
    end
    local stand = LOS.Scavenge.standingSquare(npc, sq)
    if not stand then
        br.storeRetryAt = now + REST_MS
        return false
    end
    br.storeJob = { object = obj, container = c, stand = stand, at = now, tries = 0, only = only }
    local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), stand:getX() + 0.5, stand:getY() + 0.5)
    LOS.log("STORE npc=%d takes %.1f weight to the group's storage %.0f tiles away (%s%s)", id,
        LOS.Scavenge.haulWeight(npc), d, why, only and (": its " .. LOS.Storage.typeLabel(only) .. " to the place marked for it") or "")
    return true
end

O.startStore = startStore




local function foughtSinceWalk(br, job)
    return br.fightAt ~= nil and job.walkAt ~= nil and br.fightAt >= job.walkAt
end


-- PATCH: is the walker for this job already on its way there?  The shipped
-- code called ctx.orderMove() on every brain tick, which cleared the queue and
-- started a fresh LOSWalkTo over and over.  Pathfinding never got a chance to
-- run, and the two quick re-orders made walkSpent() give up on a short walk.
local function currentActionOf(npc)
    local q = ISTimedActionQueue.queues[npc]
    return q and q.queue and q.queue[1] or nil
end

local function walkingTo(npc, sq, tag)
    local a = currentActionOf(npc)
    if not (a and a.Type == "LOSWalkTo" and a.tag == tag) then return false end
    if not sq or a.tx == nil then return true end
    return a.tx == sq:getX() and a.ty == sq:getY() and a.tz == sq:getZ()
end

local function inBaseAt(x, y)
    local St = LOS.Storage
    return St and St.inBase and St.inBase(x, y) or false
end

-- PATCH: don't sprint while looking after the base.  The old rule was a flat
-- "more than 15 tiles", which sent companions charging across the base (and
-- out to a composter) for no reason.
local function runFor(npc, sq, want)
    if not want then return false end
    if inBaseAt(npc:getX(), npc:getY()) then return false end
    if sq and inBaseAt(sq:getX(), sq:getY()) then return false end
    return true
end


local function countWalk(br, job, here, now)
    local closer = job.walkFrom ~= nil and here < job.walkFrom - 1.0
    if foughtSinceWalk(br, job) or closer then
        job.tries = 0
        job.walkFirstAt = nil
    end
    if (job.tries or 0) == 0 then job.walkFirstAt = now end
    job.tries = (job.tries or 0) + 1
    job.walkAt, job.walkFrom = now, here
end
O.countWalk = countWalk


local function walkSpent(br, job)
    if foughtSinceWalk(br, job) then return false end
    if (job.tries or 0) < WALK_TRIES then return false end
    return getTimestampMs() - (job.walkFirstAt or 0) >= WALK_GIVEUP_MS
end
O.walkSpent = walkSpent



local function sideTaken(br, job)
    local s = br.sideTaken
    if not (s and job and job.stand) then return end
    br.sideTaken = nil
    if s.fx == job.stand:getX() and s.fy == job.stand:getY() and s.fz == job.stand:getZ() then
        local sq = getCell():getGridSquare(s.x, s.y, s.z)
        if sq then job.stand = sq end
    end
end
O.sideTaken = sideTaken


local function storeStep(id, npc, br, role, now, ctx)
    local job = br.storeJob
    sideTaken(br, job)
    local here = IsoUtils.DistanceTo(npc:getX(), npc:getY(), job.stand:getX() + 0.5, job.stand:getY() + 0.5)
    if here <= ARRIVE then
        local items = LOS.Scavenge.haulItems(npc)
        -- PATCH: only hand the container what it can actually hold.  The
        -- original passed the whole load and LOSLoot left the rest behind,
        -- which the storage then reported as "full".
        local batch = batchFor(npc, job.container, items, job.only)
        if not job.object:getSquare() then
            br.storeJob = nil
            return false
        end
        if #batch == 0 then
            br.storeJob = nil
            if #items == 0 then return false end
            -- the box filled up while we walked; find another one
            if startStore(id, npc, br, role, now, ctx, "container filled on the way") then
                return storeStep(id, npc, br, role, now, ctx)
            end
            return false
        end
        ctx.setState(br, role, now, "haul", string.format("(putting %d things in the group's storage)", #batch))
        ISTimedActionQueue.add(LOSLoot:new(npc, job.object, job.container, batch, { store = true }))
        return true
    end
    local f = br.walkFail
    if (f and f.tag == "store" and f.at >= job.at) or walkSpent(br, job) then
        LOS.log("STORE npc=%d couldn't get to the group's storage; keeps its load for now", id)
        br.storeJob = nil
        br.storeRetryAt = now + REST_MS
        return false
    end
    if ctx.standUp(npc, br, "store") then return true end
    if walkingTo(npc, job.stand, "store") then return true end
    countWalk(br, job, here, now)
    ctx.setState(br, role, now, "haul", string.format("(to the group's storage, %.0f tiles)", here))
    ctx.orderMove(npc, job.stand, runFor(npc, job.stand, here > 15), "store")
    return true
end
O.storeStep = storeStep


local function walkTo(npc, br, role, now, ctx, job, tag, what)
    sideTaken(br, job)
    local here = IsoUtils.DistanceTo(npc:getX(), npc:getY(), job.stand:getX() + 0.5, job.stand:getY() + 0.5)
    if here <= ARRIVE then return "here" end
    local f = br.walkFail
    if (f and f.tag == tag and f.at >= job.at) or walkSpent(br, job) then return "failed" end
    if ctx.standUp(npc, br, tag) then return "busy" end
    if walkingTo(npc, job.stand, tag) then return "busy" end
    countWalk(br, job, here, now)
    ctx.setState(br, role, now, tag, string.format("(%s, %.0f tiles)", what, here))
    ctx.orderMove(npc, job.stand, runFor(npc, job.stand, here > 15), tag)
    return "busy"
end
O.walkTo = walkTo






local FETCH_MAX = 4
local FETCH_IDLE_MS = 120000

local function fetchIdle(id, npc, br, now, line)
    br.fetchIdleUntil = now + FETCH_IDLE_MS
    if line and br.fetchSaid ~= line then
        br.fetchSaid = line
        LOS.say(npc, line)
        LOS.log("FETCH npc=%d waits: %s", id, line)
    end
    return false
end



local function emptyBottles(c, max)
    local out, liquids = {}, 0
    local items = c:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)


        if it:getFluidContainer() then
            liquids = liquids + 1
            if #out < max and LOS.Water.isFillable(it) then table.insert(out, it) end
        end
    end
    return out, liquids
end

-- PATCH: the shipped code only looked for empty bottles in the one container
-- the player designated as the main storage.  Bottles kept in any other box
-- in the base were invisible, so companions stood about saying there were
-- none.  Look through the group's marked containers, then the building the
-- storage is in, and remember the result for a little while.
local BOTTLE_SCAN_MS = 20000
local bottleCache = { at = 0, list = {} }

local function bottleSources(c, sq)
    local now = getTimestampMs()
    if now < bottleCache.at then return bottleCache.list end
    bottleCache.at = now + BOTTLE_SCAN_MS
    local list, seen = {}, {}
    local function look(object, container, square)
        if not (object and container and square) or seen[container] then return end
        seen[container] = true
        local bottles = emptyBottles(container, FETCH_MAX)
        if #bottles > 0 then
            list[#list + 1] = { object = object, container = container, sq = square, bottles = bottles }
        end
    end
    look(LOS.Storage.target())
    for _, mark in pairs(LOS.Storage.marks()) do
        if type(mark) == "table" and mark.x and not mark.private then
            look(LOS.Storage.boxOfMark(mark))
        end
    end
    if sq then
        local cell = getCell()
        local b = sq:getBuilding()
        local def = b and b:getDef()
        if def then
            local x1, y1 = def:getX(), def:getY()
            local x2, y2 = x1 + def:getW(), y1 + def:getH()
            for z = 0, 3 do
                for x = x1, x2 do
                    for y = y1, y2 do
                        local s = cell:getGridSquare(x, y, z)
                        if s and s:getBuilding() == b then
                            local objs = s:getObjects()
                            for i = 0, objs:size() - 1 do
                                local o = objs:get(i)
                                for ci = 0, o:getContainerCount() - 1 do
                                    local cc = o:getContainerByIndex(ci)
                                    local mark = cc and LOS.Storage.markOf(o, ci) or nil
                                    if cc and not (mark and mark.private) then look(o, cc, s) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    bottleCache.list = list
    return list
end

function O.fetchWater(id, npc, br, rec, role, cur, now, ctx)
    if cur and (cur.tag == "fetch" or cur.tag == "store" or cur.Type == "LOSLoot" or cur.Type == "ISTakeWaterAction") then
        return true
    end
    if cur then return false end
    if br.storeJob then return storeStep(id, npc, br, role, now, ctx) end
    if now < (br.fetchIdleUntil or 0) then return false end
    local obj, c, ssq = LOS.Storage.target()
    if not obj then
        return fetchIdle(id, npc, br, now, LOS.Storage.get() and "The storage is too far from here." or "We've got no storage to fill.")
    end
    if not LOS.Storage.hauling() then return fetchIdle(id, npc, br, now, "The storage is full.") end

    local job = br.fetchJob
    if not job then
        local carried, toFill, other = LOS.Scavenge.haulItems(npc), {}, 0
        for _, it in ipairs(carried) do
            if LOS.Water.isFillable(it) then table.insert(toFill, it) else other = other + 1 end
        end
        if #carried > 0 and (br.fetchFilled or #toFill == 0 or other > 0) then

            br.fetchFilled = nil
            if startStore(id, npc, br, role, now, ctx, "water fetched") then return storeStep(id, npc, br, role, now, ctx) end
            return fetchIdle(id, npc, br, now, nil)
        elseif #toFill > 0 then
            local src, sq, stand = LOS.Water.findSource(ssq:getX(), ssq:getY(), ssq:getZ(), LOS.Water.FETCH_RADIUS, npc)
            if not src then return fetchIdle(id, npc, br, now, "There's no clean water near the storage.") end
            job = { kind = "fill", object = src, stand = stand, at = now, tries = 0 }
            LOS.log("FETCH npc=%d takes %d bottles to the water at %d,%d", id, #toFill, sq:getX(), sq:getY())
        else
            local sources = bottleSources(c, ssq)
            if #sources == 0 then
                if br.fetchSaid == nil then
                    LOS.log("FETCH npc=%d: found no empty bottle to fill anywhere in the base", id)
                end
                return fetchIdle(id, npc, br, now, "There are no bottles to fill.")
            end
            local src = sources[1]
            local stand = LOS.Scavenge.standingSquare(npc, src.sq)
            if not stand then return fetchIdle(id, npc, br, now, nil) end
            job = { kind = "collect", object = src.object, container = src.container, stand = stand, at = now, tries = 0 }
            LOS.log("FETCH npc=%d goes for %d empty bottle(s) in the group's storage", id, #src.bottles)
        end
        br.fetchJob, br.fetchSaid = job, nil
    end
    local r = walkTo(npc, br, role, now, ctx, job, "fetch", job.kind == "fill" and "to the water" or "to the storage")
    if r == "busy" then return true end
    br.fetchJob = nil
    if r == "failed" then
        LOS.log("FETCH npc=%d couldn't get %s", id, job.kind == "fill" and "to the water" or "to the storage")
        return fetchIdle(id, npc, br, now, nil)
    end
    if job.kind == "collect" then
        local empties = emptyBottles(job.container, FETCH_MAX)
        if #empties == 0 then
            -- PATCH: the box changed while we walked; scan again next time.
            bottleCache.at = 0
            return false
        end
        local hauled = {}
        for i = 1, #empties do hauled[i] = true end
        ctx.setState(br, role, now, "fetch", string.format("(taking %d empty bottles)", #empties))
        ISTimedActionQueue.add(LOSLoot:new(npc, job.object, job.container, empties, { hauled = hauled }))
        return true
    end

    if not LOS.Water.isCleanSource(job.object) then return false end
    local toFill = {}
    for _, it in ipairs(LOS.Scavenge.haulItems(npc)) do
        if LOS.Water.isFillable(it) then table.insert(toFill, it) end
    end
    local n = LOS.Water.useSource(npc, job.object, false, toFill)
    br.fetchFilled = true
    ctx.setState(br, role, now, "fetch", string.format("(filling %d bottles)", n))
    return n > 0
end




local RESUPPLY_RANGE = 40
local RESUPPLY_CHECK_MS = 30000
local AVOID_MS = 600000

function O.resupply(id, npc, br, rec, role, cur, now, ctx)
    if not LOS.Storage then return false end
    if cur and (cur.tag == "resupply" or (br.resupplyJob and cur.Type == "LOSLoot")) then return true end
    local job = br.resupplyJob
    if not job then
        if now < (br.nextResupply or 0) then return false end
        br.nextResupply = now + RESUPPLY_CHECK_MS
        local needs = LOS.Storage.needs(npc)
        if not needs then return false end


        local avoid = {}
        for c, untilMs in pairs(br.resupplyAvoid or {}) do
            if untilMs > now then avoid[c] = true else br.resupplyAvoid[c] = nil end
        end
        local obj, c, sq, picks = LOS.Storage.resupplySource(npc, needs, avoid, RESUPPLY_RANGE)
        if not obj then return false end
        local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), sq:getX() + 0.5, sq:getY() + 0.5)
        if d > RESUPPLY_RANGE then return false end
        local stand = LOS.Scavenge.standingSquare(npc, sq)
        if not stand then return false end
        local what = {}
        for k, n in pairs(needs) do table.insert(what, k .. " " .. n) end
        LOS.log("RESUPPLY npc=%d goes to the group's storage (%.0f tiles) for %s", id, d, table.concat(what, ", "))
        br.resupplyJob = { object = obj, container = c, stand = stand, at = now, tries = 0 }
        job = br.resupplyJob
    end
    sideTaken(br, job)
    local here = IsoUtils.DistanceTo(npc:getX(), npc:getY(), job.stand:getX() + 0.5, job.stand:getY() + 0.5)
    if here <= ARRIVE then

        local picks = LOS.Storage.resupplyPicks(npc, job.container, LOS.Storage.needs(npc) or {})
        if #picks == 0 or not job.object:getSquare() then
            br.resupplyJob = nil
            return false
        end
        ctx.setState(br, role, now, "resupply", string.format("(taking %d things from the group's storage)", #picks))

        if LOS.Bonds and role == "companion" then
            local picked, tookFood = {}, false
            for _, it in ipairs(picks) do
                picked[it:getID()] = true
                if instanceof(it, "Food") then tookFood = true end
            end
            if tookFood then
                local left = false
                local items = job.container:getItems()
                for i = 0, items:size() - 1 do
                    local it = items:get(i)
                    if instanceof(it, "Food") and not picked[it:getID()] and LOS.Needs.foodProblem(it) == nil then
                        left = true
                        break
                    end
                end
                if not left then LOS.Bonds.onTookLastFood(id, npc) end
            end
        end
        ISTimedActionQueue.add(LOSLoot:new(npc, job.object, job.container, picks))
        return true
    end
    local f = br.walkFail
    if (f and f.tag == "resupply" and f.at >= job.at) or walkSpent(br, job) then
        LOS.log("RESUPPLY npc=%d couldn't get to the group's storage: tries another for %d min", id, math.floor(AVOID_MS / 60000))
        br.resupplyAvoid = br.resupplyAvoid or {}
        br.resupplyAvoid[job.container] = now + AVOID_MS
        br.resupplyJob = nil
        br.nextResupply = now + RESUPPLY_CHECK_MS
        return false
    end
    if ctx.standUp(npc, br, "resupply") then return true end
    if walkingTo(npc, job.stand, "resupply") then return true end
    countWalk(br, job, here, now)
    ctx.setState(br, role, now, "resupply", string.format("(to the group's storage, %.0f tiles)", here))
    ctx.orderMove(npc, job.stand, runFor(npc, job.stand, here > 15), "resupply")
    return true
end



local ELSEWHERE_MS = 45000
local AT_SPOT = 16
local function elsewhere(id, npc, br, now)
    local rec = LOS.Records.get(id)
    local o = rec and rec.order
    if not (o and o.kind == "scavenge" and o.x) or now < (br.elsewhereAt or 0) then return false end

    if o.house then
        LOS.say(npc, o.looted and "That's everything I could use in here." or "Nothing worth taking in here.")
        LOS.log("LOOT npc=%d has been through the house at %d,%d (%s): back to following", id, o.house.x, o.house.y, o.looted and "took things" or "nothing for it")
        rec.order = { kind = "follow" }
        rec.objective = { kind = "none" }
        return true
    end
    if IsoUtils.DistanceTo(npc:getX(), npc:getY(), o.x + 0.5, o.y + 0.5) > AT_SPOT then return false end
    br.elsewhereAt = now + ELSEWHERE_MS
    local from = string.format("%d,%d", o.x, o.y)
    local what, info = LOS.Scavenge.elsewhere(npc, o)
    local dir = "?"
    if info and LOS.Hail and LOS.Hail.direction then dir = LOS.Hail.direction(npc:getX(), npc:getY(), info.x, info.y) end
    if what == "moved" then
        br.lootSkip = {}
        br.nextLootScan = now + NEXT_MS
        o.walkInAt = now
        if not o.looted and not o.saidEmpty then
            o.saidEmpty = true
            LOS.say(npc, string.format(LOS.T("Nothing out here to search. I'll try the houses to the %s."), dir))
        elseif now >= (br.nextPlaceSay or 0) then
            br.nextPlaceSay = now + 120000
            LOS.say(npc, "Nothing more here. I'll try the next place.")
        end
        LOS.log("LOOT npc=%d nothing more for it round %s: on to the building %.0f tiles to the %s (order now at %d,%d)", id,
            from, info.dist, dir, o.x, o.y)
        return true
    elseif what == "far" then
        if not o.saidFar then
            o.saidFar = true
            LOS.say(npc, string.format(LOS.T("There's nothing out here to search. The nearest houses are a long way to the %s."), dir))
        end
        LOS.log("LOOT npc=%d nothing to search round %s, and the nearest building not searched out is %.0f tiles to the %s: out of reach",
            id, from, info.dist, dir)


        if LOS.Expedition and LOS.Expedition.explore(id, o.backBy or false) then return true end
        br.nextLootScan = now + 600000
        return true
    elseif what == "none" then
        if not o.saidNone then
            o.saidNone = true
            LOS.say(npc, "Everything round here's been picked over.")
        end
        LOS.log("LOOT npc=%d nothing to search round %s and no building left that its group hasn't searched out", id, from)
        if LOS.Expedition and LOS.Expedition.explore(id, o.backBy or false) then return true end
        br.nextLootScan = now + 600000
        return true
    end
    return false
end




function O.nudge(id, npc, br, now, idleMs)
    if br.lootJob or br.storeJob or br.entry then return false end
    LOS.log("IDLE npc=%d out scavenging has done nothing for %d s: looks for the next thing to search now", id, math.floor((idleMs or 0) / 1000))
    br.nextLootScan, br.elsewhereAt = now, 0
    return true
end



local function scavenge(id, npc, br, role, cur, now, ctx, haul)

    if br.entry and LOS.Entry then
        local busy, inside = LOS.Entry.step(id, npc, br, role, cur, now, ctx)
        if busy then return true end
        if inside then
            if br.lootJob then br.lootJob.at, br.lootJob.tries = now, 0 end
        else
            dropJob(br, "no way in", id)
            return false
        end
    end
    if cur and (cur.Type == "LOSLoot" or cur.tag == "loot" or cur.tag == "store") then return true end
    if cur then return false end

    if br.storeJob then return storeStep(id, npc, br, role, now, ctx) end


    local order = LOS.Records.get(id) and LOS.Records.get(id).order
    local mayStore = haul == true and LOS.Storage.hauling() and now >= (br.storeRetryAt or 0) and not (order and order.house)
    local haulW = LOS.Scavenge.haulWeight(npc)
    if mayStore and not br.lootJob and haulW > 0 and haulW >= LOS.Scavenge.haulLoad(npc) * HAUL_TRIP then
        if startStore(id, npc, br, role, now, ctx, "a full load") then return storeStep(id, npc, br, role, now, ctx) end
    end

    local job = br.lootJob
    if job then
        sideTaken(br, job)
        local here = IsoUtils.DistanceTo(npc:getX(), npc:getY(), job.stand:getX() + 0.5, job.stand:getY() + 0.5)
        if here <= ARRIVE then
            local picks, hauled = LOS.Scavenge.pick(npc, job.container, nil, haul)

            if job.object:getSquare() then LOS.Scavenge.remember(npc, job.key, job.container, picks) end
            if #picks == 0 or not job.object:getSquare() then
                dropJob(br, "nothing left for it", id)
                return false
            end

            local jsq = job.object:getSquare()
            if role ~= "companion" and LOS.Trespass and LOS.Storage and LOS.Storage.inBase(jsq:getX(), jsq:getY())
                    and LOS.Trespass.caughtLooting(id, npc, LOS.Records.get(id), now) then
                dropJob(br, "told to leave the base", id)
                return false
            end

            if role ~= "companion" and LOS.Theft and LOS.Theft.caught(id, npc, LOS.Records.get(id), jsq:getX(), jsq:getY(), now) then
                dropJob(br, "told to get out of someone's home", id)
                return false
            end
            ctx.setState(br, role, now, "scavenge", string.format("(searching %s)", tostring(job.container:getType())))
            ISTimedActionQueue.add(LOSLoot:new(npc, job.object, job.container, picks, { hauled = hauled }))
            return true
        end
        local f = br.walkFail
        if f and f.tag == "loot" and f.at >= job.at then


            if LOS.Entry then
                if LOS.Entry.begin(id, npc, br, LOS.Records.get(id), job, now) then return true end
            end
            dropJob(br, "no way there", id)
            return false
        end
        if ctx.standUp(npc, br, "loot") then return true end
        if walkSpent(br, job) then
            dropJob(br, "didn't get there", id)
            return false
        end
        countWalk(br, job, here, now)
        ctx.orderMove(npc, job.stand, false, "loot")
        return true
    end


    if br.sitUntil and now < br.sitUntil then return false end


    if LOS.Brain and LOS.Brain.calm and not LOS.Brain.calm(br, now) then return false end
    if now < (br.nextLootScan or 0) then return false end
    br.nextLootScan = now + SCAN_MS
    br.lootSkip = br.lootSkip or {}
    local f = LOS.Scavenge.find(npc, br.lootSkip, haul)
    if not f then

        if mayStore and LOS.Scavenge.haulWeight(npc) > 0 and startStore(id, npc, br, role, now, ctx, "nothing left around") then
            return storeStep(id, npc, br, role, now, ctx)
        end
        br.nextLootScan = now + REST_MS

        if role == "companion" then elsewhere(id, npc, br, now) end
        return false
    end
    local frec = LOS.Records.get(id)
    if frec and frec.order then frec.order.looted = true end
    br.lootJob = { key = f.key, object = f.object, container = f.container, stand = f.stand, at = now, tries = 0 }
    local forGroup = 0
    for _ in pairs(f.hauled or {}) do forGroup = forGroup + 1 end

    LOS.log("LOOT npc=%d heading for %s at %d,%d (%s; stand %d,%d; %.0f tiles; %d things it wants, %d of them for the group)",
        id, tostring(f.container:getType()), f.square:getX(), f.square:getY(),
        f.square:isOutside() and "outdoors" or "indoors", f.stand:getX(), f.stand:getY(), f.dist, #f.picks, forGroup)
    if ctx.standUp(npc, br, "loot") then return true end
    countWalk(br, br.lootJob, f.dist, now)
    ctx.setState(br, role, now, "scavenge", string.format("(%s %.0f tiles away: %d things it wants)",
        tostring(f.container:getType()), f.dist, #f.picks))
    ctx.orderMove(npc, f.stand, false, "loot")
    return true
end





local HOME_NEAR = 6
function O.comeHome(id, npc, br, rec, role, cur, now, ctx)
    if cur and (cur.Type == "LOSLoot" or cur.tag == "store" or cur.tag == "homeward") then return true end
    if cur then return true end
    br.lootJob = nil
    if br.storeJob then return storeStep(id, npc, br, role, now, ctx) end
    local s = LOS.Storage and LOS.Storage.get()
    if s and LOS.Storage.hauling() and now >= (br.storeRetryAt or 0) and LOS.Scavenge.haulWeight(npc) > 0
            and LOS.Storage.target() and startStore(id, npc, br, role, now, ctx, "back for the night") then
        return storeStep(id, npc, br, role, now, ctx)
    end
    local hx, hy, hz
    if s then
        hx, hy, hz = s.x, s.y, s.z or 0
    else
        local player = getSpecificPlayer(0)
        if not player or player:isDead() then return "home" end
        hx, hy, hz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    end
    local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), hx + 0.5, hy + 0.5)
    if d <= HOME_NEAR then return "home" end
    if ctx.waitAfterFail(br, "homeward", now) then return false end
    if ctx.standUp(npc, br, "homeward") then return true end
    local sq = LOS.legToward(npc, hx, hy, hz)
    if not sq then return false end
    ctx.setState(br, role, now, "homeward", string.format("(%.0f tiles from home)", d))
    ctx.orderMove(npc, sq, false, "homeward")
    return true
end





local HOME_LEASH = 25
local POST_RANGE = 4

local function homeOf(rec)
    local g = LOS.Population and LOS.Population.groupOf(rec)
    return g and g.home or nil
end


local function goHome(id, npc, br, role, cur, now, ctx, home, leash, what)
    if cur then return cur.tag == what end
    local d = IsoUtils.DistanceTo(npc:getX(), npc:getY(), home.x + 0.5, home.y + 0.5)
    if d <= leash then return false end
    if ctx.waitAfterFail(br, what, now) then return false end
    if ctx.standUp(npc, br, what) then return true end
    local sq = LOS.walkableSquare(home.x, home.y, home.z or 0, 6, 2)
    if not sq then return false end
    ctx.setState(br, role, now, what, string.format("(%.0f tiles from home)", d))
    ctx.orderMove(npc, sq, d > 15, what)
    return true
end







local TRIP_HOURS = 6
local TRIP_HOME_HOUR = 18
local TRIP_HURT = 0.5
local TRIP_FAILS = 3
local AT_BUILDING = 3

local function inBuilding(npc, b)
    local x, y = npc:getX(), npc:getY()
    return x >= b.x - AT_BUILDING and x <= b.x + b.w + AT_BUILDING and y >= b.y - AT_BUILDING and y <= b.y + b.h + AT_BUILDING
end

local function trip(id, npc, br, rec, role, cur, now, ctx)
    local t = rec.objective
    local function over(why, empty)
        local carried = math.max(0, #LOS.Scavenge.haulItems(npc) - (t.startItems or 0))
        if LOS.Living then LOS.Living.tripDone(rec, t, why, carried, empty) end

        if not (LOS.Cars and LOS.Cars.tripOver(rec, t)) then rec.objective = { kind = "scavenge" } end
        br.lootJob, br.tripFails = nil, nil
        return false
    end
    if cur and (cur.Type == "LOSLoot" or cur.tag == "loot" or cur.tag == "trip") then return true end
    local load = LOS.Scavenge.haulLoad(npc) * (LOS.Living and LOS.Living.HAUL_SHARE or 0.6)
    if t.arrived and LOS.Scavenge.haulWeight(npc) >= load then return over("a load to bring home") end
    if getGameTime():getWorldAgeHours() - (t.since or 0) > TRIP_HOURS then return over("out long enough") end
    if getGameTime():getHour() >= TRIP_HOME_HOUR then return over("evening") end
    if LOS.hp(npc) < TRIP_HURT then return over("hurt") end

    local quit = LOS.Mind and LOS.Mind.quitWhy(npc)
    if quit == "bitten" or quit == "out of rounds" then return over(quit) end
    if cur then return false end
    if not inBuilding(npc, t.b) then

        local f = br.walkFail
        if f and f.tag == "trip" and f.at ~= br.tripFailAt then
            br.tripFailAt = f.at
            br.tripFails = (br.tripFails or 0) + 1
            if br.tripFails >= TRIP_FAILS then return over("no way there", true) end
        end
        if ctx.waitAfterFail(br, "trip", now) then return false end
        if ctx.standUp(npc, br, "trip") then return true end
        local sq = LOS.legToward(npc, t.x, t.y, t.z or 0)
        if not sq then return over("no way there", true) end
        ctx.setState(br, role, now, "trip", string.format("(on the way to the building at %s, %.0f tiles)", tostring(t.key),
            IsoUtils.DistanceTo(npc:getX(), npc:getY(), t.x + 0.5, t.y + 0.5)))
        ctx.orderMove(npc, sq, false, "trip")
        return true
    end
    if not t.arrived then
        t.arrived = true
        t.startItems = #LOS.Scavenge.haulItems(npc)
        br.lootSkip, br.nextLootScan = {}, now
        LOS.log("LIVING npc=%d is at the building at %s; searching it for its group", id, tostring(t.key))
    end
    local haul = LOS.Living and LOS.Living.haulFor(rec) or false
    if scavenge(id, npc, br, role, cur, now, ctx, haul) then return true end

    if (br.nextLootScan or 0) - now > SCAN_MS then return over("nothing more there", true) end
    return false
end


function O.step(id, npc, br, rec, role, cur, now, ctx)
    local obj = O.of(rec)
    if not obj then return false end
    if obj.kind == "raid" and LOS.Raids then return LOS.Raids.step(id, npc, br, rec, role, cur, now, ctx) end

    if obj.kind == "scout" and LOS.BaseWord then return LOS.BaseWord.scoutStep(id, npc, br, rec, role, cur, now, ctx) end
    if obj.kind == "visit" and LOS.Visits then return LOS.Visits.step(id, npc, br, rec, role, cur, now, ctx) end
    if obj.kind == "tradepost" and LOS.Visits then return LOS.Visits.postStep(id, npc, br, rec, role, cur, now, ctx) end
    if obj.kind == "checkpoint" and LOS.World then return LOS.World.checkpointStep(id, npc, br, rec, role, cur, now, ctx) end
    if obj.kind == "trip" then return trip(id, npc, br, rec, role, cur, now, ctx) end

    if obj.kind == "along" then return LOS.Member ~= nil and LOS.Member.alongStep(id, npc, br, rec, role, cur, now, ctx) end
    if obj.kind == "car" then return LOS.Cars ~= nil and LOS.Cars.step(id, npc, br, rec, role, cur, now, ctx) end

    if (obj.kind == "city" or (obj.kind == "scavenge" and rec.city)) and LOS.City and LOS.City.alive() then
        return LOS.City.step(id, npc, br, rec, role, cur, now, ctx)
    end

    if (obj.kind == "return" or obj.kind == "move") and LOS.Raids then
        return LOS.Raids.returnStep(id, npc, br, rec, role, cur, now, ctx)
    end
    if obj.kind == "post" then

        if obj.patrol then
            local tgt = obj.leg == "a" and obj.patrol.a or obj.patrol.b
            if goHome(id, npc, br, role, cur, now, ctx, { x = tgt.x, y = tgt.y, z = 0 }, POST_RANGE, "patrol") then return true end
            obj.leg = obj.leg == "a" and "b" or "a"
            return false
        end

        local home = obj.x and { x = obj.x, y = obj.y, z = obj.z or 0 } or homeOf(rec)
        if home ~= nil and goHome(id, npc, br, role, cur, now, ctx, home, POST_RANGE, "post") then return true end

        if rec.sitAtPost and LOS.Seats and not npc:isSittingOnFurniture() and now >= (br.postSitAt or 0) then
            br.postSitAt = now + 60000
            if LOS.Seats.sit(id, npc, br, now, "at the post's table", true, { x = home.x, y = home.y, z = home.z or 0, reach = 4 }) then return true end
        end
        return false
    end
    if obj.kind == "scavenge" then
        if role ~= "companion" and not br.lootJob then
            local home = homeOf(rec)
            if home and goHome(id, npc, br, role, cur, now, ctx, home, HOME_LEASH, "home") then return true end
            if LOS.Settle and LOS.Settle.step(id, npc, br, rec, role, cur, now, ctx) then return true end
        end


        local haul = role == "companion" and LOS.Storage ~= nil
        if role ~= "companion" and LOS.Living then haul = LOS.Living.haulFor(rec) or false end
        return scavenge(id, npc, br, role, cur, now, ctx, haul)
    end
    return false
end



local function groupBodies(group)
    local out = {}
    for oid, other in pairs(LOS.Bodies.byId) do
        local r = LOS.Records.get(oid)
        if r and r.objective and r.objective.kind == "ambush" and r.objective.group == group then
            table.insert(out, { id = oid, npc = other, rec = r })
        end
    end
    return out
end

local function spring(group, why, byId)
    O.sprungGroups[group] = true
    local first = true
    for _, m in ipairs(groupBodies(group)) do
        m.rec.objective.sprung = true
        m.rec.objective.sprungAt = getTimestampMs()
        m.npc:setSneaking(false)
        LOS.say(m.npc, first and "Don't move!" or "Now!")
        first = false
    end
    LOS.log("AMBUSH group %s sprung by npc=%s: %s", tostring(group), tostring(byId), why)
end




function O.ambushHold(id, npc, br, rec, role, cur, h, hd, z, zd, now, ctx)
    local obj = rec.objective
    if obj.sprung or O.sprungGroups[obj.group] then
        if not obj.sprung then
            obj.sprung, obj.sprungAt = true, now
            npc:setSneaking(false)
        end

        if h or (z and zd < 12) then
            br.ambushQuietSince = nil
        else
            br.ambushQuietSince = br.ambushQuietSince or now
            if now - br.ambushQuietSince > CALM_MS then
                O.set(rec, { kind = "scavenge" })
                LOS.log("AMBUSH npc=%d: it's over; scavenging", id)
            end
        end
        return false
    end

    if getGameTime():getWorldAgeHours() - (obj.since or 0) > GIVE_UP_HOURS then
        O.set(rec, { kind = "scavenge" })
        npc:setSneaking(false)
        LOS.log("AMBUSH npc=%d: nobody came; gave up and went scavenging", id)
        return false
    end

    local hp = LOS.hp(npc)
    if br.ambushHp and hp < br.ambushHp - 0.01 then
        spring(obj.group, string.format("hurt (%.2f -> %.2f)", br.ambushHp, hp), id)
        return false
    end
    br.ambushHp = hp
    if h and hd <= SPRING_RANGE then
        local who = (h == getSpecificPlayer(0)) and "the player" or ("npc #" .. tostring(LOS.idOf(h)))
        spring(obj.group, string.format("%s came within %.1f tiles", who, hd), id)
        return false
    end
    if z and zd <= SPRING_ZOMBIE then
        spring(obj.group, string.format("a zombie at %.1f tiles", zd), id)
        return false
    end


    ctx.setState(br, role, now, "ambush", "(lying in wait)")
    if cur and cur.tag ~= "ambush" then ISTimedActionQueue.clear(npc); cur = nil end
    if ctx.standUp(npc, br, "ambush") then return true end
    local away = IsoUtils.DistanceTo(npc:getX(), npc:getY(), obj.x + 0.5, obj.y + 0.5)
    if away > 1.5 then
        if not cur then
            local sq = getCell():getGridSquare(obj.x, obj.y, obj.z)
            if sq then ctx.orderMove(npc, sq, false, "ambush") end
        end
        return true
    end
    if not npc:isSneaking() then npc:setSneaking(true) end
    if h then
        npc:faceThisObject(h)
    elseif obj.faceX then
        npc:faceLocationF(obj.faceX, obj.faceY)
    end
    return true
end




local function hidingSquare(player)
    local cell = getCell()
    local px, py, z = player:getX(), player:getY(), math.floor(player:getZ())
    local best, bestScore = nil, -1
    for _ = 1, 300 do
        local a = ZombRandFloat(0, 6.2832)
        local r = ZombRandFloat(HIDE_MIN, HIDE_MAX)
        local sq = cell:getGridSquare(math.floor(px + math.cos(a) * r), math.floor(py + math.sin(a) * r), z)
        if sq and not sq:isCanSee(0) and LOS.walkableSquare(sq:getX(), sq:getY(), z, 1, 0) == sq then
            local score = 0
            if not sq:isCouldSee(0) then score = score + 2 end
            if sq:getRoom() then score = score + 2
            elseif sq:HasTree() or sq:hasBush() then score = score + 1 end
            if score > bestScore then best, bestScore = sq, score end
            if score >= 4 then break end
        end
    end
    return best, bestScore
end


function O.spawnAmbush(player, count)
    local spot, score = hidingSquare(player)
    if not spot then
        LOS.log("AMBUSH: no hidden square %d-%d tiles from the player", HIDE_MIN, HIDE_MAX)
        return 0
    end
    local group = nil
    local made = 0
    for i = 1, count do
        local sq = spot
        if i > 1 then sq = LOS.walkableSquare(spot:getX(), spot:getY(), spot:getZ(), 8, 1.5) or spot end
        local npc, rec = LOS.Bodies.createNew(sq, "Base.Pistol", "raider")
        if npc and rec then
            group = group or rec.id
            O.set(rec, { kind = "ambush", x = sq:getX(), y = sq:getY(), z = sq:getZ(), group = group,
                since = getGameTime():getWorldAgeHours(), faceX = player:getX(), faceY = player:getY() })
            npc:setSneaking(true)
            npc:faceLocationF(player:getX(), player:getY())
            made = made + 1
        end
    end
    local where = {}
    if not spot:isCouldSee(0) then table.insert(where, "behind cover") end
    if spot:getRoom() then table.insert(where, "indoors")
    elseif spot:HasTree() or spot:hasBush() then table.insert(where, "among trees") end
    local kind = #where > 0 and table.concat(where, ", ") or "out of view only"
    LOS.log("AMBUSH group %s: %d raiders lying in wait at %d,%d, %.0f tiles from the player (%s)", tostring(group),
        made, spot:getX(), spot:getY(), IsoUtils.DistanceTo(player:getX(), player:getY(), spot:getX(), spot:getY()), kind)
    return made
end

LOS.log("PATCH objectives hauling/storing/water fixes loaded")
