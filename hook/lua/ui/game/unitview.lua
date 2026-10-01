--******************************************************************************
--** TeamMouse -- hook/lua/ui/game/unitview.lua
--**
--** Caches commander units as they are rolled over, for the optional replay
--** codec in modules/replaycodec.lua.
--**
--** Only useful when the replay codec is on. During replay
--** playback GetArmyAvatars only reaches the army you are currently observing,
--** so reading any other army's commander name depends on having seen that
--** commander at some point. That is a real limitation of the approach, not
--** something this hook can fix; it just widens the coverage a little.
--**
--** The cache lives on _G under a namespaced key so the module can reach it
--** without importing this hooked file.
--******************************************************************************

rawset(_G, 'TeamMouseCommanders', rawget(_G, 'TeamMouseCommanders') or {})

local TeamMouseOriginalSetupUnitViewLayout = SetupUnitViewLayout
function SetupUnitViewLayout(parent, orderControl)
    TeamMouseOriginalSetupUnitViewLayout(parent, orderControl)

    -- UpdateWindow is defined by the time the layout is set up, so it is safe
    -- to wrap here but not at file scope.
    local TeamMouseOriginalUpdateWindow = UpdateWindow
    function UpdateWindow(info)
        if TeamMouseOriginalUpdateWindow then
            TeamMouseOriginalUpdateWindow(info)
        end

        -- Cheap enough to keep whether or not the codec is on this game
        -- (it may be switched on by the lobby option, which this hook,
        -- importing nothing of the mod's but its config, cannot see).
        pcall(function()
            if not info or not info.userUnit then
                return
            end
            local unit = info.userUnit
            local bp = unit:GetBlueprint()
            if bp and bp.CategoriesHash and bp.CategoriesHash.COMMAND then
                local cache = rawget(_G, 'TeamMouseCommanders')
                if cache then
                    cache[unit:GetArmy()] = unit
                end
            end
        end)
    end
end
