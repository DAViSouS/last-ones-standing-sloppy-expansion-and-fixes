-- Last Ones Standing Sloppy Expansion and Fixes
--
-- Last Ones Standing is updated often, and this patch rewrites shipped
-- modules, so an update can leave it editing code that is no longer there.
-- This guard compares the running version with the version the patch was
-- written against.  When they differ, every file of the patch returns at
-- once and the game runs Last Ones Standing exactly as shipped: a stale
-- patch cannot break a save, and nothing has to be uninstalled while the
-- patch is rebased.
--
-- Rebase procedure (also in README.md):
--   1. apply the upstream changes to the *Patched.lua copies;
--   2. run tools/check_upstream.py --accept --yes;
--   3. set TESTED_VERSION below to the new LastOnesStanding.VERSION.
--
-- TESTED_VERSION is the upstream LastOnesStanding.VERSION string, not the
-- game build and not this patch's own modversion.

LastOnesStandingSloppyPatch = LastOnesStandingSloppyPatch or {}
local G = LastOnesStandingSloppyPatch

G.TESTED_VERSION = "0.2.292-dev"


local function report(msg)
    print(msg)
    -- Last Ones Standing keeps its own dev log; write there too when it can.
    local los = LastOnesStanding
    if los and type(los.log) == "function" then
        pcall(los.log, "%s", msg)
    end
end


local function disable(why)
    if G.reason ~= why then
        G.reason = why
        report("SLOPPY PATCH DISABLED: " .. why ..
            ". The patch is not running and Last Ones Standing runs as shipped." ..
            " Rebase the patch, then update TESTED_VERSION in LOS_PatchGuard.lua.")
    end
    return false
end


-- Sandbox option on the patch's own page, for trying a new Last Ones Standing
-- build before the patch is rebased.  Off by default: it is a testing aid,
-- not a supported configuration.
local function forced()
    local page = SandboxVars and SandboxVars.SloppyExpansion
    return type(page) == "table" and page.forceOn == true
end


-- True when the patch may run.  Every file of the patch calls this once on
-- load, and the wrappers call it again when they install at game start.
function G.active()
    local los = LastOnesStanding
    if not los then return disable("Last Ones Standing is not loaded") end
    local v = los.VERSION
    if not v then return disable("Last Ones Standing reports no VERSION") end
    if v == G.TESTED_VERSION then
        if not G.once then
            G.once = true
            report("SLOPPY PATCH ENABLED: Last Ones Standing " .. v ..
                " matches TESTED_VERSION.")
        end
        return true
    end

    if forced() then
        if not G.forcedNoted then
            G.forcedNoted = true
            report("SLOPPY PATCH FORCED ON: Last Ones Standing is " .. tostring(v) ..
                " but the patch was written for " .. G.TESTED_VERSION ..
                ". The force option is on, so the patch runs anyway; expect breakage.")
        end
        return true
    end

    return disable("Last Ones Standing is " .. tostring(v) ..
        " but the patch was written for " .. G.TESTED_VERSION)
end
