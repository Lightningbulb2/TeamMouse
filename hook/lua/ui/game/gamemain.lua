--******************************************************************************
--** TeamMouse -- hook/lua/ui/game/gamemain.lua
--**
--** Entry points. This file is hooked into the gamemain module's own scope, so
--** AddBeatFunction, RemoveBeatFunction and friends are reachable directly
--** here. They are NOT reachable from modules/teammouse.lua, which lives in
--** its own module table -- anything it needs from gamemain it must import.
--******************************************************************************

_G.TeamMousePath = "/mods/TeamMouse"

local TeamMouse = import(_G.TeamMousePath .. '/modules/teammouse.lua')

--- Named key so RemoveBeatFunction can find it again on teardown.
local beatKey = 'TeamMouse'

local function TeamMouseBeat()
    TeamMouse.OnBeat()
end

local TeamMouseOriginalCreateUI = CreateUI
function CreateUI(isReplay)
    TeamMouseOriginalCreateUI(isReplay)

    local ok, err = pcall(function()
        TeamMouse.InitTeamMouse(isReplay)

        -- throttle = true caps this at ten calls a second. Without it the
        -- callback runs on every sim beat, so at high sim speed or during
        -- replay fast-forward it fires far more often than the network
        -- update rate needs.
        AddBeatFunction(TeamMouseBeat, true, beatKey)

        -- Proper teardown hook. Note that gamemain has no OnDestroy of its
        -- own to wrap -- defining one would create a function nothing ever
        -- calls, which is why the previous attempt at this was commented out.
        AddOnUIDestroyedFunction(function()
            pcall(function()
                RemoveBeatFunction(TeamMouseBeat, beatKey)
                TeamMouse.Destroy()
            end)
        end)
    end)

    if not ok then
        LOG('TeamMouse: startup failed, mod disabled for this session: ' .. tostring(err))
    end
end

--- Layout changes destroy and recreate the world views, so every cursor needs
--- reparenting onto the new ones.
local TeamMouseOriginalSetLayout = SetLayout
function SetLayout(layout)
    TeamMouseOriginalSetLayout(layout)

    local ok, err = pcall(function()
        TeamMouse.SyncViews()
    end)

    if not ok then
        LOG('TeamMouse: SetLayout sync failed: ' .. tostring(err))
    end
end
