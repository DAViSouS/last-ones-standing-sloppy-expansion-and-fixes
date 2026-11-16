-- Last Ones Standing Sloppy Expansion and Fixes
-- Combat fixes for Last Ones Standing:
--   * no attack, melee or gun, from a seat, a bed, the floor, while knocked
--     down or while getting up
--   * a tired NPC hits softer (and, optionally, misses more) against people;
--     fights with the dead keep the shipped numbers
--   * a hit wakes a sleeping NPC
--   * the extra blow damage on the player is a multiplier on the blow after
--     fatigue, so it shrinks with it (a halved blow's extra hit is halved too)
--   * a hit on an NPC that is already down can knock it down again
-- Everything is tuned from the sandbox page "Sloppy Expansion and Fixes".
-- A Last Ones Standing update disables this file until the patch is rebased.
-- LOS_HitReact/LOS_Combat are shipped files we do not edit: the melee hit is a
-- copy of the shipped resolveHit (ranged still goes to the shipped function)
-- because the damage number is computed inside it.

require "LastOnesStanding/LOS_Core"
require "LastOnesStanding/LOS_Engage"
require "LastOnesStanding/LOS_Combat"
require "LastOnesStanding/LOS_Die"
require "LastOnesStanding/LOS_Sleep"
require "LastOnesStanding/LOS_HitReact"

local LOS = LastOnesStanding
local Guard = LastOnesStandingSloppyPatch
if not (LOS and Guard and Guard.active()) then return end

---------------------------------------------------------------------------
-- Sandbox options
---------------------------------------------------------------------------
local PAGE = "SloppyExpansion"

local function raw(name, default)
    local page = SandboxVars and SandboxVars[PAGE]
    if type(page) ~= "table" then return default end
    local v = page[name]
    if v == nil then return default end
    return v
end

local function flag(name, default)
    local v = raw(name, default)
    if v == nil then return default end
    return v and true or false
end

local function num(name, default)
    local v = tonumber(raw(name, default))
    if v == nil then return default end
    return v
end

local function pct(name, default) return num(name, default) / 100 end

---------------------------------------------------------------------------
-- Shared state
---------------------------------------------------------------------------
local UPSTREAM_BEGIN, UPSTREAM_RESOLVE, UPSTREAM_HIT = nil, nil, nil
local hooked = false
local realPostureOf = nil
local pretendUp = nil

local function fatigueOf(npc)
    local ok, v = pcall(function() return npc:getStats():get(CharacterStat.FATIGUE) end)
    if ok and type(v) == "number" then return v end
    return 0
end


-- True when the NPC is in no state to attack: sitting, lying, in bed, down,
-- or still playing the get-up animation.  Getting up matters for guns: the
-- engine clears isOnFloor()/isKnockedDown() before the get-up anim finishes,
-- so a shot started in that window plays no shooting animation and only the
-- fallback timer lands it.  Standing in a seat is left alone (shooting from a
-- car goes another path).
local function blocksSwing(npc)
    if npc:getVehicle() ~= nil then return false end
    if npc.isGettingUp and npc:isGettingUp() then return true end
    if LOS.isDown and LOS.isDown(npc) then return true end
    local p = (LOS.postureOf and LOS.postureOf(npc)) or "up"
    return p ~= "up" and p ~= "seat"
end


---------------------------------------------------------------------------
-- Fatigue curves
---------------------------------------------------------------------------
-- Fatigue only changes fights against people.  A tired companion still has
-- to be able to defend the base from the dead, so zombie fights are left with
-- the shipped numbers.
local function isPerson(target)
    if not target then return false end
    if instanceof(target, "IsoPlayer") then return true end
    return LOS.idOf ~= nil and LOS.idOf(target) ~= nil
end


-- Four steps, like the four tiredness moodle levels.  The boundaries are not
-- the moodle numbers: they are spread evenly from the configured threshold to
-- 100, so changing the threshold moves all of them.  (0.60 / 0.70 / 0.80 /
-- 0.90 with the defaults.)
local TIRED_STEPS = 4

local function tiredStep(f)
    local from = pct("tiredFrom", 60)
    if f < from then return 0 end
    local band = math.max(0.01, 1 - from) / TIRED_STEPS
    return math.min(TIRED_STEPS, math.floor((f - from) / band + 1e-7) + 1)
end


-- Damage lost at each step, slewed straight from "lost at the threshold" to
-- "lost at 100" (50 % to 85 % by default), so the two middle steps are the
-- even in-between values: x0.50, x0.38, x0.27, x0.15.
local function tiredReduction(f)
    local step = tiredStep(f)
    if step <= 0 then return 0 end
    local start, most = pct("tiredDamageStart", 50), pct("tiredDamageMost", 85)
    return start + (most - start) * (step - 1) / (TIRED_STEPS - 1)
end


local function tiredDamageMult(f)
    if not flag("tiredDamage", true) then return 1 end
    return math.max(0.02, 1 - tiredReduction(f))
end


local function tiredMissChance(f)
    if not flag("tiredMiss", false) then return 0 end
    local step = tiredStep(f)
    if step <= 0 then return 0 end
    return pct("tiredMissMost", 50) * (step - 1) / (TIRED_STEPS - 1)
end


---------------------------------------------------------------------------
-- No attack from the ground (melee or gun)
---------------------------------------------------------------------------
-- beginAttack() only looked at the *target's* posture, so a seated or lying
-- NPC landed a normal standing swing or shot.  Refusing the start leaves the
-- brain's own stand-up path to get it on its feet; the attack happens after
-- that.  Guns are included: a shot started while sitting or getting up plays
-- no shooting animation, and only the hit fallback timer lands it.
-- If the NPC is still in no state to attack after a second, the action is
-- finished so the brain can take over (never a locked aim pose).  One second
-- is the length of a stand-up; less than that would thrash the action queue.
local DOWN_WAIT_MS = 1000

local function beginAttackPatched(self, now)
    local npc = self.character
    if flag("standingOnly", true) and npc and blocksSwing(npc) then
        self.nextAttack = now + 300
        local since = self.patchDownSince or now
        self.patchDownSince = since
        if now - since >= DOWN_WAIT_MS then
            self.patchDownSince = nil
            if self.forceComplete then self:forceComplete() end
        end
        return
    end
    self.patchDownSince = nil
    return UPSTREAM_BEGIN and UPSTREAM_BEGIN(self, now)
end


---------------------------------------------------------------------------
-- A shot cannot land from the ground either
---------------------------------------------------------------------------
-- The start gate covers attacks that begin while the NPC is down.  This
-- catches the other order: the attack began on its feet and the NPC was put
-- down during the wind-up, so the fallback timer would land a shot with no
-- shooting animation.  resolveHit never runs, so the round is not spent.
local function hitPatched(self, source)
    if self.ranged and flag("standingOnly", true) and self.character and blocksSwing(self.character) then
        self.hitDone = true
        LOS.log("PATCH npc=%s shot dropped (%s): it was not on its feet",
            tostring(LOS.idOf(self.character)), tostring(source))
        return
    end
    return UPSTREAM_HIT and UPSTREAM_HIT(self, source)
end


---------------------------------------------------------------------------
-- Melee hits (a copy of the shipped resolveHit melee path)
---------------------------------------------------------------------------
-- The shipped function rolls dmg from the weapon and hands it straight to
-- Hit(), so there is no hook to scale it.  Ranged shots still go upstream.
local playerHits = {}
local function readPlayerHits()
    if #playerHits == 0 then return end
    local now = getTimestampMs()
    local player = getSpecificPlayer(0)
    local keep = {}
    for _, h in ipairs(playerHits) do
        if now - h.at >= 500 then
            if player then LOS.log("ATTACK npc=%s's hit on the player, half a second on: health %.3f -> %.3f", h.id, h.hp0, LOS.hp(player)) end
        else
            table.insert(keep, h)
        end
    end
    for i = #playerHits, 1, -1 do playerHits[i] = nil end
    for _, h in ipairs(keep) do table.insert(playerHits, h) end
end


local function meleeHit(npc, target, w, source, reaction)
    local id = tostring(LOS.idOf(npc))
    local dist = npc:DistTo(target)
    local reach = (reaction == "Floor") and (LOS.MELEE_REACH + 0.3) or LOS.MELEE_REACH
    if dist > reach or LOS.floorApart(npc, target) then
        if LOS.Stamina then LOS.Stamina.swing(npc, target, w, 0) end
        LOS.log("ATTACK npc=%s swing miss (%s) dist=%.1f", id, source, dist)
        return false
    end

    local f = fatigueOf(npc)
    local hurts = isPerson(target)
    local miss = hurts and tiredMissChance(f) or 0
    if miss > 0 and ZombRandFloat(0, 1) < miss then
        if LOS.Stamina then LOS.Stamina.swing(npc, target, w, 0) end
        LOS.log("ATTACK npc=%s swing miss (%s) dist=%.1f; too tired (fatigue %.2f, %d%% off)", id, source, dist, f,
            math.floor(miss * 100 + 0.5))
        return false
    end

    local dmg = w:getMinDamage() + (w:getMaxDamage() - w:getMinDamage()) * ZombRandFloat(0, 1)
    local mult = hurts and tiredDamageMult(f) or 1
    dmg = dmg * mult

    local hp0 = LOS.hp(target)
    local crit, side = false, nil
    if instanceof(target, "IsoZombie") then
        side = LOS.hitSides(npc, target)
        npc:setVariable("ZombieHitReaction", reaction or "")
        local critChance = npc:calculateCritChance(target)
        crit = type(critChance) == "number" and ZombRand(100) < critChance
        npc:setCriticalHit(crit)
        if reaction == "Floor" then LOS.spatter(target, w) end
    elseif reaction then
        target:setHitReaction(reaction)
    end

    local lent = LOS.AimMode ~= nil and LOS.AimMode.lend(npc, w)
    local wasParts = (target == getSpecificPlayer(0) and LOS.partsHealth) and LOS.partsHealth(target) or nil

    target:Hit(w, npc, dmg, false, 1.0)
    if wasParts and LOS.hardenBlow then LOS.hardenBlow(target, wasParts) end

    local hs = w:getZombieHitSound()
    if hs and hs ~= "" then npc:playSound(hs) end
    if LOS.Stamina then LOS.Stamina.swing(npc, target, w, dmg) end
    if lent then LOS.AimMode.takeBack(npc) end
    if instanceof(target, "IsoZombie") then
        if LOS.Learn then LOS.Learn.hitDead(npc, target) end
        npc:clearVariable("ZombieHitReaction")
        npc:setCriticalHit(false)
        if LOS.bloodAfterHit then LOS.bloodAfterHit(npc, target, w) end
    end
    if LOS.Skills then LOS.Skills.onHit(npc, w, target, dmg) end

    LOS.log("ATTACK npc=%s swing hit (%s) %s%s dist=%.1f dmg=%.2f target hp %.3f -> %.3f%s%s", id, source,
        tostring(reaction), crit and " CRITICAL" or "", dist, dmg, hp0, LOS.hp(target),
        side and ("; from its " .. side) or "",
        mult < 0.999 and string.format("; weakened by fatigue %.2f (x%.2f)", f, mult) or "")
    if target == getSpecificPlayer(0) then
        table.insert(playerHits, { id = id, hp0 = hp0, at = getTimestampMs() })
    end
    return true
end


local function resolveHitPatched(npc, target, w, source, reaction)
    if w and w:isRanged() then
        if not UPSTREAM_RESOLVE then return false end
        return UPSTREAM_RESOLVE(npc, target, w, source, reaction)
    end
    return meleeHit(npc, target, w, source, reaction)
end


---------------------------------------------------------------------------
-- The extra blow damage on the player
---------------------------------------------------------------------------
-- Same loop as LOS.hardenBlow, but the multiplier comes from the sandbox.
-- Nothing is added for fatigue here on purpose: the extra damage is a
-- multiplier of the part damage that Hit() already applied, and that damage
-- has been through the fatigue rule in meleeHit, so a tired NPC's extra blow
-- is already a tired extra blow (x3 becomes x1.5 when the blow is halved).
-- Calls from LOS_Die (an NPC's own death blow) use the same multiplier.
local function hardenBlowPatched(chr, was)
    if not (chr and was) then return false end
    if not flag("hardenBlow", true) then return false end
    local mult = pct("hardenBlowPercent", 300)
    if mult <= 1 then return false end
    local bd = chr:getBodyDamage()
    local parts = bd:getBodyParts()
    local hit = false
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        local d = (was[i] or 100) - part:getHealth()
        if d > 0 then
            part:SetHealth(math.max(0, part:getHealth() - d * (mult - 1)))
            hit = true
        end
    end
    if hit then bd:calculateOverallHealth() end
    return hit
end


---------------------------------------------------------------------------
-- Hits on an NPC that is already down
---------------------------------------------------------------------------
-- LOS_HitReact stops every reaction for a posture that is not "up", so a
-- downed NPC could only be hit, never staggered again.  This rolls a chance
-- and runs the shipped knockdown reaction anyway (crit = it counts as a
-- critical blow, which is the branch that knocks a character down).
local function postureProxy(npc)
    if npc == pretendUp then return "up" end
    if realPostureOf then return realPostureOf(npc) end
    return "up"
end


local function staggerDown(target, by, weapon, damage)
    if not flag("staggerDown", true) then return end
    local chance = num("staggerDownChance", 30)
    if chance <= 0 or ZombRand(100) >= chance then return end
    if not (LOS.HitReact and LOS.HitReact.hit) then return end
    local id = LOS.idOf and LOS.idOf(target)
    if not id then return end   -- players and zombies have their own knockdown
    local how = {
        cause = "blow", weapon = weapon, damage = damage, crit = true, game = true,
        swing = (LOS.swingOf and by) and LOS.swingOf(by, target) or nil,
        gait = LOS.gaitOf and LOS.gaitOf(target) or nil,
    }
    LOS.HitReact.drop(target, "staggered by the patch")
    pretendUp = target
    local ok, applied = pcall(LOS.HitReact.hit, target, by, how, nil)
    pretendUp = nil
    if not ok then
        LOS.log("PATCH npc=%s stagger failed: %s", tostring(id), tostring(applied))
    elseif applied then
        LOS.log("PATCH npc=%d knocked down again by a hit (%d%% chance)", id, math.floor(chance + 0.5))
    end
end


-- Only a body that is really on the ground: sitting on a bench or lying in
-- bed is left to the brain, it is not a knockdown.
local function isDownNow(target)
    if LOS.isDown and LOS.isDown(target) then return true end
    local p = LOS.postureOf and LOS.postureOf(target)
    return p == "floor" or p == "lying"
end


---------------------------------------------------------------------------
-- One handler for both evening jobs
---------------------------------------------------------------------------
-- Run on the next tick, not inside the weapon hit: waking a sleeper and
-- setting a knockdown both clear the NPC's action queue, and the game is
-- still applying the blow at this point.
local pending = {}

local function onWeaponHit(wielder, target, weapon, damage)
    if not target then return end
    pending[#pending + 1] = { target = target, by = wielder, weapon = weapon, damage = damage }
end


local function drainPending()
    if #pending == 0 then return end
    local list = pending
    pending = {}
    for _, h in ipairs(list) do
        local target = h.target
        if target and not target:isDead() then
            local woke = false
            if flag("wakeOnHit", true) then
                local id = LOS.idOf and LOS.idOf(target)
                local br = id and LOS.Brain and LOS.Brain.get and LOS.Brain.get(id)
                if br and br.asleep and LOS.Sleep and LOS.Sleep.wake then
                    LOS.Sleep.wake(id, target, br, "hurt", true)
                    LOS.log("PATCH npc=%d woken by a hit", id)
                    woke = true
                end
            end
            if not woke and isDownNow(target) then staggerDown(target, h.by, h.weapon, h.damage) end
        end
    end
end


---------------------------------------------------------------------------
-- Install / re-install (mod load order safety)
---------------------------------------------------------------------------
local function install()
    if not (LOS and LOSEngage) then return end

    if LOSEngage.beginAttack ~= beginAttackPatched then
        if not UPSTREAM_BEGIN then UPSTREAM_BEGIN = LOSEngage.beginAttack end
        LOSEngage.beginAttack = beginAttackPatched
    end

    if LOSEngage.hit ~= hitPatched then
        if not UPSTREAM_HIT then UPSTREAM_HIT = LOSEngage.hit end
        LOSEngage.hit = hitPatched
    end

    if LOS.resolveHit ~= resolveHitPatched then
        if not UPSTREAM_RESOLVE then UPSTREAM_RESOLVE = LOS.resolveHit end
        LOS.resolveHit = resolveHitPatched
    end

    if LOS.hardenBlow ~= hardenBlowPatched then
        LOS.hardenBlow = hardenBlowPatched
    end

    if LOS.postureOf and LOS.postureOf ~= postureProxy then
        realPostureOf = LOS.postureOf
        LOS.postureOf = postureProxy
    end

    if not hooked and Events and Events.OnWeaponHitCharacter then
        hooked = true
        Events.OnWeaponHitCharacter.Add(LOS.handler("PatchCombat.onWeaponHit", onWeaponHit))
        Events.OnTick.Add(LOS.handler("PatchCombat.drainPending", drainPending))
        Events.OnTick.Add(LOS.handler("PatchCombat.readPlayerHits", readPlayerHits))
    end
end

install()
Events.OnGameBoot.Add(install)
Events.OnGameStart.Add(install)

LOS.log("PATCH combat loaded: no attacks from a bed, chair, the ground or while getting up, fatigue weakens blows on people, hits wake sleepers, hits can keep an NPC down")
