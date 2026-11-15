# Last Ones Standing Sloppy Expansion and Fixes

A companion patch for **[Last Ones Standing](https://steamcommunity.com/sharedfiles/filedetails/?id=3830310103)**
(the 1993 survivors sandbox). It fixes the bugs I ran into while playing –
companions swinging from the floor, a 3× extra blow on the player, NPCs not
waking when hit, storage and tidy jobs that give up – without editing the
shipped mod, and it turns itself off when Last Ones Standing changes version so
a stale patch can never break a save.

This is not a fork. It requires Last Ones Standing and loads after it.

- **Base:** Last Ones Standing `0.2.292-dev`
- **Game:** Project Zomboid 42.22.2 (`3d39148846`), `versionMin = 42.21`
- **Every change, with the shipped code it replaces:** [CHANGELOG.md](CHANGELOG.md)

## Disclaimer

This is AI slop. Yes, even this disclaimer. The AI was pointed at bugs and
incomplete behaviours and only moderately kept in check by a human, so read the
diff before you trust it. Use at your own risk — you were warned.

It is also not an exhaustive list of fixes. Last Ones Standing is early and
still being worked on, and this started as a local patch for one playthrough
and one person's tastes. It is public because it might help someone else, and
because the author might see an idea or a bug fix worth implementing properly
in the mod itself.

## Install

1. Subscribe to (or install) **Last Ones Standing**.
2. Copy this folder to `%USERPROFILE%\Zomboid\mods\` so that
   `...\Zomboid\mods\<this folder>\42\mod.info` exists.
3. Enable both mods. Load order is enforced by `require=LastOnesStanding1993`.

The mod id is `LastOnesStandingSloppyExpansion`, so an existing save picks it up
as a new mod. Removing it later is safe: it does not write mod data of its own.

## Version guard

Last Ones Standing is updated often, and this patch rewrites shipped code. On
load it compares `LastOnesStanding.VERSION` with the version it was written for
(`TESTED_VERSION` in `42/media/lua/shared/LastOnesStanding/LOS_PatchGuard.lua`).

| Situation | What happens |
|---|---|
| Versions match | The patch runs normally, with one `SLOPPY PATCH ENABLED` line in `console.txt`. |
| Versions differ | Every file of the patch returns immediately. `console.txt` gets one line: `SLOPPY PATCH DISABLED: Last Ones Standing is X but the patch was written for Y...` The game runs Last Ones Standing exactly as shipped. |
| LOS missing | Same, with `Last Ones Standing is not loaded`. |

Nothing has to be uninstalled while the patch is rebased, and saves are never
touched by a disabled patch. The whole guard is one file; the three whole-file
copies apply *after* the shipped file instead of replacing it, which is what
makes this possible.

**`forceOn`** is a sandbox option on the patch's page (off by default). It runs
the patch on an untested version anyway, for trying a new build before rebasing.
It is labelled testing-only because a mismatch can leave containers or NPCs in
states the patch cannot repair.

## Sandbox page

All tuning lives on its own page, **Sloppy Expansion and Fixes**
(`SandboxVars.SloppyExpansion`). Defaults in brackets.

| Option | Meaning |
|---|---|
| No swings from a seat or the ground [on] | Refuse to start a melee swing unless the NPC is on its feet. |
| Hits wake sleepers [on] | A hit wakes a sleeping NPC at once. |
| Fatigue weakens blows [on] | Melee damage against people drops with the attacker's fatigue. Zombie fights untouched. |
| Fatigue where blows start to weaken (%) [60] | First tiredness moodle. Blows are untouched below it. |
| Damage lost at the first step (%) [50] | First step halves the blow, so the mod's 3× extra hit becomes 1.5×. |
| Damage lost at the last step (%) [85] | At fatigue 100 the blow lands at 15 %. |
| Fatigue makes swings miss [off] | Extra miss chance, same boundaries, on top of the damage penalty. |
| Miss chance at the last step (%) [50] | Miss chance at fatigue 100. |
| Extra blow damage on the player [on] | The mod's extra body-part damage after a melee blow. |
| Extra blow damage (%) [300] | Total multiplier; 300 is the shipped value, 150 half of it. Applied after fatigue. |
| Hits can keep an NPC down [on] | A hit on an NPC already on the floor can knock it down again. |
| Chance to keep them down (%) [30] | Rolled per hit on a downed NPC. |
| Run on an untested Last Ones Standing version [off] | `forceOn`, testing only. |

### Fatigue curve

Four steps, like the tiredness moodle, but the boundaries follow your threshold
instead of copying the moodle's own numbers:

```
band      = (100 - threshold) / 4
step      = 1 + floor((fatigue - threshold) / band)      -- 0 below the threshold
reduction = start + (most - start) * (step - 1) / 3
```

With the defaults the steps land on 0.60 / 0.70 / 0.80 / 0.90, and a blow lands
at 100 % / 50 % / 38 % / 27 % / 15 % of the roll. Raise the threshold to 40 and
the steps move to 0.40 / 0.55 / 0.70 / 0.85 with the same end values.

## Repository layout

```
42/mod.info
42/media/sandbox-options.txt                      sandbox page and options
42/media/lua/shared/LastOnesStanding/
    LOS_PatchGuard.lua                            version guard
42/media/lua/shared/Translate/EN/Sandbox.json     option labels and tooltips
42/media/lua/server/LastOnesStanding/
    LOS_CombatPatch.lua                           combat, fatigue, waking, stagger
    LOS_LivingExtras.lua                          additive fixes (wrapping shipped functions)
    LOS_LivingPatched.lua                         shipped file + inline fixes
    LOS_ObjectivesPatched.lua                     shipped file + inline fixes
    LOS_TidyPatched.lua                           shipped file + inline fixes
```

The `*Patched.lua` files are the shipped file with the fix inline and `PATCH:`
comments on every change. Everything else leaves the shipped files alone and
wraps exported functions.

## Rebasing after a Last Ones Standing update

1. Update the workshop copy of Last Ones Standing.
2. Diff the three `*Patched.lua` files against the new upstream
   `LOS_Living.lua`, `LOS_Objectives.lua` and `LOS_Tidy.lua` (any diff tool, or
   `git diff --no-index upstream.lua 42/.../LOS_TidyPatched.lua`). The `PATCH:`
   comments mark every intended change, so anything else in the diff is new
   upstream code to bring in.
3. Merge the upstream changes into the three `*Patched.lua` files, keeping the
   `PATCH:` comments. Re-check the wrappers in `LOS_LivingExtras.lua` and
   `LOS_CombatPatch.lua` against the changed functions.
4. Set `TESTED_VERSION` in `LOS_PatchGuard.lua` to the new
   `LastOnesStanding.VERSION`, bump `modversion` and add a CHANGELOG entry.
5. In game, check `console.txt` for `SLOPPY PATCH ENABLED`, `PATCH combat
   loaded` and `PATCH living storage/scavenging fixes loaded`, and make sure
   there is no `SLOPPY PATCH DISABLED` line.

Until step 4 is done the patch disables itself, so a rebase can be finished
without anyone losing a save.

## Credit

All original code, design and content belong to the author of Last Ones Standing.
This repository only contains the patch on top, plus the `*Patched.lua` copies
that are shown in full so every change can be reviewed line by line.

## License

No license is granted here for Last Ones Standing's code. The patch changes are
offered for the author to take, adapt or ignore.
