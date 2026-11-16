# Patch notes

Everything this mod changes in **Last Ones Standing**, written for the mod's
author and for anyone reviewing the patch before installing it.

- Base: **Last Ones Standing 0.2.292-dev** (`LastOnesStanding.VERSION`), Project Zomboid **42.22.2** (`3d39148846`).
- The three files marked *patched copy* below are the shipped file with the fix
  inline, rebased line by line. Everything else is added on top of the shipped
  files, which are not edited.
- `PATCH:` comments in the source point at each change, and the
  `*Patched.lua` files are the shipped file with the fix inline.
- The mod turns itself off when `LastOnesStanding.VERSION` is not the version
  above. See **Version guard** at the end.

---

## 1.0.1 — 16 November 2026

First Workshop build as 1.0.0 on 15 November; this rebuild adds the gun and
getting-up gate, the circling fix and the Hop It! note.

### Combat

**Attacks from the floor, a bed, a chair or while knocked down.**
`LOS_Engage:isValid()`/`beginAttack()` only checked the *target's* posture, so
an NPC lying on the floor, asleep in bed or sitting on a chair landed a normal
standing swing or shot. That is how a sleeping NPC killed a player in one bat
hit.
The patch refuses to start a melee swing or a shot unless the attacker is
genuinely on its feet, and leaves the brain's own stand-up path to get it
there. If it is still unable to attack after one second, the attack action is
finished so the brain regains its action slot (previously the aim pose held the
slot and the NPC took seconds to stand up). *Sandbox: `standingOnly`.*

**Shots from the ground, and shots with no animation** *(untested)*. Guns went
through the same `beginAttack()` without that posture check, so a survivor that
the player had just knocked sitting on the ground drew a rifle and shot the
player dead while its get-up animation was playing; the follow-up shot landed
after it stood with no shooting animation either. The engine clears
`isOnFloor()`/`isKnockedDown()` before the get-up animation ends, so
`postureOf()` already said "up" while `Bob_GetUp_*` was still playing — a shot
started in that window played no animation, and only the hit fallback timer
landed it. The gate now also refuses a shot while the NPC is sitting, lying,
knocked down or `isGettingUp()`, and `LOSEngage:hit` drops a shot whose shooter
was put down during the wind-up instead of resolving it from the floor (the
round is not spent, because `resolveHit` never runs).

**Melee damage ignored fatigue.**
`LOS_Combat`'s melee path rolls `dmg` from the weapon and hands it straight to
`Hit()`; there is no fatigue, endurance or skill term. An exhausted NPC hit as
hard as a fresh one. The patch uses a copy of the shipped melee `resolveHit`
(ranged shots still go to the shipped function, because `dmg` is computed and
applied inside it) and scales the blow against **people only** — fights with
the dead keep the shipped numbers, so a tired companion can still defend the
base.

The curve has four steps, like the tiredness moodle, but the boundaries are
computed from the configured threshold instead of copied from the moodle:

```
band      = (100 - threshold) / 4
step      = 1 + floor((fatigue - threshold) / band)      -- 0 below the threshold
reduction = start + (most - start) * (step - 1) / 3
```

Defaults (threshold 60, first step 50 %, last step 85 %):

| Fatigue | Step | Blow lands at | The mod's 3× extra hit lands at |
|---|---|---|---|
| below 0.60 | — | 100 % | 300 % |
| 0.60–0.69 | 1 | 50 % | 150 % |
| 0.70–0.79 | 2 | 38 % | 115 % |
| 0.80–0.89 | 3 | 27 % | 80 % |
| 0.90–1.00 | 4 | 15 % | 45 % |

Changing the threshold moves all four boundaries; changing the two end values
changes only the damage. *Sandbox: `tiredDamage`, `tiredFrom`,
`tiredDamageStart`, `tiredDamageMost`.*

**Optional miss chance on top of the damage penalty.**
Same four boundaries, zero on the first step and the configured figure on the
last. Off by default, because the aim was to weaken the blow rather than make
the NPC flail. *Sandbox: `tiredMiss`, `tiredMissMost`.*

**The 3× extra blow on the player is now configurable and obeys fatigue.**
`LOS.hardenBlow` (`LOS_Die`, `BLOW_MULT = 3`) takes the damage the game just
dealt to each body part and subtracts another `2 ×` of it. The patch replaces
the multiplier with a sandbox value (300 % = shipped) and applies it to the
damage `Hit()` already applied, i.e. after the fatigue rule, so a halved blow's
extra hit is halved too (3× becomes 1.5× at fatigue 0.60) without a second
option. The same replacement is used by the NPC death-blow path, which has no
attacker context. *Sandbox: `hardenBlow`, `hardenBlowPercent`.*

### Downed and sleeping NPCs

