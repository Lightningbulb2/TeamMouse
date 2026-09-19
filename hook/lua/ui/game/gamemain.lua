--******************************************************************************
--** SharedMouse2026 -- hook/lua/ui/game/gamemain.lua
--**
--** Entry points. This file is hooked into the gamemain module's own scope, so
--** AddBeatFunction, RemoveBeatFunction and friends are reachable directly
--** here. They are NOT reachable from modules/sharedmouse.lua, which lives in
--** its own module table -- anything it needs from gamemain it must import.
--******************************************************************************

local SharedMouse = import('/mods/SharedMouse2026/modules/sharedmouse.lua')

--- Named key so RemoveBeatFunction can find it again on teardown.
local beatKey = 'SharedMouse2026'

local function SharedMouseBeat()
    SharedMouse.OnBeat()
end

local sharedMouseOriginalCreateUI = CreateUI
function CreateUI(isReplay)
    sharedMouseOriginalCreateUI(isReplay)

    local ok, err = pcall(function()
        SharedMouse.InitSharedMouse(isReplay)

        -- throttle = true caps this at ten calls a second. Without it the
        -- callback runs on every sim beat, so at high sim speed or during
        -- replay fast-forward it fires far more often than the network
        -- update rate needs.
        AddBeatFunction(SharedMouseBeat, true, beatKey)

        -- Proper teardown hook. Note that gamemain has no OnDestroy of its
        -- own to wrap -- defining one would create a function nothing ever
        -- calls, which is why the previous attempt at this was commented out.
        AddOnUIDestroyedFunction(function()
            pcall(function()
                RemoveBeatFunction(SharedMouseBeat, beatKey)
                SharedMouse.Destroy()
            end)
        end)
    end)

    if not ok then
        LOG('SharedMouse2026: startup failed, mod disabled for this session: ' .. tostring(err))
    end
end

--- Layout changes destroy and recreate the world views, so every cursor needs
--- reparenting onto the new ones.
local sharedMouseOriginalSetLayout = SetLayout
function SetLayout(layout)
    sharedMouseOriginalSetLayout(layout)

    local ok, err = pcall(function()
        SharedMouse.SyncViews()
    end)

    if not ok then
        LOG('SharedMouse2026: SetLayout sync failed: ' .. tostring(err))
    end
end
