--******************************************************************************
--** TeamMouse -- hook/lua/ui/game/commandmode.lua
--**
--** The engine calls OnCommandIssued once for every command the player really
--** issues -- one per structure placed, with its blueprint and position. A
--** placement the engine refuses (a bad spot, say) issues nothing. That is how
--** TeamMouse tells a structure that was placed from one that only looked
--** like it would be, so teammates are not shown buildings that never happened.
--**
--** No import here, on purpose: this file becomes part of commandmode.lua,
--** which gamemain imports, and teammouse.lua imports gamemain. Anything this
--** file imported would join that chain (see "import() and circular
--** dependency" in extras/references/engine-gotchas.md). teammouse.lua parks
--** its listener on _G instead, and takes it away on teardown.
--******************************************************************************

--- Present from load: lets teammouse.lua know the hook is in place at all.
rawset(_G, 'TeamMouseCommandHook', true)

local TeamMouseOriginalOnCommandIssued = OnCommandIssued

function OnCommandIssued(command)
    local listener = rawget(_G, 'TeamMouseOnCommandIssued')
    if listener then
        -- Never let the mod get in the way of an order being given.
        pcall(listener, command)
    end
    return TeamMouseOriginalOnCommandIssued(command)
end