**A hit wakes a sleeper.** A hit used to be added to health with no reaction
while the NPC kept sleeping (six hits in the reported fight, no wake). Hits now
wake the NPC at once through `LOS.Sleep.wake(..., "hurt")`. *Sandbox: `wakeOnHit`.*

**A hit can keep an already-downed NPC down.** `LOS.HitReact.hit` returns
immediately for any posture other than `"up"`, so a downed NPC could be hit but
never staggered again, and stood up after its timer regardless. The patch rolls
a chance and runs the shipped knockdown reaction anyway (using the shipped
`Hr.drop`, with `crit = true`, which is the branch that knocks a character
down), only for LOS NPCs that are really on the floor — sitting on a bench or
lying in bed is left to the brain. It runs on the next tick, not inside the
blow, because both waking and knocking down clear the action queue. *Sandbox:
`staggerDown`, `staggerDownChance`.*

### Tidy and storage — *patched copy of `LOS_Tidy`*

**Carrying 125 % of the weight limit.** `HAUL_FREE = 1.25` let a companion load
itself past its maximum and then sit there ("it can carry no more") when a walk
failed. It is 1.0 now.

**Walk said "here", the action refused the distance, forever.** `walkTo()`
reports arrival within `ARRIVE` (1.6) of the stand square, but `LOSLoot` and
`LOSPickUp` refuse beyond 2.0/1.8 of the object itself. A stand on the far
corner queued an action the game threw away every tick ("goes to take out" for
thousands of lines). The patch measures distance to the object, takes one step
to the nearest standable square beside it, and only once per job; a watchdog
catches the rest.

**Broken glass was invisible to tidy** *(untested)*. `IsoBrokenGlass` is a world object, not
an inventory item, so the floor scan never saw it. The base is swept for glass
when there is nothing else to do, using the game's pickup actions; the resulting
`Base.BrokenGlass` inventory item goes through normal put-away, and stray pieces
are removed from the inventory so they cannot be dropped on the floor or filed
in a cupboard.

**Full containers kept attracting jobs.** Containers were chosen by label only,
never by free space, so a full crate kept winning jobs that then gave up, and
"Anything" boxes were treated as a first choice. Containers are ranked now:
marked for that kind first, then a parent/food mark, then Anything; only boxes
with real room are considered; Anything is only emptied when a marked box has
room, which also ends the Anything → Anything take-out/put-back loop; and no
more is queued than the destination can hold.

**Heavy loads were never put down.** A companion that looted planks, bleach or
tins and was then given chores had no way to put the load down — only things it
had picked up for tidying were ever considered — so it stayed at 20+ of 12
weight and tidy could never pick anything up. Over the weight limit it now sheds
ordinary carried things too, not only loot marked `LOS_Haul` (starting kits have
no such mark). Only bulky, easily replaced kinds may be set on the floor: a
radio, a tool, a weapon or personal things are never dropped to make room.

**Tools stayed in hand.** Hammers, saws and screwdrivers were only unequipped
into the inventory, never put away, so the player had to keep taking them back —
and a hammer kept in hand after boarding blocked later board jobs. They are
stored now, even from the hand.

**Jobs the game refused, remade every tick.** A job that is made four times in
half a minute without ever reaching the action queue is blacklisted for ten
minutes, so chores fall through to the next kind of work. Stale scans are
re-read instead of remaking the same job.

### Objectives and hauling — *patched copy of `LOS_Objectives`*

**Walker restarted on every brain tick.** `ctx.orderMove()` was called every
tick, clearing the queue and starting a fresh `LOSWalkTo` over and over;
pathfinding never got a chance to run, and two quick re-orders made `walkSpent()`
give up on a container a few tiles away. The patch checks whether a walker for
that job is already on its way (90 s give-up window), and does not sprint while
looking after the base unless the distance really needs it — the old rule was a
flat "more than 15 tiles", which sent companions charging across the base and
out to the composter.

**One full box marked the whole storage "full" for an hour.** A tidy put-away
that leaves a thing or two behind means one container is full, not the base.
Tidy marks that container itself; only a real haul trip that could not finish
marks the group's storage full. Loads are also split by what each container can
actually take (`batchFor`), instead of handing the whole load to one box and
reporting the leftovers as "full".

**Wrong container for the load.** The old order added the main storage before
most marks, so a full building-materials crate sent planks into an Anything
shelf that tidy then emptied straight back out. The container marked for the
load's kind is tried first, then a parent mark, then Anything. Composters and
bins are not places for carrying things. There is no blanket fall back to the
main storage, because the ranking already includes it last.

**Empty bottles were only searched for in the main storage.** Bottles kept in
any other marked box in the base were invisible, so companions stood about
saying there were none. The patch looks through the group's marked containers,
then the building the job is in, and rescans if the box changed while walking.

### Living and the house — *patched copy of `LOS_Living`*

