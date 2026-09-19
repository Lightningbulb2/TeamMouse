--******************************************************************************
--** TeamMouse -- hook/lua/ui/game/unitview.lua
--**
--** Caches commander units as they are rolled over, for the optional replay
--** codec in modules/replaycodec.lua.
--**
--** Only useful when Config.ReplayCodec.Enabled is true. During replay
--** playback GetArmyAvatars only reaches the army you are currently observing,
--** so reading any other army's commander name depends on having seen that
--** commander at some point. That is a real limitation of the approach, not
--** something this hook can fix; it just widens the coverage a little.
--**
--** The cache lives on _G under a namespaced key so the module can reach it
--** without importing this hooked file.
--******************************************************************************

local Config = import(_G.TeamMousePath .. '/modules/config.lua')

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

        if not Config.ReplayCodec.Enabled then
            return
        end

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