**Food was only accepted if it carried a `LOS_StockOf` stamp.** A group could
starve in a house full of player-dropped or pre-existing food. Ordinary food is
accepted now, but nothing is ever taken from a container the player marked
private, and ordinary water counts.

**Over-assigned containers.** `hasRoomFor()` only sees what is already inside a
container, not what is planned for it, so a batch could be over-assigned and fail
on arrival. Reserved weight per container is tracked while planning.

### Base life — *additions in `LOS_LivingExtras`*

- **Companions hopping over every piece of furniture (with *Hop It!*).**
  `isFree(false)` is true for counters, shelves and beds (solidtrans without
  solid), so LOS kept choosing them as stand squares. *Hop It!* treats those
  squares as obstacles, so the NPC hopped over — or onto — every piece of
  furniture between it and the spot, then arrived somewhere it could not work
  from and jammed. Stand squares now use the same standability test *Hop It!*
  uses for its obstacles, so furniture is never picked as somewhere to stand,
  and the nearest standable square is searched in rings instead of
  `walkableSquare()` picking at random.
- **Hold squares recorded on furniture.** `LOS.Orders.give()` stored the current
  square as the place to return to; from a chair or counter every "wait" return
  ordered a walk the pathfinder refuses, and the companion collected orders
  forever. The recorded hold square is repaired before shipped code uses it.
- **Pacing in circles over furniture, unable to wait where it was told**
  *(untested)*. A wait or guard order remembers the square the companion stood
  on, and `backTo()`
  sends it back there every few seconds. If that square becomes unreachable
  while the companion is still close to it — *Hop It!* hopped it out of the
  room, a door shut behind it, furniture was pushed across — every one of those
  orders is a path request the game refuses. The companion paces, hops
  furniture and never settles, and the stuck watchdog eventually sets it aside
  for a minute. Once a return walk has failed for good, the recorded spot moves
  to the square it is standing on, so it waits there instead. Wait posts on a
  wall line are left alone, because they are where walls get built.
- **Couches as beds.** Some couches have no sprite grid, so only one tile was
  recorded; the get-in animation lies the character on a neighbouring tile of the
  same couch, the shipped check called that "off its bed" and the companion got
  up to sleep on the floor. A character in bed, next to the bed it chose and on
  the same floor counts as in bed, whichever tile it lies on. Bed start also no
  longer offers the two corners beside the bed, which the get-in animation cannot
  line up (it works from the side).
- **A break taken while dead on its feet becomes sleep.** A break scores above
  everything else while it is on, so a companion that sat down exhausted could
  never recover.
- **Bins outside the base as cupboards.** The player's faction keeps every
  container mark ever made; marks outside the base are no longer used for storage.
- **Unopened tins count as food** when scavenging (they have no hunger value until
  the opening recipe is used).
- **Home inside the base.** `homeContainers()` returned nil when the group's home
  lay inside the base, so the house was ignored; the home is used either way.
- **Bodies.** The picker started 20 tiles outside the *whole base bounds* and
  could choose unloaded squares; bodies are put down close by, on a loaded square.
- **Cleaning** looks through every container in the base, not just the main one.
- **Boarding** finds materials in any container in the base's building, and boards
  the window from the other side when the square inside the building is furniture
  instead of declaring it unreachable.
- **Salvaging** no longer wanders 40 tiles out of the base looking for things.
- **Doors.** `goRound()` only handled locked doors; ordinary closed doors inside
  the base are opened instead of standing at them. A walker whose current square
  is blocked (a door square, a bed, a pushed-about square) steps off before
  pathing instead of failing every request.

### Metadata and safety

- Name: **Last Ones Standing Sloppy Expansion and Fixes**; mod id
  `LastOnesStandingSloppyExpansion`; `modversion` 1.0.1.
- Sandbox page **Sloppy Expansion and Fixes** (`SloppyExpansion`), 13 options,
  English labels and tooltips in `42/media/lua/shared/Translate/EN/Sandbox.json`.
- **Version guard** (`LOS_PatchGuard.lua`): the patch was written for
  `LastOnesStanding.VERSION = "0.2.292-dev"`. On any other version every file of
  the patch returns immediately, `console.txt` gets one `SLOPPY PATCH DISABLED:`
  line, and the game runs Last Ones Standing as shipped. Nothing needs to be
  uninstalled and saves are untouched. The sandbox option
  **`forceOn`** (off by default, labelled as testing-only) runs the patch anyway
  on an untested version.
- The three whole-file copies are no longer installed at the shipped paths
  (`LOS_Living.lua`, `LOS_Objectives.lua`, `LOS_Tidy.lua`). They are
  `LOS_LivingPatched.lua`, `LOS_ObjectivesPatched.lua`, `LOS_TidyPatched.lua`
  and apply after the shipped file, which is what makes the version guard
  possible: an old patch leaves the shipped file in place instead of replacing
  it.
